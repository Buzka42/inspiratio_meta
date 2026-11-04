// Meta Model API client (docs/RESEARCH.md (section 1)). OpenAI-compatible Chat Completions, plus the
// Responses API for the built-in `web_search` tool. Base https://api.meta.ai/v1 (Meta's developer blog).
// Secret META_API_KEY. Optional META_BASE_URL, accepted only as https on api.meta.ai under /v1.
// META_MODEL is required when META_API_KEY is set: no model id lives in code (D-E). Any *-contributor model is
// refused on every call under every DATA_MODE (D2: they train on prompts). The Nebius build runs with META_API_KEY unset (D-F).
// Fixed error codes only; nothing here logs or returns prompts, keys or upstream bodies.
// Verified live (muse-spark-1.3, 2 Nov 2026): Bearer auth, `url_citation` annotations on Responses output_text,
// hidden reasoning spending max_tokens (hence the role floors), web_search needing ~3000 output tokens.
// [unverified] 403 as the region refusal.
import { isContributorModel } from "../data-mode.js";
import { ProviderError, chatBody, pinnedBase, postJson, readCompletion } from "./chat.js";

export const META_PROVIDER = "meta";
export const META_HOST = "api.meta.ai";
export const META_BASE_URL = `https://${META_HOST}/v1`;
export const META_BASE_REFUSED = `META_BASE_URL refused: only https://${META_HOST} is allowed`;
export const META_CONTRIBUTOR_REFUSED = "META_MODEL refused: contributor models train on prompts";
export const META_MODEL_MISSING = "META_MODEL missing";

const blank = (v) => typeof v !== "string" || !v.trim();
export const metaBase = (env = {}) => pinnedBase(env.META_BASE_URL, META_HOST, META_BASE_URL);
export const metaModel = (env = {}) => (blank(env.META_MODEL) ? null : env.META_MODEL.trim());

export function metaConfigProblem(env = {}) {
  if (blank(env.META_API_KEY)) return "META_API_KEY missing";
  if (!metaModel(env)) return META_MODEL_MISSING;
  if (!metaBase(env)) return META_BASE_REFUSED;
  if (isContributorModel(metaModel(env))) return META_CONTRIBUTOR_REFUSED;
  return null;
}

function ready(env, model) {
  if (isContributorModel(model)) throw new ProviderError("meta_contributor_refused");
  if (metaConfigProblem(env)) throw new ProviderError("meta_not_configured", { fallback: true });
}

const headers = (env) => ({ Authorization: `Bearer ${env.META_API_KEY}` });

// Hidden reasoning spends max_tokens before any content, so each role gets a floor (unknown roles: 2000).
export const META_TOKEN_FLOORS = Object.freeze({ relay: 2000, final: 3000, plan: 1500, expert: 2000, repair: 2000, summary: 1500, web: 3000, reply: 2000 });
export const metaMaxTokens = (role, maxTokens) => Math.max(Number(maxTokens) || 0, Object.hasOwn(META_TOKEN_FLOORS, role) ? META_TOKEN_FLOORS[role] : 2000);

// Muse accepts reasoning_effort minimal|low|medium|high|xhigh|max ("none" is rejected). Verified live 2 Nov 2026:
// minimal cuts hidden reasoning ~4x, so the short structured roles ask for it; tool, final and repair turns keep the default.
export const META_MINIMAL_EFFORT_ROLES = new Set(["plan", "expert", "summary"]);

// Returns { content, tool_calls, model }.
export async function chatMeta(messages, env, { fetchFn = fetch, model = metaModel(env), tools, maxTokens, json, timeoutMs, role } = {}) {
  ready(env, model);
  const body = chatBody(model, messages, { tools, maxTokens: metaMaxTokens(role, maxTokens), json });
  if (META_MINIMAL_EFFORT_ROLES.has(role)) body.reasoning_effort = "minimal";
  const data = await postJson(`${metaBase(env)}/chat/completions`, {
    headers: headers(env),
    body,
    fetchFn,
    timeoutMs,
    prefix: "meta",
  });
  return { ...readCompletion(data, "meta"), model };
}

// Responses API with the server-side web_search tool. Returns { text, results: [{title, url}], complete: true }.
export async function webSearchMeta(query, env, { fetchFn = fetch, model = metaModel(env), timeoutMs } = {}) {
  ready(env, model);
  const data = await postJson(`${metaBase(env)}/responses`, {
    headers: headers(env),
    body: {
      model,
      input: `Search the web for reputable public health guidance (WHO, NHS, CDC, peer-reviewed reviews) on: ${query}. ` +
        "Summarise the findings in three short neutral sentences.",
      tools: [{ type: "web_search" }],
      max_output_tokens: META_TOKEN_FLOORS.web,
    },
    fetchFn,
    timeoutMs,
    prefix: "meta",
  });
  return readResponses(data);
}

// OpenAI Responses shape: output[] items of type "message" with content[] of type "output_text", each with
// annotations[] of type "url_citation" {url, title}. An incomplete response (narration only) is an error. Only the
// final message counts; when it cites, only its cited parts form the text. Results are cited https URLs (max 5);
// with no citation, results is [] and web.js decides on Tavily.
export function readResponses(data) {
  if (data?.status === "incomplete" || data?.incomplete_details?.reason === "max_output_tokens") {
    throw new ProviderError("meta_incomplete", { fallback: true });
  }
  const final = (Array.isArray(data?.output) ? data.output : []).filter((o) => o?.type === "message").at(-1);
  const parts = (Array.isArray(final?.content) ? final.content : []).filter((c) => c?.type === "output_text" && typeof c.text === "string");
  const citesOf = (c) => (Array.isArray(c.annotations) ? c.annotations : []).filter((a) => a?.type === "url_citation" && typeof a.url === "string");
  const cited = parts.filter((c) => citesOf(c).length);
  const text = (cited.length ? cited : parts).map((c) => c.text.trim()).filter(Boolean).join(" ");
  const seen = new Set();
  const results = [];
  for (const a of cited.flatMap(citesOf)) {
    if (!/^https:\/\//i.test(a.url) || seen.has(a.url)) continue;
    seen.add(a.url);
    results.push({ title: typeof a.title === "string" && a.title ? a.title.slice(0, 200) : a.url, url: a.url });
  }
  if (!text) throw new ProviderError("meta_empty", { fallback: true });
  return { text, results: results.slice(0, 5), complete: true };
}
