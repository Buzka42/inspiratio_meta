import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { DeviceQuotaCounter, DurableObjectQuotaStore, checkQuota } from "../src/quota.js";

// Stand-in for the runtime module, so the real entry (src/worker.js) loads under node.
registerHooks({
  resolve(specifier, context, next) {
    if (specifier !== "cloudflare:workers") return next(specifier, context);
    const src = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
    return { url: `data:text/javascript,${encodeURIComponent(src)}`, shortCircuit: true };
  },
});
const { QuotaCounter, default: entry } = await import("../src/worker.js");

// Synthetic only.
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const NOW = Date.parse("2026-10-23T23:59:30Z");
const quiet = { warn() {}, error() {} };
const noNet = () => { throw new Error("network touched"); };

// Fake ctx.storage: async get/put that yield between calls, like real I/O.
function fakeStorage() {
  const data = new Map();
  const tick = () => new Promise((r) => setTimeout(r, Math.random() * 3));
  return {
    data,
    async get(k) { await tick(); return structuredClone(data.get(k)); },
    async put(k, v) { await tick(); data.set(k, structuredClone(v)); },
    async delete(k) { await tick(); return data.delete(k); },
  };
}

// Fake namespace: one QuotaCounter (the real DO class) per name, like idFromName + get.
function fakeNamespace() {
  const objects = new Map();
  return {
    objects,
    idFromName: (name) => `id-${name}`,
    get(id) {
      if (!objects.has(id)) objects.set(id, new QuotaCounter({ storage: fakeStorage() }, {}));
      return objects.get(id);
    },
  };
}

test("quota DO: worker entry exports the class and the fetch handler", () => {
  assert.equal(typeof QuotaCounter, "function");
  assert.equal(typeof entry.fetch, "function");
  const obj = new QuotaCounter({ storage: fakeStorage() }, { X: 1 });
  assert.ok(obj.ctx.storage && obj.env.X === 1, "super(ctx, env) called");
});

test("quota DO: counts per key, resets on a new UTC day in one record", async () => {
  const storage = fakeStorage();
  const c = new DeviceQuotaCounter(storage);
  assert.equal(await c.hit("d1:turn", "2026-10-23"), 1);
  assert.equal(await c.hit("d1:turn", "2026-10-23"), 2);
  assert.equal(await c.hit("d1:reply", "2026-10-23"), 1);
  assert.equal(await c.hit("d1:turn", "2026-10-24"), 1, "new day starts at 1");
  assert.deepEqual([...storage.data.keys()], ["quota"], "one key, yesterday dropped");
  assert.deepEqual(storage.data.get("quota"), { day: "2026-10-24", counts: { "d1:turn": 1 } });
  // A late hit stamped with the old day counts against today, never resets it.
  assert.equal(await c.hit("d1:turn", "2026-10-23"), 2);
});

test("quota DO: counts survive a new object over the same storage", async () => {
  const storage = fakeStorage();
  await new DeviceQuotaCounter(storage).hit("d1:council", "2026-10-23");
  assert.equal(await new DeviceQuotaCounter(storage).hit("d1:council", "2026-10-23"), 2);
});

test("quota DO: concurrent hits in one object never lose a count", async () => {
  const c = new DeviceQuotaCounter(fakeStorage());
  const counts = await Promise.all(Array.from({ length: 50 }, () => c.hit("d1:turn", "2026-10-23")));
  assert.deepEqual([...counts].sort((a, b) => a - b), Array.from({ length: 50 }, (_, i) => i + 1));
  assert.equal(await c.hit("d1:turn", "2026-10-23"), 51);
});

test("quota DO: bad input is refused and does not block later hits", async () => {
  const c = new DeviceQuotaCounter(fakeStorage());
  await assert.rejects(c.hit("bad key", "2026-10-23"), /key invalid/);
  await assert.rejects(c.hit("d1:turn", "23/10/2026"), /day invalid/);
  assert.equal(await c.hit("d1:turn", "2026-10-23"), 1);
});

test("quota DO: limit hit returns bucket, limit and retry_after", async () => {
  const store = new DurableObjectQuotaStore(fakeNamespace());
  const args = { deviceId: "dev-q", pathname: "/council", env: { QUOTA_COUNCIL_PER_DAY: "2" }, store, now: NOW };
  assert.equal(await checkQuota(args), null);
  assert.equal(await checkQuota(args), null);
  assert.deepEqual(await checkQuota(args), { bucket: "council", limit: 2, retry_after: 30 });
  assert.equal(await checkQuota({ ...args, now: NOW + 60_000 }), null, "next UTC day resets");
});

const post = (h, path, body, deviceId, env) =>
  h(new Request(`https://x.test${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${issueToken(deviceId, SECRET, { now: NOW })}` },
    body: JSON.stringify(body),
  }), { DEVICE_TOKEN_SECRET: SECRET, ...env });

test("quota DO: handler uses env.QUOTA_DO by default and answers 429 at the limit", async () => {
  const ns = fakeNamespace();
  const env = { QUOTA_DO: ns, QUOTA_TURNS_PER_DAY: "1" };
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore(), logger: quiet, now: () => NOW });
  assert.equal((await post(h, "/turn", { transcript: "plan my day" }, "dev-h", env)).status, 200);
  // A second handler (another isolate) shares the same object.
  const h2 = createHandler({ fetchFn: noNet, store: new InMemoryStore(), logger: quiet, now: () => NOW });
  const res = await post(h2, "/turn", { transcript: "plan my day" }, "dev-h", env);
  assert.equal(res.status, 429);
  assert.deepEqual(await res.json(), { error: "quota_exceeded", bucket: "turn", limit: 1, retry_after: 30 });
  assert.deepEqual([...ns.objects.keys()], ["id-dev-h"]);
});

test("quota DO: an unreachable counter fails closed with 503", async () => {
  const logs = [];
  const ns = { idFromName: (n) => n, get: () => ({ hit: async () => { throw new Error("do down"); } }) };
  const h = createHandler({
    fetchFn: noNet, store: new InMemoryStore(), now: () => NOW,
    logger: { warn() {}, error: (...a) => logs.push(a) },
  });
  const res = await post(h, "/turn", { transcript: "plan my day" }, "dev-x", { QUOTA_DO: ns });
  assert.equal(res.status, 503);
  assert.deepEqual(await res.json(), { error: "quota_unavailable" });
  assert.deepEqual(logs, [["quota_store_error", "/turn", "dev-x"]], "codes only, no error text");
});
