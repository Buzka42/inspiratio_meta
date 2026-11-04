// Test path (COUNCIL_TEST_PROVIDER=openrouter_poc): per-role Nemotron rows, reasoning off, fallback model,
// think stripping, finish-reason codes, relay time reserve, parallel consults, JSON-plan fallback, route logs.
// Every network call is a fake; keys are generated per run; all text is synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ProviderError, chatBody, postJson, readCompletion, stripThinking } from "../src/providers/chat.js";
import { callBrain, brainConfigProblem, testModel } from "../src/council/provider.js";
import { runCouncilV2 } from "../src/council/relay.js";
import { summarizeSession } from "../src/session-summary.js";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { EMBED_DIMS } from "../src/knowledge/retrieve.js";
import { MODELS } from "../src/models.js";

const OR_KEY = `or-test-${crypto.randomUUID()}`;
const ENV = { COUNCIL_TEST_PROVIDER: "openrouter_poc", OPENROUTER_API_KEY: OR_KEY, DATA_MODE: "owner_any" };
const res = (body, status = 200) => new Response(JSON.stringify(body), { status });
const chat = (content, tool_calls, extra = {}) => res({ choices: [{ message: { content, ...(tool_calls ? { tool_calls } : {}) }, ...extra }] });
const tc = (id, expert_id) => ({ id, type: "function", function: { name: "consult", arguments: JSON.stringify({ expert_id, question: "synthetic q" }) } });
const finalJson = (synthesis = "Synthetic: a calmer wind-down may help.") => JSON.stringify({ synthesis, experts_consulted: [], sources: [], medical: false });
const isExpert = (body) => body.messages[0].content.startsWith("You are one expert");
const isRelay = (body) => body.messages[0].content.startsWith("You are the relay");
const expertReply = (body) => {
  const { sources } = JSON.parse(body.messages[1].content);
  return chat(JSON.stringify({ points: [{ text: "Synthetic point.", source_ids: [sources[0].id] }], caveats: [], confidence: 0.6 }));
};

function bindings() {
  return {
    AI: { run: async (model, { text }) => ({ shape: [text.length, EMBED_DIMS], data: text.map(() => Array.from({ length: EMBED_DIMS }, () => 0.01)) }) },
    KNOWLEDGE: {
      async query(vector, { namespace: ns }) {
        return { matches: [1].map((i) => ({ id: `${ns}:${i}`, score: 0.9, metadata: { expert: ns, source_id: `${ns}-src-${i}`, title: `Synthetic ${ns}`, url: `https://example.test/${ns}`, licence: "OGL-3.0", text: "synthetic passage" } })) };
      },
    },
  };
}

function recorder(answer) {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body });
    return answer(body, calls.length - 1);
  };
  return { fn, calls };
}

// ---- chat helpers ----

test("stripThinking drops closed, stray-closed and unclosed think blocks", () => {
  assert.equal(stripThinking("<think>plan</think> {\"a\":1}"), '{"a":1}');
  assert.equal(stripThinking("reasoning without an opening tag</think>\nanswer"), "answer");
  assert.equal(stripThinking("answer <think>cut off while thinking"), "answer");
  assert.equal(stripThinking("<think>only thinking"), "");
  assert.equal(stripThinking("plain"), "plain");
});

test("readCompletion: empty content keeps a whitelisted finish reason and never reads the reasoning field", () => {
  const empty = (finish_reason) => ({ choices: [{ message: { content: null, reasoning: "secret chain of thought" }, finish_reason }] });
  for (const [given, kept] of [["length", "length"], ["stop", "stop"], ["weird upstream text", "other"], [undefined, null]]) {
    assert.throws(() => readCompletion(empty(given), "openrouter"), (e) => e instanceof ProviderError && e.code === "openrouter_empty" && e.finish === kept);
  }
  assert.equal(readCompletion({ choices: [{ message: { content: "<think>x</think>ok", reasoning: "r" } }] }, "p").content, "ok");
});

test("postJson: a 429 body becomes a fixed rate-limit kind, never kept", async () => {
  for (const [body, kind] of [
    ['{"error":{"message":"Rate limit exceeded: free-models-per-day. synthetic-body"}}', "per_day"],
    ['{"error":{"message":"x is temporarily rate-limited upstream"}}', "upstream"],
    ['{"error":{"message":"Rate limit exceeded: free-models-per-min."}}', "per_min"],
    ["synthetic", "other"],
  ]) {
    const fetchFn = async () => new Response(body, { status: 429 });
    await assert.rejects(postJson("https://x.test", { body: {}, fetchFn, prefix: "openrouter" }), (e) =>
      e.code === "openrouter_status_4xx" && e.status === 429 && e.limit === kind && e.fallback && !JSON.stringify(e).includes("synthetic"));
  }
});

test("chatBody sends reasoning only when given", () => {
  assert.deepEqual(chatBody("m", [], { reasoning: { effort: "none" } }).reasoning, { effort: "none" });
  assert.equal("reasoning" in chatBody("m", []), false);
});

test("postJson: a timeout while the body is still arriving is a timeout, not bad_json", async () => {
  const fetchFn = async () => ({ ok: true, status: 200, json: async () => { throw Object.assign(new Error("aborted"), { name: "AbortError" }); } });
  await assert.rejects(postJson("https://x.test", { body: {}, fetchFn, prefix: "openrouter" }), (e) => e.code === "openrouter_timeout");
  const garbage = async () => new Response("not json", { status: 200 });
  await assert.rejects(postJson("https://x.test", { body: {}, fetchFn: garbage, prefix: "openrouter" }), (e) => e.code === "openrouter_bad_json");
});

// ---- per-role rows ----

test("models: one free Nemotron row per council role, reasoning off", () => {
  for (const key of ["council_test", "council_test_expert", "summary_test"]) {
    const row = MODELS[key];
    assert.equal(row.provider, "openrouter_poc");
    assert.match(row.model, /^nvidia\/nemotron-.*:free$/);
    assert.deepEqual(row.reasoning, { effort: "none" });
  }
  assert.equal(MODELS.council_test.env, "COUNCIL_TEST_MODEL");
  assert.equal(MODELS.council_test_expert.env, "COUNCIL_TEST_EXPERT_MODEL");
  assert.equal(MODELS.summary_test.env, "COUNCIL_TEST_SUMMARY_MODEL");
  assert.match(MODELS.council_test.fallback, /^nvidia\/nemotron-.*:free$/);
});

test("callBrain test path: role picks the model, reasoning off, JSON mode only where the row lists it", async () => {
  const { fn, calls } = recorder(() => chat("ok"));
  for (const role of ["relay", "expert", "summary", undefined]) await callBrain([{ role: "user", content: "hi" }], ENV, { fetchFn: fn, json: true, role });
  assert.deepEqual(calls.map((c) => c.body.model), [MODELS.council_test.model, MODELS.council_test_expert.model, MODELS.summary_test.model, MODELS.council_test.model]);
  for (const c of calls) {
    assert.deepEqual(c.body.reasoning, { effort: "none" });
    assert.match(c.url, /^https:\/\/openrouter\.ai\//);
  }
  assert.equal(calls[1].body.response_format, undefined, "lightning:free does not list response_format");
});

test("callBrain test path: per-role env overrides win and are data-guarded", async () => {
  const env = { ...ENV, COUNCIL_TEST_EXPERT_MODEL: "nvidia/synthetic-expert:free", COUNCIL_TEST_SUMMARY_MODEL: "nvidia/synthetic-summary:free" };
  assert.equal(testModel(env, "expert").model, "nvidia/synthetic-expert:free");
  assert.equal(testModel(env, "summary").model, "nvidia/synthetic-summary:free");
  assert.equal(testModel(env, "relay").model, MODELS.council_test.model);
  assert.match(brainConfigProblem({ ...env, DATA_MODE: "owner_real" }), /refused/);
});

test("callBrain test path: a 404, per-minute 429 or 5xx on the relay model retries once on the fallback; a 400 does not", async () => {
  for (const status of [404, 429, 503]) {
    const { fn, calls } = recorder((body, i) => (i === 0 ? res({}, status) : chat("ok")));
    const out = await callBrain([{ role: "user", content: "hi" }], ENV, { fetchFn: fn, role: "relay", timeoutMs: 10_000 });
    assert.equal(out.model, MODELS.council_test.fallback, String(status));
    assert.deepEqual(calls.map((c) => c.body.model), [MODELS.council_test.model, MODELS.council_test.fallback]);
  }
  const daily = recorder(() => new Response('{"error":{"message":"Rate limit exceeded: free-models-per-day"}}', { status: 429 }));
  await assert.rejects(callBrain([{ role: "user", content: "hi" }], ENV, { fetchFn: daily.fn, role: "relay" }), (e) => e.limit === "per_day");
  assert.equal(daily.calls.length, 1, "the per-day cap is account wide: no retry");
  const { fn, calls } = recorder(() => res({}, 400));
  await assert.rejects(callBrain([{ role: "user", content: "hi" }], ENV, { fetchFn: fn, role: "relay" }), (e) => e.status === 400);
  assert.equal(calls.length, 1);
  const expert = recorder(() => res({}, 404));
  await assert.rejects(callBrain([{ role: "user", content: "hi" }], ENV, { fetchFn: expert.fn, role: "expert" }));
  assert.equal(expert.calls.length, 1, "expert row has no fallback");
});

// ---- relay ----

test("relay: consults from one turn run in parallel, at most `parallel` at a time, and keep call order", async () => {
  let inFlight = 0, peak = 0;
  const { fn, calls } = recorder(async (body) => {
    if (isRelay(body)) {
      if (body.messages.some((m) => m.role === "tool")) return chat(finalJson());
      return chat("", ["sleep_lifestyle", "training", "diet", "breath_stress", "cardiology"].map((id, i) => tc(`t${i}`, id)));
    }
    inFlight++; peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 20));
    inFlight--;
    return expertReply(body);
  });
  const out = await runCouncilV2({ question: "synthetic sleep question" }, { ...ENV, ...bindings(), COUNCIL_MEDICAL: "on" }, { fetchFn: fn, limits: { parallel: 3 } });
  assert.equal(peak, 3);
  assert.equal(out.consults, 5);
  assert.match(out.synthesis, /^Synthetic: a calmer wind-down/);
  const relay2 = calls.filter((c) => isRelay(c.body))[1].body.messages.filter((m) => m.role === "tool").map((m) => m.tool_call_id);
  assert.deepEqual(relay2, ["t0", "t1", "t2", "t3", "t4"]);
  for (const c of calls) assert.equal(c.body.model, isExpert(c.body) ? MODELS.council_test_expert.model : MODELS.council_test.model);
});

test("relay: slow consults stop at the reserve so the closing call still writes the synthesis", async () => {
  let t = 0;
  const now = () => t;
  const { fn, calls } = recorder((body) => {
    if (isExpert(body)) { t += 9_000; return expertReply(body); }
    t += 2_000;
    if (body.tools) return chat("", [tc(`c${t}`, "training")]);
    return chat(finalJson("Synthetic: an earlier session may help."));
  });
  const out = await runCouncilV2({ question: "synthetic question" }, { ...ENV, ...bindings() }, { fetchFn: fn, now, limits: { timeLimitMs: 25_000, finalReserveMs: 8_000 } });
  assert.match(out.synthesis, /^Synthetic: an earlier session/);
  assert.ok(out.limits_hit.includes("time_limit"));
  assert.ok(!calls.at(-1).body.tools, "closing call without tools");
  assert.ok(t <= 25_000 + 2_000, `fake clock ${t}`);
});

test("relay: a later relay failure still returns 200 with a fixed message; the first one throws", async () => {
  const later = recorder((body, i) => (isExpert(body) ? expertReply(body) : i === 0 ? chat("", [tc("a", "diet")]) : res({}, 400)));
  const out = await runCouncilV2({ question: "synthetic question" }, { ...ENV, ...bindings() }, { fetchFn: later.fn });
  assert.match(out.synthesis, /could not finish/);
  assert.ok(out.limits_hit.includes("relay_unavailable"));
  assert.ok(out.upstream_codes.some((c) => c.startsWith("openrouter_status_4xx:400")));
  const first = recorder(() => res({}, 500));
  await assert.rejects(runCouncilV2({ question: "synthetic question" }, { ...ENV, ...bindings() }, { fetchFn: first.fn }));
});

test("relay: tools refused (400) falls back to a JSON plan, parallel consults, then the closing call", async () => {
  const { fn, calls } = recorder((body) => {
    if (isExpert(body)) return expertReply(body);
    if (body.tools) return res({}, 400);
    const last = body.messages.at(-1).content;
    if (last.startsWith("Tools are unavailable")) return chat(JSON.stringify({ consult: [{ expert_id: "sleep_lifestyle", question: "q1" }, { expert_id: "training", question: "q2" }] }));
    return chat(finalJson("Synthetic: plan path answer."));
  });
  const out = await runCouncilV2({ question: "synthetic sleep question" }, { ...ENV, ...bindings() }, { fetchFn: fn });
  assert.match(out.synthesis, /^Synthetic: plan path answer/);
  assert.deepEqual(out.experts_consulted, ["sleep_lifestyle", "training"]);
  assert.ok(out.limits_hit.includes("tools_unsupported"));
  const closing = calls.filter((c) => isRelay(c.body)).at(-1).body.messages;
  assert.ok(closing.some((m) => m.role === "user" && m.content.includes("consult_results")));
});

// ---- summary ----

test("summary on the test path: summary row, reasoning off, think block stripped", async () => {
  const { fn, calls } = recorder(() => chat('<think>hmm</think>{"summary":"Synthetic: user plans earlier training.","topics":["training"]}'));
  const out = await summarizeSession({ turns: [{ role: "user", text: "synthetic text" }] }, ENV, { fetchFn: fn });
  assert.equal(out.summary, "Synthetic: user plans earlier training.");
  assert.equal(out.provider, "openrouter_poc");
  assert.equal(calls[0].body.model, MODELS.summary_test.model);
  assert.deepEqual(calls[0].body.reasoning, { effort: "none" });
  assert.equal(calls[0].body.max_tokens, 600);
});

// ---- route logs ----

test("routes: fixed-code logs only (upstream_detail, council_run), never question text or keys", async () => {
  const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
  const NOW = Date.parse("2026-10-25T09:00:00Z");
  const lines = [];
  const capture = (...a) => lines.push(a.join(" "));
  const run = async (fetchFn, path, body) => {
    const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), now: () => NOW, logger: { log: capture, warn: capture, error: capture } });
    const token = issueToken("device-t", SECRET, { now: NOW });
    return h(new Request(`https://x.test${path}`, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }),
      { DEVICE_TOKEN_SECRET: SECRET, QUOTA_COUNCIL_PER_DAY: "1000", QUOTA_SESSION_SUMMARIES_PER_DAY: "1000", ...ENV, ...bindings() });
  };
  const empty = async () => res({ choices: [{ message: { content: "" }, finish_reason: "length" }] });
  const r1 = await run(empty, "/session/summary", { turns: [{ role: "user", text: "synthetic-marker" }] });
  assert.equal(r1.status, 502);
  assert.ok(lines.includes("upstream_detail /session/summary openrouter_empty - length"), lines.join("\n"));
  const { fn } = recorder((body, i) => (isExpert(body) ? expertReply(body) : i === 0 ? chat("", [tc("a", "diet")]) : chat(finalJson())));
  const r2 = await run(fn, "/council", { question: "synthetic-marker question" });
  const out = await r2.json();
  assert.equal(r2.status, 200);
  assert.equal(out.upstream_codes, undefined);
  assert.equal(out.upstream_calls, undefined);
  const runLine = lines.find((l) => l.startsWith("council_run device-t"));
  assert.match(runLine, /^council_run device-t \d+ 1 relay:\d+:ok,expert:\d+:ok,relay:\d+:ok -$/);
  for (const l of lines) {
    assert.ok(!l.includes("synthetic-marker"));
    assert.ok(!l.includes(OR_KEY));
  }
});
