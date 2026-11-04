import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createHandler } from "../src/index.js";
import { issueToken, verifyToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { checkTree, scanText, checkWrangler } from "../scripts/check-deploy.mjs";

// Synthetic only. Secrets are generated per run and never written to disk.
const secret = () => `${crypto.randomUUID()}${crypto.randomUUID()}`;
const SECRET = secret();
const ENV = { DEVICE_TOKEN_SECRET: SECRET };
const noNet = () => { throw new Error("network touched"); };
const req = (path, { token, body = {}, method = "POST", header } = {}) =>
  new Request(`https://x.test${path}`, {
    method,
    headers: header ? { Authorization: header } : token ? { Authorization: `Bearer ${token}` } : {},
    body: method === "GET" ? undefined : JSON.stringify(body),
  });

test("auth: issue and verify are pure and round-trip", () => {
  const now = Date.now();
  const t = issueToken("device-1", SECRET, { now });
  assert.equal(t, issueToken("device-1", SECRET, { now }));
  assert.match(t, /^device-1\.\d+\.\d+\.[A-Za-z0-9_-]{43}$/);
  assert.equal(verifyToken(t, SECRET), "device-1");
  assert.equal(verifyToken(t, secret()), null);
  assert.equal(verifyToken(t.replace("device-1.", "device-2."), SECRET), null);
  assert.equal(verifyToken(`${t}x`, SECRET), null);
  assert.equal(verifyToken("device-1.", SECRET), null);
  assert.equal(verifyToken(t, "short"), null);
  assert.equal(verifyToken(t, undefined), null);
  assert.throws(() => issueToken("bad.id", SECRET), /device id/);
  assert.throws(() => issueToken("ok", "short"), /secret/);
});

test("auth: /health needs no token", async () => {
  const h = createHandler({ fetchFn: noNet });
  const res = await h(req("/health", { method: "GET" }), ENV);
  assert.equal(res.status, 200);
});

test("auth: missing token is 401 on every other route", async () => {
  const h = createHandler({ fetchFn: noNet, logger: { warn() {}, error() {} } });
  for (const p of ["/router", "/turn", "/memory/write", "/memory/recall", "/council", "/digest", "/digest/voice", "/nope"]) {
    const res = await h(req(p, { body: { transcript: "hi" } }), ENV);
    assert.equal(res.status, 401, p);
    assert.deepEqual(await res.json(), { error: "unauthorized" });
  }
});

test("auth: wrong token is 401", async () => {
  const h = createHandler({ fetchFn: noNet, logger: { warn() {}, error() {} } });
  const body = { transcript: "hi" };
  const other = issueToken("device-1", secret());
  for (const header of [`Bearer ${other}`, "Bearer device-1.AAAA", "Bearer nodot", `Basic ${issueToken("device-1", SECRET)}`, "Bearer "]) {
    assert.equal((await h(req("/router", { header, body }), ENV)).status, 401, header.slice(0, 6));
  }
  // No secret configured: fail closed, even with an otherwise valid token.
  assert.equal((await h(req("/router", { token: issueToken("device-1", SECRET), body }), {})).status, 401);
});

test("auth: good token passes", async () => {
  const h = createHandler({ fetchFn: noNet, store: new InMemoryStore() });
  const token = issueToken("device-1", SECRET);
  const res = await h(req("/router", { token, body: { transcript: "help me with my breathing" } }), ENV);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).skill_id, "breathwork");
  assert.equal((await h(req("/nope", { token }), ENV)).status, 404);
});

test("logs: no token, secret, transcript or payload reaches the logger", async () => {
  const lines = [];
  const capture = (...args) => lines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  const logger = { log: capture, info: capture, warn: capture, error: capture, debug: capture };
  const MARK = "synthetic-transcript-zebra-7731";
  const PAYLOAD = "synthetic-payload-heron-5512";
  // Upstream that fails with an error message echoing the request body.
  const leakyFetch = async (_url, init) => { throw new Error(`upstream said: ${init.body}`); };
  const h = createHandler({ fetchFn: leakyFetch, store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), logger });
  const token = issueToken("device-log", SECRET);
  const badToken = issueToken("device-log", secret());
  const env = { ...ENV, META_API_KEY: "synthetic", META_MODEL: "synthetic/meta-model-test", QUOTA_COUNCIL_PER_DAY: "1" };

  await h(req("/turn", { token: badToken, body: { transcript: MARK } }), env);
  await h(req(`/${PAYLOAD}`, { token: badToken }), env);
  await h(req("/turn", { token, body: { transcript: MARK, context: { note: PAYLOAD } } }), env);
  await h(req("/council", { token, body: { question: `${MARK} ${PAYLOAD}` } }), env);
  await h(req("/council", { token, body: { question: MARK } }), env); // over quota
  await h(req("/memory/recall", { token, body: { query: PAYLOAD } }), { ...env, MEMORY_KEY: "synthetic" });

  assert.ok(lines.length >= 4, `expected logs, got ${lines.length}`);
  for (const line of lines) {
    for (const forbidden of [token, badToken, token.split(".")[1], badToken.split(".")[1], SECRET, MARK, PAYLOAD, "upstream said"]) {
      assert.ok(!line.includes(forbidden), "a log line carries forbidden content");
    }
  }
  assert.ok(lines.some((l) => l.startsWith("route_error /council device-log upstream_error")));
  assert.ok(lines.some((l) => l.startsWith("quota_exceeded /council device-log council")));
  assert.ok(lines.some((l) => l === "auth_rejected other"));
});

const SERVER_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

test("deploy check: the server tree is clean", () => {
  assert.deepEqual(checkTree(SERVER_ROOT), []);
});

test("deploy check: catches key-shaped strings and secret vars", () => {
  // Built at runtime so this file holds no key-shaped literal.
  const body = "A".repeat(32);
  for (const sample of [`tvly-${body}`, `sk-${body}`, `v1.Cm${body}`, `Authorization: Bearer ${body}`]) {
    assert.equal(scanText(`x = "${sample}"`).length, 1, sample.slice(0, 5));
  }
  assert.deepEqual(scanText("prefixes like tvly- and sk- in prose are fine"), []);
  assert.deepEqual(checkWrangler(`{ "vars": { "DEVICE_TOKEN_SECRET": "x" } }`), ["wrangler var DEVICE_TOKEN_SECRET looks secret"]);
  assert.deepEqual(checkWrangler(`{\n  // note\n  "vars": { "QUOTA_TURNS_PER_DAY": "200" } }`), []);

  const dir = mkdtempSync(join(tmpdir(), "illunis-deploy-"));
  try {
    mkdirSync(join(dir, "src"));
    writeFileSync(join(dir, "wrangler.jsonc"), "{}");
    writeFileSync(join(dir, "src", "a.js"), "export const ok = 1;\n");
    assert.deepEqual(checkTree(dir), []);
    writeFileSync(join(dir, "src", "b.js"), `const k = "sk-${body}";\n`);
    assert.deepEqual(checkTree(dir), ["src/b.js:1 openai-style-key"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
