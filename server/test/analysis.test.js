// 21-day analysis: pure functions only, synthetic fixtures only (no real check-ins).
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildDailySeries, signalSeries, localDate } from "../src/analysis/daily.js";
import { mean, sampleSd, olsTrend, lag1Autocorr } from "../src/analysis/stats.js";
import { qualityFlags, RULES } from "../src/analysis/quality.js";
import { computeFindings, toHypothesis, isExpired, seFactor, rollingMeans, SOURCE } from "../src/analysis/findings.js";
import { buildPhrasePrompt, checkPhrasing, phraseInput, routeCrisis, fallbackText } from "../src/analysis/phrase.js";
import { NOT_MEDICAL_ADVICE, REFERRAL_TEXT, touchesHealth } from "../src/safety.js";
import { InMemoryStore, validateMemory } from "../src/memory.js";

const NOW = Date.parse("2026-10-25T09:00:00Z");
const DAY = 86_400_000;
const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) < eps, `${a} != ${b}`);

// Seeded PRNG (mulberry32) so noise fixtures are stable across runs.
const rng = (a) => () => {
  a |= 0;
  a = (a + 0x6d2b79f5) | 0;
  let t = Math.imul(a ^ (a >>> 15), 1 | a);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
// 21 values (null = missing) -> one energy check-in at noon UTC per observed day.
const energy = (vals, start = "2026-09-01") =>
  signalSeries(
    buildDailySeries(
      vals.flatMap((v, i) => (v === null ? [] : [{ at: Date.parse(`${start}T12:00:00Z`) + i * DAY, energy: v }])),
      { start, tz: "UTC" },
    ),
    "energy",
  );
const stable = () => {
  const r = rng(1);
  return Array.from({ length: 21 }, () => 3 + (r() - 0.5) * 1.6);
};
const declining = () => Array.from({ length: 21 }, (_, i) => 5 - 0.15 * i);
const ar1 = (seed, phi = 0.7) => {
  const r = rng(seed);
  let y = 0;
  return Array.from({ length: 21 }, () => {
    y = phi * y + (r() - 0.5) * 1.2;
    return Math.min(5, Math.max(1, 3 + y));
  });
};

// daily.js

test("daily: 21 slots, missing day is null, same-day check-ins give mean and count", () => {
  const d = buildDailySeries(
    [
      { at: "2026-09-01T08:00:00Z", mood: 2, energy: 3 },
      { at: "2026-09-01T20:00:00Z", mood: 4 },
      { at: "2026-09-03T08:00:00Z", energy: 7 }, // out of range, ignored
      { at: "2026-08-31T08:00:00Z", energy: 4 }, // before the window
    ],
    { start: "2026-09-01", tz: "UTC" },
  );
  assert.equal(d.dates.length, 21);
  assert.equal(d.dates[20], "2026-09-21");
  assert.deepEqual(d.signals.mood[0], { mean: 3, count: 2 });
  assert.deepEqual(d.signals.energy[0], { mean: 3, count: 1 });
  assert.equal(d.signals.mood[1], null);
  assert.equal(d.signals.energy[2], null);
  assert.equal(d.signals.sleep.filter(Boolean).length, 0);
});

test("daily: local day follows the time zone, bad input throws", () => {
  assert.equal(localDate("2026-09-01T22:30:00Z", "Europe/Warsaw"), "2026-09-02");
  const d = buildDailySeries([{ at: "2026-09-01T22:30:00Z", mood: 5 }], { start: "2026-09-01", tz: "Europe/Warsaw" });
  assert.equal(d.signals.mood[0], null);
  assert.deepEqual(d.signals.mood[1], { mean: 5, count: 1 });
  assert.throws(() => buildDailySeries([], { start: "2026-02-30" }), TypeError);
  assert.throws(() => buildDailySeries([], { start: "2026-09-01", tz: "Nowhere/City" }), RangeError);
});

// stats.js, against hand-computed values

test("stats: mean and sample SD", () => {
  assert.equal(mean([1, 2, 3, 4]), 2.5);
  assert.equal(mean([]), null);
  close(sampleSd([2, 4, 4, 4, 5, 5, 7, 9]), Math.sqrt(32 / 7));
  assert.equal(sampleSd([3]), null);
});

test("stats: OLS slope, SE, t, df on a 4-point example", () => {
  // x 0..3, y 1,3,2,4: Sxx 5, Sxy 4, b 0.8, a 1.3, RSS 1.8, s sqrt(0.9), SE s/sqrt(5).
  const f = olsTrend([0, 1, 2, 3], [1, 3, 2, 4]);
  close(f.slope, 0.8);
  close(f.intercept, 1.3);
  close(f.se, Math.sqrt(0.9) / Math.sqrt(5));
  close(f.t, 0.8 / (Math.sqrt(0.9) / Math.sqrt(5)));
  assert.equal(f.df, 2);
  f.residuals.forEach((r, i) => close(r, [-0.3, 0.9, -0.9, 0.3][i]));
  assert.equal(olsTrend([0, 1], [1, 2]), null);
});

test("stats: lag-1 autocorrelation", () => {
  close(lag1Autocorr([1, 2, 3, 4, 5]), 0.4); // 4 / 10
  close(lag1Autocorr([1, -1, 1, -1]), -0.75); // -3 / 4
  assert.equal(lag1Autocorr([2, 2, 2]), null);
});

// quality.js and findings.js fixtures

test("stable seeded noise: no flags beyond self_report_only, nothing to say", () => {
  const f = computeFindings(energy(stable()));
  assert.deepEqual(f.flags, ["self_report_only"]);
  assert.equal(f.effect, null);
  assert.ok(Math.abs(f.trend.t) < 2);
  assert.equal(f.confidence, 0.56); // 0.3 + 0.02 * (21 - 8)
  assert.equal(toHypothesis(f, NOW), null);
});

test("exact declining line: effect and trend, hypothesis record shape", () => {
  const f = computeFindings(energy(declining()));
  assert.deepEqual(f.flags, ["self_report_only"]);
  close(f.effect.diff, -2.1);
  close(f.baseline.mean, 4.55);
  close(f.recent.mean, 2.45);
  close(f.trend.slope, -0.15);
  assert.equal(f.trend.se, 0);
  assert.equal(f.trend.t, -Infinity);
  assert.equal(f.trend.df, 12);
  assert.equal(f.trend.r1, null);
  assert.equal(f.confidence, 0.56);
  close(f.rolling[6], mean(declining().slice(0, 7)));
  assert.equal(f.rolling[2], null); // fewer than 4 days in the window

  const h = toHypothesis(f, NOW);
  assert.equal(h.kind, "hypothesis");
  assert.equal(h.label, "observation");
  assert.equal(h.source, SOURCE);
  assert.equal(h.confidence, 0.56);
  assert.equal(h.expires_at, new Date(NOW + 14 * DAY).toISOString());
  assert.match(h.text, /energy self-ratings averaged 2\.1 points lower in the last 7 days than in the first 7 \(14 of 14 days rated\)/);
  assert.match(h.text, /drifted down by about 0\.15 points per day \(14 days rated\)/);
  assert.ok(!validateMemory(h, NOW).error, "record passes validateMemory");
});

test("8 missing days: sparse, no claims, confidence 0.2", () => {
  const v = declining();
  for (const i of [1, 4, 8, 10, 12, 15, 17, 19]) v[i] = null;
  const f = computeFindings(energy(v));
  assert.ok(f.flags.includes("sparse"));
  assert.equal(f.valid_days, 13);
  assert.equal(f.effect, null);
  assert.equal(f.trend, null);
  assert.equal(f.confidence, 0.2);
  assert.equal(toHypothesis(f, NOW), null);
  assert.equal(phraseInput(f), null);
});

test("constant series: low_variance blocks claims", () => {
  const f = computeFindings(energy(Array(21).fill(3)));
  assert.deepEqual(f.flags, ["low_variance", "self_report_only"]);
  assert.equal(f.effect, null);
  assert.equal(f.confidence, 0.2);
  assert.equal(toHypothesis(f, NOW), null);
});

test("4 points: too_few_points, baseline_insufficient, sparse", () => {
  const v = Array(21).fill(null);
  [0, 6, 13, 20].forEach((i, k) => (v[i] = [2, 3, 4, 5][k]));
  const flags = qualityFlags(energy(v));
  for (const flag of ["sparse", "too_few_points", "baseline_insufficient", "self_report_only"]) assert.ok(flags.includes(flag), flag);
  assert.equal(computeFindings(energy(v)).trend, null);
});

test("AR(1) phi 0.7: residual autocorrelation inflates SE and lowers confidence", () => {
  const f = computeFindings(energy(ar1(11)));
  assert.deepEqual(f.flags, ["self_report_only"]);
  assert.ok(f.trend.r1 > RULES.r1Limit, `r1 ${f.trend.r1}`);
  assert.equal(f.trend.inflated, true);
  close(f.trend.se, f.trend.se_raw * Math.sqrt((1 + f.trend.r1) / (1 - f.trend.r1)));
  assert.ok(Math.abs(f.trend.t) < Math.abs(f.trend.slope / f.trend.se_raw));
  assert.equal(f.confidence, 0.46); // 0.56 - 0.1
});

test("SE factor: only |r1| > 0.3 inflates, never shrinks", () => {
  assert.equal(seFactor(0.2), 1);
  assert.equal(seFactor(null), 1);
  close(seFactor(0.5), Math.sqrt(3));
  assert.equal(seFactor(-0.5), 1);
});

test("rolling mean needs 4 observed days in the trailing 7", () => {
  const slots = [1, null, 2, null, 3, 4, null].map((v) => (v === null ? null : { mean: v, count: 1 }));
  const r = rollingMeans(slots);
  assert.equal(r[4], null);
  close(r[5], 2.5);
});

test("expired hypothesis: expires 14 days after creation and drops from recall", async () => {
  const h = toHypothesis(computeFindings(energy(declining())), NOW);
  assert.equal(isExpired(h, NOW + 13 * DAY), false);
  assert.equal(isExpired(h, NOW + 14 * DAY), true);
  // Local test store only; the analysis is not wired to memory yet.
  const store = new InMemoryStore();
  await store.write(validateMemory(h, NOW).item);
  assert.equal((await store.recall({ query: "energy", now: NOW + DAY })).length, 1);
  assert.equal((await store.recall({ query: "energy", now: NOW + 15 * DAY })).length, 0);
});

// phrase.js and safety

test("crisis text routes to the referral before analysis and in model output", () => {
  assert.equal(routeCrisis(["slept badly", "I want to die"]), REFERRAL_TEXT);
  assert.equal(routeCrisis(["slept badly"]), null);
  const input = phraseInput(computeFindings(energy(declining())));
  const r = checkPhrasing("Your energy dipped. I want to die.", input);
  assert.deepEqual(r, { ok: false, reason: "gate", text: REFERRAL_TEXT });
  assert.equal(checkPhrasing("You must rest more.", input).reason, "gate");
});

test("energy-only text carries the not-medical-advice line", () => {
  assert.ok(touchesHealth({ texts: ["My energy was low this week"] }));
  assert.ok(touchesHealth({ texts: ["felt energetic"] }));
  const input = phraseInput(computeFindings(energy(declining())));
  const r = checkPhrasing("A tentative observation: energy ratings were 2.1 points lower in the last 7 days.", input);
  assert.equal(r.ok, true);
  assert.ok(r.text.endsWith(NOT_MEDICAL_ADVICE));
  assert.equal(r.text.split(NOT_MEDICAL_ADVICE).length, 2, "disclaimer once");
  const h = toHypothesis(computeFindings(energy(declining())), NOW);
  assert.ok(fallbackText(h).endsWith(NOT_MEDICAL_ADVICE));
  assert.equal(checkPhrasing(h.text, input).ok, true, "own sentence passes its own checker");
});

test("checker rejects numbers absent from the input and forbidden words", () => {
  const input = phraseInput(computeFindings(energy(declining())));
  assert.equal(checkPhrasing("Energy was 0.9 points lower in these check-ins.", input).reason, "number_not_in_input");
  assert.equal(checkPhrasing("Energy was 2.1 points lower, about 30% less.", input).reason, "number_not_in_input");
  assert.equal(checkPhrasing("In conclusion, energy was 2.1 points lower.", input).reason, "forbidden_word");
  assert.equal(checkPhrasing("Energy was lower, a sign of burnout.", input).reason, "forbidden_word");
  assert.equal(checkPhrasing("Energy was lower because of work.", input).reason, "forbidden_word");
  assert.equal(checkPhrasing("Energy dropped, which looks like depression.", input).reason, "forbidden_word");
  assert.equal(checkPhrasing("", input).reason, "empty");
});

test("prompt carries only the structured findings", () => {
  const f = computeFindings(energy(declining()));
  const input = phraseInput(f);
  const [system, user] = buildPhrasePrompt(input);
  assert.equal(system.role, "system");
  assert.deepEqual(JSON.parse(user.content), input);
  assert.deepEqual(Object.keys(input).sort(), ["confidence", "effect", "flags", "scale", "signal", "trend", "window"]);
  assert.deepEqual(input.effect, { direction: "lower", points: 2.1, days_rated: 14 });
  assert.deepEqual(input.trend, { direction: "down", points_per_day: 0.15, days_rated: 14 });
  assert.ok(!user.content.includes("rolling") && !user.content.includes("residual"));
});
