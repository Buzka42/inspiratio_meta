// OpenRouter provider (REPLY_PROVIDER / COUNCIL_PROVIDER = openrouter_poc). Test/PoC only.
// Synthetic only: fake fetch, per-run key, invented text. No live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { OPENROUTER_DEFAULT_MODEL, replyConfigProblem, runReply } from "../src/reply.js";
import {
  OPENROUTER_BASE_REFUSED, OPENROUTER_ERRORS, OPENROUTER_PROVIDER, OPENROUTER_URL, chatOpenRouter, openRouterUrl,
} from "../src/openrouter.js";
import { SESSION_HEADER } from "../src/opencode.js";
import { COUNCIL_MODELS, MODELS, OPENROUTER_MEMBERS } from "../src/models.js";
import { DEFAULT_MEMBERS, OPENROUTER_COUNCIL_MEMBERS, runCouncil, validateMembers } from "../src/council.js";

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const KEY = `openrouter-test-${crypto.randomUUID()}`;
const PLAN = { personality_id: "calm_guide", skill_id: null };
const REPLY_ENV = { DATA_MODE: "synthetic", REPLY_PROVIDER: OPENROUTER_PROVIDER, OPENROUTER_API_KEY: KEY };
const COUNCIL_ENV = { DATA_MODE: "synthetic", COUNCIL_PROVIDER: OPENROUTER_PROVIDER, OPENROUTER_API_KEY: KEY };
const NO_QUOTA = { QUOTA_COUNCIL_PER_DAY: "100000", QUOTA_REPLIES_PER_DAY: "100000" };
const COUNCIL_REPLY = { options: [{ title: "synthetic-option-7a", evidence: ["synthetic-evidence"] }], dissent: [] };

function fakeFetch(respond) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return respond(url, init);
  };
  return { fn, calls };
}
const ok = (content) => () => new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
const leakyError = () => new Response(`upstream says ${KEY} bad`, { status: 429 });

const post = (fetchFn, path, body, env) =>
  createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore() })(
    new Request(`https://x.test${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${issueToken("device-openrouter", SECRET)}` },
      body: JSON.stringify(body),
    }),
    { DEVICE_TOKEN_SECRET: SECRET, ...NO_QUOTA, ...env },
  );

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

test("chatOpenRouter: OpenRouter URL, bearer key, fixed app headers, no session, chatJson body", async () => {
  const { fn, calls } = fakeFetch(ok("{}"));
  await chatOpenRouter([{ role: "user", content: "synthetic" }], { OPENROUTER_API_KEY: KEY }, { fetchFn: fn, model: "m" });
  assert.equal(calls[0].url, OPENROUTER_URL);
  assert.equal(OPENROUTER_URL, "https://openrouter.ai/api/v1/chat/completions");
  const h = calls[0].init.headers;
  assert.equal(h.Authorization, `Bearer ${KEY}`);
  assert.equal(h["Content-Type"], "application/json");
  assert.equal(typeof h["HTTP-Referer"], "string");
  assert.equal(typeof h["X-Title"], "string");
  assert.ok(!(SESSION_HEADER in h));
  assert.deepEqual(
    { t: calls[0].body.temperature, m: calls[0].body.max_tokens, f: calls[0].body.response_format, model: calls[0].body.model },
    { t: 0.4, m: 2048, f: { type: "json_object" }, model: "m" },
  );
});

test("chatOpenRouter: upstream error and empty content give fixed codes, never the body", async () => {
  const env = { OPENROUTER_API_KEY: KEY };
  await assert.rejects(chatOpenRouter([], env, { fetchFn: leakyError, model: "m" }), (err) => {
    assert.equal(err.message, OPENROUTER_ERRORS.status);
    assert.ok(!err.message.includes(KEY));
    return true;
  });
  await assert.rejects(chatOpenRouter([], env, { fetchFn: ok(""), model: "m" }), { message: OPENROUTER_ERRORS.empty });
  await assert.rejects(chatOpenRouter([], {}, { fetchFn: ok("{}"), model: "m" }), { message: OPENROUTER_ERRORS.notConfigured });
});

test("OPENROUTER_BASE_URL: only https on openrouter.ai", () => {
  assert.equal(openRouterUrl({}), OPENROUTER_URL);
  assert.equal(openRouterUrl({ OPENROUTER_BASE_URL: "https://openrouter.ai/api/v1" }), OPENROUTER_URL);
  assert.equal(openRouterUrl({ OPENROUTER_BASE_URL: "https://openrouter.ai/api/v1/chat/completions" }), OPENROUTER_URL);
  for (const bad of ["http://openrouter.ai/api/v1", "https://evil.test/api/v1", "https://openrouter.ai.evil.test/api/v1",
    "https://x.openrouter.ai/api/v1", "https://openrouter.ai:8443/api/v1", "https://u:p@openrouter.ai/api/v1",
    "https://openrouter.ai/api/v1?x=1", "https://openrouter.ai/other", "not a url"]) {
    assert.equal(openRouterUrl({ OPENROUTER_BASE_URL: bad }), null, bad);
  }
  assert.equal(replyConfigProblem({ ...REPLY_ENV, OPENROUTER_BASE_URL: "https://evil.test/v1" }), OPENROUTER_BASE_REFUSED);
});

test("reply config: openrouter_poc needs OPENROUTER_API_KEY, named without a value", () => {
  assert.equal(replyConfigProblem(REPLY_ENV), null);
  const problem = replyConfigProblem({ DATA_MODE: "synthetic", REPLY_PROVIDER: OPENROUTER_PROVIDER, OPENCODE_API_KEY: KEY });
  assert.match(problem, /^OPENROUTER_API_KEY missing for REPLY_PROVIDER=openrouter_poc$/);
  assert.match(replyConfigProblem({ DATA_MODE: "synthetic", REPLY_PROVIDER: OPENROUTER_PROVIDER, OPENROUTER_API_KEY: " " }), /OPENROUTER_API_KEY missing/);
  for (const p of ["openrouter", "OpenRouter_poc", "openrouter_poc "]) {
    assert.match(replyConfigProblem({ ...REPLY_ENV, REPLY_PROVIDER: p }), /REPLY_PROVIDER unknown/, p);
  }
});

test("reply: missing key is refused with 503 before any outbound call", async () => {
  const { fn, calls } = fakeFetch(ok("x"));
  const res = await post(fn, "/reply", { plan: PLAN, transcript: "synthetic-transcript plan my day" }, { DATA_MODE: "synthetic", REPLY_PROVIDER: OPENROUTER_PROVIDER });
  assert.equal(res.status, 503);
  const body = await res.json();
  assert.equal(body.error, "reply_not_configured");
  assert.match(body.detail, /OPENROUTER_API_KEY missing/);
  assert.equal(calls.length, 0);
});

test("reply on openrouter_poc: OpenRouter URL, bearer key, default model, no session header", async () => {
  assert.equal(OPENROUTER_DEFAULT_MODEL, "nvidia/nemotron-3.5-lightning:free");
  assert.equal(OPENROUTER_DEFAULT_MODEL, MODELS.reply_openrouter.model);
  const { fn, calls } = fakeFetch(ok("synthetic-reply Start with the first meeting."));
  const out = await runReply({ plan: PLAN, transcript: "synthetic-transcript plan my day", fetchFn: fn, env: REPLY_ENV });
  assert.equal(out.status, 200);
  assert.equal(out.body.safety, "passed");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, OPENROUTER_URL);
  assert.equal(calls[0].init.headers.Authorization, `Bearer ${KEY}`);
  assert.ok(!(SESSION_HEADER in calls[0].init.headers));
  assert.equal(calls[0].body.model, OPENROUTER_DEFAULT_MODEL);
  assert.ok(!JSON.stringify(out.body).includes(KEY));

  const over = fakeFetch(ok("synthetic-reply ok."));
  await runReply({ plan: PLAN, transcript: "synthetic", fetchFn: over.fn, env: { ...REPLY_ENV, REPLY_LLM_MODEL: "x/y:free" } });
  assert.equal(over.calls[0].body.model, "x/y:free");
});

test("reply on openrouter_poc: upstream error gives fixed reply_upstream", async () => {
  const out = await runReply({ plan: PLAN, transcript: "synthetic", fetchFn: leakyError, env: REPLY_ENV });
  assert.equal(out.status, 502);
  assert.deepEqual(out.body, { error: "reply_upstream" });
  assert.equal(out.code, "reply_upstream");
});

test("council default stays OpenCode Zen with a session header", async () => {
  const { fn, calls } = fakeFetch(ok(JSON.stringify(COUNCIL_REPLY)));
  await runCouncil({ question: "synthetic question" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode", OPENCODE_API_KEY: "k" }, { fetchFn: fn, runId: "run-1" });
  assert.deepEqual([...new Set(calls.map((c) => c.body.model))].sort(), Object.values(COUNCIL_MODELS).sort());
  assert.ok(calls.every((c) => c.init.headers[SESSION_HEADER] === "illunis-council-run-1"));
  assert.ok(calls.every((c) => c.url !== OPENROUTER_URL));
});

test("council on openrouter_poc: three OpenRouter ids, same personas, bearer key, no session header", async () => {
  assert.deepEqual(Object.values(OPENROUTER_MEMBERS), [
    "nvidia/nemotron-3.5-lightning:free",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
    "nvidia/nemotron-3-ultra-550b-a55b:free",
  ]);
  assert.deepEqual(OPENROUTER_COUNCIL_MEMBERS.map((m) => [m.id, m.style]), DEFAULT_MEMBERS.map((m) => [m.id, m.style]));
  const { fn, calls } = fakeFetch(ok(JSON.stringify(COUNCIL_REPLY)));
  const out = await runCouncil({ question: "synthetic question" }, COUNCIL_ENV, { fetchFn: fn, runId: "run-2" });
  assert.equal(calls.length, 9);
  assert.deepEqual([...new Set(calls.map((c) => c.body.model))].sort(), Object.values(OPENROUTER_MEMBERS).sort());
  assert.ok(calls.every((c) => c.url === OPENROUTER_URL));
  assert.ok(calls.every((c) => c.init.headers.Authorization === `Bearer ${KEY}`));
  assert.ok(calls.every((c) => !(SESSION_HEADER in c.init.headers)));
  assert.equal(out.options[0].title, "synthetic-option-7a");
  assert.equal(out.advise_only, true);
});

test("council validateMembers: OpenRouter ids only with the provider; Zen and contributor ids refused there", () => {
  const orMember = [{ id: "a", model: OPENROUTER_MEMBERS.glm }];
  const zenMember = [{ id: "a", model: COUNCIL_MODELS.glm }];
  assert.equal(validateMembers(orMember, COUNCIL_ENV), null);
  assert.match(validateMembers(orMember, {}), /model not allowed/);
  assert.match(validateMembers(zenMember, COUNCIL_ENV), /model not allowed/);
  assert.equal(validateMembers(zenMember, {}), null);
  assert.match(validateMembers([{ model: "synthetic-meta-1-contributor" }], COUNCIL_ENV), /contributor model not allowed/);
  assert.match(validateMembers([{ model: "nvidia/some-contributor:free" }], COUNCIL_ENV), /contributor model not allowed/);
});

test("council route: Zen persona refused on openrouter_poc; missing key and unknown provider give 503", async () => {
  const { fn, calls } = fakeFetch(ok(JSON.stringify(COUNCIL_REPLY)));
  const zen = await post(fn, "/council", { question: "q", personas: [{ id: "a", model: COUNCIL_MODELS.glm }] }, COUNCIL_ENV);
  assert.equal(zen.status, 400);
  const noKey = await post(fn, "/council", { question: "q" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: OPENROUTER_PROVIDER });
  assert.equal(noKey.status, 503);
  assert.match((await noKey.json()).detail, /^OPENROUTER_API_KEY missing for COUNCIL_PROVIDER=openrouter_poc$/);
  const unknown = await post(fn, "/council", { question: "q" }, { COUNCIL_PROVIDER: "openrouter", OPENROUTER_API_KEY: KEY });
  assert.equal(unknown.status, 503);
  assert.match((await unknown.json()).detail, /COUNCIL_PROVIDER unknown/);
  assert.equal(calls.length, 0);
});

test("no logged line or response contains the key, on success and on upstream error", async () => {
  const bodies = [];
  const lines = await captureConsole(async () => {
    for (const fetchFn of [ok(JSON.stringify(COUNCIL_REPLY)), leakyError]) {
      bodies.push(await (await post(fetchFn, "/council", { question: "synthetic q" }, COUNCIL_ENV)).text());
      bodies.push(await (await post(fetchFn, "/reply", { plan: PLAN, transcript: "synthetic t" }, REPLY_ENV)).text());
    }
  });
  assert.ok(lines.length > 0, "error paths log fixed codes");
  for (const line of [...lines, ...bodies]) {
    assert.ok(!line.includes(KEY), "key leaked");
    assert.ok(!line.includes("upstream says"), "upstream body leaked");
  }
});
