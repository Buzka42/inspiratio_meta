// Spec and knowledge-source routes (plan P5): GET /spec, POST /spec/propose, POST /spec/apply,
// GET /knowledge/sources, POST /knowledge/add, POST /knowledge/remove. The device token is checked by index.js.
// Hackathon scope as in assistants/routes.js: one owner (ASSISTANT_OWNER_DEVICE_ID), whose AssistantInbox object
// holds the spec. Other devices read DEFAULT_SPEC and may not write. Only the phone's device token reaches
// /spec/apply (Hermes has no device token and never sees a change_id).
// Bot output is untrusted: a change from words is re-validated by SpecState, and the diff and readback are the
// Worker's own. Free text the bot wrote (guidelines, a source body) is refused on that path: the user must type it.
// Responses carry fixed codes only.
import { DEVICE_ID } from "../auth.js";
import { BANK_IDS } from "../council/experts.js";
import { embedTexts } from "../knowledge/retrieve.js";
import { callHermes, hermesConfigProblem } from "../assistants/hermes.js";
import { signSpec, usableSecret } from "../assistants/contract.js";
import { assistantStub } from "../assistants/store.js";
import { ALL_SKILL_IDS, DEFAULT_SPEC, isPlain, renderSpecMd } from "./schema.js";
import { GUARDRAILS } from "./guardrails.js";
import { sourceIndex } from "./knowledge.js";
import { proposeChange } from "./propose.js";

// The one list of skill ids and banks a change may name (schema.js ALL_SKILL_IDS, experts.js BANK_IDS).
export const SPEC_REGISTRY = Object.freeze({ skills: ALL_SKILL_IDS, banks: BANK_IDS });

export const SPEC_ROUTES = Object.freeze([
  "GET /spec", "POST /spec/propose", "POST /spec/apply", "GET /knowledge/sources", "POST /knowledge/add", "POST /knowledge/remove",
  "GET /spec/history", "POST /spec/revert",
]);
export const SPEC_PATHS = Object.freeze([...new Set(SPEC_ROUTES.map((r) => r.split(" ")[1]))]);
const GUARD_LINES = Object.freeze([GUARDRAILS.crisis, GUARDRAILS.medical, GUARDRAILS.data]);
const MIRROR_TIMEOUT_MS = 5000;
export const MAX_CHUNKS = 8; // text <= 3200, each chunk takes at least CHUNK / 2 characters
const CHUNK = 800;

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const bad = (detail) => json({ error: "bad_request", detail }, 400);
const coded = (status, code) => json({ error: code, code }, status);
const refusedRes = (refused) => json({ error: "refused", code: "refused", refused }, 422);

export const specConfigured = (env = {}) => Boolean(env.ASSISTANT_DO?.idFromName)
  && typeof env.ASSISTANT_OWNER_DEVICE_ID === "string" && DEVICE_ID.test(env.ASSISTANT_OWNER_DEVICE_ID);
export const isOwner = (env, deviceId) => specConfigured(env) && deviceId === env.ASSISTANT_OWNER_DEVICE_ID;
const stub = (env) => assistantStub(env.ASSISTANT_DO, env.ASSISTANT_OWNER_DEVICE_ID);

// The spec for this request. null: no spec store in this deploy, or the owner never applied a change (a saved
// spec always has version > 1), so today's env-only behaviour holds. Other devices, or a failed read: DEFAULT_SPEC.
export async function loadSpec(env, deviceId) {
  if (!specConfigured(env)) return null;
  if (!isOwner(env, deviceId)) return DEFAULT_SPEC;
  try {
    const { spec } = await stub(env).specGet();
    return spec?.version > 1 ? spec : null;
  } catch {
    return DEFAULT_SPEC;
  }
}

// ---- knowledge chunks in Vectorize: id `${bank}:${hex}:${i}`, metadata.source_id = the src_ id, metadata.part = i ----
export function chunkText(text) {
  const out = [];
  let rest = String(text ?? "").trim();
  while (rest && out.length < MAX_CHUNKS) {
    if (rest.length <= CHUNK) { out.push(rest); break; }
    const space = rest.lastIndexOf(" ", CHUNK);
    const at = space >= CHUNK / 2 ? space : CHUNK;
    out.push(rest.slice(0, at).trim());
    rest = rest.slice(at).trim();
  }
  return out;
}
export const chunkId = (sourceId, bank, i) => `${bank}:${sourceId.slice(4)}:${i}`;

async function indexSource(src, env, fetchFn) {
  if (typeof env.KNOWLEDGE?.upsert !== "function") return { indexed: false, code: "knowledge_not_bound" };
  const chunks = chunkText(src.text);
  const emb = await embedTexts(chunks, env, { fetchFn });
  if (emb.code) return { indexed: false, code: emb.code };
  const url = /^https:\/\/\S+$/.test(src.origin) ? src.origin : "";
  const vectors = chunks.map((text, i) => ({
    id: chunkId(src.id, src.bank, i),
    namespace: src.bank,
    values: emb.vectors[i],
    metadata: { expert: src.bank, source_id: src.id, part: i, title: src.title, url, origin: src.origin, licence: "", retrieved: src.date, text, embed: emb.tag },
  }));
  try {
    await env.KNOWLEDGE.upsert(vectors);
    return { indexed: true, chunks: vectors.length };
  } catch {
    return { indexed: false, code: "knowledge_upsert_failed" };
  }
}

async function unindexSource(sourceId, bank, env) {
  if (typeof env.KNOWLEDGE?.deleteByIds !== "function" || !BANK_IDS.includes(bank)) return { unindexed: false, code: "knowledge_not_bound" };
  try {
    await env.KNOWLEDGE.deleteByIds(Array.from({ length: MAX_CHUNKS }, (_, i) => chunkId(sourceId, bank, i)));
    return { unindexed: true };
  } catch {
    return { unindexed: false, code: "knowledge_delete_failed" };
  }
}

async function knowledgeEffects(out, env, fetchFn) {
  if (out.added) return { knowledge: { added: sourceIndex(out.added), ...(await indexSource(out.added, env, fetchFn)) } };
  if (!out.removed) return {};
  const bank = out.diff.find((d) => d.path === "knowledge.remove")?.from;
  return { knowledge: { removed: out.removed, ...(await unindexSource(out.removed, bank, env)) } };
}

// Best effort: the apply has already happened; this only reports where the Hermes mirror stands.
async function pushMirror(spec, env, fetchFn) {
  if (hermesConfigProblem(env) || !usableSecret(env.ILLUNIS_INBOX_SECRET)) return "off";
  const md = renderSpecMd(spec);
  try {
    const input = { version: spec.version, spec_md: md, sig: signSpec(env.ILLUNIS_INBOX_SECRET, spec.version, md) };
    const out = await callHermes("spec_apply", input, env, { fetchFn, timeoutMs: MIRROR_TIMEOUT_MS });
    return out.version === spec.version ? "synced" : "pending";
  } catch {
    return "pending";
  }
}

// ---- propose and apply ----
// From words, the bot may only pick settings; text it wrote never becomes a setting or a source.
export function botTextRefusals(change) {
  const out = [];
  if (isPlain(change.spec_patch) && Object.hasOwn(change.spec_patch, "guidelines")) out.push({ path: "spec_patch.guidelines", reason: "app_only" });
  if (change.knowledge_add !== undefined) out.push({ path: "knowledge_add", reason: "app_only" });
  return out;
}

function proposeResponse(out, via) {
  if (out.change_id) {
    const { change_id, base_version, diff, readback, expires_at } = out;
    return json({ change_id, base_version, diff, readback, expires_at, via });
  }
  if (out.refused?.length) return refusedRes(out.refused);
  if (out.problems?.[0] === "stale_version") return coded(409, "stale_version");
  return coded(422, out.problems?.[0] ?? "bad_change");
}

async function fromWords(body, ctx) {
  const extra = Object.keys(body).filter((k) => k !== "request" && k !== "base_version");
  if (extra.length) return { res: bad("request cannot be combined with a change") };
  const current = ctx.spec ?? DEFAULT_SPEC;
  if (body.base_version !== undefined && body.base_version !== current.version) return { res: coded(409, "stale_version") };
  const out = await proposeChange(body.request, current, { env: ctx.env, fetchFn: ctx.fetchFn, ...SPEC_REGISTRY });
  if (!out.ok) {
    if (out.code === "stale_version") return { res: coded(409, "stale_version") };
    return { res: out.code === "refused" ? refusedRes(out.refused ?? []) : coded(422, out.code) };
  }
  const appOnly = botTextRefusals(out.change);
  return appOnly.length ? { res: refusedRes(appOnly) } : { change: out.change, via: out.via };
}

async function propose(body, ctx) {
  let change = body;
  let via = "app";
  if (Object.hasOwn(body, "request")) {
    const words = await fromWords(body, ctx);
    if (words.res) return words.res;
    ({ change, via } = words);
  }
  return proposeResponse(await stub(ctx.env).specPropose(change, ctx.now), via);
}

const APPLY_FAIL = { unknown_change: [409, "change_unknown"], expired_change: [410, "change_expired"], stale_version: [409, "stale_version"] };

async function apply(body, ctx) {
  if (Object.keys(body).some((k) => k !== "change_id")) return bad("only change_id allowed");
  const s = stub(ctx.env);
  const out = await s.specApply(body.change_id, ctx.now);
  if (!out.spec) {
    if (out.refused?.length) return refusedRes(out.refused);
    const [status, code] = APPLY_FAIL[out.problems?.[0]] ?? [422, out.problems?.[0] ?? "bad_change"];
    return coded(status, code);
  }
  const knowledge = await knowledgeEffects(out, ctx.env, ctx.fetchFn);
  const mirror = await pushMirror(out.spec, ctx.env, ctx.fetchFn);
  await s.specMirror(mirror).catch(() => {});
  return json({ spec: out.spec, guardrails: GUARD_LINES, mirror, diff: out.diff, readback: out.readback, ...(out.restored_from && { restored_from: out.restored_from }), ...knowledge });
}

const onlyKeys = (body, keys) => Object.keys(body).every((k) => keys.includes(k));

function changeFor(key, body) {
  if (key === "POST /spec/propose") return body;
  if (key === "POST /knowledge/add") return onlyKeys(body, ["base_version", "source"]) ? { base_version: body.base_version, knowledge_add: body.source } : null;
  return onlyKeys(body, ["base_version", "source_id"]) ? { base_version: body.base_version, knowledge_remove: body.source_id } : null;
}

async function readState(env, deviceId) {
  if (!isOwner(env, deviceId)) return { spec: DEFAULT_SPEC, guardrails: GUARD_LINES, mirror: "off" };
  const { spec, mirror } = await stub(env).specGet();
  return { spec, guardrails: GUARD_LINES, mirror: mirror ?? "off" };
}

async function readBody(request) {
  try {
    const b = await request.json();
    return isPlain(b) ? b : null;
  } catch {
    return null;
  }
}

// ctx: { fetchFn, now (ms), logger, spec (loadSpec result) }.
export async function handleSpec(key, request, env, deviceId, ctx) {
  const c = { ...ctx, env };
  try {
    if (key === "GET /spec") return json(await readState(env, deviceId));
    if (key === "GET /spec/history") return json({ history: isOwner(env, deviceId) ? await stub(env).specHistory() : [] });
    if (key === "GET /knowledge/sources") return json({ sources: isOwner(env, deviceId) ? await stub(env).sources() : [] });
    if (!specConfigured(env)) return json({ error: "not_configured", detail: "ASSISTANT_DO binding and ASSISTANT_OWNER_DEVICE_ID required" }, 503);
    if (!isOwner(env, deviceId)) return coded(403, "spec_forbidden");
    const body = await readBody(request);
    if (!body) return bad("invalid json");
    if (key === "POST /spec/apply") return await apply(body, c);
    if (key === "POST /spec/revert") {
      if (Object.keys(body).some((k) => k !== "version") || !Number.isInteger(body.version) || body.version < 1) return bad("version required");
      const out = await stub(env).specRevert(body.version, c.now);
      return out.change_id ? proposeResponse(out, "app") : coded(422, out.problems?.[0] ?? "bad_revert");
    }
    const change = changeFor(key, body);
    return change ? await propose(change, c) : bad("unexpected keys");
  } catch {
    ctx.logger?.error?.("route_error", key.split(" ")[1], deviceId, "spec_unavailable");
    return coded(503, "spec_unavailable");
  }
}
