// Pairing (src/pairing.js, src/pairing-routes.js): code -> signed bot claim -> one-time credential poll.
// Real AssistantInbox over fake storage; synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { RevocationList, checkToken, issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { PairingState, pairCodeHash, signPairClaim } from "../src/pairing.js";
import { MemoryStorage } from "../src/spec/store.js";
import { hmacHex } from "../src/assistants/contract.js";
import { createHash } from "node:crypto";

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
  return { idFromName: (n) => `id-${n}`, get(id) { if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: storage() }, { DEVICE_TOKEN_SECRET: SECRET })); return objects.get(id); } };
}
function setup(nowRef = { t: T0 }) {
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: namespace(), ILLUNIS_INBOX_SECRET: INBOX_SECRET };
  const fetchFn = async () => assert.fail("no network expected");
  // Fresh revocations per setup: the handler default is a per-isolate singleton and test 1 revokes OWNER.
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), revocations: new RevocationList(), now: () => nowRef.t, logger: { log() {}, warn() {}, error() {} } });
  const call = (device) => async (method, path, body) => {
    const headers = device ? { Authorization: `Bearer ${issueToken(device, SECRET, { now: nowRef.t })}` } : {};
    const res = await h(new Request(`https://w.test${path}`, { method, headers, ...(body !== undefined && { body: JSON.stringify(body) }) }), env);
    return { status: res.status, body: await res.json() };
  };
  const claim = async (claimObj, secret = INBOX_SECRET) => {
    const res = await h(new Request("https://w.test/pair/claim", {
      method: "POST", body: JSON.stringify(claimObj),
      headers: { "Content-Type": "application/json", "X-Illunis-Signature": signPairClaim(secret, claimObj) },
    }), env);
    return { status: res.status, body: await res.json() };
  };
  return { owner: call(OWNER), other: call("other-phone"), anon: call(null), claim, nowRef };
}

test("pairing: full flow hands the credential to the phone once, never to the bot", async () => {
  const s = setup();
  const issued = await s.owner("POST", "/pair/code", {});
  assert.equal(issued.status, 200);
  assert.match(issued.body.code, /^[A-HJ-NP-Z2-9]{8}$/);
  assert.deepEqual(await s.owner("GET", "/pair/status").then((r) => r.body.status), "waiting");

  const ts = Math.floor(T0 / 1000);
  const bad = await s.claim({ bot_id: "hermes:illunis", code: issued.body.code, ts }, "z".repeat(64));
  assert.equal(bad.status, 401);
  const wrong = await s.claim({ bot_id: "hermes:illunis", code: "AAAAAAAA", ts });
  assert.equal(wrong.status, 409);
  const ok = await s.claim({ bot_id: "hermes:illunis", code: issued.body.code, ts });
  assert.equal(ok.status, 202);
  assert.ok(!("credential" in ok.body) && !("code" in ok.body));

  const again = await s.claim({ bot_id: "other:bot", code: issued.body.code, ts });
  assert.equal(again.status, 409, "single use, one bot per Worker");

  const poll = await s.owner("GET", "/pair/status");
  assert.equal(poll.body.status, "paired");
  assert.equal(checkToken(poll.body.credential, SECRET, T0).deviceId, OWNER);
  const second = await s.owner("GET", "/pair/status");
  assert.ok(!("credential" in second.body), "credential released exactly once");

  const moreCodes = await s.owner("POST", "/pair/code", {});
  assert.equal(moreCodes.body.code, "already_paired");
  // Unpairing clears the link only: the phone's token keeps working and a fresh pairing can start.
  assert.equal((await s.owner("POST", "/pair/revoke", {})).status, 200);
  const after = await s.owner("GET", "/pair/status");
  assert.deepEqual([after.status, after.body.status], [200, "unpaired"]);
  assert.equal((await s.owner("GET", "/spec")).status, 200, "owner route still works");
  assert.equal((await s.owner("POST", "/pair/code", {})).status, 200, "a new pairing can start");
});

test("pairing: unauthenticated code request refused; expired code refused", async () => {
  const nowRef = { t: T0 };
  const s = setup(nowRef);
  assert.equal((await s.anon("POST", "/pair/code", {})).status, 401);
  const issued = await s.owner("POST", "/pair/code", {});
  nowRef.t = T0 + 601_000;
  const ts = Math.floor(nowRef.t / 1000);
  const late = await s.claim({ bot_id: "hermes:illunis", code: issued.body.code, ts });
  assert.deepEqual([late.status, late.body.code], [410, "pair_expired"]);
});

test("PairingState: hashed storage, attempt burn, rate limit", async () => {
  const st = new MemoryStorage();
  const p = new PairingState(st, { now: () => T0, codeFn: () => "ABCD2345", secret: SECRET });
  const out = await p.createCode(OWNER);
  const raw = await st.get("pair:record");
  assert.equal(raw.code_hash, pairCodeHash(SECRET, "ABCD2345"));
  assert.ok(!JSON.stringify(raw).includes("ABCD2345"));
  for (let i = 0; i < 5; i++) assert.equal((await p.claim({ code: "ZZZZ9999", bot_id: "b" })).code, "pair_mismatch");
  assert.equal((await p.claim({ code: "ABCD2345", bot_id: "b" })).code, "pair_burned");

  const p2 = new PairingState(new MemoryStorage(), { now: () => T0, codeFn: () => "ABCD2345", secret: SECRET });
  await p2.createCode(OWNER);
  await p2.revoke(OWNER);
  await p2.createCode(OWNER);
  await p2.revoke(OWNER);
  await p2.createCode(OWNER);
  await p2.revoke(OWNER);
  assert.equal((await p2.createCode(OWNER)).code, "rate_limited");
  void out;
});

test("pairing: unpair clears the link only; the phone's token, an owner route and a new pairing still work", async () => {
  const s = setup();
  const issued = await s.owner("POST", "/pair/code", {});
  assert.equal((await s.claim({ bot_id: "hermes:illunis", code: issued.body.code, ts: Math.floor(T0 / 1000) })).status, 202);
  assert.equal((await s.owner("GET", "/pair/status")).body.status, "paired");
  assert.equal((await s.owner("POST", "/pair/revoke", {})).status, 200);
  assert.deepEqual(await s.owner("GET", "/pair/status").then((r) => [r.status, r.body.status]), [200, "unpaired"]);
  assert.equal((await s.owner("GET", "/spec")).status, 200);
  assert.equal((await s.owner("POST", "/pair/code", {})).status, 200);
});

test("pairing: /pair/* refuses a device that is not the owner; the code rate limit is per device", async () => {
  const s = setup();
  for (const [m, p] of [["POST", "/pair/code"], ["GET", "/pair/status"], ["POST", "/pair/revoke"]]) {
    const r = await s.other(m, p, m === "POST" ? {} : undefined);
    assert.deepEqual([r.status, r.body.code], [403, "pair_forbidden"], p);
  }
  const p = new PairingState(new MemoryStorage(), { now: () => T0, secret: SECRET });
  for (let i = 0; i < 3; i++) assert.ok((await p.createCode(OWNER)).pair_code);
  assert.equal((await p.createCode(OWNER)).code, "rate_limited");
  assert.ok((await p.createCode("second-phone")).pair_code, "another device has its own window");
});

test("PairingState: the code is stored as an HMAC under the server secret; no secret, no code", async () => {
  const st = new MemoryStorage();
  await new PairingState(st, { now: () => T0, codeFn: () => "ABCD2345", secret: SECRET }).createCode(OWNER);
  const raw = await st.get("pair:record");
  assert.equal(raw.code_hash, hmacHex(SECRET, "illunis-pair-code-v1\nABCD2345"));
  assert.notEqual(raw.code_hash, createHash("sha256").update("pair\nABCD2345").digest("hex"));
  await assert.rejects(new PairingState(new MemoryStorage(), { now: () => T0 }).createCode(OWNER));
});

test("AssistantInbox: one PairingState serves every pairing call on the object", async () => {
  const seen = new Set();
  const orig = PairingState.prototype.status;
  PairingState.prototype.status = function (...a) { seen.add(this); return orig.apply(this, a); };
  try {
    const inbox = new AssistantInbox({ storage: storage() }, { DEVICE_TOKEN_SECRET: SECRET });
    await inbox.pairStatus(OWNER, T0);
    await inbox.pairStatus(OWNER, T0 + 1);
    assert.equal(seen.size, 1);
  } finally {
    PairingState.prototype.status = orig;
  }
});
