# Meta slice: the always-on expert framework

Inspiratio is the framework, and it is the submission: the spec and its enforcement, the skill registry and modules,
knowledge banks, bot integration and pairing, the policy proxy and the chat settings card, built during the event (3 and
4 Nov 2026). Illunis is the showcase app the framework was built on top of. Its wellbeing content, expert council, phone
UI, sky and voice are pre-event code and are shown as the showcase, not as new work. The file-by-file split and the git
commands to check it are in [NEW_WORK.md](../NEW_WORK.md).

This is the brief for the Meta track submission (due 4 Nov, 9 PM ET). Status is checked against the code in this repo
(section "Status against the code"). Open items are listed at the end. Architecture: [DESIGN.md](DESIGN.md).

## What is presented
The framework, running on the Illunis showcase app. An always-on personal assistant for everyday users, built from:
- **Brain and aggregator:** Muse (`muse-spark-1.3`) on the Meta Model API (standard tier). It writes the final answer;
  the Meta demo deploy prefers Muse for both the council and the daily reply. Muse Spark Open on Baseten is an adapter;
  Nebius is the older path. Muse is a brain only; it does not hold memory (NOT BUILT).
- **Model scope caveats:** Muse is not the whole demo. When a Muse call fails, the council falls back to Nemotron on
  Nebius. Food-log parsing and embeddings do not run on Muse. The model behind the live Hermes bot is unverified.
- **Changes by talking:** no settings menu. The user asks in chat (a card with Cancel and Approve) or through the bot
  (`spec_request`); the Worker validates, diffs and applies only after the user approves.
- **Expert modules (pre-event council; the skill switches are new):** each expert is a base model with retrieval over its own knowledge bank, citing the sources it was
  given. Experts never speak to the user; their output goes to the aggregator only.
- **Switchable skills:** `breathwork`, `sleep`, `diet`, `training`, `medical` switch experts; `reading`, `habits` and
  `focus` are skill modules. The demonstration runs with the coaching and medical experts off.
- **Gates, in order, every run (pre-event safety code):** crisis language returns a fixed referral before any model call; each expert point must
  cite a source it was given; a rule-based safety check runs on all text before it is shown or spoken.

## Expert scope in the demonstration
| Expert | Demo | Folded scope |
|---|---|---|
| Training and movement | Off | Strength, hypertrophy, calisthenics, sports performance, mobility and flexibility |
| Diet and nutrition | Off | Weight, supplements |
| Breath and stress | On | Breathwork and meditation, stress management |
| Sleep and lifestyle | On | Sleep, light and circadian rhythm, habit formation, time and energy, general lifestyle |
| Medical experts (9) | Off | Not in the submission; off unless `COUNCIL_MEDICAL=on` |

**Non-medical disclosure:** wellbeing advice (diet, nutrition, training, breath and stress, sleep) is general information,
not medical advice. An answer carries the "not medical advice" line and a clinician path when it is on a medical topic or a
medical expert is consulted. The expert citations
and the aggregator's synthesis are checked before anything is shown.

**Why coaching is off:** Meta's sample anti-projects exclude sports analyzers or coaches, AI nutrition coaches, basic RAG
applications, personality analyzers and anything medical. The demo must not look like any of these.

## Name
- **Name:** Inspiratio. Trademark cleared by the owner (2026-11-04).
- **Trademark risk:** a registered INSPIRATION word mark in Class 9 (software), reg. 1768514, reportedly owned by
  Inspiration Software, Inc. Status and owner are unverified. Check USPTO TSDR before any public use.

## Differentiators to show (the concept is not new)
The council pattern is well known (Karpathy's llm-council, Nov 2025), and assistant plugin ecosystems exist (OpenClaw,
Leon). Always-on memory wearables exist (Bee, Omi, Friend). The combination was not found in searches. The
submission must show these, not just claim them:
1. **Per-expert retrieval with citations:** each expert answers only from its own bank, and uncited points are dropped.
2. **Safety gates:** crisis referral before any model call; the not-medical-advice line on medical runs; the rule-based check on all text.
3. **Memory choice:** the user picks where memory lives (on the phone, in a connected assistant, or in a server brain).
4. **Switchable modules:** experts turn on and off without changing the aggregator.

Items 1 to 3 rest on pre-event Illunis code (the council, safety gates and memory backends, 24 and 25 Oct). Item 4 and the
spec-driven change flow are event work.

Reference points to check directly before citing: https://github.com/karpathy/llm-council (the pattern),
https://www.vellum.ai/md/blog/best-open-source-personal-ai-assistants (assistant ecosystems, a secondary summary).

## Status against the code
| Item | Status |
|---|---|
| Muse as brain and aggregator, coaching off | BUILT. [server/src/providers/meta.js](../server/src/providers/meta.js); demo deploy [tools/meta/deploy-demo.sh](../tools/meta/deploy-demo.sh) (`REPLY_PROVIDER=meta`, `META_MODEL=muse-spark-1.3`, `COUNCIL_COACHING=off`). |
| Enable flags per expert module | BUILT. Spec skills in `server/src/spec/schema.js`; deploy ceilings `COUNCIL_COACHING`, `COUNCIL_MEDICAL` in `server/src/council/experts.js`. RAG design check against the Meta list: open. |
| `DATA_MODE=synthetic` for the demo | BUILT in the deploy script. Seeded history: `tools/synthetic/gen_history.mjs`. |
| Restore `QUOTA_COUNCIL_PER_DAY` to 5 | Open. The deploy script defaults to 50. |
| Settings by chat card and bot request | BUILT. Phone rebuild and Hermes reinstall pending. |
| Pairing, bot setup message | BUILT in code and tests (`server/src/pairing.js`, `server/src/bot/setup.js`) |
| Muse bot backend (Worker-hosted) | BUILT in code and tests (`server/src/bot/backend.js`) |
| Muse as memory | NOT BUILT |
| Second-model cross-check, red-team panel | BUILT in code and tests; cross-check off unless `COUNCIL_CROSSCHECK=on` |
| Server tests | 602 of 602 pass (`cd server && npm test`) |

## Open items
1. Does Meta's track accept a framework demo with coaching experts off? (organiser confirmation)
2. Does judging treat the council (RAG experts) as a "basic RAG application"? Check against the list before submission.
3. Name clearance (TSDR, EU and UK registers, npm, domain). Until then, use "the framework".
4. Muse key: a Worker secret, not checkable from the repo. Muse as memory is not built.
5. The medical experts and their knowledge notes are in the repo but off in the demo.

## Sources
- Meta track and sample anti-projects: from the track brief. Not independently checked.
- Council pattern: https://www.analyticsvidhya.com/blog/2025/12/llm-council-by-andrej-karpathy/ (secondary).
- Assistant ecosystems: https://www.vellum.ai/md/blog/best-open-source-personal-ai-assistants (secondary).
- Wearables: https://www.yankodesign.com/2026/01/18/5-ai-devices-that-just-made-smartphones-look-obsolete-in-2026/ (secondary).
- Trademark: https://trademark.justia.com/owners/inspiration-software-inc-605789 (owner listing, status unverified).
