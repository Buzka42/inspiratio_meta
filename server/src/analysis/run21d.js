// POST /analysis/21d: stateless. The phone sends check-ins (and optionally 21 daily wearable snapshots);
// plain code computes every number (daily.js, findings.js, analysis/analyze.mjs), then the council writes a
// short comment from the structured findings only. phrase.js checks that comment: every number must be in
// the structured input, no conclusion or condition words, gate passed. A rejected comment is dropped (null).
import { buildDailySeries, signalSeries, SIGNALS } from "./daily.js";
import { computeFindings, toHypothesis } from "./findings.js";
import { checkPhrasing, phraseInput, routeCrisis } from "./phrase.js";
import { analyze } from "../../analysis/analyze.mjs";
import { NOT_MEDICAL_ADVICE } from "../safety.js";
import { runCouncilV2 } from "../council/relay.js";

const MAX_CHECKINS = 500;
export const COMMENT_QUESTION =
  "Write a short, warm comment for the user on these tentative 21-day findings from their own check-ins and wearable.";

export class AnalysisInputError extends Error {}

// Only the parts of the vitals result the council may see: no dates, no raw series.
const vitalsForCouncil = (vitals) =>
  vitals.findings.map((f) => {
    const m = f.metric ? vitals.metrics[f.metric] : null;
    return {
      metric: f.metric,
      rule: f.evidence_rule,
      confidence: f.confidence,
      trend: m?.trend ?? null,
      recent_mean: m?.recent_mean ?? null,
      baseline_mean: typeof m?.baseline === "object" ? m.baseline.mean : null,
      z_score: m?.z_score ?? null,
    };
  });

export function computeAnalysis(body, now = Date.now()) {
  const { checkins = [], start, tz = "UTC", signals } = body;
  if (!Array.isArray(checkins) || checkins.length > MAX_CHECKINS) throw new AnalysisInputError(`checkins must be an array of at most ${MAX_CHECKINS}`);
  let daily;
  try {
    daily = buildDailySeries(checkins, { start, tz });
  } catch (err) {
    throw new AnalysisInputError(err instanceof RangeError ? "tz invalid" : "start must be a YYYY-MM-DD date");
  }
  const findings = SIGNALS.map((s) => computeFindings(signalSeries(daily, s)));
  let vitals = null;
  if (signals !== undefined) {
    try {
      vitals = analyze(signals);
    } catch {
      throw new AnalysisInputError("signals must be 21 daily snapshots with unique YYYY-MM-DD dates");
    }
  }
  const structured = {
    checkins: findings.map(phraseInput).filter(Boolean),
    vitals: vitals ? vitalsForCouncil(vitals) : [],
  };
  return {
    window: { start, tz, days: 21 },
    findings,
    hypotheses: findings.map((f) => toHypothesis(f, now)).filter(Boolean),
    vitals,
    structured,
  };
}

// Returns the route body. deps go to runCouncilV2 (fetchFn and test fakes).
export async function runAnalysis21d(body, env, deps = {}) {
  const notes = (Array.isArray(body.checkins) ? body.checkins : []).map((c) => c?.note).filter((n) => typeof n === "string");
  const referral = routeCrisis(notes);
  if (referral) return { crisis: true, text: referral };
  const result = computeAnalysis(body, deps.nowMs ?? Date.now());
  const { structured } = result;
  const out = { ...result, comment: null, comment_code: null, council: null, notice: NOT_MEDICAL_ADVICE };
  if (body.comment === false) return { ...out, comment_code: "comment_off" };
  if (!structured.checkins.length && !structured.vitals.length) return { ...out, comment_code: "nothing_to_comment" };
  let council;
  try {
    council = await runCouncilV2({ question: COMMENT_QUESTION, context: { findings: structured }, purpose: "analysis" }, env, deps);
  } catch (err) {
    return { ...out, comment_code: err?.message === "not configured" ? "council_not_configured" : "council_upstream" };
  }
  const checked = checkPhrasing(council.synthesis, structured);
  const meta = { experts_consulted: council.experts_consulted, sources: council.sources, medical: council.medical, providers: council.providers };
  if (!checked.ok) return { ...out, comment_code: `comment_${checked.reason}`, council: meta };
  return { ...out, comment: checked.text, council: meta };
}
