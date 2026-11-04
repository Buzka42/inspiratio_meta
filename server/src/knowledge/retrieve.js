// Knowledge retrieval over Cloudflare Vectorize. Query embeddings come from Nebius when
// KNOWLEDGE_EMBED_PROVIDER=nebius (C8, D-G), otherwise from Workers AI (the original build, untagged vectors).
// Bindings (wrangler.jsonc): AI (Workers AI, Workers AI path only) and KNOWLEDGE (Vectorize index "illunis-knowledge").
// One namespace per expert bank; metadata {expert, source_id, title, url, licence, text, embed} (embed = provider tag).
//
// Verified in the Cloudflare docs on 2026-10-25:
// - developers.cloudflare.com/vectorize/platform/limits: max 1536 dimensions (float32), 10 KiB metadata per
//   vector, topK 50 with metadata, 1000 vectors per Workers upsert, 50,000 namespaces per index (paid).
// - developers.cloudflare.com/workers-ai/models/bge-m3: model id "@cf/baai/bge-m3", input {text: string | string[]}.
// - developers.cloudflare.com/vectorize/reference/client-api: query(vector, {topK, returnMetadata: "all"}),
//   upsert([{id, values, namespace, metadata}]).
// NOT stated on the Cloudflare page: the bge-m3 output dimension. 1024 comes from the model card (BAAI);
// the code checks the length at runtime, so a different size fails closed with knowledge_bad_embedding.
// The output field "data" (number[][]) follows the other Workers AI embedding models [unverified for bge-m3].
// Create the index with: wrangler vectorize create illunis-knowledge --dimensions=1024 --metric=cosine

import { embedNebius, EMBED_DIMENSIONS, EMBED_TIMEOUT_MS, NEBIUS_PROVIDER } from "../nebius.js";

export const EMBED_MODEL = "@cf/baai/bge-m3";
export const EMBED_DIMS = EMBED_DIMENSIONS;
export const INDEX_NAME = "illunis-knowledge";
export const DEFAULT_K = 5;
const MAX_K = 20;
const MAX_QUERY = 2000;

// The tag stored in metadata.embed. The untagged Workers AI build is "", so existing vectors stay valid
// on the Workers AI path and are dropped on the Nebius path. null means an unknown provider.
export function embedTag(env = {}) {
  const provider = env.KNOWLEDGE_EMBED_PROVIDER;
  if (provider === undefined || provider === "") return "";
  if (provider === NEBIUS_PROVIDER) return `${NEBIUS_PROVIDER}:${String(env.KNOWLEDGE_EMBED_MODEL ?? "").trim()}`;
  return null;
}

// Returns { vectors, tag } or { code }. Fixed codes only.
// timeoutMs (optional): lowers the Nebius embed timeout, so a caller with a deadline is not held past it.
export async function embedTexts(texts, env, { fetchFn = fetch, timeoutMs } = {}) {
  const tag = embedTag(env);
  if (tag === null) return { code: "knowledge_not_configured" };
  if (tag !== "") {
    const cap = timeoutMs > 0 ? Math.min(timeoutMs, EMBED_TIMEOUT_MS) : EMBED_TIMEOUT_MS;
    const out = await embedNebius(texts, env, { fetchFn, timeoutMs: cap });
    return out.code ? out : { vectors: out.vectors, tag };
  }
  if (!env?.AI?.run) return { code: "knowledge_not_bound" };
  let out;
  try {
    out = await env.AI.run(EMBED_MODEL, { text: texts });
  } catch {
    return { code: "knowledge_embed_failed" };
  }
  const vectors = out?.data;
  const okVec = (v) => Array.isArray(v) && v.length === EMBED_DIMS && v.every(Number.isFinite);
  if (!Array.isArray(vectors) || vectors.length !== texts.length || !vectors.every(okVec)) return { code: "knowledge_bad_embedding" };
  return { vectors, tag };
}

const str = (v, max) => (typeof v === "string" ? v.slice(0, max) : "");

// Returns { passages: [{source_id, part, title, url, licence, text, score}], code } (part: the chunk index stored at ingest, only when stored). Never throws: no bank means no passages.
// timeoutMs (optional): passed to the query embedding (the council relay derives it from its run deadline).
export async function retrieve(expert, query, env, { k = DEFAULT_K, fetchFn = fetch, timeoutMs } = {}) {
  const q = String(query ?? "").trim().slice(0, MAX_QUERY);
  if (!q || typeof expert !== "string") return { passages: [], code: "knowledge_bad_query" };
  if (!env?.KNOWLEDGE?.query) return { passages: [], code: "knowledge_not_bound" };
  const emb = await embedTexts([q], env, { fetchFn, timeoutMs });
  if (emb.code) return { passages: [], code: emb.code };
  let res;
  try {
    res = await env.KNOWLEDGE.query(emb.vectors[0], {
      topK: Math.min(Math.max(1, k | 0), MAX_K),
      namespace: expert,
      returnMetadata: "all",
    });
  } catch {
    return { passages: [], code: "knowledge_query_failed" };
  }
  // A vector embedded with another model is not comparable: drop it (untagged vectors count as the Workers AI tag "").
  const tag = emb.tag;
  const all = (Array.isArray(res?.matches) ? res.matches : [])
    .map((m) => ({ meta: m?.metadata ?? {}, score: Number(m?.score) || 0 }))
    // A namespace is per expert; the metadata check guards against a mis-ingested vector.
    .filter(({ meta }) => meta.expert === expert && typeof meta.source_id === "string" && meta.source_id);
  const mismatch = all.some(({ meta }) => (typeof meta.embed === "string" ? meta.embed : "") !== tag);
  const passages = all
    .filter(({ meta }) => (typeof meta.embed === "string" ? meta.embed : "") === tag)
    .map(({ meta, score }) => ({
      source_id: str(meta.source_id, 100),
      ...(Number.isInteger(meta.part) && meta.part >= 0 && { part: meta.part }),
      title: str(meta.title, 200),
      url: /^https:\/\//i.test(meta.url ?? "") ? str(meta.url, 500) : "",
      licence: str(meta.licence, 100),
      text: str(meta.text, 4000),
      score,
    }));
  return { passages, code: mismatch ? "knowledge_embed_mismatch" : null };
}
