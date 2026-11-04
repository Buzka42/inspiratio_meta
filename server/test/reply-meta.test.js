// /reply through the Meta Model API (REPLY_PROVIDER=meta, D3). Synthetic only: fake fetch, per-run key,
// invented transcript. No live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MODELS } from "../src/models.js";
import { META_BASE_URL, META_CONTRIBUTOR_REFUSED, META_PROVIDER } from "../src/providers/meta.js";
import { NEBIUS_PROVIDER } from "../src/nebius.js";
import {
  META_REPLY_MIN_TOKENS, REPLY_MAX_TOKENS, STREAM_NOT_SUPPORTED, prepareReply, replyConfigProblem, replyEndpoint,
  requestBody, runReply,
} from "../src/reply.js";
import { runReplyStream } from "../src/reply-stream.js";

const KEY = `meta-test-${crypto.randomUUID()}`;
const MODEL = "synthetic-muse-test";
const ENV = { REPLY_PROVIDER: META_PROVIDER, META_API_KEY: KEY, META_MODEL: MODEL };
const PLAN = { crisis: false, personality_id: "calm_guide", skill_id: null, escalate: false };
const TRANSCRIPT = "synthetic-transcript-7d21 plan my day around three meetings";
const REPLY = "synthetic-reply-b40e Start with the first meeting and keep a short gap.";
const MESSAGES = [{ role: "user", content: TRANSCRIPT }];

function fakeFetch(content = REPLY) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
  };
  return { fn, calls };
}

test("REPLY_PROVIDER=meta selects the Meta endpoint, model and Bearer key", () => {
  assert.equal(replyConfigProblem(ENV), null);
  const ep = replyEndpoint(ENV);
  assert.equal(ep.url, `${META_BASE_URL}/chat/completions`);
  assert.equal(ep.model, MODEL);
  assert.equal(ep.headers.Authorization, `Bearer ${KEY}`);
  assert.deepEqual(MODELS.reply_meta, { provider: META_PROVIDER, model: null, env: "META_MODEL" });
});

test("meta without a key or model is a config problem, before any call", async () => {
  assert.equal(replyConfigProblem({ REPLY_PROVIDER: META_PROVIDER, META_MODEL: MODEL }), "META_API_KEY missing");
  assert.equal(replyConfigProblem({ REPLY_PROVIDER: META_PROVIDER, META_API_KEY: KEY }), "META_MODEL missing");
  const { fn, calls } = fakeFetch();
  const out = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: { REPLY_PROVIDER: META_PROVIDER, META_MODEL: MODEL }, fetchFn: fn });
  assert.equal(out.status, 503);
  assert.equal(out.body.error, "reply_not_configured");
  assert.equal(calls.length, 0);
  assert.ok(!JSON.stringify(out.body).includes(KEY));
});

test("a contributor model is refused under every DATA_MODE", () => {
  const model = "muse-spark-contributor";
  for (const DATA_MODE of [undefined, "owner_real", "owner_any", "synthetic"]) {
    const problem = replyConfigProblem({ ...ENV, META_MODEL: model, ...(DATA_MODE ? { DATA_MODE } : {}) });
    assert.ok(problem, `refused under ${DATA_MODE ?? "unset"}`);
    assert.equal(problem, "contributor model refused for reply under every DATA_MODE");
  }
  assert.match(replyConfigProblem({ REPLY_PROVIDER: "openrouter_poc", REPLY_LLM_MODEL: model, DATA_MODE: "owner_any" }), /contributor/);
  assert.equal(META_CONTRIBUTOR_REFUSED, "META_MODEL refused: contributor models train on prompts");
});

test("the data guard still applies on meta: free-tier model refused under owner_real", () => {
  assert.match(replyConfigProblem({ ...ENV, META_MODEL: "muse-free" }), /free-tier model refused/);
  assert.equal(replyConfigProblem({ ...ENV, DATA_MODE: "bogus" }).startsWith("DATA_MODE unknown"), true);
});

test("meta body: no reasoning field, max_tokens floor 2000, parsed and think-stripped", async () => {
  const { fn, calls } = fakeFetch(`<think>synthetic-plan</think>${REPLY}`);
  const out = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: fn });
  assert.equal(out.status, 200);
  assert.equal(out.body.text, REPLY);
  assert.equal(calls.length, 1);
  const { body, url, init } = calls[0];
  assert.equal(url, `${META_BASE_URL}/chat/completions`);
  assert.equal(init.headers.Authorization, `Bearer ${KEY}`);
  assert.equal(body.model, MODEL);
  assert.ok(!("reasoning" in body));
  assert.ok(!("stream" in body));
  assert.equal(META_REPLY_MIN_TOKENS, 2000);
  assert.equal(body.max_tokens, Math.max(REPLY_MAX_TOKENS, 2000));
  assert.ok(body.max_tokens >= 2000);
});

const streamText = async (out) => new Response(out.stream).text();
const sseEvents = (text) => [...text.matchAll(/event: (\w+)\ndata: (.*)\n\n/g)].map((m) => ({ event: m[1], data: JSON.parse(m[2]) }));

test("/reply/stream on meta: one non-stream Muse call, its /reply body as the only done event", async () => {
  assert.equal((await prepareReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV })).early, undefined);
  // Defence in depth: a stream body for meta is never built, so /reply/stream never sends stream: true to Muse.
  assert.throws(() => requestBody(MODEL, MESSAGES, true, ENV), { message: STREAM_NOT_SUPPORTED });
  const { fn, calls } = fakeFetch();
  const codes = [];
  const out = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: fn, onFinish: (c) => codes.push(c) });
  assert.equal(out.status, 200);
  const events = sseEvents(await streamText(out));
  const plain = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: fakeFetch().fn });
  assert.deepEqual(events, [{ event: "done", data: plain.body }]);
  assert.deepEqual(Object.keys(events[0].data), ["text", "personality_id", "safety", "health", "council_suggested"]);
  assert.equal(events[0].data.text, REPLY);
  assert.equal(calls.length, 1);
  assert.ok(!("stream" in calls[0].body));
  assert.deepEqual(codes, [null]);
});

test("/reply/stream on meta: a Muse failure is the stream's error event with the fixed code", async () => {
  const codes = [];
  const fn = async () => new Response("{}", { status: 500 });
  const out = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: fn, onFinish: (c) => codes.push(c) });
  assert.equal(out.status, 200);
  assert.deepEqual(sseEvents(await streamText(out)), [{ event: "error", data: { error: "reply_upstream" } }]);
  assert.deepEqual(codes, ["reply_upstream"]);
  const slow = () => new Promise(() => {});
  const late = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: slow, timeoutMs: 20 });
  assert.deepEqual(sseEvents(await streamText(late)), [{ event: "error", data: { error: "reply_timeout" } }]);
});

test("/reply/stream on meta: missing config is the same 503 JSON as /reply, no call", async () => {
  const { fn, calls } = fakeFetch();
  const out = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: { REPLY_PROVIDER: META_PROVIDER, META_MODEL: MODEL }, fetchFn: fn });
  assert.equal(out.stream, undefined);
  assert.equal(out.status, 503);
  assert.equal(calls.length, 0);
});

test("regression: Nebius body keeps its reasoning field and the plain budget", () => {
  const body = JSON.parse(requestBody("synthetic/model", MESSAGES, false, { REPLY_PROVIDER: NEBIUS_PROVIDER }));
  assert.deepEqual(body.reasoning, { effort: "none" });
  assert.equal(body.max_tokens, REPLY_MAX_TOKENS);
  assert.equal(JSON.parse(requestBody("synthetic/model", MESSAGES, true, { REPLY_PROVIDER: NEBIUS_PROVIDER })).stream, true);
});
