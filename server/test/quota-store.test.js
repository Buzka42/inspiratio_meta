import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { QuotaStore, MemoryBacking, InMemoryQuotaStore, DurableObjectQuotaStore, DeviceQuotaCounter, checkQuota } from "../src/quota.js";

// Synthetic only.
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const NOW = Date.parse("2026-10-23T23:59:30Z");
const quiet = { warn() {}, error() {} };
const noNet = () => { throw new Error("network touched"); };
const post = (h, path, body, deviceId = "device-s", env = {}) =>
  h(new Request(`https://x.test${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${issueToken(deviceId, SECRET, { now: NOW })}` },
    body: JSON.stringify(body),
  }), { DEVICE_TOKEN_SECRET: SECRET, ...env });

// Shared fake backing that records every call, standing in for Durable Object storage.
function fakeBacking() {
  const data = {};
  const calls = [];
  return {
    data,
    calls,
    async get(k) { calls.push(["get", k]); return data[k]; },
    async put(k, v) { calls.push(["put", k]); data[k] = v; },
    async delete(k) { calls.push(["delete", k]); return delete data[k]; },
  };
}

test("quota store: the handler counts through the injected store", async () => {
  const hits = [];
  const spy = { async hit(key, day) { hits.push([key, day]); return 1; } };
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore(), quotaStore: spy, logger: quiet, now: () => NOW });
  assert.equal((await post(h, "/turn", { transcript: "plan my day" })).status, 200);
  await post(h, "/reply", {}); // counted before the body is checked
  assert.equal((await post(h, "/router", { transcript: "x" })).status, 200);
  assert.deepEqual(hits[0], ["device-s:turn", "2026-10-23"]);
  assert.deepEqual(hits[1], ["device-s:reply", "2026-10-23"]);
  assert.equal(hits.length, 2, "uncounted /router never reaches the store");
});

test("quota store: keys are device and UTC day, and use the backing", async () => {
  const backing = fakeBacking();
  const store = new QuotaStore(backing);
  assert.equal(await store.hit("d1:turn", "2026-10-23"), 1);
  assert.equal(await store.hit("d1:turn", "2026-10-23"), 2);
  assert.equal(await store.hit("d1:turn", "2026-10-24"), 1);
  assert.equal(await store.hit("d2:turn", "2026-10-23"), 1);
  assert.deepEqual(backing.data, { "quota:2026-10-23:d1:turn": 2, "quota:2026-10-24:d1:turn": 1, "quota:2026-10-23:d2:turn": 1 });
  assert.ok(backing.calls.some(([op]) => op === "put"));
});

test("quota store: a second instance over the same backing sees the same counts", async () => {
  const backing = fakeBacking();
  const env = { QUOTA_REPLIES_PER_DAY: "2" };
  const h1 = createHandler({ fetchFn: noNet, store: new InMemoryStore(), quotaStore: new QuotaStore(backing), logger: quiet, now: () => NOW });
  assert.notEqual((await post(h1, "/reply", {}, "device-p", env)).status, 429);
  assert.notEqual((await post(h1, "/reply", {}, "device-p", env)).status, 429);

  // "Restart": new store and new handler, same backing data.
  const h2 = createHandler({ fetchFn: noNet, store: new InMemoryStore(), quotaStore: new QuotaStore(backing), logger: quiet, now: () => NOW });
  const res = await post(h2, "/reply", {}, "device-p", env);
  assert.equal(res.status, 429);
  const body = await res.json();
  assert.equal(body.bucket, "reply");
  assert.equal(body.retry_after, 30);
  assert.equal(res.headers.get("Retry-After"), "30");

  // Control: the in-memory default does not survive a new instance.
  const store = new InMemoryQuotaStore();
  const args = { deviceId: "m", pathname: "/council", env: { QUOTA_COUNCIL_PER_DAY: "1" }, now: NOW };
  assert.equal(await checkQuota({ ...args, store }), null);
  assert.ok(await checkQuota({ ...args, store }));
  assert.equal(await checkQuota({ ...args, store: new InMemoryQuotaStore() }), null);
});

test("quota store: Durable Object adapter routes by device to one counter (fake namespace)", async () => {
  const objects = new Map();
  const ns = {
    idFromName: (name) => `id-${name}`,
    get: (id) => {
      if (!objects.has(id)) objects.set(id, new DeviceQuotaCounter(new MemoryBacking()));
      return objects.get(id);
    },
  };
  const store = new DurableObjectQuotaStore(ns);
  assert.equal(await store.hit("dev-a:turn", "2026-10-23"), 1);
  assert.equal(await store.hit("dev-a:reply", "2026-10-23"), 1);
  assert.equal(await new DurableObjectQuotaStore(ns).hit("dev-a:turn", "2026-10-23"), 2);
  assert.deepEqual([...objects.keys()], ["id-dev-a"]);
  assert.throws(() => new DurableObjectQuotaStore(undefined), /namespace/);
});
