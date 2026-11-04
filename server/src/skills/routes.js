// Skill routes (plan S1), all POST: the reading companion (/reading/*) and the habit builder (/habits/*).
// The device token is checked by index.js. Records live in the owner's AssistantInbox under its SKILL_KEYS;
// writes are owner-only, as spec writes. A null spec (no store, or none applied yet) is env-only: skills allowed.
// The phone pulls /habits/due when it opens, so nothing is pushed. Responses carry fixed codes only.
import { assistantStub } from "../assistants/store.js";
import { callBrain } from "../council/provider.js";
import { retrieve } from "../knowledge/retrieve.js";
import { skillOn } from "../spec/policy.js";
import { isOwner, specConfigured } from "../spec/routes.js";
import { answer, noteAdd, noteDelete, noteList, readingStore, resumeGet, resumeSet } from "./reading.js";
import { checkIn, habitAdd, habitDelete, habitList, habitPause, habitResume, reminderDue } from "./habits.js";
import { focusComplete, focusPause, focusResume, focusStart, focusStatus } from "./focus.js";
import { SKILL_MANIFESTS, enforceManifest, validateManifests } from "./manifest.js";

const READING = ["ask", "note/add", "note/list", "note/delete", "resume/get", "resume/set"].map((p) => `/reading/${p}`);
const HABITS = ["add", "list", "pause", "resume", "delete", "checkin", "due"].map((p) => `/habits/${p}`);
const FOCUS = ["start", "pause", "resume", "complete", "status"].map((p) => `/focus/${p}`);
export const SKILL_PATHS = Object.freeze([...READING, ...HABITS, ...FOCUS]);
export const MANIFEST_ROUTE = "GET /skills/manifests";
const READS = new Set(["/reading/note/list", "/reading/resume/get", "/habits/list", "/habits/due", "/focus/status"]);

// Fixed code -> HTTP status; any other module code is a 422 refusal.
const STATUS = {
  skill_off: 403, memory_off: 403, hosted_ask: 403, skills_forbidden: 403, not_found: 404, notes_full: 409, too_many: 409,
  retrieve_failed: 502, brain_failed: 502, store_failed: 503, not_configured: 503,
};
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const coded = (code) => json({ error: code, code }, STATUS[code] ?? 422);

// One DO store for both modules: reading uses put, habits uses set.
function ownerStore(env) {
  const s = assistantStub(env.ASSISTANT_DO, env.ASSISTANT_OWNER_DEVICE_ID);
  const put = (k, v) => s.skillPut(k, v);
  return { stub: s, store: { get: (k) => s.skillGet(k), put, set: put } };
}

async function reading(path, body, { env, spec, nowMs, fetchFn, stub, store }) {
  const deps = { spec, env, store: readingStore(store, spec, { now: () => nowMs }) };
  if (path === "/reading/ask") {
    if (typeof body.question !== "string") return { code: "bad_question" };
    const sources = (await stub.sources()).filter((x) => x.bank === "reading").map((x) => x.id);
    return answer(body.question, {
      ...deps, sources,
      brain: (m, e, o) => callBrain(m, e, { ...o, fetchFn }),
      retrieve: (b, q, e, o) => retrieve(b, q, e, { ...o, fetchFn }),
    });
  }
  if (path === "/reading/note/add") return noteAdd(body, deps);
  if (path === "/reading/note/list") return noteList(deps);
  if (path === "/reading/note/delete") return noteDelete(body.id, deps);
  if (path === "/reading/resume/get") return resumeGet(deps);
  return resumeSet(body, deps);
}

function habits(path, body, { spec, nowMs, store }) {
  if (path === "/habits/add") return habitAdd(store, spec, body, nowMs);
  if (path === "/habits/list") return habitList(store, spec, nowMs);
  if (path === "/habits/pause") return habitPause(store, spec, body.id);
  if (path === "/habits/resume") return habitResume(store, spec, body.id);
  if (path === "/habits/delete") return habitDelete(store, spec, body.id);
  if (path === "/habits/checkin") return checkIn(store, spec, body.id, body.date, nowMs);
  return reminderDue(store, spec, nowMs);
}

function focus(path, body, { spec, nowMs, store }) {
  if (path === "/focus/start") return focusStart(store, spec, body, nowMs);
  if (path === "/focus/pause") return focusPause(store, spec, nowMs);
  if (path === "/focus/resume") return focusResume(store, spec, nowMs);
  if (path === "/focus/complete") return focusComplete(store, spec, nowMs);
  return focusStatus(store, spec, nowMs);
}

// The permission sheet: every skill's declared capabilities (skills/manifest.js). Device-token route.
export function handleManifests() {
  if (validateManifests().length) return json({ error: "manifest_invalid", code: "manifest_invalid" }, 503);
  return json({ manifests: SKILL_MANIFESTS });
}

// The manifest action a skill path needs (skills/manifest.js enforceManifest).
export const skillAction = (path) => (READS.has(path) ? "run" : path === "/reading/ask" ? "model" : "memory_write");

// ctx: { spec (loadSpec result), now (ms), fetchFn, logger }. body: the parsed JSON object.
export async function handleSkills(path, body, env, deviceId, { spec, now, fetchFn = fetch, logger } = {}) {
  if (!specConfigured(env)) return json({ error: "not_configured", detail: "ASSISTANT_DO binding and ASSISTANT_OWNER_DEVICE_ID required" }, 503);
  const owner = isOwner(env, deviceId);
  if (!READS.has(path) && !owner) return coded("skills_forbidden");
  if (!skillOn(spec, path.split("/")[1])) return coded("skill_off");
  if (!owner) return coded("skills_forbidden");
  // Manifest enforcement: a model call must be declared; writes must be declared; reads are a plain run.
  const verdict = enforceManifest(path.split("/")[1], skillAction(path));
  if (!verdict.allowed) return coded(verdict.code);
  try {
    const ctx = { env, spec, nowMs: now, fetchFn, ...ownerStore(env) };
    const run = path.startsWith("/reading/") ? reading(path, body, ctx) : path.startsWith("/focus/") ? focus(path, body, ctx) : habits(path, body, ctx);
    const { ok, code, ...out } = await run;
    if (code) return coded(code);
    return json(out);
  } catch {
    logger?.error?.("route_error", path, deviceId, "skills_unavailable");
    return json({ error: "skills_unavailable", code: "skills_unavailable" }, 503);
  }
}
