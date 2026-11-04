// Model phrasing of analysis findings. The model gets only a structured projection
// of the findings and may reword them, never compute or add numbers. Its output is
// checked: every number must appear in the input, gateText must pass, and
// conclusion, diagnosis and condition words are refused.
import { NOT_MEDICAL_ADVICE, REFERRAL_TEXT, gateText, isCrisis, withHealthLine } from "../safety.js";
import { blockingFlags } from "./quality.js";
import { numbersIn } from "./numbers.js";

const LABELS = { mood: "mood", energy: "energy", sleep: "sleep" };

// Crisis phrases route to the referral before any analysis runs.
export function routeCrisis(texts = []) {
  return texts.some((t) => isCrisis(t)) ? REFERRAL_TEXT : null;
}

// The only data the model sees. Numbers are pre-rounded to the form it may quote.
export function phraseInput(finding) {
  if (blockingFlags(finding.flags).length) return null;
  const effect = finding.effect
    ? {
        direction: finding.effect.diff < 0 ? "lower" : "higher",
        points: Number(Math.abs(finding.effect.diff).toFixed(1)),
        days_rated: finding.baseline.n + finding.recent.n,
      }
    : null;
  const trend = finding.trend?.notable
    ? {
        direction: finding.trend.slope < 0 ? "down" : "up",
        points_per_day: Number(Math.abs(finding.trend.slope).toFixed(2)),
        days_rated: finding.trend.n,
      }
    : null;
  if (!effect && !trend) return null;
  return {
    signal: LABELS[finding.signal] ?? finding.signal,
    scale: "self-ratings from 1 to 5",
    window: { days: 21, baseline_days: 7, recent_days: 7, trend_days: 14 },
    effect,
    trend,
    confidence: finding.confidence,
    flags: finding.flags,
  };
}

export function buildPhrasePrompt(input) {
  return [
    {
      role: "system",
      content:
        "Rewrite the structured observation below as one or two short plain sentences for the user. " +
        "Use only numbers that appear in the input, exactly as written; do not compute, round or add any. " +
        "Call it a tentative observation from these check-ins. Do not give conclusions, diagnoses, " +
        "condition names, causes or advice. Output the sentences only.",
    },
    { role: "user", content: JSON.stringify(input) },
  ];
}

const FORBIDDEN_RE =
  /\b(?:conclu\w*|diagnos\w*|burn-?out|depress\w*|anxiety|anxious|disorder\w*|insomnia|syndrome\w*|disease\w*|illness\w*|adhd|bipolar|ptsd|deficien\w*|because|caus\w*|due to|leads? to|proves?)\b/i;

// Returns {ok, text, reason}. On success text carries the not-medical-advice line.
// A gate failure returns the referral text; any other rejection returns text null,
// so the caller falls back to the plain hypothesis sentence.
export function checkPhrasing(output, input) {
  const out = String(output ?? "").trim();
  if (!out) return { ok: false, reason: "empty", text: null };
  if (gateText(out) !== out) return { ok: false, reason: "gate", text: REFERRAL_TEXT };
  if (FORBIDDEN_RE.test(out)) return { ok: false, reason: "forbidden_word", text: null };
  const allowed = new Set(numbersIn(JSON.stringify(input)));
  const extra = numbersIn(out).filter((n) => !allowed.has(n));
  if (extra.length) return { ok: false, reason: "number_not_in_input", text: null };
  return { ok: true, reason: null, text: withHealthLine(out) };
}

// Plain fallback when the model is skipped or rejected.
export const fallbackText = (hypothesis) => withHealthLine(hypothesis.text);

export { NOT_MEDICAL_ADVICE };
