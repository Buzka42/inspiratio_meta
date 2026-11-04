// POST /log/parse (plan B6): typed text to one structured log entry. The model only extracts, in JSON mode on
// Nebius; logs/schemas.js validates. Crisis text gets the fixed referral before any check or call.
// Model: LOG_LLM_MODEL, else REPLY_LLM_MODEL (no default). Key: NEBIUS_API_KEY. Base: NEBIUS_BASE_URL rules.
// Nothing here logs; results carry fixed codes only, never the text or the model output.
import { REFERRAL_TEXT, isCrisis } from "../safety.js";
import { contributorRefused, dataModeProblem } from "../data-mode.js";
import { NEBIUS_BASE_REFUSED, NEBIUS_PROVIDER, nebiusBase } from "../nebius.js";
import { notConfigured } from "../council/provider.js";
import { chatBody, postJson, readCompletion } from "../providers/chat.js";
import { EFFORT_PREFS, LOG_KINDS, NEEDS_CHOICE, envelope, validateEntry } from "./schemas.js";
import { searchTavily, tavilyConfigProblem } from "../providers/tavily.js";
import { estimateFood, extractPer100, foodCheck } from "./food-check.js";

export const MAX_LOG_TEXT = 1000;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const blank = (v) => typeof v !== "string" || !v.trim();

export const logModel = (env = {}) => (blank(env.LOG_LLM_MODEL) ? (blank(env.REPLY_LLM_MODEL) ? null : env.REPLY_LLM_MODEL.trim()) : env.LOG_LLM_MODEL.trim());

// Returns a refusal reason (names variables, never values) or null.
export function logConfigProblem(env = {}) {
  if (blank(env.NEBIUS_API_KEY)) return "NEBIUS_API_KEY missing for /log/parse";
  const model = logModel(env);
  if (!model) return "LOG_LLM_MODEL or REPLY_LLM_MODEL missing for /log/parse";
  if (!nebiusBase(env)) return NEBIUS_BASE_REFUSED;
  if (contributorRefused(env, model)) return "log model refused: contributor models train on prompts";
  return dataModeProblem(env, { provider: NEBIUS_PROVIDER, model, role: "log" });
}

// Default model call: Nebius chat completions in JSON mode. Returns { content }. Throws ProviderError (nebius_*).
export async function callLogModel(messages, env, { fetchFn = fetch, timeoutMs = 15_000 } = {}) {
  const data = await postJson(`${nebiusBase(env)}/chat/completions`, {
    headers: { Authorization: `Bearer ${env.NEBIUS_API_KEY}` },
    body: chatBody(logModel(env), messages, { json: true, maxTokens: 4096, temperature: 0, reasoning: { effort: "none" } }),
    fetchFn,
    timeoutMs,
    prefix: "nebius",
  });
  return readCompletion(data, "nebius");
}

// What the model returns per kind. Durations are parts as the user stated them; plain code converts them.
const DURATION = '{"h"?:int,"min"?:int,"s"?:number}';
const SHAPES = {
  food: '{"meal"?:"breakfast"|"lunch"|"dinner"|"snack","items":[{"name":string,"quantity"?:number,"unit"?:"g"|"ml"|"piece"|"serving","kcal"?:number}]}. Give kcal only if the user stated calories.',
  activity: `{"type":string,"duration"?:${DURATION},"distance"?:{"value":number,"unit":"km"|"mi"|"m"},"steps"?:int}`,
  strength: '{"exercises":[{"name":string,"sets":[{"count"?:int,"reps":int,"weight":number|null,"unit":"kg"|"lb"|null,EFFORT}]}]}. ' +
    'Use count for identical sets ("3x10 at 80 kg" is one set with count 3, reps 10, weight 80). weight null means bodyweight.',
  run: `{"distance":{"value":number,"unit":"km"|"mi"},"duration":${DURATION},"splits":[{"distance"?:number|null,"duration":${DURATION}}]}. ` +
    "List splits in order; give a split distance only if the user stated it.",
  cardio: `{"type":string,"duration"?:${DURATION},"hr_avg"?:int,"hr_max"?:int,"kcal"?:number}`,
};
const EFFORT = {
  none: "",
  rir: '"effort"?:{"scale":"rir","value":number} only if the user stated reps in reserve',
  rpe: '"effort"?:{"scale":"rpe","value":number} only if the user stated an RPE',
};

export function logPrompt(kind, text, effort) {
  const shape = SHAPES[kind].replace(",EFFORT", EFFORT[effort] ? `,${EFFORT[effort]}` : "");
  return [
    {
      role: "system",
      content:
        `Extract one ${kind} log entry from the user's text. Reply with JSON only, in this shape: ${shape} ` +
        "Copy numbers exactly as the user wrote them. Never compute, convert, estimate or add a number the user did " +
        "not write; leave an optional field out when it was not stated. Do not add advice or comments.",
    },
    { role: "user", content: JSON.stringify({ kind, text }) },
  ];
}

const parseJson = (s) => {
  try {
    const o = JSON.parse(String(s ?? "").trim().replace(/^```(?:json)?\s*|\s*```$/g, ""));
    return o && typeof o === "object" && !Array.isArray(o) ? o : null;
  } catch {
    return null;
  }
};

// Food check (C6): runs only for food with a kcal figure, and only when Tavily is configured and allowed.
// A mismatch returns ok:false with the choice (nothing is saved until the user picks); otherwise ok:true + check.
async function checkedFood(kind, date, entry, searchFn, extractFn) {
  const rows = await foodCheck(entry, searchFn, extractFn);
  const mismatches = rows.filter((r) => r.status === "mismatch");
  if (mismatches.length) {
    return {
      status: 200,
      body: { ok: false, code: NEEDS_CHOICE, pending: envelope(kind, date, entry), needs_choice: mismatches.map(({ status, ...r }) => r) },
      code: "food_needs_choice",
    };
  }
  const check = rows.map(({ item_index, status, source_url, source_title }) => ({ item_index, status, ...(source_url ? { source_url, source_title } : {}) }));
  const code = rows.some((r) => r.status === "unverified") ? "food_unverified" : "food_checked";
  return { status: 200, body: { ok: true, ...envelope(kind, date, entry), check }, code };
}

// Returns { status, body, code }. code is a fixed string for the route log, or null on success.
// deps: callFn (the model call, injectable for tests), fetchFn, now, searchFn (food check search, injectable).
export async function runLogParse(body, env = {}, deps = {}) {
  const { callFn = callLogModel, fetchFn = fetch, now = Date.now, searchFn } = deps;
  const badReq = (detail) => ({ status: 400, body: { error: "bad_request", detail }, code: "bad_request" });
  if (!LOG_KINDS.includes(body?.kind)) return badReq(`kind must be one of ${LOG_KINDS.join(", ")}`);
  if (blank(body.text)) return badReq("text required");
  if (body.text.length > MAX_LOG_TEXT) return badReq("text too long");
  if (body.prefs !== undefined && (body.prefs === null || typeof body.prefs !== "object" || Array.isArray(body.prefs))) return badReq("prefs must be object");
  const effort = body.prefs?.effort ?? "none";
  if (!EFFORT_PREFS.includes(effort)) return badReq(`prefs.effort must be one of ${EFFORT_PREFS.join(", ")}`);
  if (body.date !== undefined && (typeof body.date !== "string" || !DATE_RE.test(body.date) || Number.isNaN(Date.parse(body.date)))) {
    return badReq("date must be yyyy-mm-dd");
  }

  // Crisis first: the fixed referral, no config check and no model call.
  if (isCrisis(body.text)) return { status: 200, body: { ok: false, code: "crisis", crisis: true, text: REFERRAL_TEXT }, code: "crisis" };

  const problem = logConfigProblem(env);
  if (problem) throw notConfigured(problem);

  const { kind, text } = body;
  const out = await callFn(logPrompt(kind, text, effort), env, { fetchFn });
  const parsed = parseJson(out?.content);
  if (!parsed) return { status: 422, body: { ok: false, code: "bad_json" }, code: "bad_json" };
  const result = validateEntry(kind, parsed, text, { effort });
  if (!result.ok) return { status: 422, body: { ok: false, code: result.code }, code: result.code };
  // date: the phone's local day when sent, else the server's UTC day.
  const date = body.date ?? new Date(now()).toISOString().slice(0, 10);
  const tavilyOn = !tavilyConfigProblem(env, "log");
  const search = searchFn ?? ((q) => searchTavily(q, env, { fetchFn, timeoutMs: 8000, maxResults: 3, role: "log" }));
  // Foods without a stated figure get a labelled estimate from the same search (estimateFood), then the stated
  // figures are checked as before.
  // Gram and millilitre figures are read by the model and checked against the snippet text (extractPer100).
  const extractFn = (item, results) => extractPer100(item, results, (messages) => callFn(messages, env, { fetchFn }));
  if (kind === "food" && tavilyOn) await estimateFood(result.entry, search, extractFn);
  const hasKcal = kind === "food" && result.entry.items.some((it) => it.kcal !== undefined && !it.kcal_estimated);
  if (hasKcal && tavilyOn) return checkedFood(kind, date, result.entry, search, extractFn);
  return { status: 200, body: { ok: true, ...envelope(kind, date, result.entry) }, code: null };
}
