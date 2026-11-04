// Worker-side knowledge ingest and stats (C7). The device token is checked by index.js; here the device must
// also be KNOWLEDGE_INGEST_DEVICE_ID. Embeds with the active provider (embedTexts), then upserts into the
// KNOWLEDGE binding. Returns {status, body, code}. Logs nothing: index.js logs `knowledge_result <device> <code>`.
import { BANK_IDS, EXPERT_IDS } from "../council/experts.js";
import { EMBED_DIMS, embedTag, embedTexts } from "./retrieve.js";

export const INGEST_PATH = "/knowledge/ingest";
export const STATS_PATH = "/knowledge/stats";
export const KNOWLEDGE_PATHS = [INGEST_PATH, STATS_PATH];
export const MAX_RECORDS = 20;
export const MAX_TEXT = 3200;
export const STATS_TOP_K = 50;

const blank = (v) => typeof v !== "string" || !v.trim();
const out = (status, body, code) => ({ status, body, code });
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Returns a fixed detail string for the first violation, or null. Never echoes input values.
function recordProblem(r, i) {
  if (!isObject(r)) return `record ${i}: must be an object`;
  const ns = r.namespace;
  if (!BANK_IDS.includes(ns)) return `record ${i}: namespace not an expert`;
  const m = r.metadata;
  if (!isObject(m)) return `record ${i}: metadata missing`;
  if (typeof r.id !== "string" || !r.id.startsWith(`${ns}:`) || !/^[0-9a-f]{16}:\d+$/.test(r.id.slice(ns.length + 1))) {
    return `record ${i}: id invalid`;
  }
  if (m.expert !== ns) return `record ${i}: metadata.expert must equal namespace`;
  if (blank(m.source_id)) return `record ${i}: source_id missing`;
  if (typeof m.url !== "string" || !/^https:\/\/\S+$/.test(m.url)) return `record ${i}: url must be https`;
  if (typeof r.text !== "string" || r.text.trim().length < 1 || r.text.length > MAX_TEXT) {
    return `record ${i}: text must be 1 to ${MAX_TEXT} characters`;
  }
  return null;
}

export function recordsProblem(records) {
  if (!Array.isArray(records) || records.length < 1 || records.length > MAX_RECORDS) {
    return `records must be an array of 1 to ${MAX_RECORDS}`;
  }
  for (let i = 0; i < records.length; i++) {
    const p = recordProblem(records[i], i);
    if (p) return p;
  }
  return null;
}

const str = (v) => (typeof v === "string" ? v : "");

function parseBody(body) {
  if (typeof body !== "string") return isObject(body) || body === undefined ? body ?? {} : null;
  try {
    const v = JSON.parse(body);
    return isObject(v) ? v : null;
  } catch {
    return null;
  }
}

async function ingest(body, env, fetchFn) {
  const probs = recordsProblem(body.records);
  if (probs) return out(400, { error: "bad_request", detail: probs }, "bad_request");
  const records = body.records;
  if (embedTag(env) === null) return out(502, { error: "ingest_failed", code: "knowledge_not_configured" }, "knowledge_not_configured");
  const emb = await embedTexts(records.map((r) => r.text), env, { fetchFn });
  if (emb.code) return out(502, { error: "ingest_failed", code: emb.code }, emb.code);
  const vectors = records.map((r, i) => ({
    id: r.id,
    namespace: r.namespace,
    values: emb.vectors[i],
    metadata: {
      expert: r.namespace,
      source_id: r.metadata.source_id,
      part: Number(r.id.split(":").at(-1)),
      title: str(r.metadata.title),
      url: r.metadata.url,
      licence: str(r.metadata.licence),
      retrieved: str(r.metadata.retrieved),
      text: r.text,
      embed: emb.tag,
    },
  }));
  try {
    await env.KNOWLEDGE.upsert(vectors);
  } catch {
    return out(502, { error: "ingest_failed", code: "knowledge_upsert_failed" }, "knowledge_upsert_failed");
  }
  const namespaces = {};
  for (const v of vectors) namespaces[v.namespace] = (namespaces[v.namespace] ?? 0) + 1;
  return out(200, { ok: true, upserted: vectors.length, namespaces }, "ok");
}

// Unit vector e0: any query returns the bank's vectors ordered by score, which is enough to list them.
const e0 = () => {
  const v = new Array(EMBED_DIMS).fill(0);
  v[0] = 1;
  return v;
};

async function stats(body, env) {
  const banks = body.namespaces === undefined ? EXPERT_IDS : body.namespaces;
  if (!Array.isArray(banks) || banks.length > BANK_IDS.length || !banks.every((b) => BANK_IDS.includes(b))) {
    return out(400, { error: "bad_request", detail: "namespaces must be expert ids" }, "bad_request");
  }
  const result = {};
  for (const bank of banks) {
    let res;
    try {
      res = await env.KNOWLEDGE.query(e0(), { topK: STATS_TOP_K, namespace: bank, returnMetadata: "all" });
    } catch {
      return out(502, { error: "ingest_failed", code: "knowledge_query_failed" }, "knowledge_query_failed");
    }
    const matches = (Array.isArray(res?.matches) ? res.matches : []).filter(
      (m) => m?.metadata?.expert === bank && !blank(m?.metadata?.source_id),
    );
    result[bank] = {
      sources: new Set(matches.map((m) => m.metadata.source_id)).size,
      chunks: matches.length,
      capped: matches.length >= STATS_TOP_K,
    };
  }
  return out(200, { ok: true, namespaces: result }, "ok");
}

// POST /knowledge/ingest and POST /knowledge/stats. `body` is the parsed JSON (a string is parsed here too).
export async function handleKnowledge(pathname, body, env = {}, deviceId, { fetchFn = fetch } = {}) {
  if (!KNOWLEDGE_PATHS.includes(pathname)) return out(404, { error: "not_found" }, "not_found");
  if (blank(env.KNOWLEDGE_INGEST_DEVICE_ID)) {
    return out(503, { error: "not_configured", detail: "KNOWLEDGE_INGEST_DEVICE_ID missing" }, "not_configured");
  }
  if (deviceId !== env.KNOWLEDGE_INGEST_DEVICE_ID) return out(403, { error: "ingest_forbidden" }, "ingest_forbidden");
  if (typeof env.KNOWLEDGE?.query !== "function" || typeof env.KNOWLEDGE?.upsert !== "function") {
    return out(503, { error: "not_configured", detail: "KNOWLEDGE binding missing" }, "not_configured");
  }
  const parsed = parseBody(body);
  if (!parsed) return out(400, { error: "bad_request", detail: "body must be a JSON object" }, "bad_request");
  return pathname === INGEST_PATH ? ingest(parsed, env, fetchFn) : stats(parsed, env);
}
