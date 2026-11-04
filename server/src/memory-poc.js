// Memory PROOF OF CONCEPT ONLY (owner decision 2026-10-24). Synthetic data only.
// Enabled per deployment with MEMORY_PROVIDER=poc_opencode_nebius; never the default.
// Under that switch, memory text goes to exactly two third-party providers:
//   - OpenCode Go (free model) to extract one canonical fact per memory on write;
//   - Nebius Token Factory embeddings for the fact on write and the query on recall.
// Unset switch: no call is made (the clients refuse before fetch). Before real users this
// path must move to self-hosted models and this switch must be removed.
// Logs carry the operation, provider name and fixed codes only, never text or keys.
import { OPENCODE_URL, SESSION_HEADER } from "./opencode.js";
import { MODELS } from "./models.js";
import { dataModeProblem } from "./data-mode.js";

export const MEMORY_POC_PROVIDER = "poc_opencode_nebius";
export const MEMORY_POC_DEFAULT_LLM = MODELS.memory_llm.model;
export const NEBIUS_EMBED_URL = "https://api.tokenfactory.nebius.com/v1/embeddings";
export const MEMORY_POC_DEFAULT_EMBED_MODEL = MODELS.memory_embed.model;
export const MEMORY_POC_TIMEOUT_MS = 15_000;
export const MEMORY_POC_MIN_SIMILARITY = 0.3;
const MAX_FACT = 300;

// Refusal reason (names variables, never values) or null when the PoC is usable.
export function memoryPocConfigProblem(env = {}) {
  if (env.MEMORY_PROVIDER !== MEMORY_POC_PROVIDER) return `MEMORY_PROVIDER is not ${MEMORY_POC_PROVIDER}`;
  const guard = dataModeProblem(env, { provider: MEMORY_POC_PROVIDER, role: "memory" });
  if (guard) return guard;
  if (!env.OPENCODE_API_KEY) return `OPENCODE_API_KEY missing for MEMORY_PROVIDER=${MEMORY_POC_PROVIDER}`;
  if (!env.NEBIUS_API_KEY) return `NEBIUS_API_KEY missing for MEMORY_PROVIDER=${MEMORY_POC_PROVIDER}`;
  return null;
}

// The PoC sends memory text to OpenCode and Nebius: DATA_MODE=synthetic only (data-mode.js).
const switchOn = (env) =>
  env?.MEMORY_PROVIDER === MEMORY_POC_PROVIDER && !dataModeProblem(env, { provider: MEMORY_POC_PROVIDER, role: "memory" });
const timeoutMs = (env, fallback) => Number(env?.MEMORY_POC_TIMEOUT_MS) > 0 ? Number(env.MEMORY_POC_TIMEOUT_MS) : fallback;

// Every client returns { value } or { code }; codes are fixed strings, never upstream text.
async function postJson(url, key, extraHeaders, body, { fetchFn, ms }) {
  let res;
  try {
    res = await fetchFn(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", ...extraHeaders },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(ms),
    });
  } catch (err) {
    return { code: err?.name === "TimeoutError" || err?.name === "AbortError" ? "timeout" : "network" };
  }
  if (!res.ok) return { code: "status" };
  try {
    return { data: await res.json() };
  } catch {
    return { code: "bad_json" };
  }
}

// OpenCode Go chat completion that returns one canonical fact for a memory.
export async function extractFact(text, env, { fetchFn = fetch, ms = timeoutMs(env, MEMORY_POC_TIMEOUT_MS) } = {}) {
  if (!switchOn(env)) return { code: "memory_provider_off" };
  if (!env.OPENCODE_API_KEY) return { code: "memory_llm_not_configured" };
  const out = await postJson(
    env.OPENCODE_BASE_URL || OPENCODE_URL,
    env.OPENCODE_API_KEY,
    { [SESSION_HEADER]: `illunis-memory-poc-${crypto.randomUUID()}` },
    {
      model: env.MEMORY_LLM_MODEL || MEMORY_POC_DEFAULT_LLM,
      messages: [
        {
          role: "system",
          content:
            "Rewrite the user's memory note as one short, self-contained factual sentence in the same language. " +
            'Do not add facts. Reply with JSON only: {"fact": "..."}',
        },
        { role: "user", content: text },
      ],
      temperature: 0,
      max_tokens: 1024,
      response_format: { type: "json_object" },
    },
    { fetchFn, ms },
  );
  if (out.code) return { code: `memory_llm_${out.code}` };
  const content = out.data?.choices?.[0]?.message?.content;
  if (typeof content !== "string") return { code: "memory_llm_empty" };
  const json = content.replace(/<think>[\s\S]*?<\/think>/g, "").match(/\{[\s\S]*\}/)?.[0];
  let fact;
  try {
    fact = JSON.parse(json ?? "").fact;
  } catch {
    return { code: "memory_llm_bad_output" };
  }
  if (typeof fact !== "string" || !fact.trim()) return { code: "memory_llm_bad_output" };
  return { value: fact.trim().slice(0, MAX_FACT) };
}

// Nebius embeddings. Sends the model id and the text only, no other metadata.
export async function embed(text, env, { fetchFn = fetch, ms = timeoutMs(env, MEMORY_POC_TIMEOUT_MS) } = {}) {
  if (!switchOn(env)) return { code: "memory_provider_off" };
  if (!env.NEBIUS_API_KEY) return { code: "memory_embed_not_configured" };
  const out = await postJson(
    env.NEBIUS_EMBED_URL || NEBIUS_EMBED_URL,
    env.NEBIUS_API_KEY,
    {},
    { model: env.MEMORY_EMBED_MODEL || MEMORY_POC_DEFAULT_EMBED_MODEL, input: text },
    { fetchFn, ms },
  );
  if (out.code) return { code: `memory_embed_${out.code}` };
  const vector = out.data?.data?.[0]?.embedding;
  if (!Array.isArray(vector) || !vector.length || !vector.every(Number.isFinite)) return { code: "memory_embed_bad_output" };
  return { value: vector };
}

export function cosine(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length || !a.length) return 0;
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na && nb ? dot / Math.sqrt(na * nb) : 0;
}

// Vectors live beside the shared in-memory store (per isolate, like the store itself),
// so the token-overlap fallback always sees every item, embedded or not.
const vectorsByStore = new WeakMap();
function vectorsFor(shared) {
  if (!vectorsByStore.has(shared)) vectorsByStore.set(shared, new Map());
  return vectorsByStore.get(shared);
}

export class PocMemoryStore {
  // shared: an InMemoryStore holding the items. The fallback recall is shared.recall.
  constructor(env, shared, { fetchFn = fetch, logger = console } = {}) {
    this.env = env;
    this.shared = shared;
    this.vectors = vectorsFor(shared);
    this.fetchFn = fetchFn;
    this.logger = logger;
  }
  log(op, code) {
    this.logger.warn("memory_poc", op, MEMORY_POC_PROVIDER, code);
  }
  // Same interface as InMemoryStore.write. Provider failures never fail the write: the item
  // is kept without a vector and recalled by token overlap.
  async write(item) {
    const stored = await this.shared.write(item);
    const opts = { fetchFn: this.fetchFn };
    const fact = await extractFact(item.text, this.env, opts);
    if (fact.code) this.log("write", fact.code);
    const vec = await embed(fact.value ?? item.text, this.env, opts);
    if (vec.code) this.log("write", vec.code);
    else {
      this.vectors.set(item.id, vec.value);
      this.log("write", "memory_poc_ok");
    }
    return stored;
  }
  // Rank embedded items by cosine similarity; items without a vector follow by token overlap.
  // A failed query embedding falls back to token overlap for everything.
  async recall({ query = "", limit = 10, now = Date.now() } = {}) {
    const n = Number.isInteger(limit) && limit > 0 ? Math.min(limit, 50) : 10;
    if (!String(query ?? "").trim()) return this.shared.recall({ query, limit: n, now });
    const q = await embed(String(query), this.env, { fetchFn: this.fetchFn });
    if (q.code) {
      this.log("recall", q.code);
      this.log("recall", "memory_poc_fallback");
      return this.shared.recall({ query, limit: n, now });
    }
    const raw = this.env.MEMORY_MIN_SIMILARITY;
    const min = raw !== undefined && raw !== "" && Number.isFinite(Number(raw)) ? Number(raw) : MEMORY_POC_MIN_SIMILARITY;
    const live = this.shared.items.filter((m) => !m.expires_at || Date.parse(m.expires_at) > now);
    const ranked = live
      .filter((m) => this.vectors.has(m.id))
      .map((m, i) => ({ m, i, score: cosine(q.value, this.vectors.get(m.id)) }))
      .filter((r) => r.score >= min)
      .sort((a, b) => b.score - a.score || b.i - a.i)
      .map((r) => r.m);
    const unembedded = (await this.shared.recall({ query, limit: this.shared.items.length || 1, now }))
      .filter((m) => !this.vectors.has(m.id));
    this.log("recall", "memory_poc_ok");
    return [...ranked, ...unembedded].slice(0, n);
  }
}
