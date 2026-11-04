import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { analyze, METRICS } from '../analyze.mjs';

const fixture = (name) => JSON.parse(readFileSync(new URL(`../fixtures/${name}.json`, import.meta.url), 'utf8'));
const FIXTURES = ['steady_shift', 'flags_and_missing', 'building_baseline'];

function checkExpected(name) {
  const { series, expected } = fixture(name);
  const out = analyze(series);
  for (const m of METRICS) {
    for (const [key, want] of Object.entries(expected[m])) {
      assert.deepEqual(out.metrics[m][key], want, `${name} ${m}.${key}`);
    }
  }
  assert.deepEqual(out.findings.map((f) => [f.metric, f.confidence]), expected.findings, `${name} findings`);
  assert.deepEqual(out.data_quality.missing_nights, expected.missing_nights);
  assert.deepEqual(out.data_quality.flagged_days, expected.flagged_days);
  return out;
}

for (const name of FIXTURES) test(`fixture ${name} matches hand-computed values`, () => checkExpected(name));

test('steady shift: trend rule and medium confidence', () => {
  const out = checkExpected('steady_shift');
  assert.equal(out.findings[0].evidence_rule, 'deviation_z_ge_2_with_enough_data');
  assert.equal(out.findings[1].evidence_rule, 'deviation_z_ge_1');
  assert.equal(out.data_quality.valid_nights.resting_hr, 21);
});

test('flagged days are excluded from baseline and recent, and reported', () => {
  const { series } = fixture('flags_and_missing');
  const out = analyze(series);
  assert.equal(out.metrics.resting_hr.baseline.mean, 60); // 62.5 if flags were included
  assert.equal(out.metrics.resting_hr.recent_mean, 64); // 69.2 if day 19 (travel, 90) were included
  assert.equal(out.data_quality.valid_nights.resting_hr, 17);
  const unflagged = analyze(series.map((s) => ({ ...s, flags: [] })));
  assert.equal(unflagged.metrics.resting_hr.baseline.mean, 62.5);
  assert.ok(out.findings.some((f) => f.evidence_rule === 'flagged_days_excluded'));
});

test('missing nights: nulls and non-numbers are treated as missing', () => {
  const { series } = fixture('flags_and_missing');
  const out = analyze(series);
  assert.equal(out.metrics.resting_hr.recent_valid_nights, 5);
  assert.ok(out.findings.some((f) => f.evidence_rule === 'missing_nights_reported'));
  const junk = series.map((s, i) => (i === 16 ? { ...s, resting_hr: 'NaN', hrv_rmssd: undefined } : s));
  assert.deepEqual(analyze(junk).data_quality.missing_nights, ['2026-01-17']);
});

test('building_baseline path: fewer than 7 valid nights gives no z or trend', () => {
  const out = checkExpected('building_baseline');
  const f = out.findings.find((x) => x.metric === 'resting_hr');
  assert.equal(f.evidence_rule, 'baseline_needs_7_valid_nights');
  assert.equal(out.metrics.hrv_rmssd.baseline.n, 7); // exactly 7 is enough
});

test('zero baseline SD gives no z-score', () => {
  const series = fixture('steady_shift').series.map((s) => ({ ...s, resting_hr: 60 }));
  const r = analyze(series).metrics.resting_hr;
  assert.deepEqual([r.baseline.sd, r.z_score, r.trend], [0, null, null]);
});

test('input order does not matter; wrong length and duplicates throw', () => {
  const { series } = fixture('steady_shift');
  assert.deepEqual(analyze([...series].reverse()), analyze(series));
  assert.throws(() => analyze(series.slice(1)), RangeError);
  assert.throws(() => analyze(null), TypeError);
  const dup = series.map((s, i) => (i === 1 ? { ...s, date: series[0].date } : s));
  assert.throws(() => analyze(dup), /duplicate/);
});

// Seeded LCG so the fuzz run is reproducible.
function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

test('no output ever says "conclusion"; every finding is a low/medium observation', () => {
  const rand = rng(42);
  const flagsPool = ['illness', 'alcohol', 'travel', 'other'];
  const pick = (p, v) => (rand() < p ? null : v);
  const outputs = FIXTURES.map((n) => analyze(fixture(n).series));
  for (let k = 0; k < 300; k++) {
    const nullRate = rand();
    const series = Array.from({ length: 21 }, (_, i) => ({
      date: `2026-02-${String(i + 1).padStart(2, '0')}`,
      resting_hr: pick(nullRate, 45 + rand() * 30),
      hrv_rmssd: pick(nullRate, 20 + rand() * 80),
      sleep_hours: pick(nullRate, 3 + rand() * 7),
      flags: rand() < 0.15 ? [flagsPool[Math.floor(rand() * 4)]] : [],
    }));
    outputs.push(analyze(series));
  }
  for (const out of outputs) {
    assert.ok(!/conclusion/i.test(JSON.stringify(out)));
    assert.match(out.notice, /Not medical advice/);
    for (const f of out.findings) {
      assert.equal(f.kind, 'observation');
      assert.ok(['low', 'medium'].includes(f.confidence));
      assert.equal(typeof f.evidence_rule, 'string');
      assert.match(f.expires_on, /^\d{4}-\d{2}-\d{2}$/);
    }
  }
});
