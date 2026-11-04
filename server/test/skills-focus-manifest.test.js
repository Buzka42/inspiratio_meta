// Focus skill + skill manifests + red-team panel. Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { createHandler } from "../src/index.js";
import { RevocationList, issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { SKILL_MANIFESTS, enforceManifest, manifestFor, manifestLine, validateManifests } from "../src/skills/manifest.js";
import { focusComplete, focusPause, focusResume, focusStart, focusStatus } from "../src/skills/focus.js";
import { REDTEAM_CASES, runRedTeam } from "../src/redteam/panel.js";
import { DEFAULT_SPEC } from "../src/spec/schema.js";
import { skillAction } from "../src/skills/routes.js";

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
const store = () => {
  const m = new Map();
  return { get: async (k) => structuredClone(m.get(k)), set: async (k, v) => void m.set(k, structuredClone(v)), put: async (k, v) => void m.set(k, structuredClone(v)) };
};
const spec = (over = {}) => {
  const s = { ...structuredClone(DEFAULT_SPEC), ...over };
  s.skills = { ...s.skills, focus: true, ...(over.skills ?? {}) }; // focus is registered, enabled per spec
  return s;
};

test("manifests: every skill declares, habits and focus may not call a model", () => {
  assert.deepEqual(validateManifests(), []);
  assert.equal(manifestFor("habits").model, false);
  assert.equal(manifestFor("focus").model, false);
  assert.equal(manifestFor("reading").model, true);
  assert.deepEqual(manifestFor("training").banks, ["training"]);
  assert.deepEqual(manifestFor("medical").banks.length, 9);
  assert.equal(enforceManifest("habits", "model").allowed, false);
  assert.equal(enforceManifest("habits", "model").code, "capability_refused");
  assert.equal(enforceManifest("reading", "model").allowed, true);
  assert.equal(enforceManifest("nope", "run").code, "unknown_skill");
  assert.match(manifestLine("reading"), /uses a model/);
  assert.match(manifestLine("habits"), /no model/);
  assert.equal(SKILL_MANIFESTS.focus.memory_write, true);
});

test("focus: a stateful session with refusals retrieval alone lacks", async () => {
  const s = store();
  const t0 = T0;
  assert.equal((await focusStart(s, spec(), { minutes: 3 }, t0)).code, "bad_minutes");
  assert.equal((await focusStart(s, spec(), { minutes: 25 }, t0)).ok, true);
  assert.equal((await focusStart(s, spec(), { minutes: 25 }, t0)).code, "already_active");
  assert.equal((await focusResume(s, spec(), t0)).code, "not_paused");
  const paused = await focusPause(s, spec(), t0 + 10 * 60000);
  assert.equal(paused.status, "paused");
  assert.match(paused.text, /10 minutes/);
  assert.equal((await focusPause(s, spec(), t0)).code, "not_active");
  await focusResume(s, spec(), t0 + 20 * 60000);
  const done = await focusComplete(s, spec(), t0 + 35 * 60000);
  assert.deepEqual([done.minutes, done.today_minutes, done.planned_min], [25, 25, 25]);
  assert.equal((await focusComplete(s, spec(), t0)).code, "not_active");
  const st = await focusStatus(s, spec(), t0 + 40 * 60000);
  assert.deepEqual([st.status, st.today_minutes], ["idle", 25]);

  const off = spec();
  off.skills.focus = false;
  assert.equal((await focusStart(s, off, { minutes: 25 }, t0)).code, "skill_off");
});

test("redteam: every fixed case is refused with its expected code", async () => {
  const out = await runRedTeam();
  assert.equal(out.failed, 0, JSON.stringify(out.results, null, 2));
  assert.equal(out.passed, REDTEAM_CASES.length);
});

test("routes: focus runs in the DO, manifests show, red-team is owner-only", async () => {
  function storage() {
    const m = new Map();
    return { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), delete: async (k) => m.delete(k) };
  }
  function namespace() {
    const objects = new Map();
    return { idFromName: (n) => `id-${n}`, get(id) { if (!objects.has(id)) objects.set(id, new AssistantInbox({ storage: storage() }, {})); return objects.get(id); } };
  }
  const env = { DEVICE_TOKEN_SECRET: SECRET, ASSISTANT_OWNER_DEVICE_ID: OWNER, ASSISTANT_DO: namespace(), ILLUNIS_INBOX_SECRET: INBOX_SECRET };
  const h = createHandler({ fetchFn: async () => assert.fail("no network expected"), store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), revocations: new RevocationList(), now: () => T0, logger: { log() {}, warn() {}, error() {} } });
  const call = (device) => async (method, path, body) => {
    const headers = device ? { Authorization: `Bearer ${issueToken(device, SECRET, { now: T0 })}` } : {};
    const res = await h(new Request(`https://w.test${path}`, { method, headers, ...(body !== undefined && { body: JSON.stringify(body) }) }), env);
    return { status: res.status, body: await res.json() };
  };
  const owner = call(OWNER);
  const other = call("other-phone");
  assert.equal((await owner("POST", "/focus/start", { minutes: 25 })).status, 200);
  assert.equal((await owner("POST", "/focus/start", { minutes: 25 })).body.code, "already_active");
  assert.equal((await owner("POST", "/focus/status", {})).body.status, "active");
  const manifests = await owner("GET", "/skills/manifests");
  assert.equal(manifests.body.manifests.focus.model, false);
  const panel = await owner("POST", "/redteam/run");
  assert.equal(panel.body.failed, 0);
  assert.equal((await other("POST", "/redteam/run")).status, 403);
});

test("manifests: skill read routes are a plain run; writes and the model call are checked as declared", () => {
  for (const p of ["/reading/note/list", "/reading/resume/get", "/habits/list", "/habits/due", "/focus/status"]) assert.equal(skillAction(p), "run", p);
  assert.equal(skillAction("/habits/add"), "memory_write");
  assert.equal(skillAction("/reading/ask"), "model");
  assert.deepEqual(enforceManifest("habits", skillAction("/habits/list")), { allowed: true });
});
