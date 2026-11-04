# Illunis: the showcase app

Illunis is the showcase app: a personal agent for daily wellbeing whose code pre-dates the event (first added 24 to 26
Oct 2026). The Inspiratio framework was built on top of it during the event; see [NEW_WORK.md](../../NEW_WORK.md). The screen shows only sky
imagery. The user talks to it, or types when voice cannot be used. It gives general observations and options
with sources, and the user makes the decisions. It is advice only.

This folder holds the parts that belong to the example, not to the framework:

| Path | Contents |
|---|---|
| `client/` | The Flutter phone app (Android first): chat, council answers with sources, the settings screen for the spec, logs, breathwork, sky and water |
| `knowledge/` | The expert knowledge banks, one folder per expert, each note with its source URL and licence |
| `content/` | Personalities, skill packs and the breathwork library, with their schemas and `validate.mjs` |
| `moon_assets/` | The script that builds the bundled moon map from NASA SVS imagery (writes into `client/assets/moon/`) |
| `docs/SKY.md` | How the sky, water, clouds and captions are drawn and shipped |
| `docs/asset_commissions.md` | The brief for generating cloud, water, moon and sun images |
| `docs/breathwork_meditation.md` | The evidence review behind every breathwork technique in `content/breathwork/` |

Two example files stay inside the framework's server, because the server reads them directly:
`server/src/council/experts.js` (the Illunis expert registry and prompts) and `server/src/content.js` (which
imports `content/` from here).

---

## How Illunis uses the framework

```
 phone (examples/illunis/client)
   typed chat now; voice in and out is the design target
   short-term memory on the phone (conversation + last 5 session summaries)
   settings screen: the spec, proposed in words, approved by tap
        |  HTTPS, device token
        v
 Worker (server/)
   spec, guardrails, council, reply, memory, skills
        |
        v
 brain: Meta Muse, Muse Spark Open on Baseten, or Nemotron on Nebius
```

- **Council.** For big questions, the morning digest and the 21-day analysis, several experts each answer from
  their own knowledge bank and cite it. The brain writes one synthesis with sources. The app shows the synthesis
  and sources, never raw expert text.
- **Experts.** Wellbeing: diet and nutrition, training and movement, breath and stress, sleep and lifestyle.
  Nine medical experts exist in the registry and are off unless `COUNCIL_MEDICAL=on`.
- **Analysis.** Plain code computes baselines, trends and data-quality flags over 21 days of check-ins and
  health signals (`server/src/analysis/`). The model only phrases findings, and a check rejects any number not
  in the input. Findings are observations, never conclusions.
- **Skills.** Breathwork and sleep on by default; diet, training and medical off. The reading companion and the
  habit builder are on.
- **Memory.** On the phone by default (`memory.mode: phone`), or in the user's Hermes profile.

Wellbeing advice (diet, nutrition, training, breath and stress, sleep) is general information, not medical
advice. An answer carries the "not medical advice" line and a clinician path when it is on a medical topic or a
medical expert is consulted.

---

## Memory and brain options

| Option | What holds the memory and runs the brain | Status |
|---|---|---|
| Phone only | Long-term memory on the device, recall by keyword | Built |
| Existing bot | A separate Illunis profile on a bot platform the user already runs; Hermes is the reference integration | Working end to end on a development setup |
| Meta Muse | Muse on the Meta Model API is the brain. Muse as the memory is planned, not built | Code path built |
| Self-hosted brain | A temporal knowledge graph (Graphiti on FalkorDB) on a private VPS, one graph per user, encrypted per user | Design only (`docs/DESIGN.md`, section 2.2) |

---

## Voice

Voice is the design target. The typed chat is the current interface and uses the same brain, council and gates.

- Wake word: a user-chosen phrase, detected on device.
- Speech in: on-device speech-to-text (Whisper tiny.en through sherpa-onnx).
- Speech out: on-device Kokoro text-to-speech (sherpa-onnx). The model is not bundled in the APK;
  `client/tool/push_kokoro_model.sh` copies it to a test device.
- Barge-in: speaking stops playback and cancels generation.

---

## Data

- All demos run on generated, synthetic data (`DATA_MODE=synthetic`, `tools/synthetic/`).
- `client/tool/import_owner_data.dart` and `push_owner_import.sh` import an export from an earlier app into
  the phone once. The test fixture is synthetic.

---

## Run

```bash
cd examples/illunis/client && flutter pub get && flutter analyze && flutter test
node examples/illunis/content/validate.mjs && node --test examples/illunis/content/test/
cd server && node scripts/ingest-knowledge.mjs --dry-run    # reads examples/illunis/knowledge by default
```

After editing `content/breathwork/`, run `client/tool/sync_breath_content.sh`; a client test checks the copy.

## Design notes

Moved from `docs/DESIGN.md`, which now covers the framework.

### Analysis (21 days)

- Plain code computes everything: baseline, rolling mean, standard deviation, trend, effect size and quality flags.
  Method and thresholds: `docs/RESEARCH.md` section 2.
- The model never computes numbers. It receives structured findings only and may phrase them. The phrasing check
  rejects any number that is not in the input.
- Findings are stored as hypotheses with a confidence (0.2 if any quality flag) and an expiry of 14 days.
- Wording: "observation", "tentative", "in these check-ins". Never "conclusion", "diagnosis", condition names,
  "burnout" or causal claims.
- Health Connect supplies sleep, steps and heart rate on Android. Missing data stays missing.

### Voice and text

#### Speech in
- Wake word: the user's own 2 to 4 word phrase. Engine: sherpa-onnx keyword spotting (a release blocker is the
  licence of the KWS model package).
- Speech to text: Whisper tiny.en now. Muse Voice Transcribe and Parakeet-TDT-0.6b-v3 are candidates. The engine
  sits behind an interface.
- Hallucination guard: the voice-activity threshold is tied to the endpoint threshold, not an absolute -55 dBFS.
- Speech ends are detected against the session's room floor.

#### Speech out
- Kokoro via sherpa-onnx, behind a `TtsEngine` interface. Default voice `af_heart`. Speech is always on.
- Barge-in: user speech stops playback and cancels generation.
- Streaming: the Worker sends sentences over SSE. The phone speaks each sentence as it arrives. A sentence is
  released only after the next one passes the safety gate.

#### Captions
- Centred on the screen. Dismissable by tap. Fog and mist effects are an optional setting, default on.
- Font: Cormorant Garamond Light or Regular. Dissolve via a small shader during the fade only.
- Reduced motion or shaders off: plain opacity fade.
- Captions keep a `Semantics` label.

#### Spoken approval
- An assistant action is read back exactly. The user must say "yes", "do it" or "go ahead".
- Any other answer, or 8 seconds of silence, cancels. Nothing is confirmed automatically.
- An expired request says so and sends nothing.

#### Text fallback
- A typed chat with the same brain, council and gates.
- Used when voice cannot be used: microphone denied, wake word or transcription failing, a noisy room, or the user's choice.
- Text chat is the current interface; voice follows.

### Health scope

The app stays general wellbeing. The server refuses or redirects:
- diagnosis, treatment, medication, dose and disease claims;
- numeric targets for conditions (blood pressure, glucose, HbA1c, heart-rate thresholds);
- symptoms, injury, pregnancy and eating-disorder topics (with general resources and a calorie floor).

Keyword checks are brittle; do not rely on them alone.

## Licences

Code: MIT (`LICENSE` at the repository root). Knowledge notes carry their own licence per file (NHS content
under the Open Government Licence, MedlinePlus public domain). Moon imagery: NASA SVS, credited in
`client/assets/moon/manifest.json`.
