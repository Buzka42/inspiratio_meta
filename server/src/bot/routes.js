// /bot/* routes for the Worker-hosted Muse bot backend (bot/backend.js; the "bot:global"
// ASSISTANT_DO object — the name holds a colon, so it can never collide with a device id).
// POST /bot/setup renders the signed SETUP.md from the current spec and checks the bot's receipt.
// POST /bot/message sends one message with the stateless envelope (full signed spec, no memory slice
// here: recall stays on the /assistant/memory routes). Owner device only. Fixed codes only.
import { validateReply } from "../assistants/contract.js";
import { REFERRAL_TEXT, touchesHealth, withHealthLine } from "../safety.js";
import { isOwner, specConfigured } from "../spec/routes.js";
import { DEFAULT_SPEC } from "../spec/schema.js";
import { buildEnvelope, renderSetupMd, signEnvelope, signSetup, verifySetupReceipt } from "./setup.js";
import { botStub } from "./backend.js";

export const BOT_ROUTES = Object.freeze(["POST /bot/setup", "POST /bot/message"]);
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const bad = (detail) => json({ error: "bad_request", detail }, 400);
const coded = (status, code) => json({ error: code, code }, status);
const reqId = () => `req_${crypto.randomUUID().replaceAll("-", "")}`;

async function readJson(request) {
  try {
    const b = await request.json();
    return b && typeof b === "object" && !Array.isArray(b) ? b : null;
  } catch {
    return null;
  }
}

async function dispatch(env, op, input) {
  const id = reqId();
  const reply = await botStub(env.ASSISTANT_DO).botDispatch(op, input, id);
  const problems = validateReply(reply, { op, requestId: id });
  if (problems.length) return { code: "bot_contract" };
  if (!reply.ok) return { code: reply.error.code };
  return { result: reply.result };
}

// ctx: { now (ms), logger, spec (loadSpec result) }.
export async function handleBot(key, request, env, deviceId, { logger, spec } = {}) {
  if (!env.ASSISTANT_DO?.idFromName) return json({ error: "not_configured", detail: "ASSISTANT_DO binding required" }, 503);
  if (!specConfigured(env) || !isOwner(env, deviceId)) return coded(403, "spec_forbidden");
  const secret = env.ILLUNIS_INBOX_SECRET;
  if (typeof secret !== "string" || secret.length < 32) return json({ error: "not_configured", detail: "ILLUNIS_INBOX_SECRET missing or shorter than 32 characters" }, 503);
  const current = spec ?? DEFAULT_SPEC;
  try {
    if (key === "POST /bot/setup") {
      const md = renderSetupMd(current);
      const out = await dispatch(env, "setup_apply", { version: current.version, setup_md: md, sig: signSetup(secret, current.version, md) });
      if (out.code) return coded(502, out.code);
      const receipt = verifySetupReceipt(secret, out.result, { version: current.version, setupMd: md });
      if (!receipt.ok) return coded(502, receipt.code);
      return json({ version: current.version, receipt: "verified" });
    }
    const body = await readJson(request);
    if (!body || typeof body.text !== "string" || !body.text.trim() || body.text.length > 4000) return bad("text required");
    if (Object.keys(body).some((k) => !["text", "context"].includes(k))) return bad("only text and context allowed");
    const envelope = buildEnvelope(current, []);
    const input = { text: body.text, ...(body.context !== undefined && { context: body.context }), envelope, envelope_sig: signEnvelope(secret, envelope) };
    const out = await dispatch(env, "message", input);
    if (out.code) return coded(out.code === "not_allowed" ? 403 : 502, out.code);
    // Same medical line as /assistant/message: the bot text is already proxied (bot/backend.js).
    const text = out.result.text;
    const health = touchesHealth({ texts: [body.text, text] });
    return json({ text: health && text !== REFERRAL_TEXT ? withHealthLine(text) : text, health });
  } catch {
    logger?.error?.("route_error", key.split(" ")[1], deviceId, "bot_unavailable");
    return coded(503, "bot_unavailable");
  }
}
