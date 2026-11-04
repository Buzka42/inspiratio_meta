#!/usr/bin/env node
// SYNTHETIC DATA GENERATOR. Everything it writes is invented: three fictional personas with 30 days of
// check-ins, wearable signals, session summaries and memory notes, from a seeded PRNG (no dependencies).
// Output is for demos and tests only and never describes a real person. Every file carries
// `synthetic: true` and a notice, and memory notes use source "synthetic".
//
// Per persona, the JSON holds:
//   checkins[]         {at, mood, energy, sleep}            1-5, some days missing
//   wearable[]         {date, sleep_minutes, steps, resting_hr}  30 days, some nights missing
//   analysis_21d_body  POST /analysis/21d body: {checkins, start, tz, signals} for the last 21 days
//                      (signals = 21 snapshots {date, resting_hr, hrv_rmssd, sleep_hours, flags}, see
//                      server/analysis/analyze.mjs)
//   sessions[]         {id, at, summary, synthetic}
//   memory_notes[]     the phone's MemoryNote.toJson shape {text, kind, source, confidence, expires_at}
//
// Usage: node gen_history.mjs [--seed 2026] [--end YYYY-MM-DD] [--out ./out] [--stdout]
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const NOTICE = "SYNTHETIC DATA: invented for demos and tests. It describes no real person.";
export const DAYS = 30;
export const WINDOW = 21;
export const TZ = "UTC";
export const SOURCE = "synthetic";

// mulberry32: small, fast, seeded.
export function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Gaussian noise via Box-Muller.
const gauss = (r) => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const rating = (v) => clamp(Math.round(v), 1, 5);

export function addDays(date, n) {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

// Each persona is a set of daily means as a function of the day index t (0..29, 29 = last day).
export const PERSONAS = Object.freeze([
  {
    id: "synthetic_maya",
    name: "Maya (synthetic)",
    profile: "Steady routine, office job, light walking. Everything stays roughly level.",
    missCheckin: 0.1,
    missNight: 0.07,
    mood: () => 3.7, energy: () => 3.4, sleep: () => 3.6,
    sleepMin: () => 425, steps: () => 7800, rhr: () => 61,
    flags: [],
    sessions: [
      "Talked through a calm week; wants to keep the evening walk.",
      "Asked about a lighter lunch and drinking more water.",
      "Reviewed the morning digest; no changes wanted.",
      "Short chat about planning a weekend trip.",
    ],
    notes: [
      ["Prefers a short evening walk after dinner.", "note", 0.7, null],
      ["Likes the morning digest read slowly.", "note", 0.6, null],
      ["Energy self-ratings were steady over the last weeks.", "hypothesis", 0.4, 14],
    ],
  },
  {
    id: "synthetic_jonas",
    name: "Jonas (synthetic)",
    profile: "Busy project deadline; sleep shortens and energy slips in the last ten days.",
    missCheckin: 0.25,
    missNight: 0.1,
    mood: (t) => 3.6 - (t > 18 ? (t - 18) * 0.06 : 0),
    energy: (t) => 3.5 - (t > 16 ? (t - 16) * 0.14 : 0),
    sleep: (t) => 3.5 - (t > 16 ? (t - 16) * 0.12 : 0),
    sleepMin: (t) => 420 - (t > 16 ? (t - 16) * 9 : 0),
    steps: (t) => 6500 - (t > 16 ? (t - 16) * 120 : 0),
    rhr: (t) => 58 + (t > 16 ? (t - 16) * 0.35 : 0),
    flags: [[22, "alcohol"]],
    sessions: [
      "Mentioned a deadline at work and late evenings at the screen.",
      "Said sleep has felt shorter this week; asked for a wind-down idea.",
      "Talked about skipping lunch breaks while busy.",
      "Chat about tiredness in the afternoons.",
    ],
    notes: [
      ["Has a work deadline at the end of the month.", "note", 0.7, 30],
      ["Sleep self-ratings were lower in the last week than in the first two.", "hypothesis", 0.35, 14],
      ["Asked for gentle suggestions rather than firm advice.", "note", 0.8, null],
    ],
  },
  {
    id: "synthetic_priya",
    name: "Priya (synthetic)",
    profile: "Started a daily walk and a fixed bedtime around day 12; mood and steps trend up.",
    missCheckin: 0.15,
    missNight: 0.12,
    mood: (t) => 2.9 + (t > 11 ? (t - 11) * 0.055 : 0),
    energy: (t) => 2.8 + (t > 11 ? (t - 11) * 0.06 : 0),
    sleep: (t) => 3.0 + (t > 11 ? (t - 11) * 0.05 : 0),
    sleepMin: (t) => 400 + (t > 11 ? (t - 11) * 4 : 0),
    steps: (t) => 4800 + (t > 11 ? (t - 11) * 230 : 0),
    rhr: (t) => 66 - (t > 11 ? (t - 11) * 0.2 : 0),
    flags: [[9, "travel"], [10, "travel"]],
    sessions: [
      "Decided to try a daily walk after lunch.",
      "Set a fixed bedtime; asked how to keep it on weekends.",
      "Reported feeling a bit lighter this week.",
      "Chat about meal planning for the week.",
    ],
    notes: [
      ["Started a daily walk after lunch around day 12.", "note", 0.8, null],
      ["Keeps a fixed bedtime on weekdays.", "note", 0.7, null],
      ["Mood self-ratings were higher in the last week than in the first week.", "hypothesis", 0.4, 14],
    ],
  },
]);

function pad(n) { return String(n).padStart(2, "0"); }

// One persona. end: YYYY-MM-DD, the last day (day 30). Pure given (persona, seed, end).
export function generatePersona(persona, seed, end) {
  const r = prng(seed);
  const first = addDays(end, -(DAYS - 1));
  const dates = Array.from({ length: DAYS }, (_, i) => addDays(first, i));
  const flagByDay = new Map();
  for (const [day, flag] of persona.flags) flagByDay.set(day, [...(flagByDay.get(day) ?? []), flag]);

  const checkins = [];
  const wearable = [];
  dates.forEach((date, t) => {
    // Check-in: missing with probability missCheckin (never two draws per field, so streams stay stable).
    const miss = r() < persona.missCheckin;
    const hour = 7 + Math.floor(r() * 3);
    const m = rating(persona.mood(t) + gauss(r) * 0.55);
    const e = rating(persona.energy(t) + gauss(r) * 0.6);
    const s = rating(persona.sleep(t) + gauss(r) * 0.6);
    if (!miss) checkins.push({ at: `${date}T${pad(hour)}:${pad(Math.floor(r() * 60))}:00.000Z`, mood: m, energy: e, sleep: s });
    else r(); // keep the stream aligned
    const noNight = r() < persona.missNight;
    const flagged = flagByDay.has(t) ? flagByDay.get(t) : [];
    const penalty = flagged.includes("alcohol") ? -45 : 0;
    const sleepMinutes = Math.round(clamp(persona.sleepMin(t) + penalty + gauss(r) * 28, 240, 600));
    const steps = Math.round(clamp(persona.steps(t) + gauss(r) * 1300, 600, 20000));
    const rhr = Math.round(clamp(persona.rhr(t) + gauss(r) * 1.8 + (flagged.length ? 2 : 0), 40, 110));
    wearable.push({ date, sleep_minutes: noNight ? null : sleepMinutes, steps: noNight ? null : steps, resting_hr: noNight ? null : rhr, flags: flagged });
  });

  const winStart = addDays(end, -(WINDOW - 1));
  const win = wearable.filter((w) => w.date >= winStart);
  const analysis_21d_body = {
    checkins: checkins.filter((c) => c.at.slice(0, 10) >= winStart).map((c) => ({ ...c })),
    start: winStart,
    tz: TZ,
    signals: win.map((w) => ({
      date: w.date,
      resting_hr: w.resting_hr,
      hrv_rmssd: null,
      sleep_hours: w.sleep_minutes == null ? null : Math.round((w.sleep_minutes / 60) * 100) / 100,
      flags: w.flags,
    })),
  };

  // Four session summaries at spaced days, never on the same day as another.
  const sessions = persona.sessions.map((summary, i) => {
    const day = Math.min(DAYS - 1, 4 + i * 8 + Math.floor(r() * 3));
    return { id: `${persona.id}-s${i + 1}`, at: `${dates[day]}T18:${pad(Math.floor(r() * 60))}:00.000Z`, summary, synthetic: true };
  });

  const memory_notes = persona.notes.map(([text, kind, confidence, ttlDays]) => ({
    text,
    kind,
    source: SOURCE,
    confidence,
    expires_at: ttlDays == null ? null : new Date(Date.parse(`${end}T23:59:59.000Z`) + ttlDays * 86400000).toISOString(),
  }));

  return {
    synthetic: true,
    notice: NOTICE,
    persona: { id: persona.id, name: persona.name, profile: persona.profile },
    seed,
    window: { start: first, end, days: DAYS },
    checkins,
    wearable,
    analysis_21d_body,
    sessions,
    memory_notes,
  };
}

// Three personas; each gets its own derived seed so changing one never shifts another.
export function generateAll({ seed = 2026, end = "2026-11-01" } = {}) {
  if (!Number.isInteger(seed)) throw new TypeError("seed must be an integer");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(end) || addDays(end, 0) !== end) throw new TypeError("end must be YYYY-MM-DD");
  return PERSONAS.map((p, i) => generatePersona(p, (seed + 7919 * (i + 1)) >>> 0, end));
}

function main(argv) {
  const get = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
  const all = generateAll({ seed: Number(get("--seed", 2026)), end: get("--end", "2026-11-01") });
  if (argv.includes("--stdout")) return console.log(JSON.stringify(all, null, 2));
  const out = resolve(get("--out", "./out"));
  mkdirSync(out, { recursive: true });
  for (const p of all) writeFileSync(join(out, `${p.persona.id}.json`), JSON.stringify(p, null, 2) + "\n");
  console.log(`gen_history: wrote ${all.length} synthetic personas to ${out}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
