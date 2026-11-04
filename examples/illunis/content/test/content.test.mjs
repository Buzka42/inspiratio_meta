import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readdirSync } from 'node:fs';
import { basename } from 'node:path';
import {
  CONTENT_DIR, DEFAULT_IDS, MAX_BASIC_BPM, MAX_BASIC_HOLD_S, checkTechniqueSet, validateAll, validateDoc,
} from '../validate.mjs';

const results = validateAll();
const load = (file) => JSON.parse(readFileSync(join(CONTENT_DIR, file), 'utf8'));

for (const r of results) {
  test(`${r.file} is valid`, () => assert.deepEqual(r.errors, []));
}

test('required personalities and skills exist', () => {
  const files = results.map((r) => r.file);
  for (const id of ['productivity_advisor', 'personal_coach', 'socratic_tutor', 'calm_guide', 'drill_sergeant_trainer']) {
    assert.ok(files.includes(join('personalities', `${id}.json`)), id);
  }
  for (const id of ['breathwork', 'weight_training', 'motivation']) {
    assert.ok(files.includes(join('skills', `${id}.json`)), id);
  }
});

test('breathwork names about 6 breaths per minute and is not framed as treatment', () => {
  const doc = load('skills/breathwork.json');
  assert.match(doc.description, /6 breaths per minute/);
  assert.match(doc.description, /may help you feel calmer/);
  assert.match(doc.description, /not a treatment/);
});

const good = () => load('skills/breathwork.json');

test('rejects missing field, bad enum and extra property', () => {
  const doc = good();
  delete doc.steps;
  doc.claims[0].evidence_level = 'proven';
  doc.extra = 1;
  const errors = validateDoc('skill', doc, 'breathwork.json').join('\n');
  assert.match(errors, /missing steps/);
  assert.match(errors, /must be one of/);
  assert.match(errors, /unexpected property extra/);
});

test('rejects an unconfirmed number unless the claim is unverified', () => {
  const doc = good();
  doc.claims.push({ id: 'timing', text: 'Breathe in for 4 seconds.', evidence_level: 'moderate', source: null });
  assert.match(validateDoc('skill', doc, 'breathwork.json').join('\n'), /R5: claim "timing"/);
  doc.claims.at(-1).evidence_level = 'unverified';
  assert.deepEqual(validateDoc('skill', doc, 'breathwork.json'), []);
  doc.steps.push({ text: 'Hold for 7 seconds.', claims: [] });
  assert.match(validateDoc('skill', doc, 'breathwork.json').join('\n'), /R5: steps/);
});

test('rejects treatment language and unknown claim refs', () => {
  const doc = good();
  doc.claims[0].text = 'Slow breathing cures anxiety.';
  doc.steps[0].claims = ['nope'];
  const errors = validateDoc('skill', doc, 'breathwork.json').join('\n');
  assert.match(errors, /R6/);
  assert.match(errors, /R4: steps\[0\] refers to unknown claim "nope"/);
});

test('rejects a personality whose prompt uses its banned phrase or wrong id', () => {
  const doc = load('personalities/drill_sergeant_trainer.json');
  doc.system_prompt += ' No pain no gain!';
  const errors = validateDoc('personality', doc, 'other.json').join('\n');
  assert.match(errors, /R3: system_prompt contains banned phrase "no pain no gain"/);
  assert.match(errors, /R1/);
});

test('CLI exits 0 on the shipped content', () => {
  const run = spawnSync(process.execPath, [join(CONTENT_DIR, 'validate.mjs')], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
});

test('CLI exits non-zero when a file is invalid', () => {
  const dir = mkdtempSync(join(tmpdir(), 'illunis-content-'));
  try {
    for (const d of ['schemas', 'personalities', 'skills', 'breathwork']) cpSync(join(CONTENT_DIR, d), join(dir, d), { recursive: true });
    writeFileSync(join(dir, 'skills', 'broken.json'), '{"id": "broken"}');
    const run = spawnSync(process.execPath, [join(CONTENT_DIR, 'validate.mjs'), dir], { encoding: 'utf8' });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /FAIL skills\/broken.json/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// Breathwork techniques (plan B7, research examples/illunis/docs/breathwork_meditation.md).

const techFiles = readdirSync(join(CONTENT_DIR, 'breathwork')).filter((f) => f.endsWith('.json')).sort();
const techs = techFiles.map((f) => ({ file: f, doc: load(join('breathwork', f)) }));
const byId = Object.fromEntries(techs.map((t) => [t.doc.id, t.doc]));
const vt = (doc, name = `${doc.id}.json`) => validateDoc('technique', doc, name).join('\n');
const clone = (id) => structuredClone(byId[id]);
const cycle = (doc) => doc.pacing.phases.reduce((s, p) => s + p.seconds, 0);

test('ids are unique and match file names', () => {
  const ids = techs.map((t) => t.doc.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const t of techs) assert.equal(t.doc.id, basename(t.file, '.json'));
});

test('the eight default ids are exactly the basic set', () => {
  assert.equal(DEFAULT_IDS.length, 8);
  const basic = techs.filter((t) => t.doc.level === 'basic').map((t) => t.doc.id).sort();
  assert.deepEqual(basic, [...DEFAULT_IDS].sort());
});

test('every non-default technique is advanced', () => {
  const advanced = ['nadi_shodhana', 'bhramari', 'ujjayi', 'kapalabhati', 'breath_of_fire', 'kumbhaka', 'holotropic'];
  for (const id of advanced) assert.equal(byId[id]?.level, 'advanced', id);
  for (const t of techs) if (!DEFAULT_IDS.includes(t.doc.id)) assert.equal(t.doc.level, 'advanced', t.doc.id);
});

test('basic rules hold on shipped content', () => {
  for (const id of DEFAULT_IDS) {
    const doc = byId[id];
    assert.ok(doc.available, id);
    assert.ok(60 / cycle(doc) <= MAX_BASIC_BPM + 1e-9, `${id} rate`);
    assert.ok(doc.pacing.phases.every((p) => p.phase !== 'hold_empty'), `${id} hold_empty`);
    assert.ok(doc.pacing.phases.filter((p) => p.phase === 'hold').every((p) => p.seconds <= MAX_BASIC_HOLD_S), `${id} hold`);
    assert.ok(!doc.screens.includes('forceful'), `${id} forceful`);
    assert.equal(doc.count_in_cycles, 3);
  }
});

test('holotropic stays unavailable with only its own screen', () => {
  const h = byId.holotropic;
  assert.equal(h.available, false);
  assert.deepEqual(h.screens, ['holotropic']);
  assert.equal(h.pacing, null);
  const bad = clone('holotropic');
  bad.available = true;
  assert.match(vt(bad), /T7: holotropic must be available:false/);
});

test('validator rejects basic rule breaks', () => {
  const fast = clone('paced_breath');
  fast.pacing.phases = [{ phase: 'in', seconds: 4 }, { phase: 'out', seconds: 4 }];
  fast.pacing.rate_bpm = 7.5;
  assert.match(vt(fast), /T4: basic rate 7.50 bpm exceeds 6/);

  const hold = clone('box_breathing');
  hold.pacing.phases[1].seconds = 5;
  hold.pacing.rate_bpm = 60 / 17;
  assert.match(vt(hold), /T4: basic hold over 4 s/);

  const empty = clone('box_breathing');
  empty.pacing.phases[3].phase = 'hold_empty';
  assert.match(vt(empty), /T4: basic technique has a hold_empty phase/);

  const forceful = clone('long_exhale');
  forceful.screens = ['default', 'forceful'];
  assert.match(vt(forceful), /T4: basic technique has the forceful screen/);
});

test('validator rejects a rate_bpm that does not match the phases', () => {
  const doc = clone('paced_breath');
  doc.pacing.rate_bpm = 5;
  assert.match(vt(doc), /T5/);
});

test('validator rejects medical claim words in copy, cues and stop prompts', () => {
  for (const word of ['cure', 'treats', 'diagnose', 'healing', 'reduce blood pressure', 'anxiety disorder',
    'depression treatment', 'medication', 'dose']) {
    const doc = clone('paced_breath');
    doc.copy.intent = `This may ${word} things.`;
    assert.match(vt(doc), /T3: copy.intent contains medical claim term/, word);
  }
  const cue = clone('body_scan');
  cue.cues[0].text = 'This heals you.';
  assert.match(vt(cue), /T3: cues\[0\]/);
  const ok = clone('paced_breath');
  ok.copy.intent = 'If you have a health condition, ask first.';
  assert.doesNotMatch(vt(ok), /T3/);
});

test('validator enforces the not-medical-advice notice', () => {
  const doc = clone('loving_kindness');
  doc.copy.notice = 'Enjoy.';
  assert.match(vt(doc), /T2/);
});

test('validator enforces advanced screens from the research', () => {
  const kap = clone('kapalabhati');
  kap.screens = ['default'];
  assert.match(vt(kap), /T8: screens must be/);
  const unknown = clone('nadi_shodhana');
  unknown.id = 'new_pranayama';
  assert.match(vt(unknown, 'new_pranayama.json'), /T8: advanced technique has only the default screen/);
  const retention = clone('ujjayi');
  retention.pacing.phases.push({ phase: 'hold_empty', seconds: 10 });
  retention.pacing.rate_bpm = 60 / 20;
  assert.match(vt(retention), /T8: retention or long hold needs the holds screen/);
});

test('validator rejects an available technique without pacing and a bad schema', () => {
  const doc = clone('kumbhaka');
  doc.available = true;
  doc.count_in_cycles = 2;
  doc.kind = 'chant';
  const errors = vt(doc);
  assert.match(errors, /T6/);
  assert.match(errors, /count_in_cycles: must equal 3/);
  assert.match(errors, /kind: must be one of/);
});

test('set check rejects duplicate ids and a changed basic set', () => {
  const entries = techs.map((t) => ({ ...t, doc: structuredClone(t.doc) }));
  entries.find((e) => e.doc.id === 'ujjayi').doc.level = 'basic';
  entries.push({ file: 'dup.json', doc: structuredClone(byId.bhramari) });
  const errors = checkTechniqueSet(entries).join('\n');
  assert.match(errors, /C1: duplicate id "bhramari"/);
  assert.match(errors, /C1: basic set/);
});
