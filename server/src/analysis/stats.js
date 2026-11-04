// Plain statistics for the 21-day analysis. Each returns null when undefined
// for the input, never NaN.

export function mean(xs) {
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}

// Sample standard deviation (n - 1).
export function sampleSd(xs) {
  if (xs.length < 2) return null;
  const m = mean(xs);
  return Math.sqrt(xs.reduce((a, x) => a + (x - m) ** 2, 0) / (xs.length - 1));
}

// Ordinary least squares y = a + b x. b = Sxy / Sxx, s = sqrt(RSS / (n - 2)),
// SE(b) = s / sqrt(Sxx), t = b / SE, df = n - 2. An exact fit has SE 0 and
// t = +/-Infinity (0 for a flat exact fit).
export function olsTrend(xs, ys) {
  const n = xs.length;
  if (n !== ys.length || n < 3) return null;
  const mx = mean(xs);
  const my = mean(ys);
  let sxx = 0;
  let sxy = 0;
  for (let i = 0; i < n; i++) {
    sxx += (xs[i] - mx) ** 2;
    sxy += (xs[i] - mx) * (ys[i] - my);
  }
  if (sxx === 0) return null;
  const slope = sxy / sxx;
  const intercept = my - slope * mx;
  const residuals = ys.map((y, i) => y - (intercept + slope * xs[i]));
  const rss = residuals.reduce((a, r) => a + r * r, 0);
  const df = n - 2;
  const se = Math.sqrt(rss / df) / Math.sqrt(sxx);
  // Float noise on an exact line leaves RSS near 1e-30; treat it as an exact fit.
  const exact = rss <= 1e-12 * Math.max(1, sxx);
  const t = exact ? (slope === 0 ? 0 : Math.sign(slope) * Infinity) : slope / se;
  return { slope, intercept, se: exact ? 0 : se, t, df, n, residuals };
}

// Lag-1 autocorrelation: sum (x_t - m)(x_{t+1} - m) / sum (x_t - m)^2.
export function lag1Autocorr(xs) {
  if (xs.length < 3) return null;
  const m = mean(xs);
  let num = 0;
  let den = 0;
  for (let i = 0; i < xs.length; i++) {
    den += (xs[i] - m) ** 2;
    if (i < xs.length - 1) num += (xs[i] - m) * (xs[i + 1] - m);
  }
  return den <= 1e-12 ? null : num / den;
}
