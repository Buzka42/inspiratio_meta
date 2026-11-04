// Client for the owner's Hermes `illunis` profile (integrations/hermes/CONTRACT.md, RUNBOOK.md section 5).
// POST ${HERMES_BASE_URL}/p/illunis/api/sessions/${HERMES_SESSION_ID}/chat with body {message: <request JSON>}.
// The reply text is untrusted data: it must parse as exactly one contract reply object, or the call fails
// with hermes_contract. Errors carry fixed codes only; nothing here logs or returns Hermes text or payloads.
// Never sends system_message or instructions: the profile's SOUL.md is the only instruction source.
import { notConfigured } from "../council/provider.js";
import { dataModeProblem } from "../data-mode.js";
import { parseReply, validateRequest } from "./contract.js";

export const HERMES_PROVIDER = "hermes"; // the owner's own host (data-mode.js OWNER_HOSTS)
export const DEFAULT_TIMEOUT_MS = 45_000;
const MAX_RESPONSE_BYTES = 256 * 1024;
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/;
const REQUIRED = ["HERMES_BASE_URL", "HERMES_API_KEY", "HERMES_SESSION_ID"];
const ACCESS = ["CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET"];
// Testing without a zone (owner, 2026-10-25): HERMES_ACCESS_MODE=quick_tunnel drops the Cloudflare Access
// headers, only for a *.trycloudflare.com host. The PC then runs integrations/hermes/proxy/path_filter.py
// between the tunnel and Hermes, so the boundary is that path filter plus the illunis bearer key.
export const QUICK_TUNNEL = "quick_tunnel";
const QUICK_HOST = /\.trycloudflare\.com$/;
const quickTunnel = (env) => env.HERMES_ACCESS_MODE === QUICK_TUNNEL;

// Codes: hermes_timeout, hermes_network, hermes_access (401/403), hermes_status_4xx, hermes_status_5xx,
// hermes_bad_json, hermes_too_large, hermes_contract, hermes_refused (bot answered ok:false; botCode set).
export class HermesError extends Error {
  constructor(code, { status = null, botCode = null } = {}) {
    super(code);
    this.code = code;
    this.status = status;
    this.botCode = botCode;
  }
}

// https only, host only: no port, credentials, path, query or fragment. Returns the origin or null.
export function hermesBase(value) {
  let url;
  try {
    url = new URL(String(value ?? ""));
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.port || url.username || url.password || url.search || url.hash) return null;
  if (url.pathname !== "/" && url.pathname !== "") return null;
  return `https://${url.hostname.toLowerCase().replace(/\.$/, "")}`;
}

// Returns a reason naming variables only, or null.
export function hermesConfigProblem(env = {}) {
  if (env.HERMES_ACCESS_MODE && !quickTunnel(env)) return `HERMES_ACCESS_MODE unknown: use ${QUICK_TUNNEL} or leave unset`;
  const needed = quickTunnel(env) ? REQUIRED : [...REQUIRED, ...ACCESS];
  const missing = needed.filter((k) => typeof env[k] !== "string" || !env[k].trim());
  if (missing.length) return `${missing.join(", ")} missing`;
  const base = hermesBase(env.HERMES_BASE_URL);
  if (!base) return "HERMES_BASE_URL must be https://<host> with no path, port or query";
  if (quickTunnel(env) && !QUICK_HOST.test(new URL(base).hostname)) return `HERMES_ACCESS_MODE=${QUICK_TUNNEL} needs a *.trycloudflare.com HERMES_BASE_URL`;
  if (!SESSION_ID.test(env.HERMES_SESSION_ID)) return "HERMES_SESSION_ID invalid";
  return dataModeProblem(env, { provider: HERMES_PROVIDER, role: "assistant" });
}

export const newRequestId = () => `req_${crypto.randomUUID().replaceAll("-", "")}`;

async function readCapped(res) {
  const text = await res.text();
  if (text.length > MAX_RESPONSE_BYTES) throw new HermesError("hermes_too_large");
  return text;
}

// One contract call. Returns the validated `result` object.
export async function callHermes(op, input, env, { fetchFn = fetch, timeoutMs = DEFAULT_TIMEOUT_MS, idempotencyKey, requestId = newRequestId() } = {}) {
  const problem = hermesConfigProblem(env);
  if (problem) throw notConfigured(problem);
  const request = { illunis: 1, op, request_id: requestId, input };
  // A request we would send must itself satisfy the contract (routes validate first; this is the backstop).
  if (validateRequest(request).length) throw new HermesError("hermes_request_invalid");
  const url = `${hermesBase(env.HERMES_BASE_URL)}/p/illunis/api/sessions/${env.HERMES_SESSION_ID}/chat`;
  let res;
  try {
    res = await fetchFn(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.HERMES_API_KEY}`,
        ...(quickTunnel(env) ? {} : {
          "CF-Access-Client-Id": env.CF_ACCESS_CLIENT_ID,
          "CF-Access-Client-Secret": env.CF_ACCESS_CLIENT_SECRET,
        }),
        "Idempotency-Key": idempotencyKey ?? requestId,
      },
      body: JSON.stringify({ message: JSON.stringify(request) }),
      signal: AbortSignal.timeout(Math.max(1, timeoutMs)),
      redirect: "manual", // an Access login redirect must never be followed
    });
  } catch (err) {
    const timeout = err?.name === "TimeoutError" || err?.name === "AbortError";
    throw new HermesError(timeout ? "hermes_timeout" : "hermes_network");
  }
  if (res.status === 401 || res.status === 403 || (res.status >= 300 && res.status < 400)) {
    throw new HermesError("hermes_access", { status: res.status });
  }
  if (!res.ok) throw new HermesError(`hermes_status_${res.status >= 500 ? "5xx" : "4xx"}`, { status: res.status });
  let data;
  try {
    data = JSON.parse(await readCapped(res));
  } catch (err) {
    if (err instanceof HermesError) throw err;
    throw new HermesError("hermes_bad_json");
  }
  const content = data?.message?.content;
  if (typeof content !== "string") throw new HermesError("hermes_contract");
  const { reply } = parseReply(content, { op, requestId });
  if (!reply) throw new HermesError("hermes_contract");
  if (!reply.ok) throw new HermesError("hermes_refused", { botCode: reply.error.code });
  return reply.result;
}
