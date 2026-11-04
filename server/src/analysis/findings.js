// Findings from one signal's 21-day series, and the hypothesis record built from
// them. Plain code computes every number; a model may only phrase the result.
import { RULES, ALWAYS_FLAG, blockingFlags, qualityFlags, windows } from "./quality.js";
import { lag1Autocorr, mean, olsTrend, sampleSd } from "./stats.js";

export const SOURCE = "analysis:21d";
export const EXPIRY_DAYS = 14;
// Design default (not in the research): a trend is only worded when |t| >= 2.
export const TREND_T_MIN = 2;
const DAY_MS = 86_400_000;
const LABELS = { mood: "mood", energy: "energy", sleep: "sleep" };

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
const round = (x, p = 2) => Math.round(x * 10 ** p) / 10 ** p;

// Trailing 7-day mean per day; null when the window has fewer than 4 observed days.
export function rollingMeans(slots) {
  return slots.map((_, i) => {
    const w = slots.slice(Math.max(0, i - RULES.recentDays + 1), i + 1).filter(Boolean).map((s) => s.mean);
    return w.length >= RULES.minRecent ? mean(w) : null;
  });
}

// SE inflation for lag-1 residual autocorrelation. Never shrinks SE (r1 < 0 gives 1).
export function seFactor(r1) {
  if (r1 === null || Math.abs(r1) <= RULES.r1Limit) return 1;
  const r = clamp(r1, -0.99, 0.99);
  return Math.max(1, Math.sqrt((1 + r) / (1 - r)));
}

export function confidenceFor({ blocked, validDays, r1 }) {
  if (blocked) return 0.2;
  let c = clamp(0.3 + 0.02 * (validDays - 8), 0.2, 0.7);
  if (r1 !== null && Math.abs(r1) > RULES.r1Limit) c -= 0.1;
  return round(clamp(c, 0.2, 0.7));
}

function trendFor(points) {
  const fit = olsTrend(points.map((p) => p.x), points.map((p) => p.y));
  if (!fit) return null;
  const r1 = lag1Autocorr(fit.residuals);
  const factor = seFactor(r1);
  const se = fit.se * factor;
  const t = se === 0 ? fit.t : fit.slope / se;
  return { slope: fit.slope, se, se_raw: fit.se, t, df: fit.df, n: fit.n, r1, inflated: factor > 1, notable: Math.abs(t) >= TREND_T_MIN };
}

export function computeFindings(series) {
  const flags = qualityFlags(series);
  const blocked = blockingFlags(flags).length > 0;
  const w = windows(series);
  const baseline = { mean: mean(w.baseline), sd: sampleSd(w.baseline), n: w.baseline.length };
  const recent = { mean: mean(w.recent), n: w.recent.length };

  let effect = null;
  let trend = null;
  if (!blocked) {
    const d = (recent.mean - baseline.mean) / baseline.sd;
    if (Math.abs(d) >= RULES.minEffect) effect = { d, diff: recent.mean - baseline.mean };
    trend = trendFor(w.trend);
  }
  return {
    signal: series.signal,
    flags,
    valid_days: w.all.length,
    baseline,
    recent,
    rolling: rollingMeans(series.slots),
    effect,
    trend,
    confidence: confidenceFor({ blocked, validDays: w.all.length, r1: trend?.r1 ?? null }),
  };
}

// The hypothesis record for memory, or null when nothing may be said.
// Not written anywhere yet: the memory store decision is pending.
export function toHypothesis(finding, now = Date.now()) {
  if (blockingFlags(finding.flags).length) return null;
  const label = LABELS[finding.signal] ?? finding.signal;
  const parts = [];
  if (finding.effect) {
    const dir = finding.effect.diff < 0 ? "lower" : "higher";
    const days = finding.baseline.n + finding.recent.n;
    parts.push(
      `In these check-ins, ${label} self-ratings averaged ${Math.abs(finding.effect.diff).toFixed(1)} points ${dir} ` +
        `in the last 7 days than in the first 7 (${days} of 14 days rated).`,
    );
  }
  if (finding.trend?.notable) {
    const dir = finding.trend.slope < 0 ? "down" : "up";
    parts.push(
      `Over the last 14 days the ${label} ratings drifted ${dir} by about ${Math.abs(finding.trend.slope).toFixed(2)} ` +
        `points per day (${finding.trend.n} days rated).`,
    );
  }
  if (!parts.length) return null;
  return {
    kind: "hypothesis",
    label: "observation",
    text: `Tentative observation. ${parts.join(" ")}`,
    confidence: finding.confidence,
    created_at: new Date(now).toISOString(),
    expires_at: new Date(now + EXPIRY_DAYS * DAY_MS).toISOString(),
    source: SOURCE,
    flags: [ALWAYS_FLAG],
  };
}

export const isExpired = (h, now = Date.now()) => Boolean(h?.expires_at) && Date.parse(h.expires_at) <= now;
