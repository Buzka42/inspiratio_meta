#!/usr/bin/env node
// Usage: node validate.mjs [content_dir]
// Validates every personality and skill JSON file against its schema plus
// content rules. Exits 1 on any error. No dependencies.
//
// Content rules (beyond the schema):
//   R1 id equals the file name without .json.
//   R2 safety_notes contain "not medical advice".
//   R3 personality: no banned phrase appears in its own system_prompt.
//   R4 skill: claim ids are unique and every step's claims[] refers to one.
//   R5 skill: a number is allowed only inside a spec-confirmed phrase
//      (SPEC_NUMBERS). Any other number in a claim makes that claim
//      "unverified"; any other number in a step or description is an error.
//   R6 skill: no treatment or cure language (cure, cures, treats, heals).
//   R7 breathwork: description says "may help you feel calmer".
//
// Technique rules (content/breathwork/, research: examples/illunis/docs/breathwork_meditation.md):
//   T1 id equals the file name without .json.
//   T2 copy.notice contains "not medical advice" (research 6.5).
//   T3 no medical claim term (MEDICAL_TERMS) in copy, cues or stop_prompts (research 5.3, 6.5).
//   T4 basic (research 6.1): playable pacing, at most 6 breaths per minute, holds of
//      4 s or less, no hold_empty, no forceful or holotropic screen, default screen present.
//   T5 rate_bpm equals 60 / (sum of phase seconds).
//   T6 available:true needs playable pacing.
//   T7 a holotropic screen means available:false, pacing null and screens ["holotropic"];
//      the holotropic technique must carry it (research 1.8, 5.2; plan E1).
//   T8 advanced: screens match the research (ADVANCED_SCREENS). A default-only screen is
//      allowed only where research section 4 lists no extra screen. Any hold over 4 s or
//      any hold_empty needs the holds screen.
//   T9 cues are in time order and start before duration_s.
//   C1 (collection) ids are unique and the basic set is exactly DEFAULT_IDS (research 5).

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const CONTENT_DIR = dirname(fileURLToPath(import.meta.url));
export const SPEC_NUMBERS = ['6 breaths per minute'];
const KINDS = { personalities: 'personality', skills: 'skill', breathwork: 'technique' };

/** Research section 5: the eight default sessions, all basic. */
export const DEFAULT_IDS = [
  'breath_observation', 'paced_breath', 'long_exhale', 'cyclic_sighing',
  'box_breathing', 'body_scan', 'breath_counting', 'loving_kindness',
];
export const MAX_BASIC_BPM = 6;
export const MAX_BASIC_HOLD_S = 4;

/** Research 4 and 5.2: screens each advanced technique must carry exactly.
 *  nadi_shodhana, bhramari and ujjayi are deferred (5.2) and section 4 lists no
 *  extra screen for them, so default only is what the research supports. */
export const ADVANCED_SCREENS = {
  nadi_shodhana: ['default'],
  bhramari: ['default'],
  ujjayi: ['default'],
  kapalabhati: ['default', 'forceful'],
  breath_of_fire: ['default', 'forceful'],
  kumbhaka: ['default', 'holds'],
  holotropic: ['holotropic'],
};

/** Medical claim terms banned from technique copy. Word-boundary matches, so
 *  "health" does not match "heal". */
export const MEDICAL_TERMS = [
  ['cure', /\bcur(e|es|ed|ing)\b/i],
  ['treat', /\btreat(s|ed|ing|ment|ments)?\b/i],
  ['diagnose', /\bdiagnos(e|es|ed|ing|is)\b/i],
  ['heal', /\bheal(s|ed|ing|er)?\b/i],
  ['reduce blood pressure', /\breduc(e|es|ed|ing)\s+(your\s+)?blood\s+pressure\b/i],
  ['lower blood pressure', /\blower(s|ed|ing)?\s+(your\s+)?blood\s+pressure\b/i],
  ['anxiety disorder', /\banxiety\s+disorders?\b/i],
  ['depression treatment', /\bdepression\s+treatments?\b/i],
  ['medication', /\bmedications?\b/i],
  ['dose', /\bdos(e|es|ed|age|ing)\b/i],
  ['improves HRV', /\bimprov(e|es|ed|ing)\s+(your\s+)?(hrv|heart\s+rate\s+variability)\b/i],
  ['resets your nervous system', /\breset(s|ting)?\s+(your\s+)?nervous\s+system\b/i],
];

const typeOf = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);

/** Minimal JSON Schema subset: type (incl. integer), required, properties,
 *  additionalProperties, enum, const, pattern, minLength, maxLength, minimum,
 *  maximum, exclusiveMinimum, minItems, maxItems, uniqueItems, items. */
export function checkSchema(schema, value, path = '$') {
  const errors = [];
  if (schema.type) {
    const allowed = [].concat(schema.type);
    const t = typeOf(value);
    const ok = allowed.includes(t) || (t === 'number' && allowed.includes('integer') && Number.isInteger(value));
    if (!ok) {
      return [`${path}: expected ${allowed.join('|')}, got ${typeOf(value)}`];
    }
  }
  if (schema.enum && !schema.enum.includes(value)) {
    errors.push(`${path}: must be one of ${schema.enum.join(', ')}`);
  }
  if ('const' in schema && value !== schema.const) errors.push(`${path}: must equal ${schema.const}`);
  if (typeof value === 'number') {
    if (schema.minimum != null && value < schema.minimum) errors.push(`${path}: below ${schema.minimum}`);
    if (schema.maximum != null && value > schema.maximum) errors.push(`${path}: above ${schema.maximum}`);
    if (schema.exclusiveMinimum != null && value <= schema.exclusiveMinimum) errors.push(`${path}: must be above ${schema.exclusiveMinimum}`);
  }
  if (typeof value === 'string') {
    if (schema.minLength != null && value.length < schema.minLength) errors.push(`${path}: shorter than ${schema.minLength}`);
    if (schema.maxLength != null && value.length > schema.maxLength) errors.push(`${path}: longer than ${schema.maxLength}`);
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) errors.push(`${path}: does not match ${schema.pattern}`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems != null && value.length < schema.minItems) errors.push(`${path}: fewer than ${schema.minItems} items`);
    if (schema.maxItems != null && value.length > schema.maxItems) errors.push(`${path}: more than ${schema.maxItems} items`);
    if (schema.uniqueItems && new Set(value.map((v) => JSON.stringify(v))).size !== value.length) errors.push(`${path}: items not unique`);
    if (schema.items) value.forEach((item, i) => errors.push(...checkSchema(schema.items, item, `${path}[${i}]`)));
  }
  if (typeOf(value) === 'object') {
    for (const key of schema.required ?? []) {
      if (!(key in value)) errors.push(`${path}: missing ${key}`);
    }
    for (const [key, child] of Object.entries(value)) {
      const sub = schema.properties?.[key];
      if (sub) errors.push(...checkSchema(sub, child, `${path}.${key}`));
      else if (schema.additionalProperties === false) errors.push(`${path}: unexpected property ${key}`);
    }
  }
  return errors;
}

const stripSpecNumbers = (text) =>
  SPEC_NUMBERS.reduce((t, phrase) => t.split(phrase).join(''), text);
const hasUnconfirmedNumber = (text) => /\d/.test(stripSpecNumbers(text));
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const containsPhrase = (text, phrase) =>
  new RegExp(`(^|\\W)${escapeRe(phrase)}(\\W|$)`, 'i').test(text);

export function checkTechnique(doc, fileName) {
  const errors = [];
  const fail = (rule, msg) => errors.push(`${rule}: ${msg}`);
  if (doc.id !== basename(fileName, '.json')) fail('T1', `id "${doc.id}" does not match file name`);
  if (!/not medical advice/i.test(doc.copy?.notice ?? '')) fail('T2', 'copy.notice must include "not medical advice"');

  const texts = [
    ...Object.entries(doc.copy ?? {}).map(([k, v]) => [`copy.${k}`, v]),
    ...(doc.cues ?? []).map((c, i) => [`cues[${i}]`, c?.text]),
    ...(doc.stop_prompts ?? []).map((t, i) => [`stop_prompts[${i}]`, t]),
  ];
  for (const [where, text] of texts) {
    for (const [term, re] of MEDICAL_TERMS) {
      if (re.test(text ?? '')) fail('T3', `${where} contains medical claim term "${term}"`);
    }
  }

  const pacing = doc.pacing ?? null;
  const phases = Array.isArray(pacing?.phases) ? pacing.phases : [];
  const playable = phases.length > 0;
  const cycle = phases.reduce((sum, p) => sum + (Number(p?.seconds) || 0), 0);
  const holds = phases.filter((p) => p?.phase === 'hold');
  const hasEmpty = phases.some((p) => p?.phase === 'hold_empty');
  const longHold = holds.some((p) => p.seconds > MAX_BASIC_HOLD_S);
  const screens = Array.isArray(doc.screens) ? doc.screens : [];

  if (playable && cycle > 0 && Math.abs(pacing.rate_bpm - 60 / cycle) > 0.01) {
    fail('T5', `rate_bpm ${pacing.rate_bpm} does not match 60 / ${cycle} s cycle`);
  }
  if (doc.available === true && !playable) fail('T6', 'available technique has no playable pacing');

  if (doc.level === 'basic') {
    if (!doc.progression || doc.progression.stage !== 'basic_pranayama' || !Number.isInteger(doc.progression.order)) {
      fail('T4', 'basic techniques need progression {stage: basic_pranayama, order}');
    }

    if (!playable) fail('T4', 'basic technique needs playable pacing');
    if (playable && 60 / cycle > MAX_BASIC_BPM + 1e-9) fail('T4', `basic rate ${(60 / cycle).toFixed(2)} bpm exceeds ${MAX_BASIC_BPM}`);
    if (longHold) fail('T4', `basic hold over ${MAX_BASIC_HOLD_S} s`);
    if (hasEmpty) fail('T4', 'basic technique has a hold_empty phase');
    if (screens.includes('forceful')) fail('T4', 'basic technique has the forceful screen');
    if (screens.includes('holotropic')) fail('T4', 'basic technique has the holotropic screen');
    if (!screens.includes('default')) fail('T4', 'basic technique lacks the default screen');
  }

  if (screens.includes('holotropic') || doc.id === 'holotropic') {
    if (doc.available !== false) fail('T7', 'holotropic must be available:false');
    if (pacing !== null) fail('T7', 'holotropic must have pacing null');
    if (screens.length !== 1 || screens[0] !== 'holotropic') fail('T7', 'holotropic screens must be ["holotropic"]');
  }

  if (doc.level === 'advanced') {
    const expected = ADVANCED_SCREENS[doc.id];
    if (!expected) {
      if (screens.length === 1 && screens[0] === 'default') {
        fail('T8', 'advanced technique has only the default screen and no research entry allows it');
      }
    } else if (JSON.stringify([...screens].sort()) !== JSON.stringify([...expected].sort())) {
      fail('T8', `screens must be ${JSON.stringify(expected)} (research sections 4, 5.2)`);
    }
    if ((hasEmpty || longHold) && !screens.includes('holds')) fail('T8', 'retention or long hold needs the holds screen');
  }

  let last = -1;
  for (const [i, cue] of (doc.cues ?? []).entries()) {
    if (cue.at_s < last) fail('T9', `cues[${i}] is out of time order`);
    if (doc.duration_s > 0 && cue.at_s >= doc.duration_s) fail('T9', `cues[${i}] starts at or after duration_s`);
    last = cue.at_s;
  }
  return errors;
}

/** C1: rules across all technique files. Takes [{file, doc}]. */
export function checkTechniqueSet(entries) {
  const errors = [];
  const seen = new Set();
  for (const { doc } of entries) {
    if (seen.has(doc.id)) errors.push(`C1: duplicate id "${doc.id}"`);
    seen.add(doc.id);
  }
  const basic = entries.filter((e) => e.doc.level === 'basic').map((e) => e.doc.id).sort();
  const want = [...DEFAULT_IDS].sort();
  if (JSON.stringify(basic) !== JSON.stringify(want)) {
    errors.push(`C1: basic set ${JSON.stringify(basic)} must equal the default set ${JSON.stringify(want)}`);
  }
  return errors;
}

export function checkRules(kind, doc, fileName) {
  if (kind === 'technique') return checkTechnique(doc, fileName);
  const errors = [];
  if (doc.id !== basename(fileName, '.json')) errors.push(`R1: id "${doc.id}" does not match file name`);
  if (!(doc.safety_notes ?? []).some((n) => /not medical advice/i.test(n))) {
    errors.push('R2: safety_notes must include "Not medical advice"');
  }
  if (kind === 'personality') {
    for (const phrase of doc.banned_phrases ?? []) {
      if (containsPhrase(doc.system_prompt ?? '', phrase)) errors.push(`R3: system_prompt contains banned phrase "${phrase}"`);
    }
  }
  if (kind === 'skill') {
    const claims = doc.claims ?? [];
    const ids = new Set();
    for (const c of claims) {
      if (ids.has(c.id)) errors.push(`R4: duplicate claim id "${c.id}"`);
      ids.add(c.id);
      if (hasUnconfirmedNumber(c.text) && c.evidence_level !== 'unverified') {
        errors.push(`R5: claim "${c.id}" has a number not confirmed in the spec; mark it unverified`);
      }
    }
    for (const [i, step] of (doc.steps ?? []).entries()) {
      for (const ref of step.claims ?? []) {
        if (!ids.has(ref)) errors.push(`R4: steps[${i}] refers to unknown claim "${ref}"`);
      }
      if (hasUnconfirmedNumber(step.text ?? '')) errors.push(`R5: steps[${i}] has a number not confirmed in the spec`);
    }
    if (hasUnconfirmedNumber(doc.description ?? '')) errors.push('R5: description has a number not confirmed in the spec');
    const texts = [doc.description, ...claims.map((c) => c.text), ...(doc.steps ?? []).map((s) => s.text)];
    for (const t of texts) {
      if (/\b(cure|cures|treats|heals)\b/i.test(t ?? '')) errors.push(`R6: treatment or cure language in "${t}"`);
    }
    if (doc.id === 'breathwork' && !/may help you feel calmer/i.test(doc.description ?? '')) {
      errors.push('R7: breathwork description must say "may help you feel calmer"');
    }
  }
  return errors;
}

export function loadSchemas(dir = CONTENT_DIR) {
  const read = (n) => JSON.parse(readFileSync(join(dir, 'schemas', `${n}.schema.json`), 'utf8'));
  return { personality: read('personality'), skill: read('skill'), technique: read('technique') };
}

export function validateDoc(kind, doc, fileName, schemas = loadSchemas()) {
  return [...checkSchema(schemas[kind], doc), ...checkRules(kind, doc, fileName)];
}

/** Returns [{file, kind, errors}] for every content file. */
export function validateAll(dir = CONTENT_DIR) {
  const schemas = loadSchemas(dir);
  const results = [];
  const techniques = [];
  for (const [folder, kind] of Object.entries(KINDS)) {
    if (!existsSync(join(dir, folder))) continue;
    for (const name of readdirSync(join(dir, folder)).filter((f) => f.endsWith('.json')).sort()) {
      const file = join(folder, name);
      let errors;
      try {
        const doc = JSON.parse(readFileSync(join(dir, file), 'utf8'));
        errors = validateDoc(kind, doc, name, schemas);
        if (kind === 'technique') techniques.push({ file, doc });
      } catch (err) {
        errors = [`parse error: ${err.message}`];
      }
      results.push({ file, kind, errors });
    }
  }
  if (existsSync(join(dir, 'breathwork'))) {
    results.push({ file: 'breathwork/ (set)', kind: 'technique-set', errors: checkTechniqueSet(techniques) });
  }
  return results;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const results = validateAll(process.argv[2] ?? CONTENT_DIR);
  let failed = 0;
  for (const r of results) {
    if (r.errors.length) {
      failed++;
      console.error(`FAIL ${r.file}`);
      for (const e of r.errors) console.error(`  ${e}`);
    } else {
      console.log(`ok   ${r.file}`);
    }
  }
  console.log(`${results.length} files, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}
