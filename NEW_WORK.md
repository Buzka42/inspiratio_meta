# New work during the event

**Rule:** what is presented must have been built during the event (27 Oct to 4 Nov 2026, ET), and the new work must be clearly identifiable.

## What is submitted

The submission is **Inspiratio**, a framework for a personal agent its user can change safely. It is made of: the spec and
its enforcement, the skill registry and skill modules, user-managed knowledge banks, bot integration and pairing, the policy
proxy on bot output, and the chat settings card. All of it was built during the event, in commits `69a3c7d` to `9c33af0`
(3 and 4 Nov).

It is built on top of **Illunis**, the showcase app: wellbeing content, the expert council, the phone UI, the sky and
voice. That code pre-dates the event and is shown as the showcase, not as new work. Illunis features added 28 to 30 Oct
for the separate Nebius track are listed apart below and are not claimed as part of the framework.

## Counts (from `git log`, author dates as recorded)

- 185 commits in all. 61 are before 27 Oct; 124 are on or after it. First event commit: `9fdbb93` (2026-10-28).
- 892 files in the current tree. 682 were first added before 27 Oct; 210 were added on or after it.
- Of the 210: 145 were added 28 to 30 Oct (Illunis, Nebius track); 65 were added 3 and 4 Nov (the framework).
- 86 pre-event files were changed during the event (84 edited, 2 font licence files moved). 40 of them were changed in
  the framework commits.

## Framework components (built during the event)

| Component | Files | Commits |
|---|---|---|
| Spec and enforcement | `server/src/spec/schema.js`, `store.js`, `guardrails.js`, `policy.js`, `propose.js`, `routes.js` | `69a3c7d`, `1bef306` |
| Skill registry and modules | `server/src/skills/manifest.js`, `routes.js`, `reading.js`, `reading-store.js`, `habits.js`, `focus.js` | `69a3c7d`, `1bef306` |
| Skill switches on plain replies | `server/src/reply.js` (edit), `server/test/reply-skills-off.test.js` | `9c33af0` |
| Knowledge banks the user adds and removes | `server/src/spec/knowledge.js` | `69a3c7d` |
| Bot integration and pairing | `server/src/bot/backend.js`, `routes.js`, `setup.js`, `server/src/pairing.js`, `pairing-routes.js` | `1bef306` |
| Bot spec requests | `integrations/hermes/tests/spec_vectors.json`, `test_spec_mirror.py`; contract edits | `69a3c7d`, `583b670` |
| Policy proxy on bot output | `server/src/bot/policy.js` | `1bef306` |
| Cross-check and red-team panel | `server/src/council/check.js`, `server/src/redteam/panel.js` | `1bef306` |
| Chat settings card | `client/lib/app/spec_chat.dart`, `settings_spec.dart` | `69a3c7d`, `583b670` |
| Baseten brain adapter | `server/src/providers/baseten.js`, `server/scripts/probe-baseten.mjs` | `69a3c7d` |
| Demo deploy | `tools/meta/deploy-demo.sh` | `69a3c7d` |

Tests are in `server/test/` and `client/test/app/`, in the same commits.

## Pre-event code shown as the showcase

| Part | Main paths | First added |
|---|---|---|
| App baseline: phone UI, sky, water, moon shaders | `client/lib/`, `client/gpu/`, `client/shaders/`, `moon_assets/` | 24 and 25 Oct |
| Voice: wake phrase, speech in and out | `client/lib/voice/` | 24 and 25 Oct |
| Worker core: reply, turn, safety gate | `server/src/reply.js`, `turn.js`, `safety.js`, `worker.js` | 24 Oct |
| Expert council v2, relay, retrieval, data modes | `server/src/council/`, `server/src/knowledge/retrieve.js`, `server/src/data-mode.js` | 25 Oct |
| Muse provider (first version) | `server/src/providers/meta.js` | 25 Oct |
| Hermes bridge and contract | `server/src/assistants/`, `integrations/hermes/` | 25 Oct |
| Knowledge bank notes (98) | `knowledge/` | 25 Oct |
| Personalities and content | `content/personalities/` | 24 Oct |
| Synthetic history generator | `tools/synthetic/` | 25 Oct |
| Framework concept, name and brief (documents only) | `docs/META_SLICE.md`, `README.md` | 26 Oct |

## Illunis features added during the event window (Nebius track, not the framework)

28 to 30 Oct, commits `9fdbb93` to `19f391d`: breathwork library and sessions (`content/breathwork/`, `client/lib/breath/`),
structured logs and log views (`client/lib/logs/`), typed chat (`client/lib/app/chat_thread.dart`), the glass UI kit
(`client/lib/ui/`, `client/lib/widgets/glass/`), Tavily search and food checks (`server/src/providers/tavily.js`,
`server/src/logs/`), knowledge ingest (`server/src/knowledge/ingest.js`), the council trace and uncited-point removal.

## Pre-event code changed in the framework commits

- `server/src/council/experts.js`: each expert gets a spec skill switch.
- `server/src/council/relay.js`, `provider.js`: the cross-check hook, a run deadline, trace notes.
- `server/src/reply.js`, `reply-stream.js`, `session-summary.js`: spec policy (skills, memory mode) applied; Muse token floors.
- `server/src/providers/meta.js`, `providers/chat.js`, `models.js`: `muse-spark-1.3` settings from live checks (2 Nov).
- `server/src/worker.js`, `index.js`: spec, pairing and bot backend state and routes.
- `server/src/assistants/contract.js`, `routes.js`, `store.js`: spec, setup and knowledge ops; spec request inbox kinds.
- `server/src/data-mode.js`: contributor models refused under every mode.
- `server/src/knowledge/retrieve.js`: timeout passed through from the run deadline.
- `integrations/hermes/` (contract, plugin, profile, tests): spec mirror and signed spec ops.
- `client/lib/main.dart`, `app/server_port.dart`, `council_flow.dart`, `persistence.dart`, `assistant_inbox.dart`,
  `voice_setup.dart`, Android styles: settings card, spec endpoints, full screen.
- `server/scripts/check-deploy.mjs`, four existing tests, and the docs (`README.md`, `docs/`).

## How to verify

Run these in the source repository, which holds the git history. In the exported repository, `client/`, `content/`,
`knowledge/` and `moon_assets/` sit under `examples/illunis/`.

```bash
git log --format='%h %ad %s' --date=iso                 # all commits and dates
git log --format='%h %ad %s' --date=iso 19f391d..HEAD   # the framework commits
git diff --name-only --diff-filter=A 4bd60e9 HEAD | wc -l   # files added during the event (210)
git diff --name-only --diff-filter=A 19f391d HEAD           # files added for the framework (65)

git ls-files | while read -r f; do
  echo "$(git log --diff-filter=A --follow --format=%ad --date=short -- "$f" | tail -1) $f"
done | sort
```

`4bd60e9` (2026-10-26) is the last commit before the event; `19f391d` (2026-10-30) is the last commit before the framework work.
