// Illunis <-> Hermes contract v1 (integrations/hermes/CONTRACT.md), mirrored from the reference
// validators in integrations/hermes/plugins/illunis_memory/contract.py and signing.py.
// Pure: no I/O. Validators return a list of problems (empty = valid). Problems name fields only,
// never values, so they are safe to log.
import { createHash, createHmac, timingSafeEqual } from "node:crypto";

export const VERSION = 1;
export const OPS = ["message", "memory_write", "memory_recall", "action_propose", "action_execute",
  "spec_propose", "spec_apply", "setup_apply", "knowledge_add", "knowledge_remove"];
export const ACTION_TYPES = ["message_bot"];
export const ERROR_CODES = ["bad_request", "not_allowed", "approval_invalid", "approval_expired", "unavailable", "internal"];
export const EXECUTE_STATUS = ["done", "queued", "failed"];
export const MEMORY_KINDS = ["note", "hypothesis"];
export const INBOX_KINDS = ["message", "reminder", "bot_reply", "action_result", "memory", "spec_request", "spec_proposal"];
export const INBOX_SOURCE = "hermes:illunis";
export const MAX_SKEW_SECONDS = 300;
export const NONCE_TTL_SECONDS = 600;
export const INBOX_MAX_BYTES = 8 * 1024;
export const APPROVAL_TTL_SECONDS = 120; // Hermes refuses more than 180
export const APPROVAL_DOMAIN = "illunis-approval-v1";
export const MIN_SECRET_LENGTH = 32;
export const SPEC_DOMAIN = "illunis-spec-v1";
export const SPEC_MD_MAX = 16000;
export const CHANGE_MAX = 8192;
export const SPEC_REQUEST_MAX = 500; // spec_request: the user's words only, never a change or a change_id

export const REQ_ID = /^[A-Za-z0-9_-]{8,64}$/;
const MEM_ID = /^[0-9a-f]{32}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const NONCE = /^[0-9a-f]{32}$/;
const SRC_ID = /^src_[0-9a-f]{16}$/;
const BANK = /^[a-z][a-z0-9_]{0,31}$/;
const TARGET = /^[a-z0-9][a-z0-9_-]{0,63}(\/[A-Za-z0-9][A-Za-z0-9_-]{0,63})?$/;

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
// Same rule as contract.py _str: trimmed length >= lo, raw length <= hi.
const str = (v, lo, hi) => typeof v === "string" && v.trim().length >= lo && v.length <= hi;
const int = (v) => Number.isInteger(v);
const num = (v) => typeof v === "number" && Number.isFinite(v);
const iso = (v) => typeof v === "string" && /^\d{4}-\d{2}-\d{2}([T ][\d:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(v) && !Number.isNaN(Date.parse(v));

function exactKeys(obj, required, optional, where, out) {
  const keys = Object.keys(obj);
  for (const k of required) if (!keys.includes(k)) out.push(`${where}.${k} missing`);
  for (const k of keys) if (!required.includes(k) && !optional.includes(k)) out.push(`${where}.${k} not allowed`);
}

export function validateAction(action, where = "action") {
  if (!isObj(action)) return [`${where} must be an object`];
  const out = [];
  exactKeys(action, ["type", "target", "text"], [], where, out);
  if (!ACTION_TYPES.includes(action.type)) out.push(`${where}.type must be one of ${ACTION_TYPES.join(", ")}`);
  if (!(typeof action.target === "string" && TARGET.test(action.target))) out.push(`${where}.target must be a bot handle`);
  if (!str(action.text, 1, 2000)) out.push(`${where}.text must be 1-2000 characters`);
  return out;
}

// Spec ops: shapes only. The Worker re-validates every change with spec/schema.js validateChange and
// builds the diff and readback itself, so nothing here is trusted beyond its shape.
const posInt = (v) => int(v) && v >= 1;
const jsonSize = (v) => { try { return JSON.stringify(v).length; } catch { return Infinity; } };

function validateChangeShape(c, where, out) {
  if (!isObj(c)) return out.push(`${where} must be an object`);
  exactKeys(c, ["base_version"], ["spec_patch", "knowledge_add", "knowledge_remove"], where, out);
  if (!posInt(c.base_version)) out.push(`${where}.base_version must be a positive integer`);
  if ("spec_patch" in c && !isObj(c.spec_patch)) out.push(`${where}.spec_patch must be an object`);
  if ("knowledge_add" in c && !isObj(c.knowledge_add)) out.push(`${where}.knowledge_add must be an object`);
  if ("knowledge_remove" in c && !(typeof c.knowledge_remove === "string" && SRC_ID.test(c.knowledge_remove))) out.push(`${where}.knowledge_remove must be a source id`);
  if (jsonSize(c) > CHANGE_MAX) out.push(`${where} must be at most ${CHANGE_MAX} characters`);
}

function validateSource(s, where, out) {
  if (!isObj(s)) return out.push(`${where} must be an object`);
  exactKeys(s, ["title", "origin", "date", "text", "bank"], [], where, out);
  if (!str(s.title, 1, 120)) out.push(`${where}.title must be 1-120 characters`);
  if (!str(s.origin, 1, 200)) out.push(`${where}.origin must be 1-200 characters`);
  if (!iso(s.date)) out.push(`${where}.date must be ISO 8601`);
  if (!str(s.text, 1, 3200)) out.push(`${where}.text must be 1-3200 characters`);
  if (!(typeof s.bank === "string" && BANK.test(s.bank))) out.push(`${where}.bank must be an expert id`);
}

function validateApproval(a, out) {
  if (!isObj(a)) return out.push("input.approval must be an object");
  exactKeys(a, ["action_id", "expires_at", "sig"], [], "input.approval", out);
  if (!(typeof a.action_id === "string" && REQ_ID.test(a.action_id))) out.push("input.approval.action_id invalid");
  if (!int(a.expires_at)) out.push("input.approval.expires_at must be unix seconds");
  if (!(typeof a.sig === "string" && HEX64.test(a.sig))) out.push("input.approval.sig must be 64 hex characters");
}

export function validateInput(op, data) {
  if (!isObj(data)) return ["input must be an object"];
  const out = [];
  if (op === "message") {
    exactKeys(data, ["text"], ["context"], "input", out);
    if (!str(data.text, 1, 4000)) out.push("input.text must be 1-4000 characters");
    if ("context" in data && !str(data.context, 0, 4000)) out.push("input.context must be at most 4000 characters");
  } else if (op === "memory_write") {
    exactKeys(data, ["kind", "text"], ["confidence", "expires_at"], "input", out);
    if (!MEMORY_KINDS.includes(data.kind)) out.push("input.kind must be note or hypothesis");
    if (!str(data.text, 1, 1000)) out.push("input.text must be 1-1000 characters");
    const c = data.confidence ?? 0.5;
    if (!num(c) || c < 0 || c > 1) out.push("input.confidence must be 0..1");
    if ("expires_at" in data && !iso(data.expires_at)) out.push("input.expires_at must be ISO 8601");
  } else if (op === "memory_recall") {
    exactKeys(data, ["query"], ["limit"], "input", out);
    if (!str(data.query, 0, 500)) out.push("input.query must be at most 500 characters");
    const lim = data.limit ?? 8;
    if (!int(lim) || lim < 1 || lim > 50) out.push("input.limit must be 1..50");
  } else if (op === "action_propose") {
    exactKeys(data, ["request"], [], "input", out);
    if (!str(data.request, 1, 2000)) out.push("input.request must be 1-2000 characters");
  } else if (op === "action_execute") {
    exactKeys(data, ["action", "approval"], [], "input", out);
    out.push(...validateAction(data.action).map((p) => `input.${p}`));
    validateApproval(data.approval, out);
  } else if (op === "spec_propose") {
    exactKeys(data, ["request", "base_version"], ["spec_md"], "input", out);
    if (!str(data.request, 1, 2000)) out.push("input.request must be 1-2000 characters");
    if (!posInt(data.base_version)) out.push("input.base_version must be a positive integer");
    if ("spec_md" in data && !str(data.spec_md, 0, SPEC_MD_MAX)) out.push(`input.spec_md must be at most ${SPEC_MD_MAX} characters`);
  } else if (op === "spec_apply") {
    // Worker only: sent after the phone approved; Hermes writes SPEC.md only if sig verifies.
    exactKeys(data, ["version", "spec_md", "sig"], [], "input", out);
    if (!posInt(data.version)) out.push("input.version must be a positive integer");
    if (!str(data.spec_md, 1, SPEC_MD_MAX)) out.push(`input.spec_md must be 1-${SPEC_MD_MAX} characters`);
    if (!(typeof data.sig === "string" && HEX64.test(data.sig))) out.push("input.sig must be 64 hex characters");
  } else if (op === "setup_apply") {
    // Worker only: the signed SETUP.md render (bot/setup.js). The bot writes files and receipts the hashes.
    exactKeys(data, ["version", "setup_md", "sig"], [], "input", out);
    if (!posInt(data.version)) out.push("input.version must be a positive integer");
    if (!str(data.setup_md, 1, SPEC_MD_MAX)) out.push(`input.setup_md must be 1-${SPEC_MD_MAX} characters`);
    if (!(typeof data.sig === "string" && HEX64.test(data.sig))) out.push("input.sig must be 64 hex characters");
  } else if (op === "knowledge_add") {
    exactKeys(data, ["request"], [], "input", out);
    if (!str(data.request, 1, 4000)) out.push("input.request must be 1-4000 characters");
  } else if (op === "knowledge_remove") {
    exactKeys(data, ["request", "sources"], [], "input", out);
    if (!str(data.request, 1, 2000)) out.push("input.request must be 1-2000 characters");
    if (!Array.isArray(data.sources) || data.sources.length > 50) out.push("input.sources must be a list of at most 50");
    else data.sources.forEach((it, i) => {
      const w = `input.sources[${i}]`;
      if (!isObj(it)) return out.push(`${w} must be an object`);
      exactKeys(it, ["id", "title"], [], w, out);
      if (!(typeof it.id === "string" && SRC_ID.test(it.id))) out.push(`${w}.id must be a source id`);
      if (!str(it.title, 1, 120)) out.push(`${w}.title must be 1-120 characters`);
    });
  }
  return out;
}

export function validateRequest(req) {
  if (!isObj(req)) return ["request must be a JSON object"];
  const out = [];
  exactKeys(req, ["illunis", "op", "request_id", "input"], [], "request", out);
  if (req.illunis !== VERSION) out.push("request.illunis must be 1");
  if (!OPS.includes(req.op)) return [...out, "request.op unknown"];
  if (!(typeof req.request_id === "string" && REQ_ID.test(req.request_id))) out.push("request.request_id invalid");
  out.push(...validateInput(req.op, req.input));
  return out;
}

function validateResult(op, res, out) {
  if (!isObj(res)) return out.push("result must be an object");
  if (op === "message") {
    exactKeys(res, ["text"], [], "result", out);
    if (!str(res.text, 1, 2000)) out.push("result.text must be 1-2000 characters");
  } else if (op === "memory_write") {
    exactKeys(res, ["id"], [], "result", out);
    if (!(typeof res.id === "string" && MEM_ID.test(res.id))) out.push("result.id must be a memory id");
  } else if (op === "memory_recall") {
    exactKeys(res, ["items"], [], "result", out);
    if (!Array.isArray(res.items) || res.items.length > 50) return out.push("result.items must be a list of at most 50");
    res.items.forEach((it, i) => {
      const w = `result.items[${i}]`;
      if (!isObj(it)) return out.push(`${w} must be an object`);
      exactKeys(it, ["id", "kind", "text", "confidence", "created_at", "expires_at"], ["source"], w, out);
      if (!MEMORY_KINDS.includes(it.kind)) out.push(`${w}.kind invalid`);
      if (!str(it.text, 1, 1000)) out.push(`${w}.text invalid`);
      if (it.expires_at !== null && it.expires_at !== undefined && !iso(it.expires_at)) out.push(`${w}.expires_at invalid`);
    });
  } else if (op === "action_propose") {
    exactKeys(res, ["action", "readback"], [], "result", out);
    out.push(...validateAction(res.action).map((p) => `result.${p}`));
    if (!str(res.readback, 1, 300)) out.push("result.readback must be 1-300 characters");
  } else if (op === "action_execute") {
    exactKeys(res, ["action_id", "status"], ["detail"], "result", out);
    if (!(typeof res.action_id === "string" && REQ_ID.test(res.action_id))) out.push("result.action_id invalid");
    if (!EXECUTE_STATUS.includes(res.status)) out.push("result.status must be done, queued or failed");
    if ("detail" in res && !str(res.detail, 0, 500)) out.push("result.detail must be at most 500 characters");
  } else if (op === "spec_propose") {
    exactKeys(res, ["change"], [], "result", out);
    validateChangeShape(res.change, "result.change", out);
  } else if (op === "spec_apply") {
    exactKeys(res, ["version"], [], "result", out);
    if (!posInt(res.version)) out.push("result.version must be a positive integer");
  } else if (op === "setup_apply") {
    // The receipt: hashes of what the bot read back, plus its signature over them (bot/setup.js).
    exactKeys(res, ["version", "setup_hash", "spec_hash", "sig"], [], "result", out);
    if (!posInt(res.version)) out.push("result.version must be a positive integer");
    if (!(typeof res.setup_hash === "string" && HEX64.test(res.setup_hash))) out.push("result.setup_hash must be 64 hex characters");
    if (!(typeof res.spec_hash === "string" && HEX64.test(res.spec_hash))) out.push("result.spec_hash must be 64 hex characters");
    if (!(typeof res.sig === "string" && HEX64.test(res.sig))) out.push("result.sig must be 64 hex characters");
  } else if (op === "knowledge_add") {
    exactKeys(res, ["source"], [], "result", out);
    validateSource(res.source, "result.source", out);
  } else if (op === "knowledge_remove") {
    exactKeys(res, ["source_id"], [], "result", out);
    if (!(typeof res.source_id === "string" && SRC_ID.test(res.source_id))) out.push("result.source_id must be a source id");
  }
}

export function validateReply(reply, { op, requestId } = {}) {
  if (!isObj(reply)) return ["reply must be a JSON object"];
  const out = [];
  exactKeys(reply, ["illunis", "op", "request_id", "ok"], ["result", "error"], "reply", out);
  if (reply.illunis !== VERSION) out.push("reply.illunis must be 1");
  if (!OPS.includes(reply.op)) return [...out, "reply.op unknown"];
  if (op !== undefined && reply.op !== op) out.push("reply.op does not match the request");
  if (requestId !== undefined && reply.request_id !== requestId) out.push("reply.request_id does not match the request");
  if (typeof reply.ok !== "boolean") return [...out, "reply.ok must be a boolean"];
  if (reply.ok) {
    if ("error" in reply) out.push("reply.error not allowed when ok is true");
    validateResult(reply.op, reply.result, out);
  } else {
    if ("result" in reply) out.push("reply.result not allowed when ok is false");
    const err = reply.error;
    if (!isObj(err)) out.push("reply.error must be an object");
    else {
      exactKeys(err, ["code", "message"], [], "reply.error", out);
      if (!ERROR_CODES.includes(err.code)) out.push("reply.error.code unknown");
      if (!str(err.message, 0, 300)) out.push("reply.error.message must be at most 300 characters");
    }
  }
  return out;
}

// Strict: the whole trimmed text must be one JSON object. No fences, no prose.
export function parseReply(text, expect = {}) {
  let data;
  try {
    data = JSON.parse(String(text ?? "").trim());
  } catch {
    return { reply: null, problems: ["reply is not a single JSON object"] };
  }
  const problems = validateReply(data, expect);
  return { reply: problems.length ? null : data, problems };
}

// ---- signing (signing.py) ----

function sortKeys(v) {
  if (typeof v === "number" && !Number.isInteger(v)) throw new Error("floats are not allowed in signed data");
  if (Array.isArray(v)) return v.map(sortKeys);
  if (isObj(v)) return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]));
  return v;
}

// Sorted keys, no whitespace, UTF-8 kept, no floats (CONTRACT.md canonical_json).
export const canonicalJson = (value) => JSON.stringify(sortKeys(value));
export const hmacHex = (secret, message) => createHmac("sha256", secret).update(message).digest("hex");
export const actionHash = (action) => createHash("sha256").update(canonicalJson(action), "utf8").digest("hex");
export const approvalMessage = (actionId, hash, expiresAt) => `${APPROVAL_DOMAIN}\n${actionId}\n${hash}\n${expiresAt}`;

export function signApproval(secret, actionId, action, expiresAt) {
  return hmacHex(secret, approvalMessage(actionId, actionHash(action), expiresAt));
}

// Spec mirror (spec_apply): sig = hex(HMAC(secret, "illunis-spec-v1\n" + version + "\n" + hex(SHA-256(spec_md)))).
export const specHash = (specMd) => createHash("sha256").update(String(specMd), "utf8").digest("hex");
export const specMessage = (version, specMd) => `${SPEC_DOMAIN}\n${version}\n${specHash(specMd)}`;
export const signSpec = (secret, version, specMd) => hmacHex(secret, specMessage(version, specMd));

// Constant-time compare of two lowercase hex digests.
export function hexEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || !HEX64.test(a) || !HEX64.test(b)) return false;
  return timingSafeEqual(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
}

export const usableSecret = (s) => typeof s === "string" && s.length >= MIN_SECRET_LENGTH;

// Inbox push verification, CONTRACT.md steps 1-3 and 5 (step 4, the nonce, is the Durable Object's).
// raw: Uint8Array of the received body (already capped). Returns { item } or { code }.
// Codes: bad_signature, bad_body, timestamp_mismatch, timestamp_skew, bad_item. Never echoes the text.
export function verifyInbox(secret, raw, headers, nowS) {
  const sig = String(headers.get("X-Illunis-Signature") ?? "").toLowerCase();
  if (!hexEqual(sig, hmacHex(secret, raw))) return { code: "bad_signature" };
  let body;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    return { code: "bad_body" };
  }
  const tsHeader = String(headers.get("X-Illunis-Timestamp") ?? "");
  if (!isObj(body) || !/^\d{1,12}$/.test(tsHeader) || body.ts !== Number(tsHeader)) return { code: "timestamp_mismatch" };
  if (Math.abs(nowS - body.ts) > MAX_SKEW_SECONDS) return { code: "timestamp_skew" };
  const out = [];
  exactKeys(body, ["kind", "nonce", "source", "text", "ts", "v"], [], "body", out);
  if (out.length || body.v !== 1 || body.source !== INBOX_SOURCE || !INBOX_KINDS.includes(body.kind)
    || !(typeof body.nonce === "string" && NONCE.test(body.nonce))
    || !str(body.text, 1, body.kind === "spec_request" ? SPEC_REQUEST_MAX : 2000)) {
    return { code: "bad_item" };
  }
  return { item: { kind: body.kind, text: body.text, ts: body.ts, nonce: body.nonce } };
}

// A stored spec_request inbox item (assistants/store.js): kind, text, received_at; id and ts as stored.
// Any other key (a change_id, a change) makes it invalid: the bot asks in words, the phone proposes and approves.
export function validateSpecRequest(item) {
  if (!isObj(item)) return ["item must be an object"];
  const out = [];
  exactKeys(item, ["kind", "text", "received_at"], ["id", "ts"], "item", out);
  if (item.kind !== "spec_request") out.push("item.kind must be spec_request");
  if (!str(item.text, 1, SPEC_REQUEST_MAX)) out.push(`item.text must be 1-${SPEC_REQUEST_MAX} characters`);
  if (!(int(item.received_at) && item.received_at > 0)) out.push("item.received_at must be unix seconds");
  return out;
}
