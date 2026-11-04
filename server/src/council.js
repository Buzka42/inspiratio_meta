// LEGACY test council: three rounds, advise only, free test models. The real council is council/relay.js (v2).
// Reached only with COUNCIL_PROVIDER=opencode (OpenCode Zen, DEFAULT_MEMBERS, one session per run) or
// COUNCIL_PROVIDER=openrouter_poc (OPENROUTER_COUNCIL_MEMBERS, no session header), and only under
// DATA_MODE=synthetic: these providers may keep or train on prompts.
// Members see the question and the previous round summary only, never memory.
import { chatJson } from "./opencode.js";
import { chatOpenRouter, openRouterConfigProblem } from "./openrouter.js";
import { gateText } from "./safety.js";
import { COUNCIL_MODELS, COUNCIL_PROVIDER, OPENROUTER_COUNCIL_PROVIDER, OPENROUTER_MEMBERS } from "./models.js";
import { contributorRefused, dataModeProblem, isContributorModel } from "./data-mode.js";

export const ROUNDS = 3;
// Model ids live in models.js (COUNCIL_MODELS), with the verification notes.
const STYLES = { deepseek: "analytical and cautious", glm: "practical and concise", nemotron: "creative and contrarian" };
const membersFrom = (models) => Object.entries(STYLES).map(([id, style]) => ({ id, model: models[id], style }));
export const DEFAULT_MEMBERS = membersFrom(COUNCIL_MODELS);
export const OPENROUTER_COUNCIL_MEMBERS = membersFrom(OPENROUTER_MEMBERS);

// Only these models may sit on the council, per provider. Contributor tiers train on prompts
// and are refused even if added to a list by mistake.
export const ALLOWED_MODELS = new Set(DEFAULT_MEMBERS.map((m) => m.model));
export const OPENROUTER_ALLOWED_MODELS = new Set(OPENROUTER_COUNCIL_MEMBERS.map((m) => m.model));
export { isContributorModel };
export const LEGACY_COUNCIL_PROVIDERS = [COUNCIL_PROVIDER, OPENROUTER_COUNCIL_PROVIDER];
export const isLegacyCouncil = (env) => LEGACY_COUNCIL_PROVIDERS.includes(env?.COUNCIL_PROVIDER);

const onOpenRouter = (env) => env?.COUNCIL_PROVIDER === OPENROUTER_COUNCIL_PROVIDER;
export const councilMembers = (env) => (onOpenRouter(env) ? OPENROUTER_COUNCIL_MEMBERS : DEFAULT_MEMBERS);

// Returns a refusal reason (names variables, never values) or null. Called directly, unset means OpenCode Zen;
// the /council route sends unset COUNCIL_PROVIDER to council v2 instead.
export function councilConfigProblem(env = {}) {
  const provider = onOpenRouter(env) ? OPENROUTER_COUNCIL_PROVIDER : COUNCIL_PROVIDER;
  if (env.COUNCIL_PROVIDER && !isLegacyCouncil(env)) {
    return `COUNCIL_PROVIDER unknown: use v2, ${COUNCIL_PROVIDER}, ${OPENROUTER_COUNCIL_PROVIDER} or leave unset`;
  }
  const guard = dataModeProblem(env, { provider, role: "council" });
  if (guard) return guard;
  if (onOpenRouter(env)) return openRouterConfigProblem(env, "COUNCIL_PROVIDER");
  return null;
}

// Returns an error string, or null when every member is allowed. Contributor ids are refused unless DATA_MODE=owner_any.
export function validateMembers(members, env = {}) {
  const openRouter = onOpenRouter(env);
  const allowed = openRouter ? OPENROUTER_ALLOWED_MODELS : ALLOWED_MODELS;
  for (const m of members) {
    const model = m?.model ?? councilMembers(env)[0].model;
    if (contributorRefused(env, model)) return `contributor model not allowed: ${model}`;
    if (!allowed.has(model)) return `model not allowed: ${model}`;
  }
  return null;
}

// One OpenCode session per council run, derived from the caller's run id.
const RUN_ID = /^[A-Za-z0-9_-]{1,64}$/;
export function sessionIdFor(runId) {
  if (typeof runId !== "string" || !RUN_ID.test(runId)) throw new Error("run id must match [A-Za-z0-9_-]{1,64}");
  return `illunis-council-${runId}`;
}

const SYSTEM =
  "You advise only; the user decides. Reply with JSON: " +
  '{"options":[{"title":string,"evidence":[string]}],"dissent":[string]}. ' +
  "Label findings as observations, never conclusions. Do not diagnose or give commands.";

export function buildMessages(member, question, previousSummary) {
  return [
    { role: "system", content: `${SYSTEM} Your style: ${member.style ?? "balanced"}.` },
    { role: "user", content: JSON.stringify({ question, previous_summary: previousSummary }) },
  ];
}

function parseMember(raw) {
  try {
    const o = JSON.parse(raw);
    const options = Array.isArray(o.options) ? o.options : [];
    return {
      options: options.filter((x) => typeof x?.title === "string").map((x) => ({
        title: x.title,
        evidence: Array.isArray(x.evidence) ? x.evidence.filter((e) => typeof e === "string") : [],
      })),
      dissent: Array.isArray(o.dissent) ? o.dissent.filter((d) => typeof d === "string") : [],
    };
  } catch {
    return { options: [], dissent: [] };
  }
}

// Plain-code summary of a round: no model call.
export function summarize(results) {
  const titles = [...new Set(results.flatMap((r) => r.options.map((o) => o.title)))];
  const dissent = results.flatMap((r) => r.dissent);
  return `Options so far: ${titles.join("; ") || "none"}. Dissent: ${dissent.join("; ") || "none"}.`;
}

export function mergeOptions(results) {
  const byTitle = new Map();
  for (const r of results) {
    for (const o of r.options) {
      const cur = byTitle.get(o.title) ?? { title: o.title, evidence: [] };
      cur.evidence = [...new Set([...cur.evidence, ...o.evidence])];
      byTitle.set(o.title, cur);
    }
  }
  return [...byTitle.values()];
}

export function gateOutput(options, dissent) {
  return {
    options: options.map((o) => ({ title: gateText(o.title), evidence: o.evidence.map(gateText) })),
    dissent: dissent.map(gateText),
  };
}

// Thrown before any outbound call; index.js maps it to 503 not_configured with this detail.
function notConfigured(detail) {
  const err = new Error("not configured");
  err.detail = detail;
  return err;
}

export async function runCouncil({ question, personas }, env, { fetchFn = fetch, runId } = {}) {
  const problem = councilConfigProblem(env);
  if (problem) throw notConfigured(problem);
  const defaults = councilMembers(env);
  const members = (personas?.length ? personas : defaults).map((m) => ({
    ...m,
    model: m?.model ?? defaults[0].model,
  }));
  const invalid = validateMembers(members, env);
  if (invalid) throw new Error(invalid);
  const sessionId = sessionIdFor(runId); // run id is validated on both providers
  const ask = onOpenRouter(env)
    ? (messages, model) => chatOpenRouter(messages, env, { fetchFn, model })
    : (messages, model) => chatJson(messages, env, { fetchFn, model, sessionId });
  let summary = "";
  let last = [];
  for (let round = 1; round <= ROUNDS; round++) {
    // Members run one after another: free tiers rate-limit parallel calls, and the
    // order of answers is kept for the summary.
    last = [];
    for (const m of members) {
      last.push(parseMember(await ask(buildMessages(m, question, summary), m.model)));
    }
    summary = summarize(last);
  }
  const gated = gateOutput(mergeOptions(last), [...new Set(last.flatMap((r) => r.dissent))]);
  return { ...gated, rounds: ROUNDS, advise_only: true, experimental: true };
}
