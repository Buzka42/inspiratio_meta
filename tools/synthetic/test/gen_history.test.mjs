import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { generateAll, generatePersona, PERSONAS, prng, addDays, NOTICE, DAYS, WINDOW } from "../gen_history.mjs";

const END = "2026-11-01";
const all = generateAll({ seed: 2026, end: END });

test("prng is deterministic and in [0,1)", () => {
  const a = prng(5), b = prng(5);
  for (let i = 0; i < 100; i++) { const x = a(); assert.equal(x, b()); assert.ok(x >= 0 && x < 1); }
});

test("same seed gives identical output, other seed differs", () => {
  assert.deepEqual(generateAll({ seed: 2026, end: END }), all);
  assert.notDeepEqual(generateAll({ seed: 1, end: END }), all);
});

test("three personas, all marked synthetic", () => {
  assert.equal(all.length, 3);
  assert.equal(new Set(all.map((p) => p.persona.id)).size, 3);
  for (const p of all) {
    assert.equal(p.synthetic, true);
    assert.equal(p.notice, NOTICE);
    assert.match(p.persona.name, /synthetic/);
    assert.ok(p.sessions.every((s) => s.synthetic === true));
    assert.ok(p.memory_notes.every((n) => n.source === "synthetic"));
  }
});

test("30 days, ratings 1-5, some check-in days missing", () => {
  for (const p of all) {
    assert.equal(p.wearable.length, DAYS);
    assert.ok(p.checkins.length < DAYS, `${p.persona.id} should miss days`);
    assert.ok(p.checkins.length >= 15);
    for (const c of p.checkins) for (const k of ["mood", "energy", "sleep"]) {
      assert.ok(Number.isInteger(c[k]) && c[k] >= 1 && c[k] <= 5);
    }
    assert.equal(p.window.end, END);
    assert.equal(p.window.start, addDays(END, -(DAYS - 1)));
  }
  // the sparsest persona misses more days than the steadiest
  assert.ok(all[1].checkins.length < all[0].checkins.length + 3);
});

test("wearable signals are plausible and some nights are missing", () => {
  const nights = all.flatMap((p) => p.wearable);
  assert.ok(nights.some((w) => w.sleep_minutes === null));
  for (const w of nights.filter((x) => x.sleep_minutes !== null)) {
    assert.ok(w.sleep_minutes >= 240 && w.sleep_minutes <= 600);
    assert.ok(w.steps >= 600 && w.steps <= 20000);
    assert.ok(w.resting_hr >= 40 && w.resting_hr <= 110);
  }
});

test("analysis body has the /analysis/21d shape", () => {
  for (const p of all) {
    const b = p.analysis_21d_body;
    assert.deepEqual(Object.keys(b).sort(), ["checkins", "signals", "start", "tz"]);
    assert.equal(b.signals.length, WINDOW);
    assert.equal(b.start, addDays(END, -(WINDOW - 1)));
    assert.equal(new Set(b.signals.map((s) => s.date)).size, WINDOW);
    for (const s of b.signals) assert.ok(Array.isArray(s.flags) && "resting_hr" in s && "sleep_hours" in s && "hrv_rmssd" in s);
    for (const c of b.checkins) assert.ok(c.at.slice(0, 10) >= b.start);
  }
});

test("memory notes match MemoryNote.toJson", () => {
  for (const p of all) for (const n of p.memory_notes) {
    assert.deepEqual(Object.keys(n).sort(), ["confidence", "expires_at", "kind", "source", "text"]);
    assert.ok(["note", "hypothesis"].includes(n.kind));
    assert.ok(n.confidence >= 0 && n.confidence <= 1);
    assert.ok(n.expires_at === null || !Number.isNaN(Date.parse(n.expires_at)));
  }
});

test("persona trends point the intended way", () => {
  const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
  const g = (id) => generateAll({ seed: 99, end: END }).find((p) => p.persona.id === id);
  const jonas = g("synthetic_jonas").wearable.filter((w) => w.sleep_minutes !== null);
  assert.ok(mean(jonas.slice(-7).map((w) => w.sleep_minutes)) < mean(jonas.slice(0, 7).map((w) => w.sleep_minutes)));
  const priya = g("synthetic_priya").wearable.filter((w) => w.steps !== null);
  assert.ok(mean(priya.slice(-7).map((w) => w.steps)) > mean(priya.slice(0, 7).map((w) => w.steps)));
});

test("rejects bad input", () => {
  assert.throws(() => generateAll({ seed: 1.5 }), TypeError);
  assert.throws(() => generateAll({ end: "2026-02-31" }), TypeError);
  assert.equal(PERSONAS.length, 3);
  assert.ok(generatePersona(PERSONAS[0], 1, END).checkins.length > 0);
});

const run21d = fileURLToPath(new URL("../../../server/src/analysis/run21d.js", import.meta.url));
test("server accepts the body (computeAnalysis)", { skip: !existsSync(run21d) }, async () => {
  const { computeAnalysis } = await import(run21d);
  for (const p of all) {
    const r = computeAnalysis(p.analysis_21d_body);
    assert.equal(r.window.days, 21);
    assert.ok(r.vitals && Array.isArray(r.vitals.findings));
  }
});
