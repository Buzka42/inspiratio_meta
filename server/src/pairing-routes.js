// /pair/* routes: POST /pair/code and GET /pair/status and POST /pair/revoke are device-token routes;
// POST /pair/claim is the bot's HMAC-signed call (no device token, like the inbox push). Device routes: owner only.
// The pairing record lives in the single "pairing:global" AssistantInbox object (one bot per Worker).
// Responses carry fixed codes only; the code itself is shown once, to the phone that asked for it.
import { issueToken } from "./auth.js";
import { usableSecret } from "./assistants/contract.js";
import { isOwner, specConfigured } from "./spec/routes.js";
import { PAIR_CODE, pairingStub, verifyPairClaim } from "./pairing.js";

export const PAIR_CLAIM_ROUTE = "POST /pair/claim";
export const PAIR_DEVICE_ROUTES = Object.freeze(["POST /pair/code", "GET /pair/status", "POST /pair/revoke"]);

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const bad = (detail) => json({ error: "bad_request", detail }, 400);
const coded = (status, code) => json({ error: code, code }, status);
const notConfigured = (detail) => json({ error: "not_configured", detail }, 503);

const doProblem = (env) => (env.ASSISTANT_DO?.idFromName ? null : "ASSISTANT_DO binding missing");
const secretProblem = (env) => (usableSecret(env.ILLUNIS_INBOX_SECRET) ? null : "ILLUNIS_INBOX_SECRET missing or shorter than 32 characters");
const stub = (env) => pairingStub(env.ASSISTANT_DO);

async function readJson(request) {
  try {
    const b = await request.json();
    return b && typeof b === "object" && !Array.isArray(b) ? b : null;
  } catch {
    return null;
  }
}

// The bot's claim. The signature is the credential; a valid claim consumes the code.
export async function handlePairClaim(request, env, { now, logger } = {}) {
  const problem = doProblem(env) ?? secretProblem(env) ?? (usableSecret(env.DEVICE_TOKEN_SECRET) ? null : "DEVICE_TOKEN_SECRET missing or shorter than 32 characters");
  if (problem) return notConfigured(problem);
  const body = await readJson(request);
  if (!body || Object.keys(body).some((k) => !["bot_id", "code", "ts"].includes(k))) return bad("bot_id, code and ts required");
  const nowS = Math.floor(now / 1000);
  const out = verifyPairClaim(env.ILLUNIS_INBOX_SECRET, body, request.headers.get("X-Illunis-Signature"), nowS);
  if (out.code) {
    logger?.warn?.("pair_rejected", out.code);
    return out.code === "bad_signature" ? coded(401, out.code) : bad(out.code);
  }
  const res = await stub(env).pairClaim(out.claim, now);
  if (!res.ok) return coded(res.code === "pair_expired" ? 410 : 409, res.code);
  return json({ ok: true, paired: true }, 202);
}

// Device routes, owner device only (as bot/routes.js). ctx: { now (ms), logger }.
export async function handlePairDevice(key, request, env, deviceId, { now, logger } = {}) {
  if (doProblem(env)) return notConfigured("ASSISTANT_DO binding missing");
  if (!specConfigured(env) || !isOwner(env, deviceId)) return coded(403, "pair_forbidden");
  try {
    if (key === "POST /pair/code") {
      const body = await readJson(request);
      if (body && Object.keys(body).length) return bad("no body fields allowed");
      const out = await stub(env).pairCreate(deviceId, now);
      if (out.code) return out.code === "rate_limited" ? coded(429, out.code) : coded(409, out.code);
      return json({ code: out.pair_code, expires_at: out.expires_at, code_format: PAIR_CODE.source });
    }
    if (key === "GET /pair/status") {
      const st = await stub(env).pairStatus(deviceId, now);
      if (st.status !== "paired" || st.delivered) return json(st);
      // First poll after the claim: hand the credential over exactly once.
      const delivered = await stub(env).pairDeliver(deviceId, now);
      if (!delivered.ok) return json({ status: "paired", bot_id: st.bot_id, delivered: true });
      const credential = issueToken(deviceId, env.DEVICE_TOKEN_SECRET, { now });
      return json({ status: "paired", bot_id: st.bot_id, claimed_at: st.claimed_at, delivered: true, credential });
    }
    // POST /pair/revoke clears the link only: the phone's device token keeps working. Data is untouched.
    const out = await stub(env).pairRevoke(deviceId, now);
    if (!out.ok) return coded(404, "not_paired");
    return json({ ok: true, revoked: true, bot_id: out.bot_id });
  } catch {
    logger?.error?.("route_error", key.split(" ")[1], deviceId, "pair_unavailable");
    return coded(503, "pair_unavailable");
  }
}
