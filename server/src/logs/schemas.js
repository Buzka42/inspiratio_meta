// Log entry validator (plan B6). The model only extracts; this file checks types, enums and ranges, removes the
// effort field unless the user's pref allows it, converts duration parts to seconds, numbers the run splits,
// expands a strength set count, and refuses any number the user did not state.
// Totals, pace and averages are computed on the phone (client/lib/logs/log_math.dart), never here.
// Returns {ok:true, entry} or {ok:false, code}; codes are fixed strings, never model or user text.
import { numbersOutside, statedNumbers } from "../analysis/numbers.js";

export const LOG_SCHEMA = "illunis.log/1";
export const LOG_KINDS = Object.freeze(["food", "activity", "strength", "run", "cardio"]);
export const EFFORT_PREFS = Object.freeze(["none", "rir", "rpe"]);
export const LOG_CODES = Object.freeze(["not_object", "bad_field", "out_of_range", "empty_entry", "number_not_in_text"]);
// Food check (C6): per-item statuses on a success, and the choice code on a mismatch.
export const CHECK_STATUSES = Object.freeze(["match", "unverified"]);
export const NEEDS_CHOICE = "needs_choice";

const MEALS = ["breakfast", "lunch", "dinner", "snack"];
const FOOD_UNITS = ["g", "ml", "piece", "serving"];
const WEIGHT_UNITS = ["kg", "lb"];
const RUN_UNITS = ["km", "mi"];
const DISTANCE_UNITS = ["km", "mi", "m"];
const MAX_DAY_S = 86_400;

class Reject extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}
const reject = (code) => {
  throw new Reject(code);
};

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const absent = (v) => v === undefined || v === null;

// One validation pass. `seen` collects every extracted value for the number check.
function makeChecks(seen) {
  const num = (v, { min, max, int = false, minExclusive = false }) => {
    if (typeof v !== "number" || !Number.isFinite(v)) reject("bad_field");
    if (int && !Number.isInteger(v)) reject("bad_field");
    if (v < min || v > max || (minExclusive && v === min)) reject("out_of_range");
    seen.push(v);
    return v;
  };
  const str = (v, max) => {
    if (typeof v !== "string" || !v.trim()) reject("bad_field");
    const s = v.trim();
    if (s.length > max) reject("out_of_range");
    seen.push(s);
    return s;
  };
  const oneOf = (v, list) => (list.includes(v) ? v : reject("bad_field"));
  const list = (v, max) => {
    if (!Array.isArray(v)) reject("bad_field");
    if (!v.length) reject("empty_entry");
    if (v.length > max) reject("out_of_range");
    return v;
  };
  // duration: {h?, min?, s?} as the user stated it; plain code turns it into seconds.
  const duration = (d) => {
    if (!isObj(d)) reject("bad_field");
    const parts = [["h", 3600, 24], ["min", 60, 1440], ["s", 1, MAX_DAY_S]].filter(([k]) => !absent(d[k]));
    if (!parts.length) reject("bad_field");
    const total = parts.reduce((t, [k, mult, max]) => t + num(d[k], { min: 0, max, int: k !== "s" }) * mult, 0);
    if (total <= 0 || total > MAX_DAY_S) reject("out_of_range");
    return Math.round(total * 10) / 10;
  };
  const distance = (d, units) => {
    if (!isObj(d)) reject("bad_field");
    return { value: num(d.value, { min: 0, max: 1000, minExclusive: true }), unit: oneOf(d.unit, units) };
  };
  return { num, str, oneOf, list, duration, distance };
}

const KINDS = {
  food(o, c) {
    const entry = {};
    if (!absent(o.meal)) entry.meal = c.oneOf(o.meal, MEALS);
    entry.items = c.list(o.items, 50).map((it) => {
      if (!isObj(it)) reject("bad_field");
      const item = { name: c.str(it.name, 80) };
      if (!absent(it.quantity)) item.quantity = c.num(it.quantity, { min: 0, max: 100_000, minExclusive: true });
      if (!absent(it.unit)) item.unit = c.oneOf(it.unit, FOOD_UNITS);
      // kcal only when the user stated it: the number check below enforces that.
      if (!absent(it.kcal)) item.kcal = c.num(it.kcal, { min: 0, max: 10_000 });
      return item;
    });
    return entry;
  },

  activity(o, c) {
    const entry = { type: c.str(o.type, 60) };
    if (!absent(o.duration)) entry.duration_s = c.duration(o.duration);
    if (!absent(o.distance)) entry.distance = c.distance(o.distance, DISTANCE_UNITS);
    if (!absent(o.steps)) entry.steps = c.num(o.steps, { min: 0, max: 200_000, int: true });
    return entry;
  },

  strength(o, c, prefs) {
    const exercises = c.list(o.exercises, 30).map((ex) => {
      if (!isObj(ex)) reject("bad_field");
      const sets = [];
      for (const s of c.list(ex.sets, 50)) {
        if (!isObj(s)) reject("bad_field");
        const count = absent(s.count) ? 1 : c.num(s.count, { min: 1, max: 20, int: true });
        const weight = absent(s.weight) ? null : c.num(s.weight, { min: 0, max: 1000 });
        const set = { reps: c.num(s.reps, { min: 0, max: 1000, int: true }), weight };
        // unit is required with a weight; a bodyweight set (weight null) may leave it null.
        set.unit = weight === null && absent(s.unit) ? null : c.oneOf(s.unit, WEIGHT_UNITS);
        const effort = effortOf(s.effort, prefs, c);
        for (let i = 0; i < count; i++) sets.push({ ...set, ...(effort ? { effort: { ...effort } } : {}) });
      }
      if (sets.length > 50) reject("out_of_range");
      return { name: c.str(ex.name, 80), sets };
    });
    return { exercises };
  },

  run(o, c) {
    const entry = { distance: c.distance(o.distance, RUN_UNITS), duration_s: c.duration(o.duration) };
    const splits = absent(o.splits) ? [] : Array.isArray(o.splits) ? o.splits : reject("bad_field");
    if (splits.length > 200) reject("out_of_range");
    // index is the split's position, set here; a split distance is kept only when the user stated it.
    entry.splits = splits.map((s, i) => {
      if (!isObj(s)) reject("bad_field");
      return {
        index: i + 1,
        distance: absent(s.distance) ? null : c.num(s.distance, { min: 0, max: 1000, minExclusive: true }),
        duration_s: c.duration(s.duration),
      };
    });
    return entry;
  },

  cardio(o, c) {
    const entry = { type: c.str(o.type, 60) };
    if (!absent(o.duration)) entry.duration_s = c.duration(o.duration);
    if (!absent(o.hr_avg)) entry.hr_avg = c.num(o.hr_avg, { min: 25, max: 250, int: true });
    if (!absent(o.hr_max)) entry.hr_max = c.num(o.hr_max, { min: 25, max: 250, int: true });
    if (entry.hr_avg !== undefined && entry.hr_max !== undefined && entry.hr_max < entry.hr_avg) reject("out_of_range");
    if (!absent(o.kcal)) entry.kcal = c.num(o.kcal, { min: 0, max: 10_000 });
    return entry;
  },
};

// Effort is removed (never checked) unless prefs.effort names its scale. RIR 0-10, RPE 1-10, in halves.
function effortOf(effort, prefs, c) {
  const allowed = prefs?.effort;
  if (absent(effort) || !isObj(effort) || allowed === "none" || !EFFORT_PREFS.includes(allowed)) return null;
  if (effort.scale !== allowed) return null;
  const value = c.num(effort.value, allowed === "rir" ? { min: 0, max: 10 } : { min: 1, max: 10 });
  if (!Number.isInteger(value * 2)) reject("bad_field");
  return { scale: allowed, value };
}

// kind: one of LOG_KINDS. output: the model's parsed JSON. text: the user's own text. prefs: {effort}.
export function validateEntry(kind, output, text, prefs = {}) {
  if (!KINDS[kind]) return { ok: false, code: "bad_field" };
  if (!isObj(output)) return { ok: false, code: "not_object" };
  const seen = [];
  try {
    const entry = KINDS[kind](output, makeChecks(seen), prefs);
    if (numbersOutside(seen, statedNumbers(text)).length) return { ok: false, code: "number_not_in_text" };
    return { ok: true, entry };
  } catch (err) {
    if (err instanceof Reject) return { ok: false, code: err.code };
    throw err;
  }
}

export const envelope = (kind, date, entry) => ({ schema: LOG_SCHEMA, kind, date, source: "typed", entry });
