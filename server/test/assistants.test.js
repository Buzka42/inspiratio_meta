// Hermes bridge (src/assistants/): contract validation, Hermes client, inbox HMAC, approvals, inbox polling.
// Fake Hermes (fetchFn) and fake Durable Object storage only; per-run secrets; synthetic data only.
// Pinned hex vectors were computed with the Python reference (integrations/hermes/plugins/illunis_memory/signing.py).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { REFERRAL_TEXT } from "../src/safety.js";
import {
  actionHash, canonicalJson, hmacHex, parseReply, signApproval, validateReply, validateRequest,
} from "../src/assistants/contract.js";
import { callHermes, hermesBase, hermesConfigProblem } from "../src/assistants/hermes.js";
import { AssistantState, PENDING_MAX } from "../src/assistants/store.js";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier !== "cloudflare:workers") return next(specifier, context);
    const src = "export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }";
    return { url: `data:text/javascript,${encodeURIComponent(src)}`, shortCircuit: true };
  },
});
const { AssistantInbox } = await import("../src/worker.js");

const DEVICE_SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const INBOX_SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`.replaceAll("-", "");
const API_KEY = `hermes-test-${crypto.randomUUID()}`;
const ACCESS_SECRET = `access-test-${crypto.randomUUID()}`;
const OWNER = "owner-phone";
const T0 = Date.parse("2026-10-25T12:00:00Z");
const quiet = { warn() {}, error() {}, log() {} };
const noNet = () => { throw new Error("network touched"); };

function fakeStorage() {
  const data = new Map();
  const tick = () => new Promise((r) => setTimeout(r, Math.random() * 2));
  return {
    data,
    async get(k) { await tick(); return structuredClone(data.get(k)); },
    async put(k, v) { await tick(); data.set(k, structuredClone(v)); },
    async delete(k) { await tick(); return data.delete(k); },
  };
}
// One real AssistantInbox (the Durable Object class) per name.
function fakeNamespace() {
  const objects = new Map();
  return {
    objects,
    idFromName: (name) => `id-${name}`,
    get(id) {
      if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: fakeStorage() }, {}));
      return objects.get(id);
    },
  };
}

const baseEnv = (ns = fakeNamespace()) => ({
  DEVICE_TOKEN_SECRET: DEVICE_SECRET,
  HERMES_BASE_URL: "https://hermes.example.test",
  HERMES_API_KEY: API_KEY,
  HERMES_SESSION_ID: "sess_bot_chat_1",
  CF_ACCESS_CLIENT_ID: "access-id.test",
  CF_ACCESS_CLIENT_SECRET: ACCESS_SECRET,
  ILLUNIS_INBOX_SECRET: INBOX_SECRET,
  ASSISTANT_OWNER_DEVICE_ID: OWNER,
  ASSISTANT_DO: ns,
});

// Fake Hermes: answer(request) returns the reply object (or a string/Response). Records calls.
function fakeHermes(answer) {
  const calls = [];
  const fn = async (url, init) => {
    const outer = JSON.parse(init.body);
    const request = JSON.parse(outer.message);
    calls.push({ url, init, outer, request });
    const out = await answer(request, calls.length - 1);
    if (out instanceof Response) return out;
    const content = typeof out === "string" ? out : JSON.stringify(out);
    return new Response(JSON.stringify({ object: "hermes.session.chat.completion", message: { role: "assistant", content } }), { status: 200 });
  };
  return { fn, calls };
}
const ok = (req, result) => ({ illunis: 1, op: req.op, request_id: req.request_id, ok: true, result });
const fail = (req, code) => ({ illunis: 1, op: req.op, request_id: req.request_id, ok: false, error: { code, message: `bot says ${API_KEY}` } });

function setup(fetchFn = noNet, { device = OWNER, quotaStore = new InMemoryQuotaStore(), logger = quiet } = {}) {
  const clock = { now: T0 };
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore, now: () => clock.now, logger });
  const token = issueToken(device, DEVICE_SECRET, { now: T0 });
  const call = (method, path, body, env) =>
    h(new Request(`https://w.test${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}` },
      ...(body !== undefined ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {}),
    }), env);
  return {
    clock,
    post: (path, body, env) => call("POST", path, body, env),
    get: (path, env) => call("GET", path, undefined, env),
    raw: (req, env) => h(req, env),
  };
}

function signedPush({ kind = "message", text = "Synthetic reminder", ts = Math.floor(T0 / 1000), nonce = crypto.randomUUID().replaceAll("-", ""), secret = INBOX_SECRET, headerTs, mutate } = {}) {
  let body = canonicalJson({ v: 1, kind, text, ts, nonce, source: "hermes:illunis" });
  const sig = hmacHex(secret, Buffer.from(body, "utf8"));
  if (mutate) body = mutate(body);
  return new Request("https://w.test/assistant/inbox", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Illunis-Timestamp": String(headerTs ?? ts), "X-Illunis-Signature": sig },
    body,
  });
}

// ---- contract ----

test("contract: CONTRACT.md known vector, same bytes and HMAC as the Python reference", () => {
  const body = canonicalJson({ v: 1, text: "hi", ts: 1700000000, source: "hermes:illunis", nonce: "0".repeat(32), kind: "message" });
  assert.equal(body, '{"kind":"message","nonce":"00000000000000000000000000000000","source":"hermes:illunis","text":"hi","ts":1700000000,"v":1}');
  assert.equal(hmacHex("k".repeat(32), Buffer.from(body, "utf8")), "52436349a6ed253a6c161edd8042ee2f2e1b64893e41484892f6efa07689f4d0");
});

test("contract: approval hash and signature match signing.py, UTF-8 kept, floats refused", () => {
  const action = { type: "message_bot", target: "researcher", text: "Ask about the Thursday plan" };
  assert.equal(actionHash(action), "5f32dfd52dce327d3984cf5f1044bb0609a8dbaa25cc48caac3b374c49d64029");
  assert.equal(signApproval("a".repeat(64), "act_abcdef12", action, 1790000060), "f8ce78d974fe06b2ba5916b5eb8300bdb43baa9f9e80ce490e4574766e0f5886");
  // Key order does not matter; non-ASCII and quotes are kept as Python's ensure_ascii=False does.
  assert.equal(actionHash({ text: 'zażółć "q"', target: "peer/agent", type: "message_bot" }), "70fccdc5f8e0b44f7ebd4acabec8e4d4c1b5deacfca73c53e1fa67fe57b979aa");
  assert.throws(() => canonicalJson({ a: 1.5 }), /floats/);
});

test("contract: requests reject unknown keys and bad shapes at every level", () => {
  const good = { illunis: 1, op: "message", request_id: "req_12345678", input: { text: "hello" } };
  assert.deepEqual(validateRequest(good), []);
  assert.ok(validateRequest({ ...good, extra: 1 }).length);
  assert.ok(validateRequest({ ...good, input: { text: "hi", system_message: "x" } }).length);
  assert.ok(validateRequest({ ...good, request_id: "short" }).length);
  assert.ok(validateRequest({ ...good, op: "shell" }).length);
  assert.ok(validateRequest({ ...good, op: "memory_recall", input: { query: "", limit: 51 } }).length);
  const exec = { illunis: 1, op: "action_execute", request_id: "req_12345678",
    input: { action: { type: "message_bot", target: "Researcher", text: "x" }, approval: { action_id: "act_12345678", expires_at: 1, sig: "0".repeat(64) } } };
  assert.ok(validateRequest(exec).some((p) => p.includes("target")));
});

test("contract: replies are one strict JSON object matching op and request_id", () => {
  const expect = { op: "message", requestId: "req_12345678" };
  const reply = { illunis: 1, op: "message", request_id: "req_12345678", ok: true, result: { text: "Hello." } };
  assert.ok(parseReply(`  ${JSON.stringify(reply)}\n`, expect).reply);
  assert.equal(parseReply("```json\n" + JSON.stringify(reply) + "\n```", expect).reply, null);
  assert.equal(parseReply(`Sure! ${JSON.stringify(reply)}`, expect).reply, null);
  assert.ok(validateReply({ ...reply, request_id: "req_other000" }, expect).length);
  assert.ok(validateReply({ ...reply, op: "memory_write" }, expect).length);
  assert.ok(validateReply({ ...reply, result: { text: "x", extra: 1 } }, expect).length);
  assert.ok(validateReply({ ...reply, ok: false, error: { code: "sudo", message: "" } }, expect).length);
  assert.ok(validateReply({ ...reply, error: { code: "internal", message: "" } }, expect).length);
  assert.deepEqual(validateReply({ illunis: 1, op: "message", request_id: "req_12345678", ok: false, error: { code: "unavailable", message: "later" } }, expect), []);
  const item = { id: "a".repeat(32), kind: "note", text: "Likes tea", confidence: 0.8, created_at: "2026-10-25T10:00:00Z", expires_at: null };
  assert.deepEqual(validateReply({ illunis: 1, op: "memory_recall", request_id: "req_12345678", ok: true, result: { items: [item] } }), []);
  assert.ok(validateReply({ illunis: 1, op: "memory_recall", request_id: "req_12345678", ok: true, result: { items: [{ ...item, kind: "secret" }] } }).length);
});

// ---- Hermes client ----

test("hermes: URL, headers, body {message} only, no system_message, idempotency key", async () => {
  const { fn, calls } = fakeHermes((req) => ok(req, { text: "Synthetic hello." }));
  const out = await callHermes("message", { text: "hi" }, baseEnv(), { fetchFn: fn, idempotencyKey: "idem_12345678" });
  assert.deepEqual(out, { text: "Synthetic hello." });
  const { url, init, outer, request } = calls[0];
  assert.equal(url, "https://hermes.example.test/p/illunis/api/sessions/sess_bot_chat_1/chat");
  assert.equal(init.headers.Authorization, `Bearer ${API_KEY}`);
  assert.equal(init.headers["CF-Access-Client-Id"], "access-id.test");
  assert.equal(init.headers["CF-Access-Client-Secret"], ACCESS_SECRET);
  assert.equal(init.headers["Idempotency-Key"], "idem_12345678");
  assert.equal(init.redirect, "manual");
  assert.ok(init.signal);
  assert.deepEqual(Object.keys(outer), ["message"]);
  assert.deepEqual(validateRequest(request), []);
});

test("hermes: config is https host only and names variables, never values", () => {
  assert.equal(hermesBase("https://hermes.example.test/"), "https://hermes.example.test");
  for (const bad of ["http://hermes.example.test", "https://u:p@h.test", "https://h.test:8443", "https://h.test/p/illunis", "https://h.test?x=1", "nope"]) {
    assert.equal(hermesBase(bad), null, bad);
  }
  const p = hermesConfigProblem({ ...baseEnv(), HERMES_API_KEY: "", CF_ACCESS_CLIENT_SECRET: undefined });
  assert.match(p, /HERMES_API_KEY, CF_ACCESS_CLIENT_SECRET missing/);
  assert.ok(!p.includes(API_KEY) && !p.includes(ACCESS_SECRET));
  assert.match(hermesConfigProblem({ ...baseEnv(), HERMES_BASE_URL: "http://h.test" }), /HERMES_BASE_URL/);
  assert.match(hermesConfigProblem({ ...baseEnv(), DATA_MODE: "public" }), /DATA_MODE unknown/);
  assert.equal(hermesConfigProblem({ ...baseEnv(), DATA_MODE: "owner_real" }), null, "owner's own host is allowed under owner_real");
});

test("hermes: failures map to fixed codes", async () => {
  const env = baseEnv();
  const code = async (fetchFn) => callHermes("message", { text: "hi" }, env, { fetchFn }).then(() => "none", (e) => e.code);
  assert.equal(await code(async () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); }), "hermes_timeout");
  assert.equal(await code(async () => { throw new TypeError("dns"); }), "hermes_network");
  assert.equal(await code(async () => new Response("login", { status: 403 })), "hermes_access");
  assert.equal(await code(async () => new Response("", { status: 302, headers: { Location: "https://x.cloudflareaccess.com" } })), "hermes_access");
  assert.equal(await code(async () => new Response("x", { status: 503 })), "hermes_status_5xx");
  assert.equal(await code(async () => new Response("not json", { status: 200 })), "hermes_bad_json");
  assert.equal(await code(fakeHermes(() => "I did it!").fn), "hermes_contract");
  assert.equal(await code(fakeHermes((r) => ({ ...ok(r, { text: "x" }), request_id: "req_wrong000" })).fn), "hermes_contract");
  assert.equal(await code(fakeHermes((r) => fail(r, "not_allowed")).fn), "hermes_refused");
  const timed = await callHermes("message", { text: "hi" }, env, { fetchFn: async (u, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason))), timeoutMs: 20 }).catch((e) => e.code);
  assert.equal(timed, "hermes_timeout");
});

// ---- device routes ----

test("/assistant/message: gated reply, crisis short-circuit, owner only, upstream errors carry no text", async () => {
  const lines = [];
  const capture = (...a) => lines.push(a.join(" "));
  const { fn, calls } = fakeHermes((req) => (req.input.text === "refuse" ? fail(req, "not_allowed") : req.input.text === "bad"
    ? `{"oops": "${API_KEY}"}` : ok(req, { text: req.input.text === "diag" ? "You must rest, I diagnose stress." : "Synthetic answer." })));
  const s = setup(fn, { logger: { warn: capture, error: capture, log: capture } });
  const env = baseEnv();
  const good = await (await s.post("/assistant/message", { text: "hello", context: "synthetic summary" }, env)).json();
  assert.deepEqual(good, { text: "Synthetic answer.", safety: "passed", health: false });
  assert.deepEqual(calls[0].request.input, { text: "hello", context: "synthetic summary" });
  const gated = await (await s.post("/assistant/message", { text: "diag" }, env)).json();
  assert.equal(gated.text, REFERRAL_TEXT);
  assert.equal(gated.safety, "replaced");
  const crisis = await (await s.post("/assistant/message", { text: "I want to die" }, env)).json();
  assert.equal(crisis.text, REFERRAL_TEXT);
  assert.equal(calls.length, 2, "crisis never reaches Hermes");
  const refused = await s.post("/assistant/message", { text: "refuse" }, env);
  assert.equal(refused.status, 422);
  assert.deepEqual(await refused.json(), { error: "assistant_refused", code: "not_allowed" });
  const broken = await s.post("/assistant/message", { text: "bad" }, env);
  assert.equal(broken.status, 502);
  assert.deepEqual(await broken.json(), { error: "assistant_unavailable", code: "hermes_contract" });
  assert.equal((await s.post("/assistant/message", { text: "" }, env)).status, 400);
  assert.equal((await s.post("/assistant/message", { text: "x".repeat(4001) }, env)).status, 400);
  const all = lines.join("\n");
  assert.ok(!all.includes(API_KEY) && !all.includes("hello") && !all.includes("synthetic summary"), "logs carry codes only");

  const other = setup(fn, { device: "someone-else" });
  const res = await other.post("/assistant/message", { text: "hello" }, env);
  assert.equal(res.status, 403);
  assert.deepEqual(await res.json(), { error: "assistant_not_linked" });
  const anon = await s.raw(new Request("https://w.test/assistant/message", { method: "POST", body: "{}" }), env);
  assert.equal(anon.status, 401);
});

test("/assistant/memory/write and /recall pass validated input and return validated results", async () => {
  const item = { id: "b".repeat(32), kind: "note", text: "Prefers evening walks", confidence: 0.7, created_at: "2026-10-25T10:00:00Z", expires_at: null, source: "illunis" };
  const { fn, calls } = fakeHermes((req) => (req.op === "memory_write" ? ok(req, { id: "c".repeat(32) }) : ok(req, { items: [item] })));
  const s = setup(fn);
  const env = baseEnv();
  const w = await s.post("/assistant/memory/write", { kind: "hypothesis", text: "Sleeps better after walks", confidence: 0.4, source: "phone" }, env);
  assert.deepEqual(await w.json(), { id: "c".repeat(32) });
  assert.deepEqual(calls[0].request.input, { kind: "hypothesis", text: "Sleeps better after walks", confidence: 0.4 });
  assert.equal((await s.post("/assistant/memory/write", { kind: "secret", text: "x" }, env)).status, 400);
  const r = await s.post("/assistant/memory/recall", { query: "walks", limit: 5 }, env);
  assert.deepEqual(await r.json(), { items: [item] });
  assert.deepEqual(calls[1].request.input, { query: "walks", limit: 5 });
  assert.equal((await s.post("/assistant/memory/recall", { limit: 0 }, env)).status, 400);
});

// ---- approvals ----

const ACTION = { type: "message_bot", target: "researcher", text: "Synthetic: ask about Thursday" };

function actionHermes({ action = ACTION, status = "queued" } = {}) {
  return fakeHermes((req) => (req.op === "action_propose"
    ? ok(req, { action, readback: "I will just say hi." })
    : ok(req, { action_id: req.input.approval.action_id, status, detail: "Delivery queued." })));
}

test("action: propose stores the action and reads back the action itself; confirm signs and executes once", async () => {
  const { fn, calls } = actionHermes();
  const s = setup(fn);
  const env = baseEnv();
  const p = await (await s.post("/assistant/action/propose", { request: "Ask my researcher bot about Thursday" }, env)).json();
  assert.match(p.action_id, /^act_[0-9a-f]{32}$/);
  assert.equal(p.readback, `I will message researcher: ${ACTION.text}`, "never the bot's own readback");
  assert.equal(p.expires_in, 60);
  assert.deepEqual(calls[0].request.input, { request: "Ask my researcher bot about Thursday" });

  s.clock.now += 59_000;
  const c = await s.post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env);
  assert.equal(c.status, 200);
  assert.deepEqual(await c.json(), { action_id: p.action_id, status: "queued", detail: "Delivery queued." });
  const exec = calls[1].request;
  assert.equal(exec.op, "action_execute");
  assert.deepEqual(exec.input.action, ACTION);
  const nowS = Math.floor(s.clock.now / 1000);
  assert.equal(exec.input.approval.expires_at, nowS + 120);
  assert.equal(exec.input.approval.sig, signApproval(INBOX_SECRET, p.action_id, ACTION, nowS + 120));
  assert.equal(exec.input.approval.sig, createHmac("sha256", INBOX_SECRET)
    .update(`illunis-approval-v1\n${p.action_id}\n${actionHash(ACTION)}\n${nowS + 120}`).digest("hex"));
  assert.match(calls[1].init.headers["Idempotency-Key"], /^exec_[0-9a-f]{32}$/);

  const again = await s.post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env);
  assert.equal(again.status, 404, "single use");
  assert.equal(calls.length, 2);
});

test("action: confirm after 60 s is expired, and an expired id cannot be retried", async () => {
  const { fn, calls } = actionHermes();
  const s = setup(fn);
  const env = baseEnv();
  const p = await (await s.post("/assistant/action/propose", { request: "Message researcher" }, env)).json();
  s.clock.now += 60_000;
  const late = await s.post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env);
  assert.equal(late.status, 410);
  assert.equal((await s.post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env)).status, 404);
  assert.equal(calls.length, 1, "no action_execute sent");
});

test("action: confirm needs exactly {action_id, confirm_phrase_heard: true}; other devices cannot claim", async () => {
  const { fn, calls } = actionHermes();
  const ns = fakeNamespace();
  const env = baseEnv(ns);
  const s = setup(fn);
  const p = await (await s.post("/assistant/action/propose", { request: "Message researcher" }, env)).json();
  for (const body of [{ action_id: p.action_id }, { action_id: p.action_id, confirm_phrase_heard: "yes" },
    { action_id: p.action_id, confirm_phrase_heard: true, action: ACTION }, { action_id: "act_nope", confirm_phrase_heard: true }]) {
    assert.equal((await s.post("/assistant/action/confirm", body, env)).status, 400, JSON.stringify(Object.keys(body)));
  }
  assert.equal((await s.post("/assistant/action/confirm", { action_id: `act_${"0".repeat(32)}`, confirm_phrase_heard: true }, env)).status, 404);
  assert.equal((await setup(fn, { device: "someone-else" }).post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env)).status, 403);
  // Still pending for the owner after the rejected attempts.
  assert.equal((await s.post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env)).status, 200);
  assert.equal(calls.length, 2);
});

test("action: crisis request and a readback failing the gate are refused before anything is stored", async () => {
  const ns = fakeNamespace();
  const env = baseEnv(ns);
  const crisis = await setup(noNet).post("/assistant/action/propose", { request: "tell them I want to die" }, env);
  assert.equal(crisis.status, 422);
  assert.equal((await crisis.json()).text, REFERRAL_TEXT);
  const { fn } = actionHermes({ action: { ...ACTION, text: "You must take this prescription" } });
  const gated = await setup(fn).post("/assistant/action/propose", { request: "Message researcher" }, env);
  assert.equal(gated.status, 422);
  assert.deepEqual(await gated.json(), { error: "action_refused", code: "gate" });
  assert.equal(ns.objects.size, 0, "nothing stored");
  const { fn: badShape } = fakeHermes((req) => ok(req, { action: { ...ACTION, type: "shell" }, readback: "ok" }));
  assert.equal((await setup(badShape).post("/assistant/action/propose", { request: "x" }, env)).status, 502);
});

test("action: an execute reply for another action id is a contract failure", async () => {
  const { fn } = fakeHermes((req) => (req.op === "action_propose" ? ok(req, { action: ACTION, readback: "r" }) : ok(req, { action_id: "act_other_123", status: "done" })));
  const s = setup(fn);
  const env = baseEnv();
  const p = await (await s.post("/assistant/action/propose", { request: "Message researcher" }, env)).json();
  const c = await s.post("/assistant/action/confirm", { action_id: p.action_id, confirm_phrase_heard: true }, env);
  assert.equal(c.status, 502);
});

test("store: pending actions are capped and single use under concurrent claims", async () => {
  const st = new AssistantState(fakeStorage());
  const ids = Array.from({ length: PENDING_MAX + 3 }, (_, i) => `act_${String(i).padStart(32, "0")}`);
  for (const id of ids) await st.propose(id, ACTION, actionHash(ACTION), 1000);
  assert.equal((await st.claim(ids[0], 1001)).code, "action_unknown", "oldest dropped");
  const last = ids.at(-1);
  const results = await Promise.all([st.claim(last, 1001), st.claim(last, 1001), st.claim(last, 1001)]);
  assert.equal(results.filter((r) => r.action).length, 1);
});

// ---- inbox push ----

test("inbox push: valid signature accepted (202), stored for the owner device", async () => {
  const ns = fakeNamespace();
  const env = baseEnv(ns);
  const s = setup();
  const res = await s.raw(signedPush({ text: "Synthetic: stretch at six" }), env);
  assert.equal(res.status, 202);
  assert.deepEqual(await res.json(), { accepted: true, id: 1 });
  assert.deepEqual([...ns.objects.keys()], [`id-${OWNER}`]);
});

test("inbox push: bad signature, tampered body, wrong secret, header/body ts mismatch, skew, bad items", async () => {
  const env = baseEnv();
  const s = setup();
  const ts = Math.floor(T0 / 1000);
  const status = async (req) => (await s.raw(req, env)).status;
  assert.equal(await status(signedPush({ secret: "z".repeat(64) })), 401);
  assert.equal(await status(signedPush({ mutate: (b) => b.replace('"message"', '"reminder"') })), 401);
  const noSig = signedPush();
  noSig.headers.delete("X-Illunis-Signature");
  assert.equal(await status(noSig), 401);
  assert.equal(await status(signedPush({ headerTs: ts + 1 })), 400);
  assert.equal(await status(signedPush({ ts: ts - 301 })), 400);
  assert.equal(await status(signedPush({ ts: ts + 301 })), 400);
  assert.equal(await status(signedPush({ ts: ts - 300 })), 202);
  assert.equal(await status(signedPush({ ts: ts + 300 })), 202);
  assert.equal(await status(signedPush({ kind: "command" })), 400);
  assert.equal(await status(signedPush({ text: "" })), 400);
  assert.equal(await status(signedPush({ text: "x".repeat(2001) })), 400);
  assert.equal(await status(signedPush({ nonce: "short" })), 400);
  const big = signedPush({ text: "x".repeat(2000) });
  assert.equal(await status(new Request(big.url, { method: "POST", headers: big.headers, body: "x".repeat(8 * 1024 + 1) })), 413);
  const skewed = await s.raw(signedPush({ ts: ts - 301, text: "Synthetic secret words" }), env);
  const body = await skewed.text();
  assert.ok(!body.includes("Synthetic secret words"), "error bodies never echo the text");
  assert.deepEqual(JSON.parse(body), { error: "bad_request", code: "timestamp_skew" });
});

test("inbox push: a nonce is refused for 600 s, beyond the skew window", async () => {
  const env = baseEnv();
  const s = setup();
  const nonce = "a".repeat(32);
  const ts = Math.floor(T0 / 1000);
  assert.equal((await s.raw(signedPush({ nonce }), env)).status, 202);
  assert.equal((await s.raw(signedPush({ nonce }), env)).status, 409, "exact replay");
  s.clock.now += 290_000;
  assert.equal((await s.raw(signedPush({ nonce, ts: ts + 290 }), env)).status, 409, "re-signed with a fresh ts, same nonce");
  s.clock.now = T0 + 601_000;
  assert.equal((await s.raw(signedPush({ nonce, ts: ts + 601 }), env)).status, 202, "nonce forgotten after 600 s");
});

test("inbox push: missing config answers 503 naming variables only; other methods are 404", async () => {
  const s = setup();
  const env = baseEnv();
  for (const [k, re] of [["ILLUNIS_INBOX_SECRET", /ILLUNIS_INBOX_SECRET/], ["ASSISTANT_OWNER_DEVICE_ID", /ASSISTANT_OWNER_DEVICE_ID missing/], ["ASSISTANT_DO", /ASSISTANT_DO binding missing/]]) {
    const res = await s.raw(signedPush(), { ...env, [k]: undefined });
    assert.equal(res.status, 503, k);
    const text = await res.text();
    assert.match(text, re);
    assert.ok(!text.includes(INBOX_SECRET) && !text.includes(OWNER), "names only");
  }
  assert.equal((await s.raw(signedPush(), { ...env, ILLUNIS_INBOX_SECRET: "short" })).status, 503);
  assert.equal((await s.raw(new Request("https://w.test/assistant/inbox", { method: "PUT" }), env)).status, 401);
});

// ---- inbox poll ----

test("inbox poll: items come back in order, are acked by the read, and are gated", async () => {
  const env = baseEnv();
  const s = setup();
  const texts = ["Synthetic one", "Synthetic two", "You must stop, I diagnose you", "Synthetic four"];
  for (const [i, text] of texts.entries()) assert.equal((await s.raw(signedPush({ text, kind: i === 1 ? "bot_reply" : "message" }), env)).status, 202);
  const first = await (await s.get("/assistant/inbox?limit=3", env)).json();
  assert.deepEqual(first.items.map((i) => i.id), [1, 2, 3]);
  assert.deepEqual(first.items.map((i) => i.text), ["Synthetic one", "Synthetic two", REFERRAL_TEXT]);
  assert.equal(first.items[1].kind, "bot_reply");
  assert.equal(first.more, true);
  const second = await (await s.get("/assistant/inbox", env)).json();
  assert.deepEqual(second, { items: [{ id: 4, kind: "message", text: "Synthetic four", ts: Math.floor(T0 / 1000) }], more: false });
  assert.deepEqual(await (await s.get("/assistant/inbox", env)).json(), { items: [], more: false });
  assert.equal((await setup(noNet, { device: "someone-else" }).get("/assistant/inbox", env)).status, 403);
});

// ---- config, quotas, deploy wiring ----

test("assistant routes: missing config answers 503 naming variables, never values, with no network", async () => {
  const s = setup(noNet);
  const env = baseEnv();
  const cases = [
    ["/assistant/message", { text: "hi" }, { HERMES_API_KEY: undefined, CF_ACCESS_CLIENT_ID: "" }, /HERMES_API_KEY, CF_ACCESS_CLIENT_ID missing/],
    ["/assistant/memory/recall", {}, { HERMES_SESSION_ID: undefined }, /HERMES_SESSION_ID missing/],
    ["/assistant/action/propose", { request: "x" }, { ILLUNIS_INBOX_SECRET: undefined }, /ILLUNIS_INBOX_SECRET/],
    ["/assistant/action/propose", { request: "x" }, { ASSISTANT_DO: undefined }, /ASSISTANT_DO binding missing/],
    ["/assistant/action/confirm", { action_id: `act_${"0".repeat(32)}`, confirm_phrase_heard: true }, { HERMES_BASE_URL: "http://plain.test" }, /HERMES_BASE_URL/],
    ["/assistant/message", { text: "hi" }, { ASSISTANT_OWNER_DEVICE_ID: undefined }, /ASSISTANT_OWNER_DEVICE_ID missing/],
  ];
  for (const [path, body, patch, re] of cases) {
    const res = await s.post(path, body, { ...env, ...patch });
    assert.equal(res.status, 503, path);
    const text = await res.text();
    assert.match(JSON.parse(text).detail, re);
    for (const v of [API_KEY, ACCESS_SECRET, INBOX_SECRET]) assert.ok(!text.includes(v));
  }
  assert.equal((await s.get("/assistant/inbox", { ...env, ASSISTANT_DO: undefined })).status, 503);
});

test("assistant routes: shared daily quota bucket, 429 before Hermes is called", async () => {
  const { fn, calls } = fakeHermes((req) => ok(req, { text: "Synthetic." }));
  const s = setup(fn);
  const env = { ...baseEnv(), QUOTA_ASSISTANT_PER_DAY: "2" };
  assert.equal((await s.post("/assistant/message", { text: "a" }, env)).status, 200);
  assert.equal((await s.post("/assistant/memory/recall", {}, env)).status, 502); // counts, reply shape is wrong
  const over = await s.post("/assistant/message", { text: "c" }, env);
  assert.equal(over.status, 429);
  assert.equal((await over.json()).bucket, "assistant");
  assert.equal(calls.length, 2);
  const polls = { ...baseEnv(), QUOTA_INBOX_POLLS_PER_DAY: "1" };
  assert.equal((await s.get("/assistant/inbox", polls)).status, 200);
  assert.equal((await s.get("/assistant/inbox", polls)).status, 429);
});

test("deploy wiring: worker exports AssistantInbox, wrangler binds ASSISTANT_DO with migration v2", () => {
  assert.equal(typeof AssistantInbox, "function");
  const cfg = JSON.parse(readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8").replace(/^\s*\/\/.*$/gm, ""));
  assert.ok(cfg.durable_objects.bindings.some((b) => b.name === "ASSISTANT_DO" && b.class_name === "AssistantInbox"));
  assert.deepEqual(cfg.migrations.map((m) => m.tag), ["v1", "v2"]);
  assert.deepEqual(cfg.migrations[1].new_sqlite_classes, ["AssistantInbox"]);
  assert.ok(!cfg.vars, "no owner-specific vars committed");
});
