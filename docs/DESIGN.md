# Design

Current architecture for the rework. Inspiratio is the framework (the submission, built during the event); Illunis is the pre-event
showcase app it was built on top of ([NEW_WORK.md](../NEW_WORK.md)). Status labels:
BUILT (in code, covered by tests), PLANNED (plan only, no code), NOT BUILT (neither). Section 9 gives the current
status. The showcase app, including its sky and visual asset notes, lives in
[examples/illunis/](../examples/illunis/README.md).

---

## 1. System

```
phone (Flutter, Android first)
  voice in: wake word, speech to text          text fallback: typed chat
  short-term memory on the phone (conversation + last 5 session summaries)
  long-term memory: one MemoryBackend interface
  Health Connect reader, check-ins, chat approval card (no settings screen)
        |  HTTPS, device token
        v
Worker (Cloudflare, server/)
  guards: data mode, crisis referral, rule-based safety gate
  spec: one JSON spec per deploy (propose, diff, approve, enforce)
  reply, streaming reply, session summary, 21-day analysis
  council: experts (base models + RAG) -> aggregator (the brain's model)
  assistant bridge (routes to the chosen brain)
        |
        v
brain: Meta Muse, Muse Spark Open on Baseten, or Nebius (section 2)
        |
        v
answer + sources  ->  speech out (on-device Kokoro) or text
```

Routes and their request shapes: [server/src/worker.js](../server/src/worker.js) and
[server/src/index.js](../server/src/index.js). Hermes contract: [integrations/hermes/CONTRACT.md](../integrations/hermes/CONTRACT.md).

---

## 2. Brain and memory options

Brain and memory are separate choices in the spec (`server/src/spec/schema.js`).

**Brain** (`spec.brain`: `auto`, `meta`, `baseten`, `nebius`). `server/src/council/provider.js` tries Meta, then
Baseten, then Nebius; a set preference moves that provider first, and an unconfigured provider is skipped. This
is fallback, not cross-checking (the optional cross-check is section 3.3).

Live-test caveats for the Meta demo deploy: Muse is not the whole demo. When a Muse call fails, the council falls
back to Nemotron on Nebius. Food-log parsing and embeddings do not run on Muse (the deploy keeps embeddings on
Nebius). The model behind the live Hermes bot is unverified.

| Brain | Model | Status |
|---|---|---|
| Meta Muse API | `muse-spark-1.3` (set by `META_MODEL`, standard tier; `server/src/providers/meta.js`) | BUILT. Preferred by the Meta demo deploy for the council and the daily reply. |
| Muse Spark Open on Baseten (adapter) | `meta-models/muse-spark-open` by default (`server/src/providers/baseten.js`) | BUILT. Never sends `response_format` or `tool_choice`; tool-call behaviour unconfirmed. |
| Nebius Token Factory (older path) | Set by `COUNCIL_NEBIUS_MODEL`; Nemotron in the deploys (`server/src/nebius.js`) | BUILT. Used for the Nebius submission. |

**Memory** (`spec.memory.mode`: `off`, `phone`, `hermes`; enforced by `memoryAllowed` in `server/src/spec/policy.js`).
Default `phone`, retention 30 days.

| Option | Holds long-term memory | Status |
|---|---|---|
| Phone only | On the phone (`LocalMemoryBackend`). Recall by keyword. | BUILT. Default. |
| Existing bot | A separate Illunis profile on the user's bot platform. Hermes is the reference integration. | BUILT. Hermes working end to end on the development setup. OpenClaw and OpenBot not started. |
| Self-hosted brain | Graphiti on FalkorDB on a private VPS, one graph per user, envelope encryption | Design only (section 2.2). |
| Muse | Muse is a brain only. It does not hold memory and has no bot object in its API. | NOT BUILT as memory. A Worker-hosted bot backend is BUILT (section 2.4). |

### 2.1 Common interface
`MemoryBackend`: `write(note)`, `recall(query, k)`, `summary()`.
- Every note has a date, a source and a confidence.
- A conversation writes notes or hypotheses, never facts.
- Notes expire. Expired notes are not recalled.
- Recalled text is data. It is never instructions to the model.

### 2.2 Option A: self-hosted brain
- Graphiti (temporal knowledge graph) on FalkorDB, one graph per user (`u_<random id>`), so a query bug cannot
  cross users.
- Envelope encryption: a master key in a KMS, one 256-bit data key per user, AES-256-GCM per field.
- Embedder: `bge-m3` (1024 dims), the same family as the knowledge banks.
- Extraction runs on the server for each write. This is the main cost and the main tension with user-held keys.
  Providers must not train on prompts.
- Shape: a small Python API next to FalkorDB, behind a reverse proxy, reachable only from the Worker.
- Deletion: immediate logical deletion, purge within 24 hours, including derived results.
- Pricing estimate: about €10 to €15 per month plus model cost (estimate). Measure RAM before sizing.

### 2.3 Option B: existing bot
- A separate profile on the user's bot platform. It does not touch the user's other profiles.
- Hermes first. The Hermes profile `illunis` runs with no terminal, file or kanban tools, its own API key, and
  unattended approvals denied. It is reached through a Cloudflare Tunnel with Access, or a quick tunnel for
  testing (`integrations/hermes/RUNBOOK.md`).
- The bot may read and write memory, message the user's other bots, act after a spoken yes, and push items to Illunis.
- OpenClaw and OpenBot follow the same contract once their APIs are checked.
- The model the live Hermes profile runs on is unverified.

### 2.4 Muse bot backend (Worker-hosted)
- Muse is the brain model only. The Meta standard tier is the only tier used. Built-in `web_search` runs on the Meta
  path only. Results are cited as sources.
- Because Muse has no bot object, the bot lives in the Worker (`server/src/bot/backend.js`, one bot per Worker). It
  accepts the signed setup message, keeps the spec mirror, implements the contract ops and returns receipts. Muse is
  reached through `callBrain`; everything the phone can see passes the policy proxy (`server/src/bot/policy.js`).
  Routes `/bot/setup` and `/bot/message`. BUILT in code and tests.

### 2.5 Settings and approval flow (no settings screen)
There is no settings menu. A change is made in words and approved by the user.
- **In-app chat** (BUILT, `examples/illunis/client/lib/app/spec_chat.dart`): a fixed-phrase gate sorts the message. A change calls
  `POST /spec/propose` with the user's words; the answer becomes one card, `<readback> Approve this change?`, with
  Cancel and Approve. Only an exact Approve on an open, unexpired card calls `POST /spec/apply`. "Show my settings"
  is answered from `GET /spec` with fixed sentences and no model call.
- **Bot request** (BUILT in code and tests; the live Hermes profile needs a reinstall): the bot calls
  `illunis_spec_request(text)`, which pushes an inbox item of kind `spec_request` with the user's words only
  (1 to 500 characters; `server/src/assistants/contract.js`). The phone proposes from those words and shows the same
  card. The bot never applies a change.
- **Worker side** (BUILT): the proposal is untrusted; every path is validated; the diff and readback come from fixed
  phrases. Pending changes live 300 s, are single use, and apply by compare-and-set on the version. Guardrail keys
  are refused.

### 2.6 Pairing and bot setup (BUILT)
- **Pairing** (BUILT, `server/src/pairing.js`, `server/src/pairing-routes.js`): the phone asks for a short-lived code
  (`POST /pair/code`, 10 minutes, 5 attempts); the user reads it to the bot; the bot sends an HMAC-signed claim
  (`POST /pair/claim`); the phone polls `GET /pair/status` and receives its credential exactly once. The bot never sees
  the credential. One bot per Worker. `POST /pair/revoke` clears the link only.
- **Bot setup message** (BUILT, `server/src/bot/setup.js`): the Worker renders the setup text from fixed phrases
  (guardrails first), signs it and sends it as the `setup_apply` op; the bot verifies it and returns a signed receipt
  over the hashes it read back. Bot prose is never stored or shown.

---

## 3. Council (advice only)

The council answers big questions, builds the morning digest, and runs the 21-day analysis. It does not run on every
reply. The user decides; the council never acts.

### 3.1 Experts and skills
- **Now:** each expert is a role-separated prompt on the same brain (`callBrain`), with RAG over its own knowledge
  bank (`examples/illunis/knowledge/<expert>/`). The expert answers only from the sources it is given and must cite them. They are not
  independent models.
- **Later:** self-trained Muse Open mixture-of-experts models with extendable knowledge banks. The expert interface
  stays the same, so a trained expert can replace a base model without changing the aggregator.
- Registry: `server/src/council/experts.js`. The spec validator takes its skill ids from it.
  - Registry skills (switch experts): `breathwork` (breath and stress), `sleep` (sleep and lifestyle), `diet`,
    `training`, `medical` (nine medical experts). Defaults: breathwork and sleep on; diet, training and medical off.
  - Skill modules (`SKILLS`): `reading` (answers only from the user's documents, quotes checked word for word, no
    model call when nothing is retrieved; `server/src/skills/reading.js`) and `habits` (no model, fixed templates;
    `server/src/skills/habits.js`). Both on by default. `focus` (a session timer computed in code, no model;
    `server/src/skills/focus.js`) is off by default.
  - Deploy ceilings: `COUNCIL_COACHING=off` removes diet and training; medical needs `COUNCIL_MEDICAL=on`. The Meta
    demo deploy (`tools/meta/deploy-demo.sh`) keeps coaching and medical off.
- Experts never talk to the user. Their JSON goes to the aggregator only.
- Wellbeing advice (diet, nutrition, training, breath and stress, sleep) is general information, not medical advice. An answer carries the "not medical advice" line and a clinician path when it is on a medical topic or a medical expert is consulted. Before it is shown or spoken, each expert point must cite a source it was given, and the aggregator's synthesis passes the rule-based safety gate.
- Expert reply shape: `{points: [{text, source_ids}], caveats, confidence, search_query}`.

### 3.2 Aggregator
- The model that powers the user's brain writes the synthesis from the expert answers.
- Output: `{synthesis, experts_consulted, sources}`.
- The phone shows the synthesis and the sources. It never shows raw expert text.

### 3.3 Gates (in order, every run)
1. Crisis language returns a fixed referral before any model call.
2. Each expert point must cite only sources it was given. Other points are dropped.
3. The rule-based safety gate runs on all text before it is shown or spoken. An answer is marked not medical advice when it is on a medical topic or a medical expert is consulted.

Optional second-model cross-check (BUILT, `server/src/council/check.js`, on with `COUNCIL_CROSSCHECK=on`): a model
from a different provider checks each point against the passage it cites and labels it supported, unsupported or
contested. Unsupported points are dropped; contested ones are kept and flagged.

Red-team panel (BUILT, `server/src/redteam/panel.js`, `POST /redteam/run`): fires a fixed set of injection and
guardrail-bypass requests at the propose, bot and pairing checks with scripted upstreams and reports each refusal code.

### 3.4 Run limits
The earlier relay design used 8 consults, 3 turns per expert, a 25 s run and a 12 s per-call limit. The aggregator design
re-sets these values. The final values are still open.

### 3.5 Knowledge banks
- Sources: open-access research summaries and hand-written notes.
- Each note: frontmatter with `source_id`, `title`, `url`, `licence`, `retrieved`, and a body of 150 to 400 words in
  our own words.
- Index: Vectorize `illunis-knowledge`, metadata `{expert, source_id, title, url, licence}`. Ingest with
  `server/scripts/ingest-knowledge.mjs`, which needs a Cloudflare token.

---

## 4. Analysis (21 days)

- Plain code computes everything: baseline, rolling mean, standard deviation, trend, effect size and quality flags.
  Method and thresholds: `server/src/analysis/`.
- The model never computes numbers. It receives structured findings only and may phrase them. The phrasing check
  rejects any number that is not in the input.
- Findings are stored as hypotheses with a confidence (0.2 if any quality flag) and an expiry of 14 days.
- Wording: "observation", "tentative", "in these check-ins". Never "conclusion", "diagnosis", condition names,
  "burnout" or causal claims.
- Health Connect supplies sleep, steps and heart rate on Android. Missing data stays missing.

---

## 5. Voice and text

### 5.1 Speech in
- Wake word: the user's own 2 to 4 word phrase. Engine: sherpa-onnx keyword spotting (a release blocker is the
  licence of the KWS model package).
- Speech to text: Whisper tiny.en now. Muse Voice Transcribe and Parakeet-TDT-0.6b-v3 are candidates. The engine
  sits behind an interface.
- Hallucination guard: the voice-activity threshold is tied to the endpoint threshold, not an absolute -55 dBFS.
- Speech ends are detected against the session's room floor.

### 5.2 Speech out
- Kokoro via sherpa-onnx, behind a `TtsEngine` interface. Default voice `af_heart`. Speech is always on.
- Barge-in: user speech stops playback and cancels generation.
- Streaming: the Worker sends sentences over SSE. The phone speaks each sentence as it arrives. A sentence is
  released only after the next one passes the safety gate.

### 5.3 Captions
- Centred on the screen. Dismissable by tap. Fog and mist effects are an optional setting, default on.
- Font: Cormorant Garamond Light or Regular. Dissolve via a small shader during the fade only.
- Reduced motion or shaders off: plain opacity fade.
- Captions keep a `Semantics` label.

### 5.4 Spoken approval
- An assistant action is read back exactly. The user must say "yes", "do it" or "go ahead".
- Any other answer, or 8 seconds of silence, cancels. Nothing is confirmed automatically.
- An expired request says so and sends nothing.

### 5.5 Text fallback
- A typed chat with the same brain, council and gates.
- Used when voice cannot be used: microphone denied, wake word or transcription failing, a noisy room, or the user's choice.
- Text chat is the fallback UI. Voice follows after the hackathons.

---

## 6. Data protection

`DATA_MODE` controls where health data may go. It is enforced on the council, reply, memory and text paths.

| Mode | Allows | Use |
|---|---|---|
| `owner_real` (default when unset) | Providers that do not train on prompts: Meta standard tier, Nebius with the training opt-out, the owner's local Hermes. Refuses contributor models and free test tiers. | Any real data from anyone other than the owner. |
| `owner_any` | Every provider except contributor models (refused under every mode) | The owner's own data, for testing, with the owner's explicit consent. |
| `synthetic` | Test providers allowed | Generated demo history only. |

Rules everywhere:
- No real user data in tests. Fixtures are synthetic.
- No keys or tokens in the repository. Keys are Worker secrets (`npx wrangler secret put <NAME>`).
- Logs carry IDs and fixed error codes, never payloads, keys or prompts.
- A health output carries the not-medical-advice line and a clinician path when it is on a medical topic or a medical expert is consulted.
- Crisis language gets a fixed referral before any model is called.
- Health text reaches a third-party model only through a provider allowed by the mode.
- Before any real data goes to a provider: check its training terms, retention and DPA.

---

## 7. Health scope

The app stays general wellbeing. The server refuses or redirects:
- diagnosis, treatment, medication, dose and disease claims;
- numeric targets for conditions (blood pressure, glucose, HbA1c, heart-rate thresholds);
- symptoms, injury, pregnancy and eating-disorder topics (with general resources and a calorie floor).

Keyword checks are brittle. How far to rely on them is still open.

---

## 8. Build and verification

- Server: `cd server && npm test` (`node --test`). Run `node scripts/check-deploy.mjs` before a deploy.
- Client: `cd examples/illunis/client && flutter analyze && flutter test`. The Flutter SDK must be installed. If it
  is missing, report "not compiled" rather than skipping silently.
- Hermes: `uv run --no-project --with pytest pytest integrations/hermes/tests -q`.

---

## 9. Status

| Part | Status |
|---|---|
| Spec, validator, diff and approval, guardrails in code | BUILT |
| Settings by chat card (no settings screen) | BUILT. Not yet on the phone (rebuild pending). |
| Settings request from the bot (`spec_request`) | BUILT. Hermes reinstall pending. |
| Brains: Meta Muse, Baseten adapter, Nebius | BUILT |
| Memory: phone, Hermes | BUILT |
| Memory held by Muse | NOT BUILT |
| Muse bot backend (Worker-hosted) | BUILT |
| Self-hosted brain (option A) | Design only |
| Skills: breathwork, sleep, diet, training, medical (registry); reading, habits, focus (modules) | BUILT |
| Pairing a phone to a bot | BUILT |
| Bot setup message | BUILT |
| Second-model cross-check of the council | BUILT, off by default |
| Red-team panel | BUILT |

Test counts: server 602 of 602 pass (`cd server && npm test`). Client and Hermes tests were not run for this document.
- Done means: the tests reproduce the behaviour. Reading the code is not a test.
- Device checks run on a test phone and are not covered by the automated tests.
