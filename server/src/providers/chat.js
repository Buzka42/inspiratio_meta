// Shared OpenAI-compatible POST for the council providers (Meta, Nebius).
// Throws ProviderError with a fixed code; never upstream text, never the request body.
// Codes: <p>_timeout, <p>_network, <p>_status_5xx, <p>_status_4xx, <p>_region, <p>_bad_json, <p>_empty.
// Meta only: meta_auth (401), meta_forbidden (403), meta_region (451), meta_rate_limited (429), meta_truncated.
// Baseten only: baseten_auth (401), baseten_forbidden (403), baseten_rate_limited (429), baseten_overloaded (529), baseten_truncated.

export class ProviderError extends Error {
  constructor(code, { status = null, fallback = false, finish = null, limit = null } = {}) {
    super(code);
    this.code = code;
    this.status = status;
    this.fallback = fallback; // true: another provider may be tried
    this.finish = finish; // one of FINISH_REASONS or null, for fixed-code logs
    this.limit = limit; // 429 only: one of "per_day", "per_min", "upstream", "other"
  }
}

// finish_reason values kept for logs; anything else becomes "other" (never upstream text).
const FINISH_REASONS = new Set(["stop", "length", "tool_calls", "content_filter", "error"]);
// Classifies a 429 body into a fixed code; the body itself is never kept.
export function rateLimitKind(text) {
  const t = String(text ?? "").toLowerCase();
  if (/per[-_ ]?day/.test(t)) return "per_day";
  if (/upstream/.test(t)) return "upstream";
  if (/per[-_ ]?min/.test(t)) return "per_min";
  return "other";
}
const finishOf = (choice) => (choice?.finish_reason == null ? null : FINISH_REASONS.has(choice.finish_reason) ? choice.finish_reason : "other");

// Region refusals: 451 always; 403 is how the Meta preview answers outside the US [unverified].
const isRegion = (status) => status === 451 || status === 403;

// Meta statuses get their own codes. 401 is a key problem, so it never falls back; 403 and 451 are kept apart.
const META_STATUS = { 401: ["meta_auth", false], 403: ["meta_forbidden", true], 451: ["meta_region", true] };
const BASETEN_STATUS = { 401: ["baseten_auth", false], 403: ["baseten_forbidden", true], 529: ["baseten_overloaded", true] };
async function basetenStatusError({ status }) {
  const [code, fallback] = status === 429 ? ["baseten_rate_limited", true] : BASETEN_STATUS[status] ?? (status >= 500 ? ["baseten_status_5xx", true] : ["baseten_status_4xx", false]);
  return new ProviderError(code, { status, fallback });
}
async function metaStatusError(res) {
  const { status } = res;
  if (status === 429) return new ProviderError("meta_rate_limited", { status, fallback: true, limit: rateLimitKind(await res.text().catch(() => "")) });
  const [code, fallback] = META_STATUS[status] ?? (status >= 500 ? ["meta_status_5xx", true] : ["meta_status_4xx", false]);
  return new ProviderError(code, { status, fallback });
}

export async function postJson(url, { headers = {}, body, fetchFn = fetch, timeoutMs = 20_000, prefix }) {
  let res;
  try {
    res = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(Math.max(1, timeoutMs)),
    });
  } catch (err) {
    const timeout = err?.name === "TimeoutError" || err?.name === "AbortError";
    throw new ProviderError(`${prefix}_${timeout ? "timeout" : "network"}`, { fallback: true });
  }
  if (!res.ok) {
    if (prefix === "meta") throw await metaStatusError(res);
    if (prefix === "baseten") throw await basetenStatusError(res);
    if (isRegion(res.status)) throw new ProviderError(`${prefix}_region`, { status: res.status, fallback: true });
    const server = res.status >= 500;
    if (res.status === 429) {
      const limit = rateLimitKind(await res.text().catch(() => ""));
      throw new ProviderError(`${prefix}_status_4xx`, { status: 429, fallback: true, limit });
    }
    throw new ProviderError(`${prefix}_status_${server ? "5xx" : "4xx"}`, { status: res.status, fallback: server || res.status === 429 });
  }
  // Some gateways (OpenRouter) send 200 headers at once and the body later, so the timeout can fire mid-body.
  try {
    return await res.json();
  } catch (err) {
    const timeout = err?.name === "TimeoutError" || err?.name === "AbortError";
    throw new ProviderError(`${prefix}_${timeout ? "timeout" : "bad_json"}`, { fallback: true });
  }
}

// Drops reasoning a model left in content: closed <think> blocks, text before a stray </think>, and an
// unclosed <think> to the end (a reply cut off while still thinking has no answer).
export function stripThinking(s) {
  let out = String(s ?? "").replace(/<think>[\s\S]*?<\/think>/gi, "");
  const close = out.toLowerCase().lastIndexOf("</think>");
  if (close >= 0) out = out.slice(close + "</think>".length);
  const open = out.toLowerCase().indexOf("<think>");
  if (open >= 0) out = out.slice(0, open);
  return out.trim();
}

// Reads one chat completion: { content, tool_calls }. Tool calls keep id, name and the raw arguments string.
// A separate reasoning field (OpenRouter) is never read as content.
export function readCompletion(data, prefix) {
  const choice = data?.choices?.[0];
  const msg = choice?.message;
  const content = typeof msg?.content === "string" ? stripThinking(msg.content) : "";
  const tool_calls = Array.isArray(msg?.tool_calls)
    ? msg.tool_calls
        .filter((c) => typeof c?.function?.name === "string")
        .map((c) => ({ id: String(c.id ?? ""), name: c.function.name, arguments: String(c.function.arguments ?? "{}") }))
    : [];
  if (!content && !tool_calls.length) throw new ProviderError(`${prefix}_empty`, { fallback: true, finish: finishOf(choice) });
  // Muse spends max_tokens on hidden reasoning, so a "length" reply with content is still a cut-off answer.
  if ((prefix === "meta" || prefix === "baseten") && choice?.finish_reason === "length") throw new ProviderError(`${prefix}_truncated`, { fallback: true, finish: "length" });
  return { content, tool_calls };
}

// Chat Completions body. JSON mode only when no tools are offered (some servers reject both together).
// reasoning: an OpenRouter reasoning object (e.g. { effort: "none" }), sent only when given.
export function chatBody(model, messages, { tools, maxTokens = 1024, temperature = 0.3, json = false, reasoning } = {}) {
  return {
    model,
    messages,
    temperature,
    max_tokens: maxTokens,
    ...(tools?.length ? { tools, tool_choice: "auto" } : {}),
    ...(json && !tools?.length ? { response_format: { type: "json_object" } } : {}),
    ...(reasoning ? { reasoning } : {}),
  };
}

// Plain https on one exact host under /v1: no port, credentials, query or fragment.
// Returns the base without a trailing slash, or null when refused.
export function pinnedBase(value, host, fallback) {
  if (value === undefined || value === "") return fallback;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  const h = url.hostname.toLowerCase().replace(/\.$/, "");
  if (url.protocol !== "https:" || h !== host || url.port || url.username || url.password || url.search || url.hash) return null;
  const path = url.pathname.replace(/\/+$/, "");
  if (!/^\/v1(\/|$)/.test(path) || /\/(chat\/completions|responses)$/.test(path)) return null;
  return `https://${host}${path}`;
}
