// Skill routes (src/skills/routes.js) through the real handler and a real AssistantInbox over in-memory storage:
// skill_off, memory_off, hosted_ask, name_refused, owner-only writes, a null spec allowing skills, and one happy
// path each for habits add and check-in. No network: fetchFn fails the test if called. Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { EMBED_DIMS } from "../src/knowledge/retrieve.js";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier !== "cloudflare:workers") return next(specifier, context);
    const src = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
    return { url: `data:text/javascript,${encodeURIComponent(src)}`, shortCircuit: true };
  },
});
const { AssistantInbox } = await import("../src/worker.js");

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const OWNER = "owner-phone";
const T0 = Date.parse("2026-11-03T12:00:00Z");

function storage() {
  const m = new Map();
  return { m, get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
}

// Vectorize and Workers AI fakes: query returns whatever was upserted in that namespace.
function knowledge() {
  const vectors = [];
  return {
    vectors,
    KNOWLEDGE: {
      upsert: async (v) => void vectors.push(...v),
      query: async (_, { namespace }) => ({ matches: vectors.filter((v) => v.namespace === namespace).map((v) => ({ metadata: v.metadata, score: 0.9 })) }),
    },
    AI: { run: async (_, { text }) => ({ data: text.map(() => new Array(EMBED_DIMS).fill(0.01)) }) },
  };
}

function setup() {
  const st = storage();
  const ns = { idFromName: (n) => `id-${n}`, obj: null, get() { return (this.obj ??= new AssistantInbox({ storage: st }, {})); } };
  const kn = knowledge();
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: ns, KNOWLEDGE: kn.KNOWLEDGE, AI: kn.AI };
  const fetchFn = async () => assert.fail("no network expected");
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  const call = (device) => async (path, body = {}, method = "POST") => {
    const token = issueToken(device, SECRET, { now: T0 });
    const res = await h(new Request(`https://w.test${path}`, {
      method, headers: { Authorization: `Bearer ${token}` }, ...(method === "POST" && { body: JSON.stringify(body) }),
    }), env);
    return { status: res.status, body: await res.json() };
  };
  return { st, kn, owner: call(OWNER), other: call("someone-else") };
}

async function approve(s, path, change) {
  const p = await s.owner(path, change);
  assert.equal(p.status, 200, JSON.stringify(p.body));
  const a = await s.owner("/spec/apply", { change_id: p.body.change_id });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  return a.body;
}

const HABIT = { name: "write 200 words", cadence: "daily", reminder_time: "09:00", timezone: "UTC" };

test("null spec (none applied yet): habits add, check-in and list work for the owner", async () => {
  const s = setup();
  const add = await s.owner("/habits/add", HABIT);
  assert.equal(add.status, 200, JSON.stringify(add.body));
  assert.equal(add.body.habit.name, HABIT.name);
  const id = add.body.habit.id;
  const ci = await s.owner("/habits/checkin", { id, date: "2026-11-03" });
  assert.deepEqual([ci.status, ci.body], [200, { recorded: true }]);
  const list = await s.owner("/habits/list");
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.habits.map((h) => [h.id, h.streak, h.week, h.status]), [[id, 1, 1, "active"]]);
  assert.deepEqual(s.st.m.get("habits:checkins"), { [id]: ["2026-11-03"] });
  assert.equal((await s.owner("/habits/due")).status, 200);
});

test("name_refused and other fixed habit codes come back as 4xx with the code", async () => {
  const s = setup();
  const r = await s.owner("/habits/add", { ...HABIT, name: "sleep 8 hours" });
  assert.deepEqual([r.status, r.body.code], [422, "name_refused"]);
  const p = await s.owner("/habits/pause", { id: "nope" });
  assert.deepEqual([p.status, p.body.code], [404, "not_found"]);
});

test("owner-only: other devices may not write, and read the default spec (skills on, still owner-only)", async () => {
  const s = setup();
  for (const path of ["/habits/add", "/habits/checkin", "/reading/ask", "/reading/note/add", "/reading/resume/set"]) {
    const r = await s.other(path, HABIT);
    assert.deepEqual([r.status, r.body.code], [403, "skills_forbidden"], path);
  }
  for (const path of ["/habits/list", "/habits/due", "/reading/note/list"]) {
    const r = await s.other(path);
    assert.deepEqual([r.status, r.body.code], [403, "skills_forbidden"], path);
  }
  assert.equal(s.st.m.size, 0, "nothing written");
  assert.equal((await s.owner("/habits/list", undefined, "GET")).status, 404, "POST only");
});

test("skill_off: a spec that turns habits off refuses habit ops", async () => {
  const s = setup();
  await approve(s, "/spec/propose", { base_version: 1, spec_patch: { skills: { habits: false, reading: true } } });
  const r = await s.owner("/habits/add", HABIT);
  assert.deepEqual([r.status, r.body.code], [403, "skill_off"]);
  assert.equal((await s.owner("/reading/note/list")).status, 200, "reading still on");
});

test("memory_off: memory.mode off refuses reading notes", async () => {
  const s = setup();
  await approve(s, "/spec/propose", { base_version: 1, spec_patch: { skills: { reading: true }, memory: { mode: "off" } } });
  for (const path of ["/reading/note/list", "/reading/resume/get"]) {
    const r = await s.owner(path);
    assert.deepEqual([r.status, r.body.code], [403, "memory_off"], path);
  }
});

test("reading bank: knowledge_add indexes source id and part; ask without hosted approval is hosted_ask, no brain call", async () => {
  const s = setup();
  const added = await approve(s, "/knowledge/add", {
    base_version: 1,
    source: { title: "Keeper", origin: "typed in the app", date: "2026-11-03", text: "The lighthouse keeper rowed out every evening.", bank: "reading" },
  });
  assert.equal(added.knowledge.indexed, true, JSON.stringify(added.knowledge));
  const [v] = s.kn.vectors;
  assert.equal(v.namespace, "reading");
  assert.deepEqual([v.metadata.source_id, v.metadata.part], [added.knowledge.added.id, 0]);
  const r = await s.owner("/reading/ask", { question: "What did the keeper do?" });
  assert.deepEqual([r.status, r.body.code], [403, "hosted_ask"]);
});
