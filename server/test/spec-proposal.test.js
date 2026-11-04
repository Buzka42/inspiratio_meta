// Bot-initiated spec proposals: a signed spec_proposal inbox item becomes the same pending diff the
// app path produces. The phone still approves via POST /spec/apply. Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { RevocationList, issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { canonicalJson, hmacHex } from "../src/assistants/contract.js";
import { inboxAllowed } from "../src/spec/policy.js";
import { DEFAULT_SPEC } from "../src/spec/schema.js";
import { botTextRefusals } from "../src/spec/routes.js";
import { MAX_BOT_PENDING, MemoryStorage, SpecState } from "../src/spec/store.js";

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
  const call = (device) => async (method, path, body) => {
    const headers = device ? { Authorization: `Bearer ${issueToken(device, SECRET, { now: T0 })}` } : {};
    const res = await h(new Request(`https://w.test${path}`, { method, headers, ...(body !== undefined && { body: JSON.stringify(body) }) }), env);
    return { status: res.status, body: await res.json() };
  };
  const push = async (kind, text, secret = INBOX_SECRET) => {
    const ts = Math.floor(T0 / 1000);
    const body = canonicalJson({ v: 1, kind, text, ts, nonce: crypto.randomUUID().replaceAll("-", ""), source: "hermes:illunis" });
    const res = await h(new Request("https://w.test/assistant/inbox", {
      method: "POST", body,
      headers: { "Content-Type": "application/json", "X-Illunis-Timestamp": String(ts), "X-Illunis-Signature": hmacHex(secret, Buffer.from(body, "utf8")) },
    }), env);
    return { status: res.status, body: await res.json() };
  };
  return { owner: call(OWNER), push };
}
async function withSpec(s) {
  const p = await s.owner("POST", "/spec/propose", { base_version: 1, spec_patch: { skills: { breathwork: false } } });
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal((await s.owner("POST", "/spec/apply", { change_id: p.body.change_id })).status, 200);
}

test("spec_proposal: bot change arrives as a pending diff; only the phone can apply it", async () => {
  const s = setup();
  await withSpec(s); // spec now version 2
  const change = JSON.stringify({ base_version: 2, spec_patch: { skills: { sleep: false } } });
  assert.equal((await s.push("spec_proposal", change, "z".repeat(64))).status, 401);
  assert.equal((await s.push("spec_proposal", change)).status, 202);

  const inbox = await s.owner("GET", "/assistant/inbox");
  assert.equal(inbox.body.items.length, 1);
  const item = inbox.body.items[0];
  assert.equal(item.kind, "spec_proposal");
  assert.match(item.proposal.change_id, /^[0-9a-f]{32}$/);
  assert.deepEqual(item.proposal.diff, [{ path: "skills.sleep", from: true, to: false }]);
  assert.equal(item.text, item.proposal.readback);
  assert.ok(!item.text.includes("spec_patch"), "bot JSON never shown");

  const applied = await s.owner("POST", "/spec/apply", { change_id: item.proposal.change_id });
  assert.equal(applied.status, 200);
  assert.equal(applied.body.spec.skills.sleep, false);
});

test("spec_proposal: guardrail keys, guidelines and stale versions are refused, nothing stored", async () => {
  const s = setup();
  await withSpec(s);
  const attempts = [
    JSON.stringify({ base_version: 2, spec_patch: { guardrails: { crisis: "off" } } }),
    JSON.stringify({ base_version: 2, spec_patch: { guidelines: "bot words" } }),
    JSON.stringify({ base_version: 1, spec_patch: { skills: { sleep: false } } }),
    "not json",
  ];
  for (const text of attempts) assert.equal((await s.push("spec_proposal", text)).status, 422, text);
  const inbox = await s.owner("GET", "/assistant/inbox");
  assert.deepEqual(inbox.body.items, []);
});

test("spec_proposal: withheld without a saved spec or after the pending change expires", () => {
  const item = { kind: "spec_proposal", text: "x", proposal: { change_id: "a".repeat(32), diff: [], readback: "r", expires_at: T0 + 1000 } };
  assert.equal(inboxAllowed(item, { ...DEFAULT_SPEC, version: 2 }, T0), true);
  assert.equal(inboxAllowed(item, null, T0), false);
  assert.equal(inboxAllowed(item, { ...DEFAULT_SPEC, version: 2 }, T0 + 2000), false);
  assert.equal(inboxAllowed({ ...item, proposal: { ...item.proposal, change_id: "nope" } }, { ...DEFAULT_SPEC, version: 2 }, T0), false);
});

test("spec_proposal: every botTextRefusals case is refused on the bot push path", async () => {
  const s = setup();
  await withSpec(s);
  const cases = [{ spec_patch: { guidelines: "bot words" } }, { knowledge_add: { bank: "sleep", title: "t", text: "x" } }];
  for (const c of cases) {
    assert.ok(botTextRefusals(c).length, "helper refuses it");
    const res = await s.push("spec_proposal", JSON.stringify({ base_version: 2, ...c }));
    assert.deepEqual([res.status, res.body.code], [422, "refused"]);
  }
});

test("spec_proposal: bot proposals have their own cap and never evict the owner's pending change", async () => {
  const s = setup();
  await withSpec(s);
  const mine = await s.owner("POST", "/spec/propose", { base_version: 2, spec_patch: { skills: { sleep: false } } });
  assert.equal(mine.status, 200);
  for (let i = 0; i < 10; i++) {
    const change = JSON.stringify({ base_version: 2, spec_patch: { skills: { reading: false } } });
    assert.equal((await s.push("spec_proposal", change)).status, 202);
  }
  const applied = await s.owner("POST", "/spec/apply", { change_id: mine.body.change_id });
  assert.equal(applied.status, 200, JSON.stringify(applied.body));
  const st = new SpecState(new MemoryStorage(), { now: () => T0 });
  for (let i = 0; i < 5; i++) await st.propose({ base_version: 1, spec_patch: { skills: { sleep: false } } }, { via: "bot" });
  const pending = Object.values(await st.storage.get("spec:pending"));
  assert.equal(pending.filter((p) => p.bot).length, MAX_BOT_PENDING);
});
