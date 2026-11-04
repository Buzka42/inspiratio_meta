// /reply through Nebius Token Factory (REPLY_PROVIDER=nebius), the target provider.
// Synthetic only: fake fetch, per-run key, invented transcript. No live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { NOT_MEDICAL_ADVICE, SAFE_FALLBACK_TEXT } from "../src/safety.js";
import { REPLY_MAX_TOKENS, replyConfigProblem, runReply } from "../src/reply.js";
import { NEBIUS_BASE_REFUSED, NEBIUS_BASE_URL, NEBIUS_PROVIDER, nebiusBase } from "../src/nebius.js";

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const KEY = `nebius-test-${crypto.randomUUID()}`;
const MODEL = "synthetic/chat-model-test";
const ENV = { DEVICE_TOKEN_SECRET: SECRET, REPLY_PROVIDER: NEBIUS_PROVIDER, NEBIUS_API_KEY: KEY, REPLY_LLM_MODEL: MODEL };
const PLAN = { crisis: false, personality_id: "calm_guide", skill_id: null, escalate: false };
const TRANSCRIPT = "synthetic-transcript-a91e slept badly, plan my day";
const PLAIN_TRANSCRIPT = "synthetic-transcript-4c7b plan my day around three meetings";
const PLAIN_REPLY = "synthetic-reply-e02f Start with the first meeting and keep a short gap.";

const ok = (content) => () => new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
function fakeFetch(respond) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return respond(url, init);
  };
  return { fn, calls };
}

const post = (fetchFn, body, env = ENV, logger = console) =>
  createHandler({ fetchFn, logger, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore() })(
    new Request("https://x.test/reply", {
      method: "POST",
      headers: { Authorization: `Bearer ${issueToken("device-nebius", SECRET)}` },
      body: JSON.stringify(body),
    }),
    env,
  );

// Captures every console line while fn runs, then restores console.
async function captureConsole(fn) {
  const lines = [];
  const saved = {};
  for (const m of ["log", "info", "warn", "error", "debug"]) {
    saved[m] = console[m];
    console[m] = (...args) => lines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  }
  try {
    await fn();
  } finally {
    Object.assign(console, saved);
  }
  return lines;
}

test("nebius config: needs NEBIUS_API_KEY and REPLY_LLM_MODEL, named without values", () => {
  assert.equal(replyConfigProblem(ENV), null);
  const noKey = replyConfigProblem({ ...ENV, NEBIUS_API_KEY: undefined });
  assert.match(noKey, /^NEBIUS_API_KEY missing/);
  assert.match(replyConfigProblem({ ...ENV, NEBIUS_API_KEY: "  " }), /^NEBIUS_API_KEY missing/);
  const noModel = replyConfigProblem({ ...ENV, REPLY_LLM_MODEL: "" });
  assert.match(noModel, /^REPLY_LLM_MODEL missing/);
  assert.ok(!noModel.includes(KEY), "refusal never carries the key");
  // The OpenCode key or a self-hosted URL does not satisfy the Nebius branch.
  assert.match(replyConfigProblem({ REPLY_PROVIDER: NEBIUS_PROVIDER, OPENCODE_API_KEY: "x", REPLY_LLM_MODEL: MODEL }), /NEBIUS_API_KEY missing/);
});

test("nebius config: unknown providers stay refused", () => {
  for (const p of ["openai", "Nebius", "nebius ", "openrouter"]) {
    assert.match(replyConfigProblem({ ...ENV, REPLY_PROVIDER: p }), /REPLY_PROVIDER unknown/, p);
  }
});

test("nebius config: NEBIUS_BASE_URL only accepts https on the Nebius host under /v1", () => {
  assert.equal(nebiusBase({}), NEBIUS_BASE_URL);
  assert.equal(nebiusBase({ NEBIUS_BASE_URL: "https://api.tokenfactory.nebius.com/v1/" }), NEBIUS_BASE_URL);
  assert.equal(nebiusBase({ NEBIUS_BASE_URL: "https://API.tokenfactory.nebius.com./v1" }), NEBIUS_BASE_URL);
  const refused = [
    "http://api.tokenfactory.nebius.com/v1",
    "https://evil.example/v1",
    "https://api.tokenfactory.nebius.com.evil.example/v1",
    "https://x.api.tokenfactory.nebius.com/v1",
    "https://tokenfactory.nebius.com/v1",
    "https://api.tokenfactory.nebius.com:8443/v1",
    "https://user:pw@api.tokenfactory.nebius.com/v1",
    "https://api.tokenfactory.nebius.com/v1?x=1",
    "https://api.tokenfactory.nebius.com/v1#x",
    "https://api.tokenfactory.nebius.com/",
    "https://api.tokenfactory.nebius.com/v1/chat/completions",
    "not a url",
  ];
  for (const u of refused) {
    assert.equal(replyConfigProblem({ ...ENV, NEBIUS_BASE_URL: u }), NEBIUS_BASE_REFUSED, u);
  }
});

test("nebius config refusal: 503 reply_not_configured before any call", async () => {
  const f = fakeFetch(ok(PLAIN_REPLY));
  const res = await post(f.fn, { plan: PLAN, transcript: PLAIN_TRANSCRIPT }, { ...ENV, NEBIUS_BASE_URL: "https://evil.example/v1" }, { warn() {}, error() {} });
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { error: "reply_not_configured", detail: NEBIUS_BASE_REFUSED });
  assert.equal(f.calls.length, 0);
});

test("nebius call: URL, Authorization header, model and server-built prompt", async () => {
  const f = fakeFetch(ok(PLAIN_REPLY));
  const res = await post(f.fn, { plan: PLAN, transcript: PLAIN_TRANSCRIPT }, ENV, { warn() {}, error() {} });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body, { text: PLAIN_REPLY, personality_id: "calm_guide", safety: "passed", health: false, council_suggested: false });
  assert.ok(!JSON.stringify(body).includes(KEY), "key is never returned");
  assert.equal(f.calls.length, 1);
  const { url, init, body: sent } = f.calls[0];
  assert.equal(url, "https://api.tokenfactory.nebius.com/v1/chat/completions");
  assert.equal(init.method, "POST");
  assert.equal(init.headers.Authorization, `Bearer ${KEY}`, "key is sent to Nebius");
  assert.equal(init.headers["Content-Type"], "application/json");
  assert.ok(!("x-opencode-session" in init.headers), "no OpenCode header on the Nebius path");
  assert.ok(init.signal, "abort signal passed");
  assert.equal(sent.model, MODEL);
  assert.equal(sent.max_tokens, REPLY_MAX_TOKENS);
  assert.equal(sent.messages[0].role, "system");
  assert.equal(sent.messages[1].content, PLAIN_TRANSCRIPT);
});

test("nebius call: an allowed NEBIUS_BASE_URL override is used", async () => {
  const f = fakeFetch(ok(PLAIN_REPLY));
  const out = await runReply({
    plan: PLAN, transcript: PLAIN_TRANSCRIPT, fetchFn: f.fn,
    env: { ...ENV, NEBIUS_BASE_URL: "https://api.tokenfactory.nebius.com/v1/" },
  });
  assert.equal(out.status, 200);
  assert.equal(f.calls[0].url, "https://api.tokenfactory.nebius.com/v1/chat/completions");
});

test("nebius output still passes the safety gate, health line added after it only for a marked reply", async () => {
  const bad = await post(fakeFetch(ok("[[HEALTH]] Based on this you must stop eating. I diagnose insomnia.")).fn, { plan: PLAN, transcript: TRANSCRIPT }, ENV, { warn() {}, error() {} });
  // The fake answers the repair call with the same failing text: the safe fallback.
  assert.deepEqual(await bad.json(), { text: `${SAFE_FALLBACK_TEXT} ${NOT_MEDICAL_ADVICE}`, personality_id: "calm_guide", safety: "replaced", health: true, council_suggested: false });
  // An unmarked wellbeing answer gets no line, whatever the transcript's words.
  const good = await post(fakeFetch(ok("Take a short walk.")).fn, { plan: PLAN, transcript: TRANSCRIPT }, ENV, { warn() {}, error() {} });
  assert.deepEqual(await good.json(), { text: "Take a short walk.", personality_id: "calm_guide", safety: "passed", health: false, council_suggested: true });
});

test("nebius crisis never reaches the model", async () => {
  const f = fakeFetch(ok(PLAIN_REPLY));
  const res = await post(f.fn, { plan: PLAN, transcript: "I want to die" }, ENV, { warn() {}, error() {} });
  assert.equal((await res.json()).safety, "replaced");
  assert.equal(f.calls.length, 0);
});

test("nebius upstream error: 502 reply_upstream with no text", async () => {
  const echo = () => new Response(JSON.stringify({ error: { message: `bad key ${KEY} for ${TRANSCRIPT}` } }), { status: 401 });
  for (const respond of [echo, () => new Response("oops", { status: 500 }), ok(""), () => { throw new Error(`net ${KEY}`); }]) {
    const res = await post(fakeFetch(respond).fn, { plan: PLAN, transcript: TRANSCRIPT }, ENV, { warn() {}, error() {} });
    assert.equal(res.status, 502);
    assert.deepEqual(await res.json(), { error: "reply_upstream" });
  }
});

test("nebius: no console line carries the key or the transcript", async () => {
  const runs = [
    ok(PLAIN_REPLY),
    ok("Based on this you must stop eating. I diagnose insomnia."),
    () => new Response(JSON.stringify({ error: `bad key ${KEY} for ${TRANSCRIPT}` }), { status: 401 }),
    () => { throw new Error(`network ${KEY} ${TRANSCRIPT}`); },
  ];
  const lines = await captureConsole(async () => {
    for (const respond of runs) await post(fakeFetch(respond).fn, { plan: PLAN, transcript: TRANSCRIPT });
    await post(fakeFetch(ok(PLAIN_REPLY)).fn, { plan: PLAN, transcript: TRANSCRIPT }, { ...ENV, REPLY_LLM_MODEL: "" });
  });
  assert.ok(lines.some((l) => l.includes("reply_upstream")), "fixed codes are logged");
  assert.ok(lines.some((l) => l.includes("reply_not_configured")));
  for (const l of lines) {
    assert.ok(!l.includes(KEY), "key in log");
    assert.ok(!l.includes("synthetic-transcript"), "transcript in log");
    assert.ok(!l.includes("diagnose"), "model text in log");
  }
});
