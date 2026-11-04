// Nebius Token Factory chat completions (OpenAI-compatible). TARGET provider for model calls
// (owner decision 2026-10-24). Enabled with REPLY_PROVIDER=nebius.
// Required: NEBIUS_API_KEY (Worker secret) and REPLY_LLM_MODEL (no default).
// Optional: NEBIUS_BASE_URL, accepted only as https on api.tokenfactory.nebius.com.
// Refusal reasons name variables, never their values.
import { contributorRefused, dataModeProblem } from "./data-mode.js";
import { ProviderError, chatBody, postJson, readCompletion } from "./providers/chat.js";

export const NEBIUS_PROVIDER = "nebius";
export const NEBIUS_HOST = "api.tokenfactory.nebius.com";
export const NEBIUS_BASE_URL = `https://${NEBIUS_HOST}/v1`;
export const NEBIUS_BASE_REFUSED = `NEBIUS_BASE_URL refused: only https://${NEBIUS_HOST} is allowed`;

const blank = (v) => typeof v !== "string" || !v.trim();

// The override must be plain https on the exact Nebius host under /v1: no other host, port,
// credentials, query or fragment. Returns the normalised base (no trailing slash) or null.
export function nebiusBase(env = {}) {
  if (env.NEBIUS_BASE_URL === undefined || env.NEBIUS_BASE_URL === "") return NEBIUS_BASE_URL;
  let url;
  try {
    url = new URL(env.NEBIUS_BASE_URL);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (url.protocol !== "https:" || host !== NEBIUS_HOST || url.port || url.username || url.password || url.search || url.hash) {
    return null;
  }
  const path = url.pathname.replace(/\/+$/, "");
  if (!/^\/v1(\/|$)/.test(path) || path.endsWith("/chat/completions")) return null;
  return `https://${NEBIUS_HOST}${path}`;
}

export function nebiusConfigProblem(env = {}) {
  if (blank(env.NEBIUS_API_KEY)) return `NEBIUS_API_KEY missing for REPLY_PROVIDER=${NEBIUS_PROVIDER}`;
  if (blank(env.REPLY_LLM_MODEL)) return `REPLY_LLM_MODEL missing for REPLY_PROVIDER=${NEBIUS_PROVIDER}`;
  if (!nebiusBase(env)) return NEBIUS_BASE_REFUSED;
  return null;
}

// Endpoint for callModel. Call only after nebiusConfigProblem(env) returned null.
export function nebiusEndpoint(env) {
  return {
    url: `${nebiusBase(env)}/chat/completions`,
    model: env.REPLY_LLM_MODEL.trim(),
    headers: { Authorization: `Bearer ${env.NEBIUS_API_KEY}` },
  };
}

// Council fallback on Nebius (owner decision 2026-10-25). Same key and base rules as the reply path.
// COUNCIL_NEBIUS_MODEL is required and has no default: the model id is checked against the Nebius console.
// Set the Nebius data-training opt-out before real owner data goes here.
export const COUNCIL_NEBIUS_MODEL_MISSING = "COUNCIL_NEBIUS_MODEL missing for the council fallback";

export function councilNebiusConfigProblem(env = {}) {
  if (blank(env.NEBIUS_API_KEY)) return "NEBIUS_API_KEY missing for the council fallback";
  if (blank(env.COUNCIL_NEBIUS_MODEL)) return COUNCIL_NEBIUS_MODEL_MISSING;
  if (contributorRefused(env, env.COUNCIL_NEBIUS_MODEL)) return "COUNCIL_NEBIUS_MODEL refused: contributor models train on prompts";
  if (!nebiusBase(env)) return NEBIUS_BASE_REFUSED;
  return null;
}

// Returns { content, tool_calls, model }. Throws ProviderError with fixed nebius_* codes.
export async function chatNebiusCouncil(messages, env, { fetchFn = fetch, tools, maxTokens, json, timeoutMs } = {}) {
  if (councilNebiusConfigProblem(env)) throw new ProviderError("nebius_not_configured");
  const model = env.COUNCIL_NEBIUS_MODEL.trim();
  const data = await postJson(`${nebiusBase(env)}/chat/completions`, {
    headers: { Authorization: `Bearer ${env.NEBIUS_API_KEY}` },
    body: chatBody(model, messages, { tools, maxTokens, json, reasoning: { effort: "none" } }),
    fetchFn,
    timeoutMs,
    prefix: "nebius",
  });
  return { ...readCompletion(data, "nebius"), model };
}

// Retrieval embeddings (C8, D-G): Qwen/Qwen3-Embedding-8B requested at 1024 dimensions. The Vectorize index
// stays at 1024. Codes are fixed; the response body is never kept.
export const EMBED_DIMENSIONS = 1024;
export const EMBED_TIMEOUT_MS = 15_000;

const embedCodes = (env) => {
  if (blank(env.NEBIUS_API_KEY) || blank(env.KNOWLEDGE_EMBED_MODEL) || !nebiusBase(env)) return "knowledge_not_configured";
  if (dataModeProblem(env, { provider: NEBIUS_PROVIDER, model: env.KNOWLEDGE_EMBED_MODEL.trim(), role: "knowledge" })) {
    return "knowledge_not_configured";
  }
  return null;
};

// Returns { vectors } (in input order) or { code }. Never throws.
export async function embedNebius(texts, env, { fetchFn = fetch, timeoutMs = EMBED_TIMEOUT_MS } = {}) {
  const config = embedCodes(env);
  if (config) return { code: config };
  if (!texts.length) return { vectors: [] };
  let data;
  try {
    data = await postJson(`${nebiusBase(env)}/embeddings`, {
      headers: { Authorization: `Bearer ${env.NEBIUS_API_KEY}` },
      body: { model: env.KNOWLEDGE_EMBED_MODEL.trim(), input: texts, dimensions: EMBED_DIMENSIONS },
      fetchFn,
      timeoutMs,
      prefix: "nebius",
    });
  } catch {
    return { code: "knowledge_embed_failed" };
  }
  const rows = Array.isArray(data?.data) ? data.data : null;
  const okRow = (r) => Number.isInteger(r?.index) && Array.isArray(r?.embedding) && r.embedding.length === EMBED_DIMENSIONS && r.embedding.every(Number.isFinite);
  if (!rows || rows.length !== texts.length || !rows.every(okRow)) return { code: "knowledge_bad_embedding" };
  const vectors = new Array(texts.length);
  for (const r of rows) {
    if (r.index < 0 || r.index >= texts.length || vectors[r.index]) return { code: "knowledge_bad_embedding" };
    vectors[r.index] = r.embedding;
  }
  return { vectors };
}
