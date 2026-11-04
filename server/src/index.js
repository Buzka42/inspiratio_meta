// Request handler (the Cloudflare entry is src/worker.js). Routes: /router, /turn, /memory/write, /memory/recall,
// /council, /digest, /digest/voice, /reply, /reply/stream, /analysis/21d, /session/summary, /log/parse, /health, and the
// Hermes bridge /assistant/* (src/assistants/routes.js; POST /assistant/inbox is HMAC-signed, not device-token), and the
// spec routes GET /spec, POST /spec/{propose,apply}, GET /knowledge/sources, POST /knowledge/{add,remove} (src/spec/routes.js).
// Skill routes POST /reading/* and /habits/* (src/skills/routes.js).
// The user's spec is loaded once per request (loadSpec) and narrows the council, reply, digest, analysis and memory routes.
import { route } from "./router.js";
import { InMemoryStore, createStore, validateMemory } from "./memory.js";
import { isLegacyCouncil, runCouncil, validateMembers } from "./council.js";
import { PURPOSES, runCouncilV2 } from "./council/relay.js";
import { brainConfigProblem, notConfigured } from "./council/provider.js";
import { AnalysisInputError, runAnalysis21d } from "./analysis/run21d.js";
import { summarizeSession, validateSession } from "./session-summary.js";
import { isCrisis } from "./safety.js";
import { ProviderError } from "./providers/chat.js";
import { buildDigest } from "./digest.js";
import { runTurn, buildVoiceDigest } from "./turn.js";
import { runReply } from "./reply.js";
import { runLogParse } from "./logs/parse.js";
import { phoneContext } from "./phone-context.js";
import { SSE_HEADERS, runReplyStream } from "./reply-stream.js";
import { authenticate, RevocationList } from "./auth.js";
import { InMemoryQuotaStore, DurableObjectQuotaStore, checkQuota } from "./quota.js";
import { KNOWLEDGE_PATHS, handleKnowledge } from "./knowledge/ingest.js";
import { ASSISTANT_DEVICE_ROUTES, INBOX_PUSH_ROUTE, handleAssistant, handleInboxPush } from "./assistants/routes.js";
import { PAIR_CLAIM_ROUTE, PAIR_DEVICE_ROUTES, handlePairClaim, handlePairDevice } from "./pairing-routes.js";
import { REDTEAM_ROUTE, handleRedTeam } from "./redteam/panel.js";
import { BOT_ROUTES, handleBot } from "./bot/routes.js";
import { SPEC_PATHS, SPEC_ROUTES, handleSpec, loadSpec } from "./spec/routes.js";
import { memoryAllowed } from "./spec/policy.js";
import { MANIFEST_ROUTE, SKILL_PATHS, handleManifests, handleSkills } from "./skills/routes.js";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const bad = (msg) => json({ error: "bad_request", detail: msg }, 400);

const sharedStore = new InMemoryStore();
// Fallback only, when the QUOTA_DO binding is absent (local dev): a soft limit that
// resets when the isolate restarts (see quota-store.js).
const sharedQuota = new InMemoryQuotaStore();
// Hard limit: the device's Durable Object when the binding exists.
const quotaFor = (env) => (env.QUOTA_DO ? new DurableObjectQuotaStore(env.QUOTA_DO) : sharedQuota);
// Per isolate as well: a revocation here is lost on restart until a persistent backing is wired.
const sharedRevocations = new RevocationList();

async function readBody(request) {
  try {
    const b = await request.json();
    return b && typeof b === "object" ? b : null;
  } catch {
    return null;
  }
}

const KNOWN_PATHS = [
  "/router", "/turn", "/memory/write", "/memory/recall", "/council", "/digest", "/digest/voice", "/reply", "/reply/stream",
  "/analysis/21d", "/session/summary", "/log/parse", ...KNOWLEDGE_PATHS, ...SPEC_PATHS, ...SKILL_PATHS,
];
// The legacy test council knows nothing of skills: refused once the spec turns any skill off.
const skillsNarrowed = (spec) => Boolean(spec) && Object.values(spec.skills ?? {}).some((v) => v !== true);
// Routes the spec narrows; only these read it (one Durable Object call per request).
const SPEC_READERS = [
  "/council", "/digest", "/analysis/21d", "/reply", "/reply/stream", "/memory/write", "/memory/recall",
  "/assistant/memory/write", "/assistant/memory/recall", "/assistant/inbox", "/bot/setup", "/bot/message", ...SPEC_PATHS, ...SKILL_PATHS,
];
const memoryOff = () => json({ error: "memory_off", code: "memory_mode" }, 403);

// Council v2 context: {short_term_summary?: string, signals?: object}. Returns an error string or null.
const MAX_SUMMARY = 2000;
const MAX_SIGNALS_JSON = 4000;
function contextProblem(context) {
  if (context === undefined) return null;
  if (!context || typeof context !== "object" || Array.isArray(context)) return "context must be object";
  const { short_term_summary: s, signals } = context;
  if (s !== undefined && (typeof s !== "string" || s.length > MAX_SUMMARY)) return `context.short_term_summary must be a string of at most ${MAX_SUMMARY}`;
  if (signals !== undefined && (!signals || typeof signals !== "object" || JSON.stringify(signals).length > MAX_SIGNALS_JSON)) {
    return `context.signals must be an object of at most ${MAX_SIGNALS_JSON} characters as JSON`;
  }
  return null;
}

const COUNCIL_V2 = ["", "v2"];
const DIGEST_QUESTION = "Morning digest: what stands out in these observations, and one gentle option for today?";
const councilView = (c) => ({ synthesis: c.synthesis, experts_consulted: c.experts_consulted, sources: c.sources, medical: c.medical, providers: c.providers, trace: c.trace, why: c.why, checks: c.checks });

// Logs carry route names, device ids and fixed codes only: never tokens, transcripts or payloads.
const errorCode = (err) => (err?.message === "not configured" ? "not_configured" : "upstream_error");

export function createHandler({
  fetchFn = fetch,
  store = sharedStore,
  quotaStore = null, // null: chosen per request from env (quotaFor)
  revocations = sharedRevocations,
  logger = console,
  now = () => Date.now(),
} = {}) {
  // The digest's council run: only when a council brain provider is configured, and it also spends a council hit.
  // A failure never fails the digest; the result carries a fixed council_code instead.
  async function digestCouncil(body, env, deviceId, spec) {
    if (brainConfigProblem(env)) return { council: null, council_code: "council_not_configured" };
    const findings = body.findings.filter((f) => typeof f?.text === "string").slice(0, 10).map((f) => f.text.slice(0, 300));
    const summary = typeof body.context?.short_term_summary === "string" ? body.context.short_term_summary.slice(0, MAX_SUMMARY) : undefined;
    if (findings.some((t) => isCrisis(t))) return { council: null, council_code: "council_crisis" };
    try {
      const over = await checkQuota({ deviceId, pathname: "/council", env, store: quotaStore ?? quotaFor(env), now: now() });
      if (over) return { council: null, council_code: "council_quota" };
      const out = await runCouncilV2({ question: DIGEST_QUESTION, context: { short_term_summary: summary, findings }, purpose: "digest" }, env, { fetchFn, spec });
      return { council: councilView(out), council_code: null };
    } catch (err) {
      logger.error("route_error", "/digest", deviceId, errorCode(err));
      return { council: null, council_code: errorCode(err) };
    }
  }

  return async function handle(request, env = {}) {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/health") return json({ ok: true });
    const routeKey = `${request.method} ${pathname}`;
    if (routeKey === INBOX_PUSH_ROUTE) return handleInboxPush(request, env, { now: now(), logger });
    if (routeKey === PAIR_CLAIM_ROUTE) return handlePairClaim(request, env, { now: now(), logger });

    const auth = await authenticate(request, env, { revocations, now: now() });
    const { deviceId } = auth;
    if (!deviceId) {
      logger.warn("auth_rejected", KNOWN_PATHS.includes(pathname) || ASSISTANT_DEVICE_ROUTES.includes(routeKey) || PAIR_DEVICE_ROUTES.includes(routeKey) ? pathname : "other");
      return json(auth.code ? { error: "unauthorized", code: auth.code } : { error: "unauthorized" }, 401);
    }

    if (routeKey === MANIFEST_ROUTE) return handleManifests();
    if (routeKey === REDTEAM_ROUTE) return handleRedTeam(request, env, deviceId);
    const assistant = ASSISTANT_DEVICE_ROUTES.includes(routeKey);
    const pairRoute = PAIR_DEVICE_ROUTES.includes(routeKey);
    const botRoute = BOT_ROUTES.includes(routeKey);
    const specRoute = SPEC_ROUTES.includes(routeKey);
    const known = KNOWN_PATHS.includes(pathname) && !SPEC_PATHS.includes(pathname);
    if (!assistant && !pairRoute && !botRoute && !specRoute && (request.method !== "POST" || !known)) return json({ error: "not_found" }, 404);
    // Pairing makes no model call: it is rate limited per device in pairing.js, not metered here.
    if (pairRoute) return handlePairDevice(routeKey, request, env, deviceId, { now: now(), logger });

    let over;
    try {
      // /reply/stream and /log/parse share the reply bucket: one hit per request, as /reply.
      // /spec/propose and /bot/* may call Hermes or the brain: they share the assistant bucket. /reading/ask calls the brain: reply bucket.
      const quotaPath = ["/reply/stream", "/log/parse", "/reading/ask"].includes(pathname) ? "/reply"
        : pathname === "/spec/propose" || botRoute ? "/assistant/message" : pathname;
      over = await checkQuota({ deviceId, pathname: quotaPath, env, store: quotaStore ?? quotaFor(env), now: now() });
    } catch {
      // Fail closed: an unreachable counter must not turn into unmetered model calls.
      logger.error("quota_store_error", pathname, deviceId);
      return json({ error: "quota_unavailable" }, 503);
    }
    if (over) {
      logger.warn("quota_exceeded", pathname, deviceId, over.bucket);
      return new Response(
        JSON.stringify({ error: "quota_exceeded", bucket: over.bucket, limit: over.limit, retry_after: over.retry_after }),
        { status: 429, headers: { "Content-Type": "application/json", "Retry-After": String(over.retry_after) } },
      );
    }

    const spec = SPEC_READERS.includes(pathname) ? await loadSpec(env, deviceId) : null;
    if (botRoute) return handleBot(routeKey, request, env, deviceId, { now: now(), logger, spec });
    if (specRoute) return handleSpec(routeKey, request, env, deviceId, { fetchFn, now: now(), logger, spec });
    if (assistant) return handleAssistant(routeKey, request, env, deviceId, { fetchFn, now: now(), logger, spec });

    const body = await readBody(request);
    if (!body) return bad("invalid json");
    if (SKILL_PATHS.includes(pathname)) return handleSkills(pathname, body, env, deviceId, { spec, now: now(), fetchFn, logger });
    if (pathname.startsWith("/knowledge/")) {
      // Worker-side knowledge ingest and stats (knowledge/ingest.js). Owner device only.
      const out = await handleKnowledge(pathname, body, env, deviceId, { fetchFn });
      logger.log("knowledge_result", deviceId, out.code ?? "ok");
      return json(out.body, out.status);
    }
    try {
      if (pathname === "/router") {
        if (typeof body.transcript !== "string") return bad("transcript required");
        return json(route(body.transcript));
      }
      if (pathname === "/turn") {
        if (typeof body.transcript !== "string" || !body.transcript.trim()) return bad("transcript required");
        const context = body.context ?? {};
        if (typeof context !== "object" || Array.isArray(context)) return bad("context must be object");
        return json(await runTurn({ transcript: body.transcript, context, memoryStore: createStore(env, store), now: now() }));
      }
      if (pathname === "/reply") {
        // Self-hosted model only; the result carries a fixed code, never transcript or reply text.
        // Prompt is rebuilt server-side; plan.memories is dropped. Top-level phone context is data (phone-context.js).
        const out = await runReply({
          plan: body.plan, transcript: body.transcript, phone: phoneContext(body), env, fetchFn, memoryStore: createStore(env, store), now: now(), spec,
        });
        for (const code of out.ignored ?? []) logger.warn("reply_input_ignored", deviceId, code);
        if (out.code) logger.warn("reply_result", deviceId, out.code);
        return json(out.body, out.status);
      }
      if (pathname === "/reply/stream") {
        // Same input and rules as /reply, sent as SSE sentence events (reply-stream.js).
        // Logs carry fixed codes only; the code arrives when the stream ends.
        const out = await runReplyStream({
          plan: body.plan, transcript: body.transcript, phone: phoneContext(body), env, fetchFn, memoryStore: createStore(env, store), now: now(),
          spec, onFinish: (code) => code && logger.warn("reply_result", deviceId, code),
        });
        for (const code of out.ignored ?? []) logger.warn("reply_input_ignored", deviceId, code);
        if (!out.stream) {
          if (out.code) logger.warn("reply_result", deviceId, out.code);
          return json(out.body, out.status);
        }
        return new Response(out.stream, { status: 200, headers: SSE_HEADERS });
      }
      if (pathname === "/log/parse") {
        // Typed log text to one structured entry (logs/parse.js). Logs carry the fixed result code only.
        const out = await runLogParse(body, env, { fetchFn, now });
        if (out.code) logger.warn("log_parse_result", deviceId, out.code);
        return json(out.body, out.status);
      }
      if (pathname === "/digest/voice") {
        if (!Array.isArray(body.findings)) return bad("findings array required");
        if (typeof body.personality_id !== "string") return bad("personality_id required");
        const digest = buildVoiceDigest(body);
        return digest ? json(digest) : bad("unknown personality_id");
      }
      if (pathname.startsWith("/memory/") && !memoryAllowed(spec, "server")) return memoryOff();
      if (pathname === "/memory/write") {
        const { item, error } = validateMemory(body, now());
        if (error) return bad(error);
        return json(await createStore(env, store).write(item));
      }
      if (pathname === "/memory/recall") {
        const items = await createStore(env, store).recall({ query: body.query, limit: body.limit, now: now() });
        return json({ items });
      }
      if (pathname === "/council") {
        if (typeof body.question !== "string" || !body.question.trim()) return bad("question required");
        if (body.question.length > 2000) return bad("question too long");
        if (body.personas !== undefined && !Array.isArray(body.personas)) return bad("personas must be array");
        if (body.personas?.length) {
          const invalid = validateMembers(body.personas, env);
          if (invalid) return bad(invalid);
        }
        if (isLegacyCouncil(env)) {
          if (skillsNarrowed(spec)) return json({ error: "council_refused", code: "legacy_council_skills" }, 403);
          // Legacy test council (synthetic data only; council.js refuses it under owner_real).
          const runId = body.run_id ?? crypto.randomUUID();
          if (typeof runId !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(runId)) return bad("run_id invalid");
          return json(await runCouncil(body, env, { fetchFn, runId }));
        }
        if (!COUNCIL_V2.includes(env.COUNCIL_PROVIDER ?? "")) {
          throw notConfigured("COUNCIL_PROVIDER unknown: use v2, opencode, openrouter_poc or leave unset");
        }
        if (body.personas?.length) return bad("personas are not used by council v2");
        const purpose = body.purpose ?? "chat";
        if (!PURPOSES.includes(purpose)) return bad(`purpose must be one of ${PURPOSES.join(", ")}`);
        const problem = contextProblem(body.context);
        if (problem) return bad(problem);
        const t0 = now();
        const { upstream_codes: codes = [], upstream_calls: calls = [], ...result } = await runCouncilV2({ question: body.question, context: body.context, purpose }, env, { fetchFn, spec });
        // Fixed values only: role, milliseconds, fixed result codes.
        logger.log("council_run", deviceId, now() - t0, result.consults ?? 0, calls.join(","), codes.join(",") || "-");
        return json(result);
      }
      if (pathname === "/analysis/21d") {
        try {
          return json(await runAnalysis21d(body, env, { fetchFn, nowMs: now(), spec }));
        } catch (err) {
          if (err instanceof AnalysisInputError) return bad(err.message);
          throw err;
        }
      }
      if (pathname === "/session/summary") {
        const invalid = validateSession(body.turns);
        if (invalid) return bad(invalid);
        return json(await summarizeSession({ turns: body.turns }, env, { fetchFn }));
      }
      if (!Array.isArray(body.findings)) return bad("findings array required");
      if (typeof body.personality_id !== "string") return bad("personality_id required");
      const digest = buildDigest(body);
      if (body.council === false) return json(digest);
      return json({ ...digest, ...(await digestCouncil(body, env, deviceId, spec)) });
    } catch (err) {
      // Fixed code only: error messages can echo upstream text or payloads.
      logger.error("route_error", pathname, deviceId, errorCode(err));
      // ProviderError codes and HTTP status are fixed values set in providers/chat.js, never upstream text.
      if (err instanceof ProviderError) logger.error("upstream_detail", pathname, err.code, err.status ?? "-", err.finish ?? err.limit ?? "-");
      if (err.message === "not configured") {
        // detail names env vars and reasons only, never values.
        return json({ error: "not_configured", detail: err.detail ?? "not configured" }, 503);
      }
      return json({ error: "upstream_error" }, 502);
    }
  };
}

const handler = createHandler();
export default { fetch: (request, env) => handler(request, env) };
