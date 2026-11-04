// Habits: deterministic, no model. Every user-facing string is a fixed template; names never leave this module.
import { randomUUID } from "node:crypto";
import { skillOn, memoryAllowed, inboxAllowed } from "../spec/policy.js";

const MAX_HABITS = 30;
const MAX_DATES = 400;
const DAY = 86400000;
const REFUSED_NAME = /https?:\/\/|www\.|\S+@\S+\.\S+|\b(diet|sleep|medication|dose|calorie)/i;
const TZ_RE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;

const fail = (code) => ({ ok: false, code });
const gate = (spec) => (!skillOn(spec, "habits") ? fail("skill_off") : !memoryAllowed(spec, "server") ? fail("memory_off") : null);
const nowOf = (now) => (now instanceof Date ? now.getTime() : Number(now ?? Date.now()));

// Minutes east of UTC for tz (IANA string or fixed minutes) at ms; null when invalid.
export function tzOffset(tz, ms) {
  if (Number.isInteger(tz)) return Math.abs(tz) <= 840 ? tz : null;
  if (typeof tz !== "string" || tz.length > 64 || !TZ_RE.test(tz)) return null;
  try {
    const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric" })
      .formatToParts(new Date(ms)).map((x) => [x.type, Number(x.value)]));
    return Math.round((Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Math.floor(ms / 60000) * 60000) / 60000);
  } catch { return null; }
}

const localMs = (tz, ms) => ms + (tzOffset(tz, ms) ?? 0) * 60000;
const dayIso = (ms) => new Date(ms).toISOString().slice(0, 10);
const addDays = (iso, n) => dayIso(Date.parse(`${iso}T00:00:00Z`) + n * DAY);
const weekend = (iso) => [0, 6].includes(new Date(`${iso}T00:00:00Z`).getUTCDay());
const today = (tz, ms) => dayIso(localMs(tz, ms));

function prevRequired(cadence, iso) {
  let d = addDays(iso, -1);
  while (cadence === "weekdays" && weekend(d)) d = addDays(d, -1);
  return d;
}

// Computed on read, never stored.
export function streak(cadence, dates, todayIso) {
  const set = new Set(dates);
  let cur = set.has(todayIso) ? todayIso : prevRequired(cadence, todayIso);
  let n = 0;
  while (set.has(cur)) { n++; cur = prevRequired(cadence, cur); }
  return n;
}

export function weekCount(dates, todayIso) {
  const dow = (new Date(`${todayIso}T00:00:00Z`).getUTCDay() + 6) % 7;
  const start = addDays(todayIso, -dow);
  return dates.filter((d) => d >= start && d <= todayIso).length;
}

export const reminderText = (name) => `Time for: ${name}.`;

const load = async (store) => ({ list: (await store.get("habits:list")) ?? [], checks: (await store.get("habits:checkins")) ?? {} });

async function mutate(store, spec, id, fn) {
  const g = gate(spec); if (g) return g;
  const { list } = await load(store);
  const h = list.find((x) => x.id === id);
  if (!h) return fail("not_found");
  const next = fn(h, list);
  await store.set("habits:list", next);
  return { ok: true };
}

export async function habitAdd(store, spec, input = {}, now) {
  const g = gate(spec); if (g) return g;
  const name = typeof input.name === "string" ? input.name.trim() : "";
  if (name.length < 1 || name.length > 60) return fail("bad_name");
  if (REFUSED_NAME.test(name)) return fail("name_refused");
  if (!["daily", "weekdays"].includes(input.cadence)) return fail("bad_cadence");
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(input.reminder_time ?? "")) return fail("bad_time");
  if (tzOffset(input.timezone, nowOf(now)) === null) return fail("bad_timezone");
  const { list } = await load(store);
  if (list.length >= MAX_HABITS) return fail("too_many");
  const habit = { id: randomUUID().slice(0, 8), name, cadence: input.cadence, reminder_time: input.reminder_time, timezone: input.timezone, status: "active" };
  await store.set("habits:list", [...list, habit]);
  return { ok: true, habit };
}

export async function habitList(store, spec, now) {
  const g = gate(spec); if (g) return g;
  const ms = nowOf(now);
  const { list, checks } = await load(store);
  const habits = list.map((h) => {
    const dates = checks[h.id] ?? [];
    const t = today(h.timezone, ms);
    return { ...h, streak: streak(h.cadence, dates, t), week: weekCount(dates, t) };
  });
  return { ok: true, habits };
}

export const habitPause = (store, spec, id) => mutate(store, spec, id, (h, l) => l.map((x) => (x === h ? { ...x, status: "paused" } : x)));
export const habitResume = (store, spec, id) => mutate(store, spec, id, (h, l) => l.map((x) => (x === h ? { ...x, status: "active" } : x)));

export async function habitDelete(store, spec, id) {
  const r = await mutate(store, spec, id, (h, l) => l.filter((x) => x !== h));
  if (!r.ok) return r;
  const { checks } = await load(store);
  delete checks[id];
  await store.set("habits:checkins", checks);
  return r;
}

export async function checkIn(store, spec, id, date, now) {
  const g = gate(spec); if (g) return g;
  const { list, checks } = await load(store);
  const h = list.find((x) => x.id === id);
  if (!h) return fail("not_found");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date ?? "") || Number.isNaN(Date.parse(date))) return fail("bad_date");
  const t = today(h.timezone, nowOf(now));
  if (date !== t && date !== addDays(t, -1)) return fail("date_out_of_range");
  const dates = checks[id] ?? [];
  if (dates.includes(date)) return { ok: true, recorded: false };
  checks[id] = [...dates, date].sort().slice(-MAX_DATES);
  await store.set("habits:checkins", checks);
  return { ok: true, recorded: true };
}

// Active habits whose reminder time fell in the last DUE_WINDOW_MIN minutes (their own timezone), each reported once
// per local day: habits:due holds { [id]: the local date it was last reported }.
export const DUE_WINDOW_MIN = 30;
const hm = (t) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
export async function reminderDue(store, spec, now) {
  const g = gate(spec); if (g) return g;
  if (spec?.proactivity?.mode === "never") return { ok: true, due: [] };
  const ms = nowOf(now);
  const { list } = await load(store);
  const seen = (await store.get("habits:due")) ?? {};
  const due = [];
  for (const h of list) {
    if (h.status !== "active") continue;
    const off = tzOffset(h.timezone, ms) ?? 0;
    const local = ms + off * 60000;
    const ago = (Math.floor(local / 60000) % 1440 - hm(h.reminder_time) + 1440) % 1440;
    const day = dayIso(local - ago * 60000);
    if (ago >= DUE_WINDOW_MIN || seen[h.id] === day || !inboxAllowed({ kind: "reminder" }, spec, ms, off)) continue;
    seen[h.id] = day;
    due.push({ id: h.id, text: reminderText(h.name) });
  }
  if (due.length) await store.set("habits:due", Object.fromEntries(Object.entries(seen).filter(([id]) => list.some((h) => h.id === id))));
  return { ok: true, due };
}
