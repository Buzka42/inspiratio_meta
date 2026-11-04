// 21-day daily series from 1-to-5 self-ratings. Pure: no I/O, no clock.
// A day with no check-in is null, never zero. Several check-ins in one local day
// become {mean, count}.

export const DAYS = 21;
export const SIGNALS = ["mood", "energy", "sleep"];
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// Local calendar date (YYYY-MM-DD) of an instant in an IANA time zone.
export function localDate(at, tz) {
  const d = new Date(at);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(d)
    .reduce((acc, p) => ({ ...acc, [p.type]: p.value }), {});
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function addDays(date, n) {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

const validRating = (v) => typeof v === "number" && Number.isFinite(v) && v >= 1 && v <= 5;

// checkins: [{at, mood?, energy?, sleep?}]; at is an ISO string or epoch ms.
// start: local date of day 1. Returns {start, tz, dates[21], signals: {name: slot[21]}},
// slot = {mean, count} or null. Out-of-window or out-of-range values are ignored.
export function buildDailySeries(checkins, { start, tz = "UTC" } = {}) {
  if (typeof start !== "string" || !DATE_RE.test(start) || addDays(start, 0) !== start) {
    throw new TypeError("start must be a YYYY-MM-DD date");
  }
  new Intl.DateTimeFormat("en-CA", { timeZone: tz }); // throws RangeError on an unknown zone
  const dates = Array.from({ length: DAYS }, (_, i) => addDays(start, i));
  const index = new Map(dates.map((d, i) => [d, i]));
  const sums = Object.fromEntries(SIGNALS.map((s) => [s, dates.map(() => ({ sum: 0, count: 0 }))]));

  for (const c of Array.isArray(checkins) ? checkins : []) {
    const i = index.get(localDate(c?.at, tz));
    if (i === undefined) continue;
    for (const s of SIGNALS) {
      if (!validRating(c[s])) continue;
      sums[s][i].sum += c[s];
      sums[s][i].count += 1;
    }
  }
  const signals = Object.fromEntries(
    SIGNALS.map((s) => [s, sums[s].map(({ sum, count }) => (count ? { mean: sum / count, count } : null))]),
  );
  return { start, tz, dates, signals };
}

// One signal's view of the daily series, the input to quality and findings.
export function signalSeries(daily, signal) {
  if (!SIGNALS.includes(signal)) throw new TypeError(`signal must be one of ${SIGNALS.join(", ")}`);
  return { signal, dates: daily.dates, slots: daily.signals[signal] };
}
