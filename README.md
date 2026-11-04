# Inspiratio: a framework for personal assistants, built to run on Muse

Inspiratio is an adaptable framework for building personal assistant apps. Users change how their assistant works by
talking to it, and every change is shown and approved before it takes effect. It is designed to run on **Muse**: the
Muse bot is the assistant the user talks to, and the Muse models are its brain.

- **Assistant.** The user pairs their phone with their Muse bot using a short code. A signed setup message then gives the
  bot its rules: skills, memory location, notification rules and what it must never do. The bot confirms the version it
  is running. Inspiratio is tested with Hermes, a bot we can run locally, and prepared for Muse through the Muse model API.
- **Brain.** `muse-spark-1.3` on the Meta Model API writes the answers, runs cited web search and produces the daily reply.
  Muse Spark Open on Baseten is an alternative brain behind the same interface. Nemotron on Nebius is a fallback, and each
  response names the model that answered.
- **Council.** Role-separated experts answer from retrieved sources, and any claim without a matching source is dropped
  before the reply. Fine-tuned Spark models for the council are coming soon.

Enforcement runs across all three layers. Approved settings apply to every request, guardrails run in code before any model
call, and personal data leaves the device only with the user's approval.

**Illunis** is the showcase app the framework was built on top of, under [examples/illunis/](examples/illunis/README.md).
Its wellbeing content, expert council, phone UI, sky and voice are **pre-event code** (first added 24 to 26 Oct 2026; features added 28 to 30 Oct for the
Nebius track are listed apart in NEW_WORK.md), and so is most of the Worker core in `server/` (reply, safety gate, council, Hermes bridge). They are shown to demonstrate the
framework, not as new work. Illunis is an always-on wellbeing guide on Android: the screen shows only sky imagery, you talk
to it or type, and it gives general observations and options with sources. You make the decisions.

There is no settings menu. Changes are made by chat (the app shows one card with the readback, Cancel and
Approve) or through the bot (the bot relays the user's words; the phone shows the same card). The user
approves every change.

Brains available (`spec.brain`; the preferred one goes first and the others are fallbacks):
- **Meta Muse API**, `muse-spark-1.3`.
- **Muse Spark Open on Baseten**, as an adapter (`server/src/providers/baseten.js`).
- **Nebius Token Factory** (Nemotron), the older path used for the Nebius submission.

---

## Try the demo (Android)

1. Download `app-release.apk` from the [demo release](https://github.com/Buzka42/inspiratio_meta/releases/tag/demo-v1).
2. On your Android phone, allow installs from unknown sources for your browser or file manager, then open the APK.
3. Open Illunis. It connects to a dedicated demo device on the hosted Worker; no pairing is needed.

What the demo device does:
- It uses synthetic data only. No real person's data is on it.
- It has its own daily quota, shared by everyone trying the demo, which resets each day.
- Changes you approve (by chat or through the bot) apply only to the demo device and its own memory.

The APK is signed with a debug key, not a release key, which is why Android asks you to allow unknown sources. The demo
access will be revoked after judging.

## How it works

```
 phone (Flutter, Android)
   voice in (wake word, speech-to-text)  ──┐
   text fallback (typed chat)             ─┤
   short-term memory (on the phone)        │
   long-term memory (one interface)        │
        │  HTTPS, device token             │
        ▼                                  │
 Worker (Cloudflare, server/)              │
   brain: Muse, Baseten or Nebius           │
   council: expert models + RAG knowledge   │
   aggregator: the brain's model writes the answer
        │
        ▼
   answer + sources ──► speech out (on-device TTS) or text
```

- **Brain.** The model that answers (above). Long-term memory is a separate
  choice (below).
- **Council.** For big questions, the morning digest and the 21-day analysis,
  several expert models each answer from their own knowledge bank. The brain's
  model then combines them into one answer with sources.
- **Short-term memory.** The current conversation and summaries of the last five
  sessions, kept on the phone.
- **Analysis.** Plain code computes baselines, trends and data-quality flags. The
  model never computes numbers. Findings are labelled as observations, not
  conclusions.

---

## Memory and brain options

The spec's memory mode is `off`, `phone` (the default) or `hermes`, enforced by the
Worker. Muse is a brain only: it does not hold memory.

| Option | What holds the memory | Status |
|---|---|---|
| **Phone only** | The device | Built |
| **Existing bot** | A separate Illunis profile on a bot platform the user already runs. Hermes is the reference integration. | Built; working end to end on a development setup. The model the live Hermes bot runs on is unverified. |
| **Self-hosted brain** | A service on a private VPS: a temporal knowledge graph (Graphiti on FalkorDB), one graph per user, encrypted per user | Design only |
| **Muse bot backend** | A bot hosted in the Worker (`server/src/bot/`), because Muse has no bot object in its API. It accepts the signed setup message, keeps the spec mirror, implements the contract ops and returns receipts. | Built in code and tests |

**Pairing.** A phone pairs with one bot per Worker (`server/src/pairing.js`, `/pair/*` routes): a short-lived code,
an HMAC-signed claim from the bot, and the phone receives its credential once. Unpairing only clears the link.
Built in code and tests.

Every memory note records its date, source and confidence. Conversations never
create facts: they create notes or hypotheses, and notes expire. Recalled memory
is treated as data, never as instructions.

---

## Expert council

The council is pre-event Illunis code. The skill switches, the cross-check and the red-team panel were added during the event.

The council is advice only. The user decides.

**Experts.** Each expert is a role-separated prompt on the same brain, with
retrieval-augmented generation (RAG) over its own knowledge bank, and it must cite
the sources it was given. They are not independent models. Experts never speak to
the user. Their output goes to the aggregator only.

**Skills.** The spec switches skills by id (registry in [server/src/council/experts.js](server/src/council/experts.js)):

| Skill | What it switches | Default |
|---|---|---|
| `breathwork` | Breath and stress expert | On |
| `sleep` | Sleep and lifestyle expert | On |
| `diet` | Diet and nutrition expert | Off |
| `training` | Training and movement expert | Off |
| `medical` | The nine medical experts | Off |
| `reading` | Skill module: answers only from the user's documents, quotes checked word for word | On |
| `habits` | Skill module: reminders and counts from fixed templates, no model | On |
| `focus` | Skill module: a session timer computed in code, fixed templates, no model | Off |

Wellbeing advice (diet, nutrition, training, breath and stress, sleep) is general information, not medical advice. An answer carries the "not medical advice" line and a clinician path when it is on a medical topic or a medical expert is consulted. Before it is shown or spoken, each expert point must cite a source it was given, and the aggregator's synthesis passes the rule-based safety gate.

**Aggregator.** The model that powers the user's brain combines the expert answers
into one synthesis, with its sources and its options. The app shows the synthesis
and sources. It never shows raw expert text.

**Knowledge banks.** Open-access research summaries and short expert notes written in
our own words. Each note records its source URL and licence.

**Gates, in order, on every council run:**

1. Crisis language returns a fixed referral before any model call.
2. Each expert point must cite only sources it was given. Other points are dropped.
3. A rule-based safety check runs on all text before it is shown or spoken.

**Cross-check (optional).** With `COUNCIL_CROSSCHECK=on`, a model from a different provider checks each point
against the passage it cites; unsupported points are dropped and contested ones are flagged
(`server/src/council/check.js`). Built in code and tests; off unless the flag is set.

**When it runs.** For the morning digest, for explicit or large questions, and for
the 21-day analysis. It does not run on every reply.

**Later:** self-trained Muse Open mixture-of-experts models with knowledge banks
that can be extended. The expert interface is designed so a trained expert can
replace a base model without changing the aggregator.

---

## Models

| Role | Model and provider | Status |
|---|---|---|
| Brain and aggregator | `muse-spark-1.3` on the Meta Model API (standard tier) | Built; preferred by the Meta demo deploy |
| Brain adapter | Muse Spark Open on Baseten (`meta-models/muse-spark-open-1026`) | Built; tool-call behaviour unconfirmed |
| Brain, older path | Nemotron on Nebius Token Factory | Built; used for the Nebius submission |
| Council experts | Role-separated prompts on the same brain, with RAG | Built |
| Speech in | On-device speech-to-text now; Muse Voice Transcribe 1.0 under evaluation | See Voice |
| Speech out | On-device Kokoro text-to-speech (sherpa-onnx) | Built |
| Knowledge retrieval | Embeddings in Vectorize; the Meta demo deploy keeps embeddings on Nebius | Index created, ingest in progress |

**Model scope of the demo.** Muse is not the whole demo. When a Muse call fails, the council falls back to
Nemotron on Nebius. Food-log parsing and embeddings do not run on Muse. The model behind the live Hermes bot
is unverified.

Muse Spark Open is an open-weight mixture-of-experts model (816B total parameters,
about 42B active per token). Its weights are under the Muse Model License.

---

## Voice

Voice is pre-event Illunis code.

Voice is the main interface.

- **Wake word:** a user-chosen phrase, detected on device.
- **Speech in:** on-device speech-to-text today. Muse Voice Transcribe 1.0 is
  under evaluation as a replacement: it is speech-to-text only, supports 25
  languages including Polish, and offers realtime and file endpoints.
- **Speech out:** on-device Kokoro. Muse does not offer speech output.
- **Barge-in:** speaking stops playback and cancels generation.

### Text fallback

When voice cannot be used (microphone blocked, transcription failing, a noisy
room, or the user prefers typing), the app offers a text chat. It uses the same
brain, the same council and the same safety gates.

---

## Data protection

The data modes are pre-event Illunis code; the spec's memory-mode enforcement was added during the event.

Health data is the most sensitive input in the app. Its use is controlled by a
data mode, enforced on the council, reply, memory and text paths.

| Mode | Where data may go | Use |
|---|---|---|
| Default | Providers that do not train on prompts. Contributor models and free test tiers are refused. | Any real user data |
| Owner test | All providers, with the owner's explicit consent for their own data | Development and testing with the owner's own data only |
| Synthetic | Test providers allowed | Demonstrations with generated data only |

Rules that apply everywhere:

- No real user data in automated tests. Tests use synthetic fixtures.
- No keys or tokens in the repository. Keys are stored as platform secrets.
- Logs carry IDs and fixed error codes only, never payloads.
- A health output carries a "not medical advice" line and a clinician path when it is on a medical topic or a medical expert is consulted. Wellbeing advice (diet, nutrition, training, breath and stress, sleep) is verified by the experts' cited sources and the aggregator's safety gate before it reaches the user.
- Crisis language gets a fixed referral before any model is called.
- Approval is required before any action on another service. The app reads the
  action back, the user confirms it by voice, and silence cancels it.

---

## Hackathon submission

- **Track:** Meta Global AI Developer Hackathon, Indie Developer (individual entry).
- **Demo video (3 minutes):** VIDEO_LINK_HERE
- **New work:** the framework was built 3 and 4 Nov 2026 on top of the Illunis showcase app. The file-by-file split and
  the commands to check it are in [NEW_WORK.md](NEW_WORK.md). Full source history: https://github.com/Buzka42/illunisv2
- **Models:** Muse as the brain and aggregator through the Meta Model API (`muse-spark-1.3`), and Muse Spark Open on
  Baseten (`meta-models/muse-spark-open-1026`) as an adapter. The council falls back to Nemotron on Nebius when Muse
  fails; food-log parsing and knowledge embeddings run on other models. See [docs/META_SLICE.md](docs/META_SLICE.md).
- **Demo deploy:** `tools/meta/deploy-demo.sh` keeps the coaching experts (training, diet) and the medical experts off.
- **Demonstration:** the demo uses generated, synthetic data.

---

## Repository layout

| Path | Contents |
|---|---|
| [server/](server/docs/SETUP.md) | Cloudflare Worker. Framework (event): spec, guardrails, skills, pairing, bot backend, policy proxy. Pre-event Illunis core: council, reply, safety, memory and assistant routes (plain JavaScript, `node --test`) |
| [integrations/hermes/](integrations/hermes/CONTRACT.md) | Hermes bot profile, tunnel proxy and tools (pre-event; spec ops added during the event) |
| `tools/` | Demo deploy script (`tools/meta/deploy-demo.sh`) and synthetic history generator (`tools/synthetic/`) |
| [examples/illunis/](examples/illunis/README.md) | The showcase app (pre-event code, with features added 28 to 30 Oct): Flutter app (`client/`), knowledge banks (`knowledge/`), personality and skill definitions (`content/`) |
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture: memory options, council, voice, data protection |
| [docs/META_SLICE.md](docs/META_SLICE.md) | What the Meta track submission presents |
| [NEW_WORK.md](NEW_WORK.md) | What was built during the event, what pre-dates it, and how to check |

Status: server tests pass (602 of 602, `cd server && npm test`). The client and the Hermes tools were not
run for this document.

---

## Build and test

```bash
# server
cd server && npm test                              # node --test
cd server && node scripts/ingest-knowledge.mjs --dry-run

# client
cd examples/illunis/client && flutter analyze && flutter test       # Flutter SDK required

# Hermes tools
uv run --no-project --with pytest pytest integrations/hermes/tests -q
```
