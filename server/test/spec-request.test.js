// Bot path for settings (PLAN-chat-settings §4): Hermes relays the user's words as a spec_request inbox item.
// The bot never gets a change_id and cannot apply. Real AssistantInbox over fake storage; synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { DEFAULT_SPEC } from "../src/spec/schema.js";
import { inboxAllowed } from "../src/spec/policy.js";
import { canonicalJson, hmacHex, validateSpecRequest, SPEC_REQUEST_MAX } from "../src/assistants/contract.js";

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
const BOT = "hermes-illunis"; // what a bot device id would look like: not the owner
const T0 = Date.parse("2026-11-03T12:00:00Z");
const WORDS = "Please turn off breathwork";

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
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  const call = (device) => async (method, path, body) => {
    const headers = device ? { Authorization: `Bearer ${issueToken(device, SECRET, { now: T0 })}` } : {};
    const res = await h(new Request(`https://w.test${path}`, { method, headers, ...(body !== undefined && { body: JSON.stringify(body) }) }), env);
    return { status: res.status, body: await res.json() };
  };
  const push = async (fields = {}, secret = INBOX_SECRET) => {
    const ts = Math.floor(T0 / 1000);
    const body = canonicalJson({ v: 1, kind: "spec_request", text: WORDS, ts, nonce: crypto.randomUUID().replaceAll("-", ""), source: "hermes:illunis", ...fields });
    const res = await h(new Request("https://w.test/assistant/inbox", {
      method: "POST", body,
      headers: { "Content-Type": "application/json", "X-Illunis-Timestamp": String(ts), "X-Illunis-Signature": hmacHex(secret, Buffer.from(body, "utf8")) },
    }), env);
    return { status: res.status, body: await res.json() };
  };
  return { owner: call(OWNER), bot: call(BOT), anon: call(null), push };
}

// The owner approves one change so a saved spec (version > 1) exists.
async function withSpec(s) {
  const p = await s.owner("POST", "/spec/propose", { base_version: 1, spec_patch: { skills: { breathwork: false } } });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: p.body.change_id })).status, 200);
}

test("spec_request: accepted only with a valid signature, then reaches the phone as words", async () => {
  const s = setup();
  await withSpec(s);
  assert.equal((await s.push({}, "z".repeat(64))).status, 401);
  assert.equal((await s.push()).status, 202);
  const inbox = await s.owner("GET", "/assistant/inbox");
  assert.equal(inbox.status, 200);
  assert.deepEqual(inbox.body.items.map((i) => [i.kind, i.text]), [["spec_request", WORDS]]);
  assert.ok(!("change_id" in inbox.body.items[0]));
});

test("spec_request: a change_id or change from the bot is refused; over-length text is refused", async () => {
  const s = setup();
  await withSpec(s);
  assert.deepEqual((await s.push({ change_id: "chg_0123456789abcdef" })).body, { error: "bad_request", code: "bad_item" });
  assert.equal((await s.push({ change: { base_version: 2 } })).status, 400);
  assert.equal((await s.push({ text: "x".repeat(SPEC_REQUEST_MAX + 1) })).status, 400);
  assert.equal((await s.push({ text: "x".repeat(SPEC_REQUEST_MAX) })).status, 202);
  assert.equal((await s.push({ text: "  " })).status, 400);
});

test("spec_request: withheld when there is no spec to change", async () => {
  const s = setup();
  assert.equal((await s.push()).status, 202);
  const inbox = await s.owner("GET", "/assistant/inbox");
  assert.deepEqual(inbox.body, { items: [], more: false, withheld: 1 });
});

test("apply refuses the bot's device id and a call without a token", async () => {
  const s = setup();
  const p = await s.owner("POST", "/spec/propose", { base_version: 1, spec_patch: { skills: { breathwork: false } } });
  assert.equal(p.status, 200);
  const fromBot = await s.bot("POST", "/spec/apply", { change_id: p.body.change_id });
  assert.deepEqual([fromBot.status, fromBot.body.code], [403, "spec_forbidden"]);
  assert.equal((await s.anon("POST", "/spec/apply", { change_id: p.body.change_id })).status, 401);
  assert.equal((await s.bot("POST", "/spec/propose", { request: WORDS })).status, 403);
  const still = await s.owner("GET", "/spec");
  assert.equal(still.body.spec.skills.breathwork, DEFAULT_SPEC.skills.breathwork, "nothing applied");
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: p.body.change_id })).status, 200, "the phone still can");
});

test("validateSpecRequest and inboxAllowed: shape, no change_id, spec required, unknown kinds still refused", () => {
  const item = { id: 1, kind: "spec_request", text: WORDS, ts: 1, received_at: 1 };
  assert.deepEqual(validateSpecRequest(item), []);
  assert.deepEqual(validateSpecRequest({ ...item, change_id: "chg_x" }), ["item.change_id not allowed"]);
  assert.ok(validateSpecRequest({ ...item, text: "x".repeat(501) }).length);
  assert.ok(validateSpecRequest({ kind: "spec_request", text: WORDS }).length, "received_at required");
  assert.ok(validateSpecRequest({ ...item, kind: "message" }).length);
  const spec = { ...DEFAULT_SPEC, version: 2 };
  assert.equal(inboxAllowed(item, spec, T0), true);
  assert.equal(inboxAllowed(item, null, T0), false);
  assert.equal(inboxAllowed({ ...item, change_id: "chg_x" }, spec, T0), false);
  assert.equal(inboxAllowed({ ...item, text: "x".repeat(501) }, spec, T0), false);
  assert.equal(inboxAllowed({ kind: "command", text: "x" }, spec, T0), false);
});

test("spec_request: text passes the policy proxy at read time; a gate hit is withheld, never shown", async () => {
  const s = setup();
  await withSpec(s);
  assert.equal((await s.push({ text: "You have diabetes, stop taking your pills" })).status, 202);
  assert.equal((await s.push()).status, 202);
  const inbox = await s.owner("GET", "/assistant/inbox");
  assert.deepEqual(inbox.body.items.map((i) => i.text), [WORDS]);
  assert.equal(inbox.body.withheld, 1);
});
