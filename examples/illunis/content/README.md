# Content

Personalities, skill packs and the breathwork library, checked by `validate.mjs`
(no dependencies).

- `node content/validate.mjs` checks every file and exits non-zero on any failure.
- `node --test content/test/` runs the content tests.

## Breathwork library

One file per technique in `breathwork/<id>.json`, checked against
`schemas/technique.schema.json`. The source for every timing, level, screen and
evidence label is `examples/illunis/docs/breathwork_meditation.md`. This is a wellbeing
feature: copy makes no medical claim and every technique carries the
"not medical advice" notice.

### Adding a technique

1. Find the technique in the research file. If it is not there, research it first.
   Do not invent timings.
2. Create `breathwork/<id>.json` with `id` equal to the file name.
3. Set `level`: `basic` only for the eight default sessions (research section 5,
   `DEFAULT_IDS` in `validate.mjs`); everything else is `advanced`.
4. Set `evidence` to the research label (`moderate`, `weak` or `practitioner`).
5. Set `pacing` from the research. Use `null` when the research gives no playable
   timing, and then set `available: false`. Set `guided: false` when the visual is
   only an ambient reference (meditations, natural-breath observation).
6. Add `screens`. For an advanced technique, add its entry to `ADVANCED_SCREENS`
   in `validate.mjs`, citing the research section.
7. If a timing or claim is marked unverified in the research, keep it, set the
   evidence label honestly, and say "Verify before release" in `note`.
8. Run the validator and the tests.

### Rules the validator enforces

- Basic techniques (research 6.1): at most 6 breaths per minute, holds of 4 s or
  less, no `hold_empty`, no `forceful` or `holotropic` screen, `default` screen present.
- `rate_bpm` equals 60 divided by the cycle length.
- An available technique has playable pacing.
- Holotropic stays `available: false`, with `pacing: null` and `screens: ["holotropic"]`.
- Advanced screens match the research; retention or a long hold needs `holds`.
- `copy.notice` includes "not medical advice".
- No medical claim term (`MEDICAL_TERMS` in `validate.mjs`) in copy, cues or stop prompts.
- Cues are in time order and start before `duration_s`.
- Ids are unique, and the basic set is exactly the eight default ids.

Phase meanings: `in`, `top_up` (a short second inhale), `hold` (a short,
comfortable, skippable pause), `out`, `hold_empty` (empty-lung retention after a
full exhale).

### Client copy

The client cannot bundle files from outside its package. It copies these files
into `client/assets/breath/` with `client/tool/sync_breath_content.sh` (built separately), and a planned
client test checks that the copy matches `content/breathwork/`. Edit the files
here, never the copies.
