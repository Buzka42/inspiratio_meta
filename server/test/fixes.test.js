import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
// Synthetic per-run secret and device token, generated at runtime, never stored.
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
// Quotas are covered in quota.test.js; lift them here so call counts do not interfere.
const NO_QUOTA = { QUOTA_TURNS_PER_DAY: "100000", QUOTA_COUNCIL_PER_DAY: "100000", QUOTA_DIGESTS_PER_DAY: "100000" };
// Issued early with a long ttl so fixed test clocks (now: () => NOW) sit inside its lifetime.
const AUTH = { Authorization: `Bearer ${issueToken("test-device", SECRET, { now: Date.parse("2026-01-01T00:00:00Z"), ttlDays: 3650 })}` };
import { InMemoryStore } from "../src/memory.js";
import { DEFAULT_MEMBERS, runCouncil, validateMembers, ROUNDS } from "../src/council.js";
import { OPENCODE_URL, SESSION_HEADER, chatJson } from "../src/opencode.js";

const call = (h, path, body, env = {}) =>
  h(new Request(`https://x.test${path}`, { method: "POST", headers: AUTH, body: JSON.stringify(body) }), { DEVICE_TOKEN_SECRET: SECRET, ...NO_QUOTA, ...env });

function recordingFetch(calls) {
  return async (url, init) => {
    calls.push({ url, headers: init.headers, body: JSON.parse(init.body) });
    const reply = { options: [{ title: "Walk", evidence: ["synthetic"] }], dissent: [] };
    return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(reply) } }] }));
  };
}

test("council: Zen free set, no Contributor member", () => {
  const models = DEFAULT_MEMBERS.map((m) => m.model);
  assert.deepEqual(models, ["deepseek-v4.1-flash-free", "glm-5.3-flash-free", "nemotron-3.5-super-vl-free"]);
  assert.ok(models.every((m) => !/contributor/i.test(m)));
  assert.equal(validateMembers(DEFAULT_MEMBERS), null);
});

test("council: Contributor ids are refused everywhere", async () => {
  for (const model of ["synthetic-meta-1-contributor", "deepseek-v4.1-flash-contributor", "GLM-CONTRIBUTOR"]) {
    assert.match(validateMembers([{ model }]), /contributor/);
    const calls = [];
    const h = createHandler({ fetchFn: recordingFetch(calls) });
    const res = await call(h, "/council", { question: "q", personas: [{ id: "x", model }] });
    assert.equal(res.status, 400);
    assert.match((await res.json()).detail, /contributor/);
    assert.equal(calls.length, 0);
    await assert.rejects(
      runCouncil({ question: "q", personas: [{ model }] }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" }, { fetchFn: recordingFetch(calls), runId: "r1" }),
      /contributor/,
    );
    assert.equal(calls.length, 0);
  }
  assert.match(validateMembers([{ model: "synthetic-meta-1" }]), /not allowed/);
});

test("opencode: default endpoint, base url override, session header sent", async () => {
  const calls = [];
  await chatJson([], { OPENCODE_API_KEY: "test" }, { fetchFn: recordingFetch(calls), model: "glm-5.3-flash", sessionId: "s1" });
  assert.equal(OPENCODE_URL, "https://opencode.ai/zen/v1/chat/completions");
  assert.equal(calls[0].url, OPENCODE_URL);
  assert.equal(calls[0].headers[SESSION_HEADER], "s1");
  await chatJson([], { OPENCODE_BASE_URL: "https://proxy.test/v1/chat/completions" }, { fetchFn: recordingFetch(calls), model: "glm-5.3-flash", sessionId: "s2" });
  assert.equal(calls[1].url, "https://proxy.test/v1/chat/completions");
  await assert.rejects(chatJson([], {}, { fetchFn: recordingFetch(calls), model: "glm-5.3-flash" }), /session id required/);
});

test("council: one session id per run, derived from the run id", async () => {
  const calls = [];
  const h = createHandler({ fetchFn: recordingFetch(calls) });
  assert.equal((await call(h, "/council", { question: "q", run_id: "run-A" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" })).status, 200);
  assert.equal(calls.length, DEFAULT_MEMBERS.length * ROUNDS);
  assert.ok(calls.every((c) => c.headers[SESSION_HEADER] === "illunis-council-run-A"));
  await call(h, "/council", { question: "q", run_id: "run-B" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" });
  assert.ok(calls.slice(DEFAULT_MEMBERS.length * ROUNDS).every((c) => c.headers[SESSION_HEADER] === "illunis-council-run-B"));
  // No run id: a fresh id per run, still one per run.
  await call(h, "/council", { question: "q" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" });
  await call(h, "/council", { question: "q" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" });
  const s3 = new Set(calls.slice(2 * DEFAULT_MEMBERS.length * ROUNDS, 3 * DEFAULT_MEMBERS.length * ROUNDS).map((c) => c.headers[SESSION_HEADER]));
  const s4 = new Set(calls.slice(3 * DEFAULT_MEMBERS.length * ROUNDS, 4 * DEFAULT_MEMBERS.length * ROUNDS).map((c) => c.headers[SESSION_HEADER]));
  assert.equal(s3.size, 1);
  assert.equal(s4.size, 1);
  assert.notDeepEqual([...s3], [...s4]);
  assert.equal((await call(h, "/council", { question: "q", run_id: "bad id!" }, { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" })).status, 400);
});

const GRAPHITI = {
  MEMORY_SERVER_URL: "https://memory.vps.test",
  MEMORY_KEY: "test",
  MEMORY_LLM_BASE_URL: "http://10.0.0.5:8000/v1",
  MEMORY_EMBED_BASE_URL: "http://10.0.0.5:8001/v1",
};
const item = { text: "synthetic", kind: "note", source: "test" };

test("memory: write refuses 503 without self-hosted LLM and embedder URLs", async () => {
  const store = new InMemoryStore();
  const h = createHandler({ store });
  for (const [missing, re] of [["MEMORY_LLM_BASE_URL", /MEMORY_LLM_BASE_URL missing/], ["MEMORY_EMBED_BASE_URL", /MEMORY_EMBED_BASE_URL missing/]]) {
    const env = { ...GRAPHITI };
    delete env[missing];
    const res = await call(h, "/memory/write", item, env);
    assert.equal(res.status, 503);
    const body = await res.json();
    assert.equal(body.error, "not_configured");
    assert.match(body.detail, re);
    assert.match(body.detail, /self-hosted/);
  }
  const openai = await call(h, "/memory/write", item, { ...GRAPHITI, MEMORY_LLM_BASE_URL: "https://api.openai.com/v1" });
  assert.equal(openai.status, 503);
  assert.match((await openai.json()).detail, /third-party/);
  // A partial Graphiti config never falls back to the in-memory store.
  assert.equal((await call(h, "/memory/write", item, { MEMORY_LLM_BASE_URL: GRAPHITI.MEMORY_LLM_BASE_URL })).status, 503);
  assert.equal(store.items.length, 0);
  // Full config reaches the adapter, which is still a stub: 503, no values echoed.
  const full = await call(h, "/memory/write", item, GRAPHITI);
  assert.equal(full.status, 503);
  const text = JSON.stringify(await full.json());
  assert.match(text, /not implemented/);
  for (const v of Object.values(GRAPHITI)) assert.ok(!text.includes(v));
});
