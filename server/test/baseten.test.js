// Baseten provider: pinned host, request shape, fixed error codes, and brain routing. All network calls are fakes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { BASETEN_DEFAULT_MODEL, basetenConfigProblem, basetenMaxTokens, chatBaseten } from "../src/providers/baseten.js";
import { ProviderError, postJson, readCompletion } from "../src/providers/chat.js";
import { brainConfigProblem, callBrain } from "../src/council/provider.js";

const KEY = `bt-test-${crypto.randomUUID()}`;
const ENV = { BASETEN_API_KEY: KEY };
const META = { META_API_KEY: `m-${crypto.randomUUID()}`, META_MODEL: "synthetic/meta-model" };
const NEBIUS = { NEBIUS_API_KEY: `n-${crypto.randomUUID()}`, COUNCIL_NEBIUS_MODEL: "synthetic/brain" };
const MSG = [{ role: "user", content: "synthetic" }];
const ok = (message, finish = "stop") => new Response(JSON.stringify({ choices: [{ message, finish_reason: finish }] }), { status: 200 });
const recorder = (res) => {
  const calls = [];
  return { calls, fn: async (url, init) => (calls.push({ url, init, body: JSON.parse(init.body) }), typeof res === "function" ? res(url) : res.clone()) };
};
const fails = (p, check) => assert.rejects(p, (e) => e instanceof ProviderError && check(e));

test("config: key required, host pinned, model defaults from code", () => {
  assert.equal(basetenConfigProblem({}), "BASETEN_API_KEY missing");
  assert.equal(basetenConfigProblem(ENV), null);
  assert.match(basetenConfigProblem({ ...ENV, BASETEN_BASE_URL: "https://evil.example/v1" }), /refused/);
  assert.match(basetenConfigProblem({ ...ENV, BASETEN_BASE_URL: "http://inference.baseten.co/v1" }), /refused/);
  assert.match(basetenConfigProblem({ ...ENV, BASETEN_MODEL: "x-contributor-y" }), /contributor/);
});

test("request: pinned URL, bearer, no response_format or tool_choice, reasoning_content ignored", async () => {
  const r = recorder(ok({ content: "answer", reasoning_content: "secret thoughts" }));
  const out = await chatBaseten(MSG, ENV, { fetchFn: r.fn, json: true, role: "relay" });
  assert.equal(out.content, "answer");
  assert.equal(r.calls[0].url, "https://inference.baseten.co/v1/chat/completions");
  assert.equal(r.calls[0].init.headers.Authorization, `Bearer ${KEY}`);
  assert.equal(r.calls[0].body.model, BASETEN_DEFAULT_MODEL);
  assert.ok(!("response_format" in r.calls[0].body) && !("tool_choice" in r.calls[0].body) && !r.calls[0].body.stream);
  assert.ok(!JSON.stringify(out).includes("secret thoughts"));
});

test("request: tools are sent without tool_choice; a no-tool reply is a normal answer", async () => {
  const r = recorder(ok({ content: "plain" }));
  const tools = [{ type: "function", function: { name: "consult", parameters: {} } }];
  const out = await chatBaseten(MSG, ENV, { fetchFn: r.fn, tools, role: "relay" });
  assert.equal(r.calls[0].body.tools.length, 1);
  assert.ok(!("tool_choice" in r.calls[0].body));
  assert.deepEqual(out.tool_calls, []);
});

test("effort: low for plan, expert and summary, medium otherwise, never none; token floors apply", async () => {
  for (const [role, effort] of [["plan", "low"], ["expert", "low"], ["summary", "low"], ["relay", "medium"], ["final", "medium"], [undefined, "medium"]]) {
    const r = recorder(ok({ content: "x" }));
    await chatBaseten(MSG, ENV, { fetchFn: r.fn, role, maxTokens: 10 });
    assert.equal(r.calls[0].body.reasoning_effort, effort);
    assert.ok(r.calls[0].body.max_tokens >= 1500);
  }
  assert.equal(basetenMaxTokens("final", 5000), 5000);
  assert.equal(basetenMaxTokens("final", 10), 3000);
});

test("status codes map to fixed codes and fallback flags, with no body kept", async () => {
  const cases = [[401, "baseten_auth", false], [403, "baseten_forbidden", true], [429, "baseten_rate_limited", true], [529, "baseten_overloaded", true],
    [400, "baseten_status_4xx", false], [500, "baseten_status_5xx", true], [503, "baseten_status_5xx", true]];
  for (const [status, code, fallback] of cases) {
    const fetchFn = async () => new Response("synthetic upstream body", { status });
    await fails(chatBaseten(MSG, ENV, { fetchFn }), (e) => e.code === code && e.fallback === fallback && !JSON.stringify(e).includes("synthetic") && !e.message.includes(KEY));
  }
});

test("timeout, network, bad_json, empty and truncated codes", async () => {
  const thrown = (name) => async () => { throw Object.assign(new Error("synthetic"), { name }); };
  await fails(chatBaseten(MSG, ENV, { fetchFn: thrown("TimeoutError") }), (e) => e.code === "baseten_timeout" && e.fallback);
  await fails(chatBaseten(MSG, ENV, { fetchFn: thrown("TypeError") }), (e) => e.code === "baseten_network" && e.fallback);
  await fails(chatBaseten(MSG, ENV, { fetchFn: async () => new Response("nope", { status: 200 }) }), (e) => e.code === "baseten_bad_json");
  await fails(chatBaseten(MSG, ENV, { fetchFn: async () => ok({ content: "", reasoning_content: "only thoughts" }, "length") }), (e) => e.code === "baseten_empty");
  await fails(chatBaseten(MSG, ENV, { fetchFn: async () => ok({ content: "cut off" }, "length") }), (e) => e.code === "baseten_truncated" && e.fallback);
});

test("brain: order is meta, baseten, nebius; baseten answers when meta is unset", async () => {
  const r = recorder(ok({ content: "from baseten" }));
  const out = await callBrain(MSG, { ...ENV, ...NEBIUS }, { fetchFn: r.fn });
  assert.equal(out.provider, "baseten");
  assert.equal(r.calls.length, 1);
});

test("brain: 429 and 529 fall back to Nebius; 401 does not", async () => {
  for (const status of [429, 529]) {
    const r = recorder((url) => (url.includes("baseten") ? new Response("x", { status }) : ok({ content: "from nebius" })));
    const out = await callBrain(MSG, { ...ENV, ...NEBIUS }, { fetchFn: r.fn });
    assert.equal(out.provider, "nebius");
    assert.equal(r.calls.length, 2);
  }
  const r = recorder(() => new Response("x", { status: 401 }));
  await fails(callBrain(MSG, { ...ENV, ...NEBIUS }, { fetchFn: r.fn }), (e) => e.code === "baseten_auth");
  assert.equal(r.calls.length, 1);
});

test("brain: meta failing falls through to baseten before nebius", async () => {
  const r = recorder((url) => (url.includes("api.meta.ai") ? new Response("x", { status: 503 }) : ok({ content: "from baseten" })));
  const out = await callBrain(MSG, { ...META, ...ENV, ...NEBIUS }, { fetchFn: r.fn });
  assert.equal(out.provider, "baseten");
  assert.deepEqual(r.calls.map((c) => new URL(c.url).hostname), ["api.meta.ai", "inference.baseten.co"]);
});

test("brain: opts.prefer goes first, an unknown prefer is ignored, an unconfigured prefer is skipped", async () => {
  const env = { ...META, ...ENV, ...NEBIUS };
  const hosts = async (prefer, e = env) => {
    const r = recorder(ok({ content: "x" }));
    const out = await callBrain(MSG, e, { fetchFn: r.fn, prefer });
    return [out.provider, r.calls.length];
  };
  assert.deepEqual(await hosts("baseten"), ["baseten", 1]);
  assert.deepEqual(await hosts("nebius"), ["nebius", 1]);
  assert.deepEqual(await hosts("bogus"), ["meta", 1]);
  assert.deepEqual(await hosts("baseten", { ...META, ...NEBIUS }), ["meta", 1]);
});

test("brainConfigProblem: baseten alone is enough; a refused base is a hard error; data mode guard runs", () => {
  assert.equal(brainConfigProblem(ENV), null);
  assert.match(brainConfigProblem({ ...ENV, BASETEN_BASE_URL: "https://evil.example/v1" }), /BASETEN_BASE_URL refused/);
  assert.match(brainConfigProblem({ ...ENV, BASETEN_MODEL: "m-contributor" }), /contributor/);
  assert.match(brainConfigProblem({}), /no council provider: .*BASETEN_API_KEY missing/);
  assert.match(brainConfigProblem({ ...ENV, DATA_MODE: "bogus" }), /DATA_MODE unknown/);
});
