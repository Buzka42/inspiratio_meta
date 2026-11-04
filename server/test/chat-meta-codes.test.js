// Meta-only status codes and the truncation rule in providers/chat.js; other prefixes keep their old codes.
// Every network call is a fake; all text is synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ProviderError, postJson, readCompletion } from "../src/providers/chat.js";

const URL = "https://api.example.test/v1/chat/completions";
const post = (prefix, status, text = "synthetic upstream body") =>
  postJson(URL, { body: {}, prefix, fetchFn: async () => new Response(text, { status }) });
const fails = (p, check) => assert.rejects(p, (e) => e instanceof ProviderError && check(e));
const noBody = (e) => !JSON.stringify(e).includes("synthetic") && !e.message.includes("synthetic");

test("meta: each HTTP status maps to its fixed code and fallback", async () => {
  const cases = [
    [401, "meta_auth", false],
    [403, "meta_forbidden", true],
    [451, "meta_region", true],
    [400, "meta_status_4xx", false],
    [404, "meta_status_4xx", false],
    [500, "meta_status_5xx", true],
    [503, "meta_status_5xx", true],
  ];
  for (const [status, code, fallback] of cases) {
    await fails(post("meta", status), (e) => e.code === code && e.status === status && e.fallback === fallback && e.limit === null && noBody(e));
  }
});

test("meta: 429 is meta_rate_limited with the fixed limit kind and no body kept", async () => {
  const kinds = [["synthetic per-day cap", "per_day"], ["synthetic per minute", "per_min"], ["synthetic upstream busy", "upstream"], ["synthetic", "other"]];
  for (const [text, kind] of kinds) {
    await fails(post("meta", 429, text), (e) => e.code === "meta_rate_limited" && e.status === 429 && e.fallback && e.limit === kind && noBody(e));
  }
});

test("meta: timeout, network and bad_json codes are unchanged", async () => {
  const thrown = (name) => postJson(URL, { body: {}, prefix: "meta", fetchFn: async () => { throw Object.assign(new Error("synthetic"), { name }); } });
  await fails(thrown("TimeoutError"), (e) => e.code === "meta_timeout" && e.fallback);
  await fails(thrown("TypeError"), (e) => e.code === "meta_network" && e.fallback);
  await fails(post("meta", 200, "not json"), (e) => e.code === "meta_bad_json" && e.fallback);
});

test("other prefixes keep the old status codes", async () => {
  for (const prefix of ["nebius", "openrouter"]) {
    await fails(post(prefix, 401), (e) => e.code === `${prefix}_status_4xx` && !e.fallback);
    await fails(post(prefix, 403), (e) => e.code === `${prefix}_region` && e.fallback);
    await fails(post(prefix, 451), (e) => e.code === `${prefix}_region` && e.fallback);
    await fails(post(prefix, 429, "synthetic per-day"), (e) => e.code === `${prefix}_status_4xx` && e.fallback && e.limit === "per_day");
    await fails(post(prefix, 502), (e) => e.code === `${prefix}_status_5xx` && e.fallback);
  }
});

const done = (content, finish_reason) => ({ choices: [{ message: { content }, finish_reason }] });

test("meta: finish_reason length is meta_truncated even with content; null content stays meta_empty", () => {
  assert.throws(() => readCompletion(done("synthetic partial answer", "length"), "meta"),
    (e) => e instanceof ProviderError && e.code === "meta_truncated" && e.fallback && e.finish === "length" && noBody(e));
  assert.throws(() => readCompletion(done(null, "length"), "meta"), (e) => e.code === "meta_empty" && e.fallback && e.finish === "length");
  assert.deepEqual(readCompletion(done("synthetic answer", "stop"), "meta"), { content: "synthetic answer", tool_calls: [] });
});

test("other prefixes still accept a length reply with content", () => {
  for (const prefix of ["nebius", "openrouter"]) {
    assert.equal(readCompletion(done("synthetic partial", "length"), prefix).content, "synthetic partial");
    assert.throws(() => readCompletion(done(null, "length"), prefix), (e) => e.code === `${prefix}_empty`);
  }
});
