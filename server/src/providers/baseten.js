// Baseten Model API client (Muse Spark Open). OpenAI-compatible Chat Completions on inference.baseten.co, Bearer auth.
// Secret BASETEN_API_KEY. BASETEN_MODEL is a plain env var (default below; a model id is not a secret). Optional
// BASETEN_BASE_URL, accepted only as https on inference.baseten.co under /v1. Stream is not used.
// Never sends response_format (JSON goes through the prompt) or tool_choice (unverified for this model: a reply
// without tool calls is the normal fallback path). Reasoning is always on and spends max_tokens; it comes back in
// message.reasoning_content, which readCompletion ignores (content only). "none" is never sent.
// Fixed error codes only (see providers/chat.js); nothing here logs or returns prompts, keys or upstream bodies.
import { isContributorModel } from "../data-mode.js";
import { ProviderError, chatBody, pinnedBase, postJson, readCompletion } from "./chat.js";

export const BASETEN_PROVIDER = "baseten";
export const BASETEN_HOST = "inference.baseten.co";
export const BASETEN_BASE_URL = `https://${BASETEN_HOST}/v1`;
export const BASETEN_DEFAULT_MODEL = "meta-models/muse-spark-open-1026"; // hackathon id (participant guide, Baseten section)
export const BASETEN_BASE_REFUSED = `BASETEN_BASE_URL refused: only https://${BASETEN_HOST} is allowed`;
export const BASETEN_CONTRIBUTOR_REFUSED = "BASETEN_MODEL refused: contributor models train on prompts";

const blank = (v) => typeof v !== "string" || !v.trim();
export const basetenBase = (env = {}) => pinnedBase(env.BASETEN_BASE_URL, BASETEN_HOST, BASETEN_BASE_URL);
export const basetenModel = (env = {}) => (blank(env.BASETEN_MODEL) ? BASETEN_DEFAULT_MODEL : env.BASETEN_MODEL.trim());

export function basetenConfigProblem(env = {}) {
  if (blank(env.BASETEN_API_KEY)) return "BASETEN_API_KEY missing";
  if (!basetenBase(env)) return BASETEN_BASE_REFUSED;
  if (isContributorModel(basetenModel(env))) return BASETEN_CONTRIBUTOR_REFUSED;
  return null;
}

// Reasoning spends max_tokens before any content, so each role gets a floor (unknown roles: 2000).
export const BASETEN_TOKEN_FLOORS = Object.freeze({ relay: 2000, final: 3000, plan: 1500, expert: 2000, repair: 2000, summary: 1500, web: 3000, reply: 2000 });
export const basetenMaxTokens = (role, maxTokens) =>
  Math.max(Number(maxTokens) || 0, Object.hasOwn(BASETEN_TOKEN_FLOORS, role) ? BASETEN_TOKEN_FLOORS[role] : 2000);

export const BASETEN_LOW_EFFORT_ROLES = new Set(["plan", "expert", "summary"]);
export const basetenEffort = (role) => (BASETEN_LOW_EFFORT_ROLES.has(role) ? "low" : "medium");

// Returns { content, tool_calls, model }.
export async function chatBaseten(messages, env, { fetchFn = fetch, model = basetenModel(env), tools, maxTokens, timeoutMs, role } = {}) {
  if (isContributorModel(model)) throw new ProviderError("baseten_contributor_refused");
  if (basetenConfigProblem(env)) throw new ProviderError("baseten_not_configured", { fallback: true });
  const body = chatBody(model, messages, { tools, maxTokens: basetenMaxTokens(role, maxTokens) });
  delete body.tool_choice;
  body.reasoning_effort = basetenEffort(role);
  const data = await postJson(`${basetenBase(env)}/chat/completions`, {
    headers: { Authorization: `Bearer ${env.BASETEN_API_KEY}` },
    body,
    fetchFn,
    timeoutMs,
    prefix: "baseten",
  });
  return { ...readCompletion(data, "baseten"), model };
}
