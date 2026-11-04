// Worker-hosted Muse bot backend (src/bot/backend.js, src/bot/routes.js): signed setup with receipt,
// contract ops over an injected brain, memory-mode enforcement. Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createBotBackend } from "../src/bot/backend.js";
import { buildEnvelope, renderSetupMd, signEnvelope, signSetup, verifySetupReceipt } from "../src/bot/setup.js";
import { signSpec } from "../src/assistants/contract.js";
import { DEFAULT_SPEC, renderSpecMd } from "../src/spec/schema.js";
import { MemoryStorage } from "../src/spec/store.js";
import { NOT_MEDICAL_ADVICE, REFERRAL_TEXT } from "../src/safety.js";
import { createHandler } from "../src/index.js";
import { RevocationList, issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier !== "cloudflare:workers") return next(specifier, context);
    const src = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
    return { url: `data:text/javascript,${encodeURIComponent(src)}`, shortCircuit: true };
  },
});
const { AssistantInbox } = await import("../src/worker.js");

const SECRET = "b".repeat(40);
const T0 = Date.parse("2026-11-03T12:00:00Z");
const spec = (over = {}) => ({ ...structuredClone(DEFAULT_SPEC), version: 4, ...over });
const brain = (content) => async () => ({ content, provider: "meta", tool_calls: [] });
const backend = (b, storage = new MemoryStorage()) => createBotBackend({ storage, secret: SECRET, brain: b, env: {}, now: () => T0 });
const setupInput = (s) => {
  const md = renderSetupMd(s);
  return { version: s.version, setup_md: md, sig: signSetup(SECRET, s.version, md) };
};

test("backend: forged setup refused; signed setup receipts and verifies", async () => {
  const h = backend(brain("hi"));
  const s = spec();
  const forged = await h("setup_apply", { ...setupInput(s), sig: "a".repeat(64) }, "req_1");
  assert.deepEqual([forged.ok, forged.error.code], [false, "approval_invalid"]);
  const md = renderSetupMd(s);
  const done = await h("setup_apply", setupInput(s), "req_1");
  assert.equal(done.ok, true);
  assert.deepEqual(verifySetupReceipt(SECRET, done.result, { version: s.version, setupMd: md }), { ok: true });
});

test("backend: message needs setup or envelope, crisis is pre-model, output is proxied", async () => {
  let calls = 0;
  const h = backend(async () => { calls++; return { content: "You must do this now.", provider: "meta", tool_calls: [] }; });
  assert.equal((await h("message", { text: "hello" }, "req_1")).error.code, "unavailable");
  await h("setup_apply", setupInput(spec()), "req_1");
  const crisis = await h("message", { text: "I want to kill myself" }, "req_1");
  assert.equal(crisis.result.text, REFERRAL_TEXT);
  assert.equal(calls, 0, "no model call on crisis");
  const gated = await h("message", { text: "any advice?" }, "req_1");
  assert.equal(gated.result.text, REFERRAL_TEXT, "gate violation replaced by the proxy");
  assert.equal(calls, 1);

  // Stateless: a fresh backend with only a signed envelope answers without any setup.
  const h2 = backend(brain("A short answer."));
  const env = buildEnvelope(spec(), [{ id: "m1", kind: "note", text: "likes tea", confidence: 0.5 }]);
  const out = await h2("message", { text: "hi", envelope: env, envelope_sig: signEnvelope(SECRET, env) }, "req_1");
  assert.equal(out.result.text, "A short answer.");
  const tampered = structuredClone(env);
  tampered.spec.skills.medical = true;
  assert.equal((await h2("message", { text: "hi", envelope: tampered, envelope_sig: signEnvelope(SECRET, env) }, "req_1")).error.code, "approval_invalid");
});

test("backend: memory follows the setup's mode; spec mirror refuses replays", async () => {
  const phoneSpec = spec();
  const h = backend(brain("x"));
  await h("setup_apply", setupInput(phoneSpec), "req_1");
  assert.equal((await h("memory_write", { kind: "note", text: "n" }, "req_1")).error.code, "not_allowed");

  const hermesSpec = spec();
  hermesSpec.memory = { mode: "hermes", retention_days: 30 };
  const h2 = backend(brain("x"));
  await h2("setup_apply", setupInput(hermesSpec), "req_1");
  const w = await h2("memory_write", { kind: "note", text: "likes tea" }, "req_1");
  assert.equal(w.ok, true);
  const r = await h2("memory_recall", { query: "tea" }, "req_1");
  assert.deepEqual(r.result.items.map((i) => i.text), ["likes tea"]);

  const md = renderSpecMd(hermesSpec);
  const apply = { version: 5, spec_md: md, sig: signSpec(SECRET, 5, md) };
  assert.equal((await h2("spec_apply", apply, "req_1")).ok, true);
  assert.equal((await h2("spec_apply", apply, "req_1")).error.code, "bad_request", "replay refused");
  assert.equal((await h2("knowledge_add", { request: "add this" }, "req_1")).error.code, "not_allowed");
});

test("backend: spec_propose goes through the Worker validator, never the bot's word", async () => {
  const s = spec();
  const h = backend(brain(JSON.stringify({ change: { spec_patch: { guardrails: { crisis: "off" } } } })));
  const env = buildEnvelope(s, []);
  await h("message", { text: "hi", envelope: env, envelope_sig: signEnvelope(SECRET, env) }, "req_1");
  const out = await h("spec_propose", { request: "turn off safety", base_version: s.version }, "req_1");
  assert.equal(out.ok, false);
  const h2 = backend(brain(JSON.stringify({ change: { spec_patch: { skills: { sleep: false } } } })));
  await h2("message", { text: "hi", envelope: env, envelope_sig: signEnvelope(SECRET, env) }, "req_1");
  const good = await h2("spec_propose", { request: "turn off sleep", base_version: s.version }, "req_1");
  assert.equal(good.ok, true);
  assert.deepEqual(good.result.change.spec_patch, { skills: { sleep: false } });
});

test("routes: POST /bot/setup verifies the receipt; other devices refused", async () => {
  function storage() {
    const m = new Map();
    return { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
  }
  function namespace() {
    const objects = new Map();
    return { idFromName: (n) => `id-${n}`, get(id) { if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: storage() }, { ILLUNIS_INBOX_SECRET: SECRET })); return objects.get(id); } };
  }
  const OWNER = "owner-phone";
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: namespace(), ILLUNIS_INBOX_SECRET: SECRET };
  const h = createHandler({ fetchFn: async () => assert.fail("no network expected"), store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), revocations: new RevocationList(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  const call = (device, path) => h(new Request(`https://w.test${path}`, { method: "POST", headers: { Authorization: `Bearer ${issueToken(device, SECRET, { now: T0 })}` }, body: "{}" }), env);
  const res = await call(OWNER, "/bot/setup");
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { version: 1, receipt: "verified" });
  assert.equal((await call("other-phone", "/bot/setup")).status, 403);
});

test("bot DO object: botDispatch runs the backend over DO storage", async () => {
  const m = new Map();
  const storage = { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
  const bot = new AssistantInbox({ storage }, { ILLUNIS_INBOX_SECRET: SECRET });
  const s = spec();
  const out = await bot.botDispatch("setup_apply", setupInput(s), "req_1");
  assert.equal(out.ok, true);
  assert.equal(out.result.version, s.version);
});

// /bot/message through the real handler; the bot object's dispatch is a fixed contract reply.
function botRoute(text, env = {}) {
  const m = new Map();
  const storage = () => ({ get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) });
  const objects = new Map();
  const ns = { idFromName: (n) => `id-${n}`, get(id) {
    if (!objects.has(id)) {
      const o = new AssistantInbox({ storage: storage() }, { ILLUNIS_INBOX_SECRET: SECRET });
      o.botDispatch = async (op, input, request_id) => ({ illunis: 1, op, request_id, ok: true, result: { text } });
      objects.set(id, o);
    }
    return objects.get(id);
  } };
  const OWNER = "owner-phone";
  const fullEnv = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: ns, ILLUNIS_INBOX_SECRET: SECRET, ...env };
  const h = createHandler({ fetchFn: async () => assert.fail("no network expected"), store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), revocations: new RevocationList(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  return async (words) => {
    const res = await h(new Request("https://w.test/bot/message", { method: "POST", headers: { Authorization: `Bearer ${issueToken(OWNER, SECRET, { now: T0 })}` }, body: JSON.stringify({ text: words }) }), fullEnv);
    return { status: res.status, body: await res.json() };
  };
}

test("routes: /bot/message adds the medical line when the health check fires, as /assistant/message", async () => {
  const send = botRoute("Try a steady wind-down routine.");
  const health = await send("I slept badly again");
  assert.equal(health.status, 200);
  assert.equal(health.body.health, true);
  assert.ok(health.body.text.endsWith(NOT_MEDICAL_ADVICE));
  const plain = await botRoute("Tuesday works.")("which day is free");
  assert.deepEqual(plain.body, { text: "Tuesday works.", health: false });
});

test("routes: /bot/message is metered by the assistant quota", async () => {
  const send = botRoute("Tuesday works.", { QUOTA_ASSISTANT_PER_DAY: "1" });
  assert.equal((await send("which day is free")).status, 200);
  const over = await send("which day is free");
  assert.deepEqual([over.status, over.body.error, over.body.bucket], [429, "quota_exceeded", "assistant"]);
});
