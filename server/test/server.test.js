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
import { route } from "../src/router.js";
import { InMemoryStore, ZepStore } from "../src/memory.js";
import { gateText, REFERRAL_TEXT } from "../src/safety.js";
import { buildMessages, DEFAULT_MEMBERS, ROUNDS } from "../src/council.js";

const noNet = () => { throw new Error("network touched"); };
const call = (h, path, body, method = "POST", env = {}) =>
  h(new Request(`https://x.test${path}`, {
    method,
    headers: AUTH,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  }), { DEVICE_TOKEN_SECRET: SECRET, ...NO_QUOTA, ...env });

test("router: keyword rule", () => {
  assert.deepEqual(route("help me with my breathing"), { personality_id: "calm_guide", skill_id: "breathwork", escalate: false });
  assert.equal(route("plan my day").skill_id, "habit_building");
});

test("router: unmatched falls back and escalates", () => {
  const r = route("blah");
  assert.equal(r.escalate, true);
  assert.equal(r.personality_id, "calm_guide");
});

test("router: crisis short-circuits with no model call", async () => {
  const h = createHandler({ fetchFn: noNet });
  const res = await call(h, "/router", { transcript: "I want to die, help me with my workout" });
  const body = await res.json();
  assert.equal(body.crisis, true);
  assert.equal(body.response, REFERRAL_TEXT);
  assert.equal(body.personality_id, null);
});

test("memory: write then recall, expiry filtered", async () => {
  let t = Date.parse("2026-10-23T00:00:00Z");
  const h = createHandler({ store: new InMemoryStore(), now: () => t });
  const mk = (text, expires_at) => ({ text, kind: "hypothesis", source: "analysis", confidence: 0.6, expires_at });
  const w = await call(h, "/memory/write", mk("short lived", "2026-10-24T00:00:00Z"));
  const stored = await w.json();
  for (const k of ["id", "text", "created_at", "source", "confidence", "expires_at", "kind"]) assert.ok(k in stored, k);
  await call(h, "/memory/write", mk("forever", null));
  assert.equal((await (await call(h, "/memory/recall", {})).json()).items.length, 2);
  t = Date.parse("2026-10-25T00:00:00Z");
  const items = (await (await call(h, "/memory/recall", {})).json()).items;
  assert.deepEqual(items.map((i) => i.text), ["forever"]);
});

test("memory: kind and confidence validation", async () => {
  const h = createHandler({ store: new InMemoryStore() });
  const base = { text: "a", source: "s" };
  assert.equal((await call(h, "/memory/write", { ...base, kind: "opinion" })).status, 400);
  assert.equal((await call(h, "/memory/write", { ...base, kind: "fact", confidence: 2 })).status, 400);
  assert.equal((await call(h, "/memory/write", { ...base, kind: "note" })).status, 200);
});

test("memory: Zep stub throws not configured", async () => {
  await assert.rejects(new ZepStore({}).write(), /not configured/);
  await assert.rejects(new ZepStore({ MEMORY_KEY: "k" }).recall(), /not configured/);
  const h = createHandler();
  const res = await call(h, "/memory/recall", {}, "POST", { MEMORY_KEY: "k", MEMORY_SERVER_URL: "https://z.test" });
  assert.equal(res.status, 503);
});

function councilFetch(sent, reply) {
  return async (url, init) => {
    sent.push(JSON.parse(init.body));
    return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(reply) } }] }));
  };
}

test("council: three rounds, only question and prior summary, never memory", async () => {
  const sent = [];
  const store = new InMemoryStore();
  await store.write({ id: "1", text: "SECRET-MEMORY-TEXT", created_at: "x", source: "s", confidence: 1, expires_at: null, kind: "fact" });
  const reply = { options: [{ title: "Walk", evidence: ["sleep trend observed"] }], dissent: ["maybe rest"] };
  const h = createHandler({ fetchFn: councilFetch(sent, reply), store });
  const res = await call(h, "/council", { question: "How to improve energy?" }, "POST", { OPENCODE_API_KEY: "test", DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" });
  const out = await res.json();
  assert.equal(sent.length, DEFAULT_MEMBERS.length * ROUNDS);
  assert.equal(out.rounds, 3);
  assert.equal(out.advise_only, true);
  assert.equal(out.experimental, true);
  assert.deepEqual(out.options, [{ title: "Walk", evidence: ["sleep trend observed"] }]);
  assert.deepEqual(out.dissent, ["maybe rest"]);
  for (const req of sent) {
    assert.equal(req.messages.length, 2);
    assert.ok(!JSON.stringify(req).includes("SECRET-MEMORY-TEXT"));
    assert.deepEqual(Object.keys(JSON.parse(req.messages[1].content)).sort(), ["previous_summary", "question"]);
  }
  assert.equal(JSON.parse(sent[0].messages[1].content).previous_summary, "");
  assert.match(JSON.parse(sent[DEFAULT_MEMBERS.length].messages[1].content).previous_summary, /Walk/);
});

test("council: unsafe member output replaced with referral", async () => {
  const reply = { options: [{ title: "Rest", evidence: ["You must stop, this is a diagnosis"] }], dissent: ["I want to die"] };
  const h = createHandler({ fetchFn: councilFetch([], reply) });
  const out = await (await call(h, "/council", { question: "q" }, "POST", { DATA_MODE: "synthetic", COUNCIL_PROVIDER: "opencode" })).json();
  assert.equal(out.options[0].title, "Rest");
  assert.equal(out.options[0].evidence[0], REFERRAL_TEXT);
  assert.equal(out.dissent[0], REFERRAL_TEXT);
});

test("safety gate", () => {
  assert.equal(gateText("Consider a walk."), "Consider a walk.");
  for (const bad of ["You must rest", "that is a diagnosis", "I feel suicidal"]) assert.equal(gateText(bad), REFERRAL_TEXT);
});

test("council: buildMessages carries only question and summary", () => {
  const m = buildMessages({ style: "x" }, "Q", "S");
  assert.deepEqual(JSON.parse(m[1].content), { question: "Q", previous_summary: "S" });
});

test("digest: disclaimer only for health findings", async () => {
  const h = createHandler({ fetchFn: noNet });
  const health = await (await call(h, "/digest", { personality_id: "personal_coach", skill_pack_id: "weight_training", findings: [{ text: "resting heart rate drifted up", kind: "health" }] })).json();
  assert.match(health.text, /observation/);
  assert.match(health.disclaimer, /not medical advice/i);
  const plain = await (await call(h, "/digest", { personality_id: "productivity_advisor", skill_pack_id: "habit_building", findings: [{ text: "three meetings today" }] })).json();
  assert.equal(plain.disclaimer, null);
});

test("404 and 400 paths", async () => {
  const h = createHandler({ fetchFn: noNet });
  assert.deepEqual(await (await call(h, "/health", undefined, "GET")).json(), { ok: true });
  assert.equal((await call(h, "/nope", {})).status, 404);
  assert.equal((await call(h, "/router", undefined, "GET")).status, 404);
  assert.equal((await call(h, "/router", "not json")).status, 400);
  assert.equal((await call(h, "/router", {})).status, 400);
  assert.equal((await call(h, "/council", {})).status, 400);
  assert.equal((await call(h, "/digest", { personality_id: "personal_coach" })).status, 400);
});
