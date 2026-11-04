// MemoryStore interface: write(item) -> stored item, recall({query, limit}) -> items.
// Adapters: InMemoryStore (now), ZepStore (Graphiti stub until a server exists) and
// PocMemoryStore (memory-poc.js, MEMORY_PROVIDER=poc_opencode_nebius, proof of concept only).
import { MEMORY_POC_PROVIDER, PocMemoryStore, memoryPocConfigProblem } from "./memory-poc.js";

export const KINDS = ["fact", "hypothesis", "note"];

export function validateMemory(input, now = Date.now()) {
  if (typeof input?.text !== "string" || !input.text.trim()) return { error: "text required" };
  if (!KINDS.includes(input.kind)) return { error: `kind must be one of ${KINDS.join(", ")}` };
  if (typeof input.source !== "string" || !input.source) return { error: "source required" };
  const confidence = input.confidence ?? 0.5;
  if (typeof confidence !== "number" || confidence < 0 || confidence > 1) return { error: "confidence must be 0..1" };
  const expires_at = input.expires_at ?? null;
  if (expires_at !== null && Number.isNaN(Date.parse(expires_at))) return { error: "expires_at must be ISO date" };
  return {
    item: {
      id: crypto.randomUUID(),
      text: input.text,
      created_at: new Date(now).toISOString(),
      source: input.source,
      confidence,
      expires_at,
      kind: input.kind,
    },
  };
}

export class InMemoryStore {
  constructor() {
    this.items = [];
  }
  async write(item) {
    this.items.push(item);
    return item;
  }
  // Empty query: newest items. Otherwise rank by content-token overlap, best first;
  // zero overlap is dropped, ties go to the newer item.
  async recall({ query = "", limit = 10, now = Date.now() } = {}) {
    const live = this.items.filter((m) => !m.expires_at || Date.parse(m.expires_at) > now);
    if (!String(query ?? "").trim()) return live.slice(-limit);
    const q = new Set(tokenize(query));
    return live
      .map((m, i) => ({ m, i, score: overlapScore(q, tokenize(m.text)) }))
      .filter((r) => r.score > 0)
      .sort((a, b) => b.score - a.score || b.i - a.i)
      .slice(0, limit)
      .map((r) => r.m);
  }
}

// Short English and Polish stopword lists; overlap on these alone never recalls.
const STOPWORDS = new Set(
  (
    "a an and are as at be been but by did do does for from had has have he her his how i if in into is it its " +
    "just me my of on or our she so that the their them then there they this to too was we were what when " +
    "which who why will with you your am im not no yes can could would should up out about again very " +
    "i w z we na do to się nie że jest o jak ale po co mi mnie ja ty on ona ono my wy oni od za dla czy już " +
    "tak jestem jesteś mam masz był była było by są tym ten ta te tego tej przez przy lub oraz bo gdy też " +
    "jeszcze tylko bardzo mój moja moje sobie tu tam albo ze"
  ).split(" "),
);

// Lowercase, split on anything that is not a letter or digit (Unicode-aware, so
// Polish diacritics stay inside a token), drop stopwords.
export function tokenize(text) {
  return String(text ?? "")
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t && !STOPWORDS.has(t));
}

// Distinct matched tokens, plus up to 0.5 for how much of the memory they cover,
// so a tighter memory beats a longer one with the same matches.
function overlapScore(queryTokens, memTokens) {
  const mem = new Set(memTokens);
  let matched = 0;
  for (const t of mem) if (queryTokens.has(t)) matched++;
  return matched ? matched + (0.5 * matched) / mem.size : 0;
}

// Graphiti (Zep) adapter, stub until the server exists.
//
// Graphiti's default LLM and embedder are OpenAI, which would send health memory
// off the VPS. The Graphiti server must therefore be run with its LLM and embedder
// pointed at self-hosted, OpenAI-compatible endpoints: the same URLs given here as
// MEMORY_LLM_BASE_URL and MEMORY_EMBED_BASE_URL. Without both, this adapter refuses.
// Its compose file must not ship default credentials (the upstream one uses
// neo4j/password) or unpinned images (upstream uses falkordb:latest); pin every
// image by tag or digest and pass credentials as secrets.

export class MemoryConfigError extends Error {
  constructor(detail) {
    super("not configured");
    this.detail = detail;
  }
}

// Hosts that are third-party model APIs, never acceptable for health memory.
const THIRD_PARTY_HOSTS = ["api.openai.com", "api.anthropic.com", "openrouter.ai", "opencode.ai", "api.meta.ai"];

function checkSelfHosted(name, value) {
  if (!value) return `${name} missing: set it to a self-hosted OpenAI-compatible endpoint`;
  let url;
  try {
    url = new URL(value);
  } catch {
    return `${name} is not a valid URL`;
  }
  const host = url.hostname.toLowerCase();
  if (THIRD_PARTY_HOSTS.some((h) => host === h || host.endsWith(`.${h}`))) {
    return `${name} points at a third-party API; it must be self-hosted`;
  }
  return null;
}

// Returns a refusal reason, or null when the Graphiti config is complete.
export function memoryConfigProblem(env = {}) {
  for (const name of ["MEMORY_SERVER_URL", "MEMORY_KEY"]) {
    if (!env[name]) return `${name} missing`;
  }
  return (
    checkSelfHosted("MEMORY_LLM_BASE_URL", env.MEMORY_LLM_BASE_URL) ??
    checkSelfHosted("MEMORY_EMBED_BASE_URL", env.MEMORY_EMBED_BASE_URL)
  );
}

export class ZepStore {
  constructor(env = {}) {
    this.env = env;
  }
  ready() {
    const problem = memoryConfigProblem(this.env);
    if (problem) throw new MemoryConfigError(problem);
  }
  async write() {
    this.ready();
    throw new MemoryConfigError("graphiti adapter not implemented yet");
  }
  async recall() {
    this.ready();
    throw new MemoryConfigError("graphiti adapter not implemented yet");
  }
}

// MEMORY_PROVIDER=poc_opencode_nebius selects the proof-of-concept store (memory-poc.js);
// any other value, or a mix with Graphiti settings, refuses. Otherwise any Graphiti setting
// selects the Graphiti adapter, so a partial config refuses instead of silently falling back.
// With none set, the in-memory adapter is used.
export class RefusedStore {
  constructor(detail) {
    this.detail = detail;
  }
  async write() {
    throw new MemoryConfigError(this.detail);
  }
  async recall() {
    throw new MemoryConfigError(this.detail);
  }
}

const GRAPHITI_VARS = ["MEMORY_SERVER_URL", "MEMORY_KEY", "MEMORY_LLM_BASE_URL", "MEMORY_EMBED_BASE_URL"];

export function createStore(env, shared, opts = {}) {
  const graphiti = GRAPHITI_VARS.some((k) => env?.[k]);
  if (env?.MEMORY_PROVIDER !== undefined && env?.MEMORY_PROVIDER !== "") {
    if (env.MEMORY_PROVIDER !== MEMORY_POC_PROVIDER) {
      return new RefusedStore(`MEMORY_PROVIDER unknown: use ${MEMORY_POC_PROVIDER} or leave unset`);
    }
    if (graphiti) return new RefusedStore("MEMORY_PROVIDER and Graphiti settings are both set: choose one");
    const problem = memoryPocConfigProblem(env);
    if (problem) return new RefusedStore(problem);
    if (!(shared instanceof InMemoryStore)) return new RefusedStore("memory PoC needs the in-memory item store");
    return new PocMemoryStore(env, shared, opts);
  }
  return graphiti ? new ZepStore(env) : shared;
}
