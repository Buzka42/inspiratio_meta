// Focus: the third skill, deliberately not RAG. A deterministic session timer with state and refusals
// that retrieval alone lacks: one live session at a time, no retroactive edits, elapsed time computed
// in code from stored timestamps. No model (see skills/manifest.js). Fixed templates only.
import { skillOn, memoryAllowed } from "../spec/policy.js";

export const SKILL_ID = "focus";
export const MIN_MINUTES = 5;
export const MAX_MINUTES = 180;
const DAY = 86400000;

const fail = (code) => ({ ok: false, code });
const gate = (spec) => (!skillOn(spec, SKILL_ID) ? fail("skill_off") : !memoryAllowed(spec, "server") ? fail("memory_off") : null);
const nowOf = (now) => (now instanceof Date ? now.getTime() : Number(now ?? Date.now()));
const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);

const load = async (store) => ({
  session: (await store.get("focus:session")) ?? { status: "idle", accumulated_ms: 0, started_at: null, planned_min: null },
  log: (await store.get("focus:log")) ?? {},
});
const elapsedMs = (s, ms) => s.accumulated_ms + (s.status === "active" ? Math.max(0, ms - s.started_at) : 0);

export const focusText = (s, ms) => {
  const min = Math.floor(elapsedMs(s, ms) / 60000);
  if (s.status === "idle") return "No focus session running.";
  if (s.status === "paused") return `Focus paused at ${min} minutes.`;
  return `Focusing for ${min} minutes.`;
};

export async function focusStart(store, spec, input = {}, now) {
  const g = gate(spec); if (g) return g;
  if (!Number.isInteger(input.minutes) || input.minutes < MIN_MINUTES || input.minutes > MAX_MINUTES) return fail("bad_minutes");
  const ms = nowOf(now);
  const { session } = await load(store);
  if (session.status !== "idle") return fail("already_active");
  const next = { status: "active", accumulated_ms: 0, started_at: ms, planned_min: input.minutes };
  await store.set("focus:session", next);
  return { ok: true, status: "active", planned_min: input.minutes, text: "Focus started." };
}

export async function focusPause(store, spec, now) {
  const g = gate(spec); if (g) return g;
  const ms = nowOf(now);
  const { session } = await load(store);
  if (session.status !== "active") return fail("not_active");
  const next = { ...session, status: "paused", accumulated_ms: elapsedMs(session, ms), started_at: null };
  await store.set("focus:session", next);
  return { ok: true, status: "paused", text: focusText(next, ms) };
}

export async function focusResume(store, spec, now) {
  const g = gate(spec); if (g) return g;
  const ms = nowOf(now);
  const { session } = await load(store);
  if (session.status !== "paused") return fail("not_paused");
  const next = { ...session, status: "active", started_at: ms };
  await store.set("focus:session", next);
  return { ok: true, status: "active", text: "Focus resumed." };
}

// Completing credits the elapsed minutes to today. There is no op to edit past days: refused by design.
export async function focusComplete(store, spec, now) {
  const g = gate(spec); if (g) return g;
  const ms = nowOf(now);
  const { session, log } = await load(store);
  if (session.status === "idle") return fail("not_active");
  const minutes = Math.floor(elapsedMs(session, ms) / 60000);
  const day = dayOf(ms);
  const nextLog = { ...log, [day]: (log[day] ?? 0) + minutes };
  // Keep at most 90 days of log.
  const kept = Object.fromEntries(Object.entries(nextLog).filter(([d]) => Date.parse(d) >= ms - 90 * DAY));
  await store.set("focus:log", kept);
  await store.set("focus:session", { status: "idle", accumulated_ms: 0, started_at: null, planned_min: null });
  return { ok: true, status: "idle", minutes, today_minutes: kept[day] ?? 0, planned_min: session.planned_min, text: `Focus complete: ${minutes} minutes.` };
}

export async function focusStatus(store, spec, now) {
  const g = gate(spec); if (g) return g;
  const ms = nowOf(now);
  const { session, log } = await load(store);
  return {
    ok: true, status: session.status, planned_min: session.planned_min,
    elapsed_min: Math.floor(elapsedMs(session, ms) / 60000), today_minutes: log[dayOf(ms)] ?? 0,
    text: focusText(session, ms),
  };
}
