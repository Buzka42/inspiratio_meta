// 21-day vitals analysis. Pure, deterministic, no network, no I/O.
// Plain code computes every number; a model only ever reads the result.
//
// INPUT: exactly 21 snapshots {date: "YYYY-MM-DD", resting_hr, hrv_rmssd,
// sleep_hours, flags}. Any metric may be null. flags is an array of strings.
// Input order does not matter; snapshots are sorted by date.
//
// RULES (heuristic thresholds for a personal trend view, not clinically validated):
//   1. Valid value: a finite number >= 0 on a day without an exclusion flag
//      (illness, alcohol, travel). Flagged days are excluded from the baseline
//      AND the recent window, and are listed in data_quality.flagged_days.
//      A missing night is a day where all three metrics are null.
//   2. Baseline: days 1-14. Mean and sample SD (n - 1) of the valid values there.
//      Fewer than 7 valid values -> baseline = "building_baseline", and no
//      z-score, trend or deviation finding is produced for that metric.
//   3. Recent: days 15-21. Mean of the valid values there. Fewer than 3 valid
//      values -> recent mean is null ("insufficient_recent_data").
//   4. z = (recent mean - baseline mean) / baseline SD. SD of 0 -> z is null.
//      Trend: z >= 1 rising, z <= -1 falling, otherwise stable.
//   5. Findings are always kind "observation", never anything stronger.
//      Deviation finding when |z| >= 1. Confidence "medium" only if |z| >= 2,
//      baseline n >= 10 and recent n >= 5; otherwise "low". Data-quality
//      findings (flagged days, missing nights, building baseline) are "low".
//      Every finding names the evidence_rule that produced it and expires
//      7 days after the last date.

export const METRICS = ['resting_hr', 'hrv_rmssd', 'sleep_hours'];
export const EXCLUSION_FLAGS = ['illness', 'alcohol', 'travel'];
export const RULES = Object.freeze({
  days: 21,
  baselineDays: 14,
  minBaseline: 7,
  minRecent: 3,
  trendZ: 1,
  mediumZ: 2,
  mediumBaselineN: 10,
  mediumRecentN: 5,
  expiryDays: 7,
});
export const NOTICE =
  'Not medical advice. These are observations from your own data, not a diagnosis. ' +
  'If anything worries you, please speak to a clinician.';

const LABELS = { resting_hr: 'Resting heart rate', hrv_rmssd: 'HRV (RMSSD)', sleep_hours: 'Sleep' };
const UNITS = { resting_hr: 'bpm', hrv_rmssd: 'ms', sleep_hours: 'h' };
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const isValue = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;
const round = (v, dp = 2) => (v == null ? null : Math.round(v * 10 ** dp) / 10 ** dp);
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
const sampleSd = (xs) => {
  const m = mean(xs);
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
};
const addDays = (date, n) => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

function normalise(snapshots) {
  if (!Array.isArray(snapshots)) throw new TypeError('snapshots must be an array');
  if (snapshots.length !== RULES.days) throw new RangeError(`expected ${RULES.days} snapshots, got ${snapshots.length}`);
  const days = snapshots.map((s, i) => {
    if (!s || typeof s !== 'object' || !DATE_RE.test(s.date ?? '')) throw new TypeError(`snapshot ${i}: bad date`);
    const flags = Array.isArray(s.flags) ? s.flags.filter((f) => typeof f === 'string') : [];
    const exclusions = EXCLUSION_FLAGS.filter((f) => flags.includes(f));
    const values = Object.fromEntries(METRICS.map((m) => [m, isValue(s[m]) ? s[m] : null]));
    return { date: s.date, values, exclusions };
  });
  days.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  for (let i = 1; i < days.length; i++) {
    if (days[i].date === days[i - 1].date) throw new RangeError(`duplicate date ${days[i].date}`);
  }
  return days;
}

const validValues = (days, metric) =>
  days.filter((d) => d.exclusions.length === 0 && d.values[metric] != null).map((d) => d.values[metric]);

function analyseMetric(metric, baseDays, recentDays) {
  const base = validValues(baseDays, metric);
  const recent = validValues(recentDays, metric);
  const recentMean = recent.length >= RULES.minRecent ? mean(recent) : null;
  const out = {
    baseline: 'building_baseline',
    baseline_valid_nights: base.length,
    recent_mean: round(recentMean),
    recent_valid_nights: recent.length,
    recent_status: recentMean == null ? 'insufficient_recent_data' : 'ok',
    z_score: null,
    trend: null,
  };
  if (base.length < RULES.minBaseline) return out;
  const bMean = mean(base);
  const bSd = sampleSd(base);
  out.baseline = { mean: round(bMean), sd: round(bSd), n: base.length };
  if (recentMean != null && bSd > 0) {
    const z = (recentMean - bMean) / bSd;
    out.z_score = round(z);
    out.trend = z >= RULES.trendZ ? 'rising' : z <= -RULES.trendZ ? 'falling' : 'stable';
  }
  return out;
}

function deviationFinding(metric, r, expires) {
  const z = r.z_score;
  if (z == null || Math.abs(z) < RULES.trendZ) return null;
  const medium =
    Math.abs(z) >= RULES.mediumZ && r.baseline.n >= RULES.mediumBaselineN && r.recent_valid_nights >= RULES.mediumRecentN;
  const dir = z > 0 ? 'higher' : 'lower';
  return {
    kind: 'observation',
    metric,
    confidence: medium ? 'medium' : 'low',
    evidence_rule: medium ? 'deviation_z_ge_2_with_enough_data' : 'deviation_z_ge_1',
    text:
      `${LABELS[metric]} averaged ${round(r.recent_mean, 1)} ${UNITS[metric]} over the last 7 days, ` +
      `${dir} than your baseline of ${round(r.baseline.mean, 1)} ${UNITS[metric]} (z ${round(z, 1)}).`,
    expires_on: expires,
  };
}

/** Analyse 21 daily snapshots. Returns plain data; see RULES above. */
export function analyze(snapshots) {
  const days = normalise(snapshots);
  const baseDays = days.slice(0, RULES.baselineDays);
  const recentDays = days.slice(RULES.baselineDays);
  const last = days.at(-1).date;
  const expires = addDays(last, RULES.expiryDays);

  const metrics = Object.fromEntries(METRICS.map((m) => [m, analyseMetric(m, baseDays, recentDays)]));
  const flagged = days.filter((d) => d.exclusions.length).map((d) => ({ date: d.date, flags: d.exclusions }));
  const missing = days.filter((d) => METRICS.every((m) => d.values[m] == null)).map((d) => d.date);

  const findings = [];
  for (const m of METRICS) {
    const r = metrics[m];
    if (r.baseline === 'building_baseline') {
      findings.push({
        kind: 'observation',
        metric: m,
        confidence: 'low',
        evidence_rule: 'baseline_needs_7_valid_nights',
        text: `${LABELS[m]} baseline is still building: ${r.baseline_valid_nights} of ${RULES.minBaseline} valid nights needed.`,
        expires_on: expires,
      });
      continue;
    }
    const f = deviationFinding(m, r, expires);
    if (f) findings.push(f);
  }
  if (flagged.length) {
    findings.push({
      kind: 'observation',
      metric: null,
      confidence: 'low',
      evidence_rule: 'flagged_days_excluded',
      text: `${flagged.length} day(s) flagged for illness, alcohol or travel were left out of the numbers.`,
      expires_on: expires,
    });
  }
  if (missing.length) {
    findings.push({
      kind: 'observation',
      metric: null,
      confidence: 'low',
      evidence_rule: 'missing_nights_reported',
      text: `${missing.length} night(s) had no data.`,
      expires_on: expires,
    });
  }

  return {
    window: { start: days[0].date, end: last, baseline_end: baseDays.at(-1).date, recent_start: recentDays[0].date },
    metrics,
    data_quality: {
      total_days: days.length,
      valid_nights: Object.fromEntries(METRICS.map((m) => [m, validValues(days, m).length])),
      missing_nights: missing,
      flagged_days: flagged,
    },
    findings,
    notice: NOTICE,
  };
}
