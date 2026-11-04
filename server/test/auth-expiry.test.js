import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { createHandler } from "../src/index.js";
import {
  issueToken, checkToken, tokenTtlDays, issueDeviceToken, revokeDevice, RevocationList, DEFAULT_TTL_DAYS,
} from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore, MemoryBacking } from "../src/quota.js";

// Synthetic only. Secrets are generated per run and never written to disk.
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const ENV = { DEVICE_TOKEN_SECRET: SECRET };
const NOW = Date.parse("2026-10-24T12:00:00Z");
const DAY = 86_400_000;
const quiet = { warn() {}, error() {} };
const noNet = () => { throw new Error("network touched"); };
const make = (now, revocations = new RevocationList()) =>
  createHandler({ fetchFn: noNet, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), revocations, logger: quiet, now: () => now });
const call = (h, token, env = ENV) =>
  h(new Request("https://x.test/router", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify({ transcript: "plan my day" }),
  }), env);

test("expiry: default ttl is 90 days, TOKEN_TTL_DAYS overrides", () => {
  assert.equal(DEFAULT_TTL_DAYS, 90);
  assert.equal(tokenTtlDays({}), 90);
  assert.equal(tokenTtlDays({ TOKEN_TTL_DAYS: "7" }), 7);
  for (const bad of ["0", "-3", "1.5", "lots"]) assert.equal(tokenTtlDays({ TOKEN_TTL_DAYS: bad }), 90, bad);
  const [, iat, exp] = issueToken("d", SECRET, { now: NOW }).split(".");
  assert.equal(Number(exp) - Number(iat), 90 * 86_400);
  const [, iat7, exp7] = issueDeviceToken("d", { ...ENV, TOKEN_TTL_DAYS: "7" }, NOW).split(".");
  assert.equal(Number(exp7) - Number(iat7), 7 * 86_400);
  assert.throws(() => issueToken("d", SECRET, { ttlDays: 0 }), /ttl/);
});

test("expiry: an expired token is 401 token_expired", async () => {
  const token = issueToken("device-x", SECRET, { now: NOW, ttlDays: 1 });
  assert.equal((await call(make(NOW + DAY - 1000), token)).status, 200);
  const res = await call(make(NOW + DAY), token);
  assert.equal(res.status, 401);
  assert.deepEqual(await res.json(), { error: "unauthorized", code: "token_expired" });
});

test("expiry: a token issued in the future is 401 token_invalid", async () => {
  const token = issueToken("device-f", SECRET, { now: NOW + 3_600_000 });
  const res = await call(make(NOW), token);
  assert.equal(res.status, 401);
  assert.deepEqual(await res.json(), { error: "unauthorized", code: "token_invalid" });
  // Within the 60 s skew allowance it is accepted.
  assert.equal((await call(make(NOW), issueToken("device-f", SECRET, { now: NOW + 30_000 }))).status, 200);
});

test("expiry: editing the expiry breaks the signature", async () => {
  const token = issueToken("device-e", SECRET, { now: NOW, ttlDays: 1 });
  const [id, iat, exp, mac] = token.split(".");
  const later = String(Number(exp) + 365 * 86_400);
  const forged = [id, iat, later, mac].join(".");
  assert.deepEqual(checkToken(forged, SECRET, NOW), { code: "token_invalid" });
  const res = await call(make(NOW + 2 * DAY), forged);
  assert.equal(res.status, 401);
  assert.equal((await res.json()).code, "token_invalid");
  // A bad signature with an expired stamp says token_invalid, not token_expired.
  assert.deepEqual(checkToken([id, iat, exp, mac.replace(/^./, (c) => (c === "A" ? "B" : "A"))].join("."), SECRET, NOW + 2 * DAY), { code: "token_invalid" });
  // The old two-part format is refused.
  const old = `${id}.${createHmac("sha256", SECRET).update(id).digest("base64url")}`;
  assert.deepEqual(checkToken(old, SECRET, NOW), { code: "token_invalid" });
});

test("revocation: a revoked device is 401 device_revoked with a valid token", async () => {
  const backing = new MemoryBacking();
  const revocations = new RevocationList(backing);
  const token = issueDeviceToken("device-r", ENV, NOW);
  const other = issueDeviceToken("device-ok", ENV, NOW);
  const h = make(NOW, revocations);
  assert.equal((await call(h, token)).status, 200);
  await revokeDevice("device-r", revocations);
  const res = await call(h, token);
  assert.equal(res.status, 401);
  assert.deepEqual(await res.json(), { error: "unauthorized", code: "device_revoked" });
  assert.equal((await call(h, other)).status, 200);
  // Stored through the backing: a new list over the same backing still refuses.
  assert.equal((await call(make(NOW, new RevocationList(backing)), token)).status, 401);
  // A forged token for a revoked device is token_invalid (no revocation oracle).
  assert.equal((await (await call(h, `device-r.1.2.${"A".repeat(43)}`)).json()).code, "token_invalid");
  await assert.rejects(() => revokeDevice("bad.id", revocations), /device id/);
});
