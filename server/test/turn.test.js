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
import { RULES, DEFAULT_ROUTE } from "../src/router.js";
import { InMemoryStore } from "../src/memory.js";
import { REFERRAL_TEXT } from "../src/safety.js";
import { getPersonality, getSkill, listPersonalities, listSkills } from "../src/content.js";
import { runTurn, RECALL_LIMIT } from "../src/turn.js";

// Synthetic fixtures only.
const NOW = Date.parse("2026-10-23T08:00:00Z");
const noNet = () => { throw new Error("network touched"); };
const call = (h, path, body) =>
  h(new Request(`https://x.test${path}`, { method: "POST", headers: AUTH, body: typeof body === "string" ? body : JSON.stringify(body) }), { DEVICE_TOKEN_SECRET: SECRET, ...NO_QUOTA });
const mem = (id, text, kind, expires_at = null) =>
  ({ id, text, kind, source: "synthetic", confidence: 0.6, created_at: "2026-10-01T00:00:00Z", expires_at });

test("content: listings and getters", () => {
  assert.deepEqual(listPersonalities().map((p) => p.id).sort(),
    ["calm_guide", "daily_planner", "dream_companion", "drill_sergeant_trainer", "personal_coach", "productivity_advisor", "reflective_journal_guide", "socratic_tutor"]);
  assert.deepEqual(listSkills().map((s) => s.id).sort(), ["breathwork", "habit_building", "meditation_basics", "motivation", "weight_training", "wind_down_routine"]);
  assert.equal(getPersonality("calm_guide").name, "Calm Guide");
  assert.equal(getSkill("nope"), null);
});

test("content: every id the router references exists in content", () => {
  const personalities = new Set([DEFAULT_ROUTE.personality_id, ...RULES.map((r) => r.personality_id)]);
  const skills = new Set(RULES.map((r) => r.skill_id).filter(Boolean));
  const missing = [
    ...[...personalities].filter((id) => !getPersonality(id)).map((id) => `personality:${id}`),
    ...[...skills].filter((id) => !getSkill(id)).map((id) => `skill:${id}`),
  ];
  assert.deepEqual(missing, [], `router ids with no content: ${missing.join(", ")}`);
});

test("turn: plan from content, no model call", async () => {
  const store = new InMemoryStore();
  const plan = await runTurn({ transcript: "help me with my breathing", memoryStore: store, now: NOW });
  assert.equal(plan.personality_id, "calm_guide");
  assert.equal(plan.skill_id, "breathwork");
  assert.equal(plan.escalate, false);
  assert.ok(plan.system_prompt.startsWith(getPersonality("calm_guide").system_prompt));
  assert.match(plan.system_prompt, /Skill: Breathwork/);
  assert.deepEqual(plan.memories, []);
});

test("turn: crisis returns referral and skips recall", async () => {
  const store = { recall: () => { throw new Error("recall touched"); } };
  const plan = await runTurn({ transcript: "I want to die", memoryStore: store, now: NOW });
  assert.equal(plan.crisis, true);
  assert.equal(plan.response, REFERRAL_TEXT);
  assert.equal(plan.system_prompt, undefined);
});

test("turn: recall caps at 5, drops expired, labels hypotheses observation", async () => {
  const store = new InMemoryStore();
  for (let i = 0; i < 7; i++) await store.write(mem(`f${i}`, `sleep fact ${i}`, "fact"));
  await store.write(mem("old", "sleep old", "hypothesis", "2026-10-22T00:00:00Z"));
  await store.write(mem("h1", "sleep shorter on weekdays", "hypothesis", "2026-11-01T00:00:00Z"));
  const plan = await runTurn({ transcript: "x", context: { query: "sleep" }, memoryStore: store, now: NOW });
  assert.equal(plan.memories.length, RECALL_LIMIT);
  assert.ok(!plan.memories.some((m) => m.id === "old"));
  const h = plan.memories.find((m) => m.id === "h1");
  assert.equal(h.label, "observation");
  assert.ok(!plan.memories.some((m) => m.label === "hypothesis"));
  assert.ok(!("kind" in h));
});

test("turn: expiry re-checked when an adapter returns expired items", async () => {
  const store = { recall: async () => [mem("e", "stale", "fact", "2026-10-01T00:00:00Z"), mem("ok", "fresh", "note")] };
  const plan = await runTurn({ transcript: "x", memoryStore: store, now: NOW });
  assert.deepEqual(plan.memories.map((m) => [m.id, m.label]), [["ok", "note"]]);
});

test("POST /turn: 400 paths", async () => {
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore() });
  assert.equal((await call(h, "/turn", "not json")).status, 400);
  assert.equal((await call(h, "/turn", {})).status, 400);
  assert.equal((await call(h, "/turn", { transcript: "  " })).status, 400);
  assert.equal((await call(h, "/turn", { transcript: "hi", context: [] })).status, 400);
});

test("POST /turn: crisis path", async () => {
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore() });
  const res = await call(h, "/turn", { transcript: "I feel suicidal, plan my day" });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.crisis, true);
  assert.equal(body.response, REFERRAL_TEXT);
  assert.equal(body.personality_id, null);
});

test("POST /turn: hypothesis memory labelled observation", async () => {
  const store = new InMemoryStore();
  await store.write(mem("h", "workout energy dips after short sleep", "hypothesis"));
  const h = createHandler({ fetchFn: noNet, store, now: () => NOW });
  const body = await (await call(h, "/turn", { transcript: "workout", context: { query: "workout" } })).json();
  assert.equal(body.personality_id, "personal_coach");
  assert.deepEqual(body.memories.map((m) => m.label), ["observation"]);
  assert.match(body.system_prompt, /labelled observation are tentative/);
});

test("POST /digest/voice: greeting uses voice_style, disclaimer rule kept", async () => {
  const h = createHandler({ fetchFn: noNet });
  const style = getPersonality("calm_guide").voice_style;
  const health = await (await call(h, "/digest/voice", { personality_id: "calm_guide", skill_pack_id: "breathwork", findings: [{ text: "resting heart rate drifted up", kind: "health" }] })).json();
  assert.ok(health.text.startsWith(`Good morning. ${style}`));
  assert.match(health.disclaimer, /not medical advice/i);
  const plain = await (await call(h, "/digest/voice", { personality_id: "personal_coach", findings: [{ text: "three meetings today" }] })).json();
  assert.equal(plain.personality_id, "personal_coach");
  assert.equal(plain.disclaimer, null);
  const unsafe = await (await call(h, "/digest/voice", { personality_id: "calm_guide", findings: [{ text: "you must rest" }] })).json();
  assert.equal(unsafe.text, REFERRAL_TEXT);
  assert.equal((await call(h, "/digest/voice", { personality_id: "ghost", findings: [] })).status, 400);
  assert.equal((await call(h, "/digest/voice", { personality_id: "calm_guide" })).status, 400);
});
