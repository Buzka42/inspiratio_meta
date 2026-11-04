// Knowledge sources on the spec approval path: /knowledge/add and /knowledge/remove propose, /spec/apply stores
// the record and its Vectorize chunks tagged with the src_ id, /knowledge/sources lists provenance without text.
// Real AssistantInbox over fake storage; fake Vectorize and Workers AI; synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { EMBED_DIMS, retrieve } from "../src/knowledge/retrieve.js";
import { MAX_CHUNKS, chunkText } from "../src/spec/routes.js";

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
const SOURCE = { title: "Synthetic sleep leaflet", origin: "https://example.test/leaflet", date: "2026-10-01", text: `Synthetic advice. ${"Keep a regular wake time. ".repeat(60)}`, bank: "sleep_lifestyle" };

function storage() {
  const m = new Map();
  return { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
}
function namespace() {
  const objects = new Map();
  return { idFromName: (n) => `id-${n}`, get(id) { if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: storage() }, {})); return objects.get(id); } };
}
// Fake Vectorize: one map, namespaces kept on each vector.
function vectorize() {
  const vectors = new Map();
  return {
    vectors,
    deleted: [],
    async upsert(list) { for (const v of list) vectors.set(v.id, v); },
    async deleteByIds(ids) { this.deleted.push(...ids); for (const id of ids) vectors.delete(id); },
    async query(_vec, { namespace: ns, topK }) {
      return { matches: [...vectors.values()].filter((v) => v.namespace === ns).slice(0, topK).map((v) => ({ id: v.id, score: 0.9, metadata: v.metadata })) };
    },
  };
}
const unit = () => Array.from({ length: EMBED_DIMS }, (_, i) => (i === 0 ? 1 : 0));
const ai = (fail = false) => ({ run: async (_m, { text }) => { if (fail) throw new Error("down"); return { data: text.map(unit) }; } });

function setup({ aiFail = false } = {}) {
  const KNOWLEDGE = vectorize();
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: namespace(), KNOWLEDGE, AI: ai(aiFail) };
  const h = createHandler({ fetchFn: () => assert.fail("no network"), store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  const call = (device) => async (method, path, body) => {
    const res = await h(new Request(`https://w.test${path}`, {
      method, headers: { Authorization: `Bearer ${issueToken(device, SECRET, { now: T0 })}` }, ...(body !== undefined && { body: JSON.stringify(body) }),
    }), env);
    return { status: res.status, body: await res.json() };
  };
  return { env, KNOWLEDGE, owner: call(OWNER), other: call("someone-else") };
}
async function approve(s, path, body) {
  const p = await s.owner("POST", path, body);
  assert.equal(p.status, 200, JSON.stringify(p.body));
  return { proposal: p.body, applied: await s.owner("POST", "/spec/apply", { change_id: p.body.change_id }) };
}

test("chunkText: bounded chunks that cover the text", () => {
  const chunks = chunkText(SOURCE.text);
  assert.ok(chunks.length > 1 && chunks.length <= MAX_CHUNKS);
  assert.ok(chunks.every((c) => c.length <= 800));
  assert.equal(chunks.join(" ").replace(/\s+/g, " "), SOURCE.text.trim().replace(/\s+/g, " "));
  assert.ok(chunkText("x".repeat(3200)).length <= MAX_CHUNKS);
});

test("add: diff names the bank only; apply stores the record and src_-tagged chunks; retrieval returns it", async () => {
  const s = setup();
  const { proposal, applied } = await approve(s, "/knowledge/add", { base_version: 1, source: SOURCE });
  assert.deepEqual(proposal.diff, [{ path: "knowledge.add", from: null, to: "sleep_lifestyle" }]);
  assert.equal(proposal.readback, "Illunis will add a knowledge source.");
  assert.equal(applied.status, 200);
  const { added, indexed, chunks } = applied.body.knowledge;
  assert.match(added.id, /^src_[0-9a-f]{16}$/);
  assert.equal(indexed, true);
  assert.ok(!("text" in added));
  const stored = [...s.KNOWLEDGE.vectors.values()];
  assert.equal(stored.length, chunks);
  for (const v of stored) {
    assert.equal(v.namespace, "sleep_lifestyle");
    assert.equal(v.metadata.source_id, added.id);
    assert.equal(v.metadata.expert, "sleep_lifestyle");
    assert.equal(v.metadata.url, SOURCE.origin);
    assert.ok(v.id.startsWith(`sleep_lifestyle:${added.id.slice(4)}:`));
  }
  const list = await s.owner("GET", "/knowledge/sources");
  assert.deepEqual(list.body.sources, [{ id: added.id, title: SOURCE.title, origin: SOURCE.origin, date: SOURCE.date, bank: SOURCE.bank, added_at: new Date(T0).toISOString() }]);
  const got = await retrieve("sleep_lifestyle", "wake time", s.env, { fetchFn: () => assert.fail() });
  assert.ok(got.passages.length > 0 && got.passages.every((p) => p.source_id === added.id));
  assert.deepEqual((await s.other("GET", "/knowledge/sources")).body.sources, []);
});

test("remove: deletes the record and every chunk id of that source", async () => {
  const s = setup();
  const id = (await approve(s, "/knowledge/add", { base_version: 1, source: SOURCE })).applied.body.knowledge.added.id;
  const before = [...s.KNOWLEDGE.vectors.keys()];
  const { proposal, applied } = await approve(s, "/knowledge/remove", { base_version: 2, source_id: id });
  assert.deepEqual(proposal.diff, [{ path: "knowledge.remove", from: "sleep_lifestyle", to: null }]);
  assert.deepEqual(applied.body.knowledge, { removed: id, unindexed: true });
  assert.ok(before.every((k) => s.KNOWLEDGE.deleted.includes(k)));
  assert.equal(s.KNOWLEDGE.vectors.size, 0);
  assert.deepEqual((await s.owner("GET", "/knowledge/sources")).body.sources, []);
});

test("refusals: unknown bank, bad fields, unknown source, extra keys; non-owner 403", async () => {
  const s = setup();
  const bank = await s.owner("POST", "/knowledge/add", { base_version: 1, source: { ...SOURCE, bank: "astrology" } });
  assert.equal(bank.status, 422);
  assert.deepEqual(bank.body.refused, [{ path: "knowledge_add.bank", reason: "unknown_bank" }]);
  const date = await s.owner("POST", "/knowledge/add", { base_version: 1, source: { ...SOURCE, date: "soon" } });
  assert.equal(date.status, 422);
  const missing = await s.owner("POST", "/knowledge/remove", { base_version: 1, source_id: `src_${"0".repeat(16)}` });
  assert.deepEqual([missing.status, missing.body.code], [422, "unknown_source"]);
  assert.equal((await s.owner("POST", "/knowledge/add", { base_version: 1, source: SOURCE, extra: 1 })).status, 400);
  assert.equal((await s.other("POST", "/knowledge/add", { base_version: 1, source: SOURCE })).status, 403);
  assert.equal(s.KNOWLEDGE.vectors.size, 0);
});

test("embedding failure: the source is stored, the apply reports indexed false with a fixed code", async () => {
  const s = setup({ aiFail: true });
  const { applied } = await approve(s, "/knowledge/add", { base_version: 1, source: SOURCE });
  assert.equal(applied.status, 200);
  assert.equal(applied.body.knowledge.indexed, false);
  assert.equal(applied.body.knowledge.code, "knowledge_embed_failed");
  assert.equal((await s.owner("GET", "/knowledge/sources")).body.sources.length, 1);
});
