import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore, checkQuota, quotaLimit } from "../src/quota.js";

// Synthetic only.
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const NOW = Date.parse("2026-10-23T23:59:30Z");
const quiet = { warn() {}, error() {} };
const noNet = () => { throw new Error("network touched"); };
const post = (h, path, body, deviceId = "device-q", env = {}) =>
  h(new Request(`https://x.test${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${issueToken(deviceId, SECRET, { now: NOW })}` },
    body: JSON.stringify(body),
  }), { DEVICE_TOKEN_SECRET: SECRET, ...env });

test("quota: limits default and read env", () => {
  assert.equal(quotaLimit("turn"), 200);
  assert.equal(quotaLimit("council"), 5);
  assert.equal(quotaLimit("digest"), 20);
  assert.equal(quotaLimit("turn", { QUOTA_TURNS_PER_DAY: "3" }), 3);
  assert.equal(quotaLimit("turn", { QUOTA_TURNS_PER_DAY: "lots" }), 200);
  assert.equal(quotaLimit("council", { QUOTA_COUNCIL_PER_DAY: "-1" }), 5);
});

test("quota: over the limit returns 429 with retry_after", async () => {
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), logger: quiet, now: () => NOW });
  const env = { QUOTA_TURNS_PER_DAY: "2" };
  for (let i = 0; i < 2; i++) assert.equal((await post(h, "/turn", { transcript: "plan my day" }, "device-q", env)).status, 200);
  const res = await post(h, "/turn", { transcript: "plan my day" }, "device-q", env);
  assert.equal(res.status, 429);
  const body = await res.json();
  assert.equal(body.error, "quota_exceeded");
  assert.equal(body.bucket, "turn");
  assert.equal(body.limit, 2);
  assert.equal(body.retry_after, 30); // seconds to 00:00 UTC
  assert.equal(res.headers.get("Retry-After"), "30");
  // Per device: another device is unaffected.
  assert.equal((await post(h, "/turn", { transcript: "plan my day" }, "device-other", env)).status, 200);
  // Uncounted routes stay open.
  assert.equal((await post(h, "/router", { transcript: "plan my day" }, "device-q", env)).status, 200);
});

test("quota: council default 5, digest routes share one bucket", async () => {
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), logger: quiet, now: () => NOW });
  const digest = { personality_id: "personal_coach", findings: [] };
  const env = { QUOTA_DIGESTS_PER_DAY: "2" };
  assert.equal((await post(h, "/digest", digest, "d", env)).status, 200);
  assert.equal((await post(h, "/digest/voice", digest, "d", env)).status, 200);
  assert.equal((await post(h, "/digest/voice", digest, "d", env)).status, 429);
  assert.equal((await post(h, "/digest", digest, "d", env)).status, 429);

  // Bad council bodies still count, so the 6th call is refused before any work.
  for (let i = 0; i < 5; i++) assert.equal((await post(h, "/council", {}, "c")).status, 400);
  assert.equal((await post(h, "/council", {}, "c")).status, 429);
});

test("quota: counters reset on the next UTC day", async () => {
  const store = new InMemoryQuotaStore();
  const env = { QUOTA_COUNCIL_PER_DAY: "1" };
  const args = { deviceId: "d", pathname: "/council", env, store };
  assert.equal(await checkQuota({ ...args, now: NOW }), null);
  assert.equal((await checkQuota({ ...args, now: NOW })).retry_after, 30);
  assert.equal(await checkQuota({ ...args, now: NOW + 60_000 }), null);
  assert.equal(await checkQuota({ ...args, pathname: "/router", now: NOW }), null);
});
