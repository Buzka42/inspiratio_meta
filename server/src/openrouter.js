// OpenRouter chat completions (OpenAI-compatible). TEST / PoC provider only (owner decision 2026-10-25):
// synthetic data only, same rule as OpenCode Zen. Enabled per deploy with REPLY_PROVIDER=openrouter_poc
// and/or COUNCIL_PROVIDER=openrouter_poc. Required: OPENROUTER_API_KEY (Worker secret).
// Optional: OPENROUTER_BASE_URL, accepted only as https on openrouter.ai. No session header.
// Errors carry fixed codes only, never the upstream body. Refusals name variables, never values.
export const OPENROUTER_PROVIDER = "openrouter_poc";
export const OPENROUTER_HOST = "openrouter.ai";
export const OPENROUTER_URL = `https://${OPENROUTER_HOST}/api/v1/chat/completions`;
export const OPENROUTER_BASE_REFUSED = `OPENROUTER_BASE_URL refused: only https://${OPENROUTER_HOST} is allowed`;
export const OPENROUTER_KEY_MISSING = "OPENROUTER_API_KEY missing";
// Fixed attribution headers (OpenRouter app ranking). Not secrets.
export const OPENROUTER_APP_HEADERS = Object.freeze({ "HTTP-Referer": "https://illunis.app", "X-Title": "Illunis" });

// Fixed error codes thrown by chatOpenRouter.
export const OPENROUTER_ERRORS = Object.freeze({
  notConfigured: "openrouter_not_configured",
  status: "openrouter_status",
  empty: "openrouter_empty",
});

// Returns the chat completions URL, or null when the override is refused.
// The override must be plain https on the exact host: no port, credentials, query or fragment.
export function openRouterUrl(env = {}) {
  const value = env.OPENROUTER_BASE_URL;
  if (value === undefined || value === "") return OPENROUTER_URL;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (url.protocol !== "https:" || host !== OPENROUTER_HOST || url.port || url.username || url.password || url.search || url.hash) {
    return null;
  }
  const path = url.pathname.replace(/\/+$/, "");
  if (!/^\/api\/v1(\/|$)/.test(path)) return null;
  return `https://${OPENROUTER_HOST}${path.endsWith("/chat/completions") ? path : `${path}/chat/completions`}`;
}

export function openRouterConfigProblem(env = {}, context = "") {
  const where = context ? ` for ${context}=${OPENROUTER_PROVIDER}` : "";
  if (typeof env.OPENROUTER_API_KEY !== "string" || !env.OPENROUTER_API_KEY.trim()) return `${OPENROUTER_KEY_MISSING}${where}`;
  if (!openRouterUrl(env)) return OPENROUTER_BASE_REFUSED;
  return null;
}

export const openRouterHeaders = (env) => ({ Authorization: `Bearer ${env.OPENROUTER_API_KEY}`, ...OPENROUTER_APP_HEADERS });

// Same body shape as chatJson (opencode.js). Returns the message content string.
export async function chatOpenRouter(messages, env, { fetchFn = fetch, model } = {}) {
  if (openRouterConfigProblem(env)) throw new Error(OPENROUTER_ERRORS.notConfigured);
  const res = await fetchFn(openRouterUrl(env), {
    method: "POST",
    headers: { "Content-Type": "application/json", ...openRouterHeaders(env) },
    body: JSON.stringify({
      model,
      messages,
      temperature: 0.4,
      max_tokens: 2048,
      response_format: { type: "json_object" },
    }),
  });
  if (!res.ok) throw new Error(OPENROUTER_ERRORS.status);
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error(OPENROUTER_ERRORS.empty);
  }
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content) throw new Error(OPENROUTER_ERRORS.empty);
  return content;
}
