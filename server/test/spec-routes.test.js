// Spec routes (src/spec/routes.js): auth, owner-only writes, stale 409, replay 409, expiry 410, guardrail refusal,
// the Hermes mirror state, and the spec reaching /council, /memory/*, /assistant/memory/* and the inbox.
// Real AssistantInbox over fake storage; fake Hermes and brain; per-run secrets; synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { DEFAULT_SPEC } from "../src/spec/schema.js";
import { loadSpec } from "../src/spec/routes.js";
import { signSpec } from "../src/assistants/contract.js";

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
const BOT_PROSE = "Done! trust me, I changed everything";
const HERMES = { HERMES_ACCESS_MODE: "quick_tunnel", HERMES_BASE_URL: "https://x.trycloudflare.com", HERMES_API_KEY: "k", HERMES_SESSION_ID: "s" };
const META = { META_API_KEY: `meta-${crypto.randomUUID()}`, META_MODEL: "synthetic/meta-model-test" };

function storage() {
  const m = new Map();
  return { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
}
function namespace() {
  const objects = new Map();
  return { objects, idFromName: (n) => `id-${n}`, get(id) { if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: storage() }, {})); return objects.get(id); } };
}

// fetchFn routes Hermes and Meta calls to the given answers and records them.
function network({ hermes = () => assert.fail("Hermes not expected"), meta = () => assert.fail("brain not expected") } = {}) {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    if (url.includes("/p/illunis/")) {
      const req = JSON.parse(body.message);
      calls.push({ hermes: req });
      const out = await hermes(req);
      if (out instanceof Response) return out;
      return new Response(JSON.stringify({ message: { role: "assistant", content: JSON.stringify(out) } }), { status: 200 });
    }
    calls.push({ meta: body });
    return new Response(JSON.stringify({ choices: [{ message: { content: meta(body) } }] }), { status: 200 });
  };
  return { fn, calls };
}
const ok = (req, result) => ({ illunis: 1, op: req.op, request_id: req.request_id, ok: true, result });

function setup(net = network(), extraEnv = {}) {
  const clock = { now: T0 };
  const ns = namespace();
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: ns, ILLUNIS_INBOX_SECRET: INBOX_SECRET, QUOTA_COUNCIL_PER_DAY: "1000", ...extraEnv };
  const h = createHandler({ fetchFn: net.fn, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), now: () => clock.now, logger: { log() {}, warn() {}, error() {} } });
  const call = (device) => async (method, path, body, more = {}) => {
    const token = issueToken(device, SECRET, { now: T0 });
    const res = await h(new Request(`https://w.test${path}`, {
      method, headers: { Authorization: `Bearer ${token}` }, ...(body !== undefined && { body: JSON.stringify(body) }),
    }), { ...env, ...more });
    return { status: res.status, body: await res.json() };
  };
  return { clock, ns, env, net, owner: call(OWNER), other: call("someone-else") };
}

const breathOff = { base_version: 1, spec_patch: { skills: { breathwork: false } } };
async function approve(s, change) {
  const p = await s.owner("POST", "/spec/propose", change);
  assert.equal(p.status, 200, JSON.stringify(p.body));
  return s.owner("POST", "/spec/apply", { change_id: p.body.change_id });
}

test("GET /spec: owner and other devices read DEFAULT_SPEC with guardrails; mirror off", async () => {
  const s = setup();
  for (const who of [s.owner, s.other]) {
    const r = await who("GET", "/spec");
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.spec, DEFAULT_SPEC);
    assert.equal(r.body.mirror, "off");
    assert.equal(r.body.guardrails.length, 3);
  }
  assert.equal((await s.owner("POST", "/spec", {})).status, 404);
  assert.equal((await s.owner("GET", "/spec/propose")).status, 404);
});

test("writes are owner only (403); no token is 401", async () => {
  const s = setup();
  for (const [path, body] of [["/spec/propose", breathOff], ["/spec/apply", { change_id: "0".repeat(32) }], ["/knowledge/add", {}], ["/knowledge/remove", {}]]) {
    const r = await s.other("POST", path, body);
    assert.equal(r.status, 403, path);
    assert.equal(r.body.code, "spec_forbidden");
  }
  const h = createHandler({ store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), logger: { warn() {} } });
  assert.equal((await h(new Request("https://w.test/spec"), s.env)).status, 401);
});

test("propose then apply: diff and readback are the Worker's, version rises, mirror off without Hermes", async () => {
  const s = setup();
  const p = await s.owner("POST", "/spec/propose", breathOff);
  assert.equal(p.status, 200);
  assert.match(p.body.change_id, /^[0-9a-f]{32}$/);
  assert.deepEqual(p.body.diff, [{ path: "skills.breathwork", from: true, to: false }]);
  assert.equal(p.body.readback, "Illunis will turn breathwork off.");
  const a = await s.owner("POST", "/spec/apply", { change_id: p.body.change_id });
  assert.equal(a.status, 200);
  assert.equal(a.body.spec.version, 2);
  assert.equal(a.body.spec.skills.breathwork, false);
  assert.equal(a.body.mirror, "off");
  assert.equal((await s.owner("GET", "/spec")).body.spec.version, 2);
  assert.equal((await s.other("GET", "/spec")).body.spec.version, 1, "other devices still read the default");
});

test("stale base_version is 409; replayed change_id 409; expired 410; stale at apply 409", async () => {
  const s = setup();
  const stale = await s.owner("POST", "/spec/propose", { ...breathOff, base_version: 7 });
  assert.deepEqual([stale.status, stale.body.code], [409, "stale_version"]);

  const p1 = await s.owner("POST", "/spec/propose", breathOff);
  const p2 = await s.owner("POST", "/spec/propose", { base_version: 1, spec_patch: { brain: "meta" } });
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: p1.body.change_id })).status, 200);
  const replay = await s.owner("POST", "/spec/apply", { change_id: p1.body.change_id });
  assert.deepEqual([replay.status, replay.body.code], [409, "change_unknown"]);
  const late = await s.owner("POST", "/spec/apply", { change_id: p2.body.change_id });
  assert.deepEqual([late.status, late.body.code], [409, "stale_version"]);

  const p3 = await s.owner("POST", "/spec/propose", { base_version: 2, spec_patch: { brain: "meta" } });
  s.clock.now += 301_000;
  const expired = await s.owner("POST", "/spec/apply", { change_id: p3.body.change_id });
  assert.deepEqual([expired.status, expired.body.code], [410, "change_expired"]);
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: p3.body.change_id })).status, 409, "single use");
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: "x", extra: 1 })).status, 400);
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: "not-hex" })).status, 409);
});

test("guardrail refusal: refused list, no diff, no change_id", async () => {
  const s = setup();
  for (const change of [{ base_version: 1, spec_patch: { disclaimer: false } }, { base_version: 1, guardrails: { crisis: false } }]) {
    const r = await s.owner("POST", "/spec/propose", change);
    assert.equal(r.status, 422);
    assert.ok(r.body.refused.some((x) => x.reason === "guardrail"));
    assert.ok(!("diff" in r.body) && !("change_id" in r.body));
  }
});

test("propose from words via Hermes: Worker diff, no bot text; mirror synced with a valid signature", async () => {
  const net = network({
    hermes: (req) => {
      if (req.op === "spec_propose") return ok(req, { change: { base_version: 1, spec_patch: { skills: { breathwork: false } } } });
      assert.equal(req.op, "spec_apply");
      assert.equal(req.input.sig, signSpec(INBOX_SECRET, req.input.version, req.input.spec_md));
      return ok(req, { version: req.input.version });
    },
  });
  const s = setup(net, HERMES);
  const p = await s.owner("POST", "/spec/propose", { base_version: 1, request: "Stop using breathwork" });
  assert.equal(p.status, 200);
  assert.equal(p.body.via, "hermes");
  assert.equal(p.body.readback, "Illunis will turn breathwork off.");
  const a = await s.owner("POST", "/spec/apply", { change_id: p.body.change_id });
  assert.equal(a.body.mirror, "synced");
  assert.equal((await s.owner("GET", "/spec")).body.mirror, "synced");
  assert.ok(!net.calls.some((c) => c.hermes?.op === "spec_apply" && "change_id" in c.hermes.input), "Hermes never sees the change_id");
});

test("mirror failure never blocks the apply: pending", async () => {
  const net = network({
    hermes: (req) => (req.op === "spec_apply" ? new Response("down", { status: 502 }) : assert.fail()),
  });
  const s = setup(net, HERMES);
  const a = await approve(s, breathOff);
  assert.equal(a.status, 200);
  assert.equal(a.body.spec.version, 2);
  assert.equal(a.body.mirror, "pending");
});

test("bot text never becomes a setting: guidelines and sources from words are app only; bot prose not echoed", async () => {
  const net = network({ hermes: (req) => ok(req, { change: { base_version: 1, spec_patch: { guidelines: BOT_PROSE } } }) });
  const s = setup(net, HERMES);
  const r = await s.owner("POST", "/spec/propose", { request: "be nicer" });
  assert.equal(r.status, 422);
  assert.deepEqual(r.body.refused, [{ path: "spec_patch.guidelines", reason: "app_only" }]);
  assert.ok(!JSON.stringify(r.body).includes("trust me"));
  const stale = await s.owner("POST", "/spec/propose", { base_version: 3, request: "x" });
  assert.equal(stale.status, 409);
  assert.equal((await s.owner("POST", "/spec/propose", { request: "x", spec_patch: {} })).status, 400);
});

test("the applied spec reaches /council: a skill turned off leaves the consult enum and roster", async () => {
  const final = JSON.stringify({ synthesis: "Synthetic.", experts_consulted: [], sources: [], medical: false });
  const net = network({ meta: () => final });
  const s = setup(net, META);
  await s.owner("POST", "/council", { question: "synthetic sleep question" });
  assert.ok(JSON.stringify(net.calls.at(-1).meta).includes("breath_stress"));
  await approve(s, breathOff);
  net.calls.length = 0;
  await s.owner("POST", "/council", { question: "synthetic sleep question" });
  assert.ok(net.calls.length > 0);
  assert.ok(!JSON.stringify(net.calls.map((c) => c.meta)).includes("breath_stress"));
});

test("legacy council is refused once any skill is off", async () => {
  const s = setup();
  await approve(s, breathOff);
  const r = await s.owner("POST", "/council", { question: "q" }, { COUNCIL_PROVIDER: "opencode", OPENCODE_API_KEY: "k" });
  assert.deepEqual([r.status, r.body.code], [403, "legacy_council_skills"]);
});

test("memory mode: off refuses /memory/*, phone refuses Hermes memory, hermes caps expires_at by retention", async () => {
  const net = network({ hermes: (req) => ok(req, req.op === "memory_write" ? { id: "a".repeat(32) } : { items: [] }) });
  const s = setup(net, HERMES);
  assert.equal((await s.owner("POST", "/memory/write", { text: "synthetic", kind: "note" })).status !== 403, true);
  const phone = await s.owner("POST", "/spec/propose", { base_version: 1, spec_patch: { memory: { mode: "off" } } });
  await s.owner("POST", "/spec/apply", { change_id: phone.body.change_id });
  for (const path of ["/memory/write", "/memory/recall", "/assistant/memory/write", "/assistant/memory/recall"]) {
    const r = await s.owner("POST", path, { query: "x", text: "synthetic", kind: "note" });
    assert.deepEqual([r.status, r.body.code], [403, "memory_mode"], path);
  }
  await approve(s, { base_version: 2, spec_patch: { memory: { mode: "hermes", retention_days: 10 } } });
  assert.equal((await s.owner("POST", "/memory/recall", { query: "x" })).status, 403, "server store is the phone's");
  const w = await s.owner("POST", "/assistant/memory/write", { kind: "note", text: "synthetic note", expires_at: "2027-12-01T00:00:00Z" });
  assert.equal(w.status, 200);
  const sent = net.calls.find((c) => c.hermes?.op === "memory_write").hermes.input;
  assert.equal(sent.expires_at, new Date(T0 + 10 * 86_400_000).toISOString());
});

test("inbox: items the spec turns off are dropped and counted", async () => {
  const s = setup();
  await approve(s, { base_version: 1, spec_patch: { notifications: { types: { bot_reply: false } } } });
  const box = s.ns.get(s.ns.idFromName(OWNER));
  const nowS = Math.floor(T0 / 1000);
  await box.push({ kind: "bot_reply", text: "synthetic reply", ts: nowS, nonce: "a".repeat(32) }, nowS);
  await box.push({ kind: "reminder", text: "synthetic reminder", ts: nowS, nonce: "b".repeat(32) }, nowS);
  const r = await s.owner("GET", "/assistant/inbox");
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.items.map((i) => i.kind), ["reminder"]);
  assert.equal(r.body.withheld, 1);
});

test("loadSpec: null without a store or before the first apply, DEFAULT_SPEC for others and on a failed read", async () => {
  const s = setup();
  assert.equal(await loadSpec({}, OWNER), null);
  assert.equal(await loadSpec(s.env, OWNER), null);
  assert.deepEqual(await loadSpec(s.env, "someone-else"), DEFAULT_SPEC);
  const broken = { ...s.env, ASSISTANT_DO: { idFromName: () => "x", get: () => ({ specGet: async () => { throw new Error("down"); } }) } };
  assert.deepEqual(await loadSpec(broken, OWNER), DEFAULT_SPEC);
  await approve(s, breathOff);
  assert.equal((await loadSpec(s.env, OWNER)).version, 2);
});
