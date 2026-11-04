// Tavily web search client (contract C2). Secret TAVILY_API_KEY. The URL is fixed: no base-URL override.
// Refused under DATA_MODE=owner_real (queries can carry the owner's data). Errors are fixed codes in a
// ProviderError; the key and upstream text never reach an error, a log or a return value.
// [UNVERIFIED: the Bearer header form and the 432/433 rate-limit codes come from the planner; confirm against
// Tavily's docs before the live check.]
import { OWNER_REAL, dataMode, dataModeProblem } from "../data-mode.js";
import { ProviderError } from "./chat.js";

export const TAVILY_URL = "https://api.tavily.com/search";
export const TAVILY_PROVIDER = "tavily";
const MAX_QUERY = 400;
const MAX_TITLE = 200;
const MAX_CONTENT = 1500;

const blank = (v) => typeof v !== "string" || !v.trim();

// Returns a refusal reason (names variables, never values) or null.
export function tavilyConfigProblem(env = {}, role = "search") {
  if (blank(env.TAVILY_API_KEY)) return "TAVILY_API_KEY missing";
  if (dataMode(env) === OWNER_REAL) return `tavily refused for ${role} under DATA_MODE=${OWNER_REAL}`;
  return dataModeProblem(env, { role });
}

// Keeps only https URLs, with bounded title and content.
function readResults(list) {
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const r of list) {
    if (!r || typeof r !== "object") continue;
    if (typeof r.url !== "string" || !/^https:\/\//i.test(r.url)) continue;
    out.push({
      title: typeof r.title === "string" && r.title.trim() ? r.title.trim().slice(0, MAX_TITLE) : r.url,
      url: r.url,
      content: typeof r.content === "string" ? r.content.slice(0, MAX_CONTENT) : "",
    });
  }
  return out;
}

// Maps a non-OK HTTP status to its fixed code.
function statusCode(status) {
  if (status === 401 || status === 403) return "tavily_unauthorized";
  if (status === 429 || status === 432 || status === 433) return "tavily_rate_limited";
  return status >= 500 ? "tavily_status_5xx" : "tavily_status_4xx";
}

// Returns { answer, results: [{title, url, content}] }. Throws ProviderError with one fixed code.
// excludeDomains: optional list sent as Tavily's exclude_domains (the council leaves out forums and video sites).
export async function searchTavily(query, env = {}, { fetchFn = fetch, timeoutMs = 8000, maxResults = 5, role = "search", excludeDomains } = {}) {
  const problem = tavilyConfigProblem(env, role);
  if (problem) throw new ProviderError(problem.includes("refused") ? "tavily_refused" : "tavily_not_configured");
  let res;
  try {
    res = await fetchFn(TAVILY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.TAVILY_API_KEY}` },
      body: JSON.stringify({
        query: String(query ?? "").slice(0, MAX_QUERY),
        search_depth: "basic",
        max_results: Math.min(Math.max(1, Math.trunc(maxResults)), 10),
        include_answer: true,
        include_raw_content: false,
        ...(Array.isArray(excludeDomains) && excludeDomains.length ? { exclude_domains: [...excludeDomains] } : {}),
      }),
      signal: AbortSignal.timeout(Math.max(1, timeoutMs)),
    });
  } catch (err) {
    const timeout = err?.name === "TimeoutError" || err?.name === "AbortError";
    throw new ProviderError(timeout ? "tavily_timeout" : "tavily_network", { fallback: true });
  }
  if (!res.ok) {
    const code = statusCode(res.status);
    const retry = code === "tavily_rate_limited" || code === "tavily_status_5xx";
    throw new ProviderError(code, { status: res.status, fallback: retry });
  }
  let data;
  try {
    data = await res.json();
  } catch (err) {
    const timeout = err?.name === "TimeoutError" || err?.name === "AbortError";
    throw new ProviderError(timeout ? "tavily_timeout" : "tavily_bad_response", { fallback: true });
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) throw new ProviderError("tavily_bad_response", { fallback: true });
  return {
    answer: typeof data.answer === "string" ? data.answer.trim() : "",
    results: readResults(data.results),
  };
}
