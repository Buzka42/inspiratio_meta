// Data-quality flags for one signal's 21-day series. The thresholds are design
// defaults from docs/RESEARCH.md (section 2), not cited figures.
import { sampleSd } from "./stats.js";

export const RULES = Object.freeze({
  days: 21,
  baselineDays: 7, // days 1-7
  minBaseline: 4, // observed days needed in the baseline
  recentDays: 7, // days 15-21, also the rolling window
  minRecent: 4, // observed days needed in a 7-day window
  trendDays: 14, // days 8-21
  minTrend: 8, // observed days needed for OLS
  maxMissing: 7, // more missing days than this is sparse
  minSd: 0.25, // below this the series is low variance
  minEffect: 0.8, // |d| needed to report an effect
  r1Limit: 0.3, // |lag-1 residual autocorrelation| above this inflates SE
});

// self_report_only is on every output; every other flag blocks claims and caps confidence.
export const ALWAYS_FLAG = "self_report_only";

export const values = (slots) => slots.filter(Boolean).map((s) => s.mean);

export function windows(series) {
  const s = series.slots;
  return {
    baseline: values(s.slice(0, RULES.baselineDays)),
    recent: values(s.slice(RULES.days - RULES.recentDays)),
    trend: s
      .map((slot, i) => (slot ? { x: i, y: slot.mean } : null))
      .slice(RULES.days - RULES.trendDays)
      .filter(Boolean),
    all: values(s),
  };
}

export function qualityFlags(series) {
  const w = windows(series);
  const flags = [];
  if (RULES.days - w.all.length > RULES.maxMissing) flags.push("sparse");
  const baseSd = sampleSd(w.baseline);
  const allSd = sampleSd(w.all);
  if ((baseSd !== null && baseSd < RULES.minSd) || (allSd !== null && allSd < RULES.minSd)) flags.push("low_variance");
  if (w.trend.length < RULES.minTrend || w.recent.length < RULES.minRecent) flags.push("too_few_points");
  if (w.baseline.length < RULES.minBaseline) flags.push("baseline_insufficient");
  flags.push(ALWAYS_FLAG);
  return flags;
}

export const blockingFlags = (flags) => flags.filter((f) => f !== ALWAYS_FLAG);
