// Spec history: hash-chained, bounded, undo through the same propose/apply approval. Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { RevocationList, issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { MemoryStorage, SpecState } from "../src/spec/store.js";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier !== "cloudflare:workers") return next(specifier, context);
    const src = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
    return { url: `data:text/javascript,${encodeURIComponent(src)}`, shortCircuit: true };
  },
});
const { AssistantInbox } = await import("../src/worker.js");

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const INBOX_SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`.replaceAll("-", "");
const OWNER = "owner-phone";
const T0 = Date.parse("2026-11-03T12:00:00Z");

function storage() {
  const m = new Map();
  return { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
}
function namespace() {
  const objects = new Map();
  return { idFromName: (n) => `id-${n}`, get(id) { if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: storage() }, {})); return objects.get(id); } };
}
function setup() {
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: namespace(), ILLUNIS_INBOX_SECRET: INBOX_SECRET };
  const fetchFn = async () => assert.fail("no network expected");
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), revocations: new RevocationList(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  return async (method, path, body) => {
    const res = await h(new Request(`https://w.test${path}`, { method, headers: { Authorization: `Bearer ${issueToken(OWNER, SECRET, { now: T0 })}` }, ...(body !== undefined && { body: JSON.stringify(body) }) }), env);
    return { status: res.status, body: await res.json() };
  };
}
const applyPatch = async (call, base, patch) => {
  const p = await call("POST", "/spec/propose", { base_version: base, spec_patch: patch });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  const a = await call("POST", "/spec/apply", { change_id: p.body.change_id });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  return a.body;
};

test("history: applies chain, listing hides snapshots and user text, revert needs approval", async () => {
  const call = setup();
  await applyPatch(call, 1, { skills: { breathwork: false } });
  await applyPatch(call, 2, { skills: { sleep: false } });
  const h = await call("GET", "/spec/history");
  assert.equal(h.body.history.length, 2);
  assert.deepEqual(h.body.history.map((e) => e.version), [2, 3]);
  assert.equal(h.body.history[1].prev, h.body.history[0].hash);
  assert.ok(!JSON.stringify(h.body.history).includes("guidelines") || !JSON.stringify(h.body.history).includes("spec_patch"));
  assert.ok(h.body.history.every((e) => !("spec" in e)));

  // Revert only proposes; nothing changes until apply.
  const r = await call("POST", "/spec/revert", { version: 2 });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.diff, [{ path: "skills.sleep", from: false, to: true }]);
  assert.equal((await call("GET", "/spec")).body.spec.skills.sleep, false);
  const done = await call("POST", "/spec/apply", { change_id: r.body.change_id });
  assert.equal(done.body.restored_from, 2);
  assert.equal(done.body.spec.version, 4);
  assert.equal(done.body.spec.skills.sleep, true);
  assert.equal(done.body.spec.skills.breathwork, false, "revert restores the whole snapshot, not one key");
  const h2 = await call("GET", "/spec/history");
  assert.equal(h2.body.history.length, 3);
  assert.equal(h2.body.history[2].prev, h2.body.history[1].hash);

  assert.equal((await call("POST", "/spec/revert", { version: 99 })).status, 422);
  assert.equal((await call("POST", "/spec/revert", { version: 4 })).body.code, "no_change");
});

test("SpecState: chain verifies, tampering is detected, window is bounded", async () => {
  const st = new MemoryStorage();
  let n = 0;
  const s = new SpecState(st, { now: () => T0, randomId: () => `${(n++).toString(16).padStart(8, "0")}${"ab".repeat(12)}`.slice(0, 32) });
  for (let i = 0; i < 12; i++) {
    const spec = await s.get();
    const p = await s.propose({ base_version: spec.version, spec_patch: { memory: { retention_days: 31 + i } } });
    assert.ok(p.change_id, JSON.stringify(p));
    assert.ok((await s.apply(p.change_id)).spec);
  }
  const h = await s.history();
  assert.equal(h.length, 10);
  assert.equal(h.at(-1).version, 13);
  assert.deepEqual(await s.verifyHistory(), { ok: true, entries: 10 });
  const raw = await st.get("spec:history");
  raw[5].spec.memory.retention_days = 1;
  await st.put("spec:history", raw);
  assert.equal((await s.verifyHistory()).ok, false);
});
