#!/usr/bin/env node
// Deploy readiness: fail if any file under server/ holds a key- or token-shaped string,
// or if wrangler.jsonc declares secret-looking vars. Prints file:line and pattern name only,
// never the matched text.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { COACHING_IDS, isMedical } from "../src/council/experts.js";

// Modes: `node scripts/check-deploy.mjs [root]` scans for secrets (static, the default).
// `node scripts/check-deploy.mjs --smoke <base_url>` calls a deployed Worker (contract C10). The device token is
// `--smoke <base_url> --meta-demo` instead requires the council to answer through Meta with no diet, training or
// medical expert (tools/meta/deploy-demo.sh), and that script must set REPLY_PROVIDER:meta and COUNCIL_COACHING:off.
// The device token is
// read from ILLUNIS_DEVICE_TOKEN only and is sent only in the Authorization header. Output has one line per check
// with fixed field values; no response text, transcript, model text or token is printed.

const SKIP_DIRS = new Set(["node_modules", ".wrangler", ".git"]);

// Each pattern needs enough body after the prefix to look like a real credential,
// so prose that names a prefix (for example "tvly-") does not trip it.
export const PATTERNS = [
  { name: "tavily-key", re: /tvly-[A-Za-z0-9_-]{16,}/ },
  { name: "openai-style-key", re: /\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}/ },
  { name: "macaroon-token", re: /v1\.Cm[A-Za-z0-9_+/=-]{20,}/ },
  { name: "bearer-literal", re: /Bearer\s+[A-Za-z0-9._~+/=-]{24,}/ },
  { name: "aws-access-key", re: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "github-token", re: /\bgh[pousr]_[A-Za-z0-9]{30,}/ },
  { name: "private-key", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
];

const SECRET_NAMES = /KEY|SECRET|TOKEN|PASSWORD/i;

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) {
      if (!SKIP_DIRS.has(name)) yield* walk(p);
    } else if (st.isFile() && st.size < 2_000_000) {
      yield p;
    }
  }
}

export function scanText(text) {
  const hits = [];
  text.split("\n").forEach((line, i) => {
    for (const { name, re } of PATTERNS) if (re.test(line)) hits.push({ line: i + 1, pattern: name });
  });
  return hits;
}

// wrangler.jsonc must not set vars whose names look secret; secrets go through `wrangler secret put`.
export function checkWrangler(text) {
  const problems = [];
  const stripped = text.replace(/^\s*\/\/.*$/gm, "");
  let config;
  try {
    config = JSON.parse(stripped);
  } catch {
    return ["wrangler.jsonc does not parse (after removing line comments)"];
  }
  const vars = [config.vars ?? {}, ...Object.values(config.env ?? {}).map((e) => e.vars ?? {})];
  for (const v of vars) for (const k of Object.keys(v)) if (SECRET_NAMES.test(k)) problems.push(`wrangler var ${k} looks secret`);
  return problems;
}

export function checkTree(root) {
  const problems = [];
  for (const file of walk(root)) {
    const text = readFileSync(file, "utf8");
    for (const h of scanText(text)) problems.push(`${relative(root, file)}:${h.line} ${h.pattern}`);
  }
  try {
    problems.push(...checkWrangler(readFileSync(join(root, "wrangler.jsonc"), "utf8")));
  } catch {
    problems.push("wrangler.jsonc missing");
  }
  return problems;
}

const SERVER_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SMOKE_TIMEOUT_MS = 60_000;
const SMOKE_FIXTURE = join(SERVER_ROOT, "test", "fixtures", "nebius-demo", "demo-lines.json");
const SAFETY_VALUES = new Set(["passed", "repaired", "replaced"]);
const TOKEN_SHAPE = /^[A-Za-z0-9._-]+$/;

// https only, or http on localhost for local dev. No credentials, query, fragment or path.
export function parseSmokeUrl(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (!(url.protocol === "https:" || (url.protocol === "http:" && local))) return null;
  if (url.username || url.password || url.search || url.hash) return null;
  if (url.pathname !== "/" && url.pathname !== "") return null;
  return url.origin;
}

export function loadDemoLines(file = SMOKE_FIXTURE) {
  const lines = JSON.parse(readFileSync(file, "utf8"));
  const ok =
    Array.isArray(lines.chat) && lines.chat.length > 0 && lines.chat.every((l) => typeof l === "string") &&
    ["big_question", "food_match", "food_mismatch"].every((k) => typeof lines[k] === "string" && lines[k].length > 0);
  if (!ok) throw new Error("demo-lines.json has the wrong shape");
  return lines;
}

// Calls one route. Returns {status, json} or {error} with a fixed code only.
async function callRoute(fetchFn, origin, token, check) {
  const headers = { "Content-Type": "application/json" };
  if (check.auth) headers.Authorization = `Bearer ${token}`;
  let res;
  try {
    res = await fetchFn(`${origin}${check.path}`, {
      method: check.method,
      headers,
      body: check.body === undefined ? undefined : JSON.stringify(check.body),
      redirect: "error",
      signal: AbortSignal.timeout(check.timeoutMs),
    });
  } catch (e) {
    return { error: e?.name === "TimeoutError" || e?.name === "AbortError" ? "timeout" : "network" };
  }
  try {
    return { status: res.status, json: await res.json() };
  } catch {
    return { status: res.status, error: "bad_json" };
  }
}

// Meta demo (tools/meta/deploy-demo.sh): providers must include "meta" and the roster must hold no coaching
// (diet, training) or medical expert. Pure, so tests need no network.
export function judgeMetaDemo(json) {
  const providers = Array.isArray(json?.providers) && json.providers.includes("meta") ? "meta" : "no_meta";
  const ids = json?.experts_consulted;
  const roster = !Array.isArray(ids) ? "missing"
    : ids.some((id) => COACHING_IDS.includes(id)) ? "coaching"
    : ids.some((id) => isMedical(id)) ? "medical" : "clean";
  return { pass: providers === "meta" && roster === "clean", fields: { providers, roster } };
}

// The Worker does not report its reply provider, so --meta-demo also reads the demo script's --var flags.
export const DEMO_SCRIPT = join(SERVER_ROOT, "..", "tools", "meta", "deploy-demo.sh");
export function judgeDemoVars(text) {
  const vars = Object.fromEntries([...String(text).matchAll(/--var "?(\w+):([^\s"]+)/g)].map((m) => [m[1], m[2]]));
  const reply_provider = vars.REPLY_PROVIDER === "meta" ? "meta" : "not_meta";
  const coaching = vars.COUNCIL_COACHING === "off" ? "off" : "not_off";
  return { pass: reply_provider === "meta" && coaching === "off", fields: { reply_provider, coaching } };
}

// Each judge returns {pass, fields}. Fields hold only fixed values or numbers derived from the response.
function smokeChecks(lines, metaDemo = false) {
  const plan = { personality_id: "calm_guide", skill_id: null, crisis: false };
  return [
    {
      route: "GET /health", method: "GET", path: "/health", auth: false,
      judge: (r) => ({ pass: r.status === 200 && r.json?.ok === true, fields: { ok: r.json?.ok === true } }),
    },
    {
      route: "POST /reply plain", method: "POST", path: "/reply", auth: true,
      body: { plan, transcript: lines.chat[0] },
      judge: (r) => {
        const safety = SAFETY_VALUES.has(r.json?.safety) ? r.json.safety : "other";
        const cs = typeof r.json?.council_suggested === "boolean" ? String(r.json.council_suggested) : "missing";
        return { pass: r.status === 200 && safety !== "other" && cs !== "missing", fields: { safety, council_suggested: cs } };
      },
    },
    {
      route: "POST /reply big question", method: "POST", path: "/reply", auth: true,
      body: { plan, transcript: lines.big_question },
      judge: (r) => ({
        pass: r.status === 200 && r.json?.council_suggested === true,
        fields: { council_suggested: String(r.json?.council_suggested) },
      }),
    },
    {
      route: "POST /council", method: "POST", path: "/council", auth: true, timeoutMs: SMOKE_TIMEOUT_MS,
      body: { question: lines.big_question, purpose: "chat" },
      judge: (r) => {
        const sources = Array.isArray(r.json?.sources) ? r.json.sources.length : null;
        if (metaDemo) {
          const m = judgeMetaDemo(r.json);
          return { pass: r.status === 200 && sources >= 1 && m.pass, fields: { sources: sources ?? "missing", ...m.fields } };
        }
        const providers = Array.isArray(r.json?.providers) && r.json.providers.length === 1 && r.json.providers[0] === "nebius"
          ? "nebius" : "not_nebius";
        return { pass: r.status === 200 && sources >= 1 && providers === "nebius", fields: { sources: sources ?? "missing", providers } };
      },
    },
    {
      route: "POST /log/parse match", method: "POST", path: "/log/parse", auth: true,
      body: { kind: "food", text: lines.food_match },
      judge: (r) => {
        const check = Array.isArray(r.json?.check) ? "present" : "missing";
        return { pass: r.status === 200 && check === "present", fields: { check } };
      },
    },
    {
      route: "POST /log/parse mismatch", method: "POST", path: "/log/parse", auth: true,
      body: { kind: "food", text: lines.food_mismatch },
      judge: (r) => {
        const code = r.json?.code === "needs_choice" ? "needs_choice" : (typeof r.json?.code === "string" ? "other" : "missing");
        return { pass: code === "needs_choice", fields: { code } };
      },
    },
  ];
}

// Runs every check (no early stop). Returns {ok, results: [{route, pass, line}]} or {ok: false, problems}.
export async function runSmoke({ baseUrl, token, lines = loadDemoLines(), fetchFn = globalThis.fetch, metaDemo = false }) {
  const origin = parseSmokeUrl(baseUrl ?? "");
  if (!origin) return { ok: false, problems: ["smoke base_url must be https://<host> (or http://localhost)"], results: [] };
  if (!token) return { ok: false, problems: ["ILLUNIS_DEVICE_TOKEN missing"], results: [] };
  if (!TOKEN_SHAPE.test(token)) return { ok: false, problems: ["ILLUNIS_DEVICE_TOKEN has the wrong shape"], results: [] };
  const results = [];
  for (const check of smokeChecks(lines, metaDemo)) {
    const r = await callRoute(fetchFn, origin, token, { timeoutMs: SMOKE_TIMEOUT_MS, ...check });
    let pass = false;
    let detail;
    if (r.error) {
      detail = `error=${r.error}`;
    } else {
      const v = check.judge(r);
      pass = v.pass;
      detail = [`status=${r.status}`, ...Object.entries(v.fields).map(([k, x]) => `${k}=${x}`)].join(" ");
    }
    results.push({ route: check.route, pass, line: `${pass ? "PASS" : "FAIL"} ${check.route} ${detail}` });
  }
  return { ok: results.every((x) => x.pass), results };
}

export async function smokeCli(argv, env, out = console.log, err = console.error) {
  const raw = argv[argv.indexOf("--smoke") + 1];
  if (!raw || raw.startsWith("--")) {
    err("usage: check-deploy.mjs --smoke <base_url> [--meta-demo]   (device token from ILLUNIS_DEVICE_TOKEN)");
    return 1;
  }
  let lines;
  try {
    lines = loadDemoLines();
  } catch {
    err("check-deploy smoke: FAIL, test/fixtures/nebius-demo/demo-lines.json unreadable or malformed");
    return 1;
  }
  if (argv.includes("--meta-demo")) {
    let v;
    try {
      v = judgeDemoVars(readFileSync(DEMO_SCRIPT, "utf8"));
    } catch {
      v = { pass: false, fields: { script: "unreadable" } };
    }
    const line = Object.entries(v.fields).map(([k, x]) => `${k}=${x}`).join(" ");
    if (!v.pass) {
      err(`check-deploy smoke: FAIL deploy-demo vars ${line}`);
      return 1;
    }
    out(`PASS deploy-demo vars ${line}`);
  }
  const r = await runSmoke({ baseUrl: raw, token: env.ILLUNIS_DEVICE_TOKEN ?? "", lines, metaDemo: argv.includes("--meta-demo") });
  if (r.problems) {
    for (const p of r.problems) err(`  ${p}`);
    err("check-deploy smoke: FAIL (setup)");
    return 1;
  }
  out(`check-deploy smoke: ${parseSmokeUrl(raw)}${argv.includes("--meta-demo") ? " (meta demo)" : ""}`);
  for (const x of r.results) out(x.line);
  const failed = r.results.filter((x) => !x.pass).length;
  if (failed) {
    err(`check-deploy smoke: FAIL (${failed} of ${r.results.length} checks)`);
    return 1;
  }
  out(`check-deploy smoke: OK (${r.results.length} checks)`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === "--smoke") {
    process.exitCode = await smokeCli(process.argv.slice(2), process.env);
  } else {
    const root = resolve(process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), ".."));
    const problems = checkTree(root);
    if (problems.length) {
      console.error(`check-deploy: FAIL (${problems.length})`);
      for (const p of problems) console.error(`  ${p}`);
      process.exit(1);
    }
    console.log("check-deploy: OK, no key-shaped strings, wrangler.jsonc lists no secrets");
  }
}
