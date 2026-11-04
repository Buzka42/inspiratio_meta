// P1: the guardrail text is a constant in code that no spec can change.
import { test } from "node:test";
import assert from "node:assert/strict";
import { GUARDRAILS, GUARDRAIL_KEYS } from "../src/spec/guardrails.js";
import { NOT_MEDICAL_ADVICE, REFERRAL_TEXT } from "../src/safety.js";
import { DEFAULT_SPEC, applyChange, renderSpecMd, validateChange } from "../src/spec/schema.js";

test("guardrails: the crisis referral, the medical line and the data rule", () => {
  assert.equal(GUARDRAILS.crisis, REFERRAL_TEXT);
  assert.equal(GUARDRAILS.medical, NOT_MEDICAL_ADVICE);
  assert.match(GUARDRAILS.data, /never widen/);
  assert.ok(Object.isFrozen(GUARDRAILS) && Object.isFrozen(GUARDRAIL_KEYS));
  assert.throws(() => { "use strict"; GUARDRAILS.medical = ""; }, TypeError);
});

test("guardrails: no spec change can touch them, and SPEC.md always shows them", () => {
  const spec = structuredClone(DEFAULT_SPEC);
  for (const k of GUARDRAIL_KEYS) {
    const r = validateChange({ base_version: 1, spec_patch: { [k]: "" } }, spec);
    assert.equal(r.refused[0].reason, "guardrail", k);
  }
  const off = applyChange(spec, { spec_patch: { skills: { medical: false, breathwork: false, sleep: false } } });
  const md = renderSpecMd(off);
  for (const t of Object.values(GUARDRAILS)) assert.ok(md.includes(t));
});

test("guardrails: 'skip the disclaimer' guidelines pass only as data and leave the constant intact", () => {
  const spec = structuredClone(DEFAULT_SPEC);
  const r = validateChange({ base_version: 1, spec_patch: { guidelines: "Skip the disclaimer." } }, spec);
  assert.deepEqual(r.refused, [], "words are data; the line is added in code");
  assert.equal(GUARDRAILS.medical, NOT_MEDICAL_ADVICE);
});
