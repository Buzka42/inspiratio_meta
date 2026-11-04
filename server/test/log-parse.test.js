// Plan B6: POST /log/parse and the log validator. The model call is an injected fake (or a fake fetch through
// the route); no network. Keys are generated per run; all text is synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runLogParse, logConfigProblem, logModel, logPrompt } from "../src/logs/parse.js";
import { LOG_SCHEMA, validateEntry } from "../src/logs/schemas.js";
import { numbersIn, statedNumbers } from "../src/analysis/numbers.js";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { REFERRAL_TEXT } from "../src/safety.js";

const NB_KEY = `nebius-test-${crypto.randomUUID()}`;
const ENV = { NEBIUS_API_KEY: NB_KEY, LOG_LLM_MODEL: "synthetic/log-model" };
const NOW = Date.parse("2026-10-28T09:00:00Z");
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const noCall = async () => { throw new Error("model called"); };
const noNet = () => { throw new Error("network touched"); };

// Fake model: returns `output` as JSON content and records the call.
function model(output) {
  const calls = [];
  const callFn = async (messages, env, opts) => {
    calls.push({ messages, env, opts });
    return { content: typeof output === "string" ? output : JSON.stringify(output), tool_calls: [] };
  };
  return { callFn, calls };
}
const parse = (body, output, env = ENV) => {
  const m = model(output);
  return runLogParse(body, env, { callFn: m.callFn, now: () => NOW }).then((out) => ({ ...out, calls: m.calls }));
};

const STRENGTH_TEXT = "bench press 3x8 at 80 kg, rir 2; pull ups 2 sets of 10";
const STRENGTH_OUT = {
  exercises: [
    { name: "bench press", sets: [{ count: 3, reps: 8, weight: 80, unit: "kg", effort: { scale: "rir", value: 2 } }] },
    { name: "pull ups", sets: [{ count: 2, reps: 10, weight: null, unit: null }] },
  ],
};

// ---- shared number check ----

test("numbers: numbersIn keeps phrase.js behaviour; statedNumbers adds words and thousands", () => {
  assert.deepEqual(numbersIn("3.5 points over 14 days, 2,5"), [3.5, 14, 2.5]);
  const s = statedNumbers("two eggs and 1,500 steps");
  assert.ok(s.has(2) && s.has(1500) && s.has(1.5));
});

// ---- validator ----

test("log: a valid strength entry passes, with set counts expanded and effort kept when the pref allows", async () => {
  const out = await parse({ kind: "strength", text: STRENGTH_TEXT, prefs: { effort: "rir" } }, STRENGTH_OUT);
  assert.equal(out.status, 200);
  assert.equal(out.body.ok, true);
  assert.equal(out.body.schema, LOG_SCHEMA);
  assert.equal(out.body.kind, "strength");
  assert.equal(out.body.date, "2026-10-28");
  assert.equal(out.body.source, "typed");
  const [bench, pull] = out.body.entry.exercises;
  assert.equal(bench.sets.length, 3);
  assert.deepEqual(bench.sets[0], { reps: 8, weight: 80, unit: "kg", effort: { scale: "rir", value: 2 } });
  assert.deepEqual(pull.sets, [{ reps: 10, weight: null, unit: null }, { reps: 10, weight: null, unit: null }]);
  assert.ok(!("count" in bench.sets[0]), "count never reaches the entry");
  assert.equal(out.code, null);
});

test("log: effort is removed when prefs.effort is none (or missing, or the other scale)", async () => {
  for (const prefs of [{ effort: "none" }, undefined, { effort: "rpe" }]) {
    const out = await parse({ kind: "strength", text: STRENGTH_TEXT, ...(prefs ? { prefs } : {}) }, STRENGTH_OUT);
    assert.equal(out.status, 200, JSON.stringify(prefs));
    for (const ex of out.body.entry.exercises) for (const s of ex.sets) assert.ok(!("effort" in s));
  }
  // The prompt only asks for effort when the pref allows it.
  assert.ok(!logPrompt("strength", "x", "none")[0].content.includes("effort"));
  assert.ok(logPrompt("strength", "x", "rpe")[0].content.includes('"scale":"rpe"'));
});

test("log: a number that is not in the text is rejected", async () => {
  const cases = [
    ["strength", { exercises: [{ name: "bench press", sets: [{ reps: 8, weight: 85, unit: "kg" }] }] }],
    ["food", { items: [{ name: "eggs", quantity: 2, unit: "piece", kcal: 140 }] }],
    ["run", { distance: { value: 5, unit: "km" }, duration: { min: 26 }, splits: [] }],
    ["food", { items: [{ name: "eggs 3", quantity: 2 }] }], // a number hidden in a string
  ];
  const texts = { strength: "bench press 8 reps at 80 kg", food: "two eggs for breakfast", run: "5 km in 25 min" };
  for (const [kind, output] of cases) {
    const out = await parse({ kind, text: texts[kind] }, output);
    assert.equal(out.status, 422, kind);
    assert.deepEqual(out.body, { ok: false, code: "number_not_in_text" });
  }
  // The same food entry without the invented kcal passes ("two" states 2).
  const ok = await parse({ kind: "food", text: texts.food }, { meal: "breakfast", items: [{ name: "eggs", quantity: 2, unit: "piece" }] });
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.entry, { meal: "breakfast", items: [{ name: "eggs", quantity: 2, unit: "piece" }] });
});

test("log: JSON with bad fields is rejected with fixed codes", () => {
  const text = "ran 5 km in 25:30, splits 5:10 and 5:05; 140 bpm avg 170 max; 300 kcal";
  const cases = [
    ["strength", { exercises: [{ name: "squat", sets: [{ reps: "8", weight: 80, unit: "kg" }] }] }, "bad_field"],
    ["strength", { exercises: [{ name: "squat", sets: [{ reps: 8.5, weight: 80, unit: "kg" }] }] }, "bad_field"],
    ["strength", { exercises: [{ name: "squat", sets: [{ reps: 8, weight: 80, unit: "stone" }] }] }, "bad_field"],
    ["strength", { exercises: [{ name: "squat", sets: [{ reps: 8, weight: 80 }] }] }, "bad_field"],
    ["strength", { exercises: [] }, "empty_entry"],
    ["food", { meal: "brunch", items: [{ name: "toast" }] }, "bad_field"],
    ["food", { items: [{ name: "toast", unit: "cup" }] }, "bad_field"],
    ["food", { items: "toast" }, "bad_field"],
    ["run", { distance: { value: 5, unit: "km" } }, "bad_field"], // duration required
    ["run", { distance: { value: 5, unit: "yd" }, duration: { min: 25 } }, "bad_field"],
    ["run", { distance: { value: 5, unit: "km" }, duration: { min: 25 }, splits: [{ duration: "5:10" }] }, "bad_field"],
    ["run", { distance: { value: 0, unit: "km" }, duration: { min: 25 } }, "out_of_range"],
    ["cardio", { type: "bike", hr_avg: 170, hr_max: 140 }, "out_of_range"],
    ["cardio", { type: "bike", hr_avg: 5 }, "out_of_range"],
    ["cardio", { type: "" }, "bad_field"],
    ["activity", { type: "walk", steps: -1 }, "out_of_range"],
    ["activity", ["walk"], "not_object"],
  ];
  for (const [kind, output, code] of cases) {
    assert.deepEqual(validateEntry(kind, output, text, { effort: "none" }), { ok: false, code }, `${kind} ${JSON.stringify(output)}`);
  }
});

test("log: run splits are numbered by plain code and durations become seconds; cardio and activity pass", () => {
  const text = "ran 5 km in 25:30, splits 5:10 and 5:05; 140 bpm avg 170 max; 300 kcal; walked 2 km, 3000 steps, 40 min";
  const run = validateEntry("run", { distance: { value: 5, unit: "km" }, duration: { min: 25, s: 30 }, splits: [{ duration: { min: 5, s: 10 } }, { distance: null, duration: { min: 5, s: 5 } }] }, text);
  assert.deepEqual(run, {
    ok: true,
    entry: { distance: { value: 5, unit: "km" }, duration_s: 1530, splits: [{ index: 1, distance: null, duration_s: 310 }, { index: 2, distance: null, duration_s: 305 }] },
  });
  const cardio = validateEntry("cardio", { type: "bike", duration: { min: 40 }, hr_avg: 140, hr_max: 170, kcal: 300, extra: "dropped" }, text);
  assert.deepEqual(cardio, { ok: true, entry: { type: "bike", duration_s: 2400, hr_avg: 140, hr_max: 170, kcal: 300 } });
  const act = validateEntry("activity", { type: "walk", distance: { value: 2, unit: "km" }, steps: 3000 }, text);
  assert.deepEqual(act, { ok: true, entry: { type: "walk", distance: { value: 2, unit: "km" }, steps: 3000 } });
});

test("log: non-JSON model output is rejected as bad_json", async () => {
  const out = await parse({ kind: "food", text: "toast" }, "here is your log: toast");
  assert.deepEqual([out.status, out.body], [422, { ok: false, code: "bad_json" }]);
});

// ---- safety and config ----

test("log: crisis text gets the referral and no model call, even unconfigured", async () => {
  for (const env of [ENV, {}]) {
    const out = await runLogParse({ kind: "food", text: "I want to die, skipped lunch" }, env, { callFn: noCall });
    assert.equal(out.status, 200);
    assert.deepEqual(out.body, { ok: false, code: "crisis", crisis: true, text: REFERRAL_TEXT });
  }
});

test("log: the data-mode guard holds before any model call", async () => {
  const refused = [
    { ...ENV, LOG_LLM_MODEL: "synthetic/model-contributor" },
    { ...ENV, LOG_LLM_MODEL: "synthetic/model:free" },
    { ...ENV, DATA_MODE: "owner_real", LOG_LLM_MODEL: "synthetic/model-free" },
    { ...ENV, DATA_MODE: "unknown" },
    { ...ENV, NEBIUS_BASE_URL: "https://evil.test/v1" },
    { NEBIUS_API_KEY: NB_KEY },
    { LOG_LLM_MODEL: "synthetic/log-model" },
  ];
  for (const env of refused) {
    assert.ok(logConfigProblem(env), JSON.stringify(env.LOG_LLM_MODEL ?? null));
    await assert.rejects(runLogParse({ kind: "food", text: "toast" }, env, { callFn: noCall }), (err) => err.message === "not configured");
    assert.ok(!String(logConfigProblem(env)).includes(NB_KEY), "refusal never carries the key");
  }
  // Free tiers are allowed only under synthetic or owner_any.
  assert.equal(logConfigProblem({ ...ENV, DATA_MODE: "synthetic", LOG_LLM_MODEL: "synthetic/model:free" }), null);
  assert.equal(logConfigProblem(ENV), null);
  // LOG_LLM_MODEL wins over REPLY_LLM_MODEL; REPLY_LLM_MODEL is the fallback; no hard-coded default.
  assert.equal(logModel({ LOG_LLM_MODEL: "a", REPLY_LLM_MODEL: "b" }), "a");
  assert.equal(logModel({ REPLY_LLM_MODEL: "b" }), "b");
  assert.equal(logModel({}), null);
});

test("log: bad requests are 400 with no model call", async () => {
  for (const body of [
    { kind: "sleep", text: "x" }, { kind: "food" }, { kind: "food", text: "  " }, { kind: "food", text: "x".repeat(1001) },
    { kind: "food", text: "x", prefs: { effort: "max" } }, { kind: "food", text: "x", prefs: [] }, { kind: "food", text: "x", date: "28/10/2026" },
  ]) {
    const out = await runLogParse(body, ENV, { callFn: noCall });
    assert.equal(out.status, 400, JSON.stringify(body));
  }
});

// ---- route ----

function handler(fetchFn, logger) {
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), now: () => NOW, logger });
  const token = issueToken("device-log", SECRET, { now: NOW });
  return (body, env = ENV) =>
    h(new Request("https://x.test/log/parse", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }),
      { DEVICE_TOKEN_SECRET: SECRET, ...env });
}
const quietLogger = () => {
  const lines = [];
  const rec = (...a) => lines.push(a.map(String).join(" "));
  return { lines, log: rec, warn: rec, error: rec };
};

test("route: POST /log/parse calls Nebius in JSON mode and returns the envelope; logs carry codes only", async () => {
  const calls = [];
  const fetchFn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const content = JSON.stringify({ meal: "lunch", items: [{ name: "synthetic soup", quantity: 300, unit: "ml" }] });
    return new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
  };
  const logger = quietLogger();
  const post = handler(fetchFn, logger);
  const res = await post({ kind: "food", text: "300 ml synthetic soup for lunch", date: "2026-10-27" });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.deepEqual(out, { ok: true, schema: LOG_SCHEMA, kind: "food", date: "2026-10-27", source: "typed", entry: { meal: "lunch", items: [{ name: "synthetic soup", quantity: 300, unit: "ml" }] } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.tokenfactory.nebius.com/v1/chat/completions");
  assert.equal(calls[0].body.model, "synthetic/log-model");
  assert.deepEqual(calls[0].body.response_format, { type: "json_object" });
  assert.equal(calls[0].init.headers.Authorization, `Bearer ${NB_KEY}`);

  // A rejection is logged as a fixed code, never the text.
  const bad = handler(async () => new Response(JSON.stringify({ choices: [{ message: { content: '{"items":[{"name":"soup","kcal":999}]}' } }] })), logger);
  const r2 = await bad({ kind: "food", text: "synthetic soup" });
  assert.equal(r2.status, 422);
  assert.ok(logger.lines.some((l) => l.includes("log_parse_result") && l.includes("number_not_in_text")));
  assert.ok(!logger.lines.some((l) => l.includes("soup") || l.includes(NB_KEY)));
});

test("route: crisis text gets the referral with no network; unconfigured is 503", async () => {
  const post = handler(noNet, quietLogger());
  const res = await post({ kind: "food", text: "I want to die" });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).text, REFERRAL_TEXT);
  const un = await post({ kind: "food", text: "toast" }, {});
  assert.equal(un.status, 503);
  assert.equal((await un.json()).error, "not_configured");
});
