// check-deploy --smoke (contract C10). Every route is a fake fetch; the token and all text are synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseSmokeUrl, loadDemoLines, runSmoke, smokeCli } from "../scripts/check-deploy.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = resolve(here, "..");
const SCRIPT = join(SERVER, "scripts", "check-deploy.mjs");
const FIXTURE_DIR = join(here, "fixtures", "nebius-demo");
const TOKEN = "synthetic.device.7f3a9c";
const BASE = "https://worker.example.test";
const LINES = loadDemoLines();

// Healthy answers for every route. `over` replaces one route's answer: (path, body) => Response.
function fakeWorker(over = () => null) {
  const calls = [];
  const fetchFn = async (url, init = {}) => {
    const { pathname } = new URL(url);
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url, method: init.method, headers: init.headers, body, signal: init.signal });
    const special = over(pathname, body);
    if (special) return special;
    const json = (o) => new Response(JSON.stringify(o), { status: 200, headers: { "Content-Type": "application/json" } });
    if (pathname === "/health") return json({ ok: true });
    if (pathname === "/reply") {
      const big = body.transcript === LINES.big_question;
      return json({ text: "synthetic reply text", personality_id: "calm_guide", safety: "passed", health: false, council_suggested: big });
    }
    if (pathname === "/council") return json({ synthesis: "synthetic", sources: [{ id: "x", title: "t", url: "https://a.test", kind: "bank" }], providers: ["nebius"] });
    if (pathname === "/log/parse") {
      return body.text === LINES.food_mismatch
        ? json({ ok: false, code: "needs_choice", pending: {}, needs_choice: [] })
        : json({ ok: true, schema: "illunis.log/1", kind: "food", entry: {}, check: [{ item_index: 0, status: "match" }] });
    }
    return new Response("not found", { status: 404 });
  };
  return { fetchFn, calls };
}

const run = (opts = {}) => runSmoke({ baseUrl: BASE, token: TOKEN, lines: LINES, ...opts });

test("base_url: https host, or http on localhost only, no credentials, path, query or fragment", () => {
  assert.equal(parseSmokeUrl("https://worker.example.test"), "https://worker.example.test");
  assert.equal(parseSmokeUrl("https://worker.example.test/"), "https://worker.example.test");
  assert.equal(parseSmokeUrl("http://localhost:8787"), "http://localhost:8787");
  assert.equal(parseSmokeUrl("http://worker.example.test"), null);
  assert.equal(parseSmokeUrl("https://user:pw@worker.example.test"), null);
  assert.equal(parseSmokeUrl("https://worker.example.test/reply"), null);
  assert.equal(parseSmokeUrl("https://worker.example.test?x=1"), null);
  assert.equal(parseSmokeUrl("not a url"), null);
});

test("demo lines fixture is synthetic and has the four required lines", () => {
  assert.equal(LINES.synthetic, true);
  assert.ok(LINES.chat.length >= 1);
  assert.equal(LINES.big_question, "why do I keep waking up at 3am every night");
  assert.notEqual(LINES.food_match, LINES.food_mismatch);
  assert.match(LINES.food_mismatch, /400 kcal/);
});

test("nebius-demo fixture holds three synthetic personas from gen_history", () => {
  const files = readdirSync(FIXTURE_DIR).filter((f) => f.endsWith(".json") && f !== "demo-lines.json");
  assert.equal(files.length, 3);
  for (const f of files) {
    const p = JSON.parse(readFileSync(join(FIXTURE_DIR, f), "utf8"));
    assert.equal(p.synthetic, true);
    assert.equal(typeof p.seed, "number");
    assert.equal(p.window.end, "2026-10-29");
  }
});

test("all checks pass against a healthy fake Worker; each route gets the right method, auth and body", async () => {
  const { fetchFn, calls } = fakeWorker();
  const r = await run({ fetchFn });
  assert.equal(r.ok, true);
  assert.equal(r.results.length, 6);
  assert.ok(r.results.every((x) => x.pass));
  const health = calls.find((c) => c.url.endsWith("/health"));
  assert.equal(health.method, "GET");
  assert.equal(health.headers.Authorization, undefined);
  for (const c of calls.filter((c) => !c.url.endsWith("/health"))) {
    assert.equal(c.headers.Authorization, `Bearer ${TOKEN}`);
    assert.equal(c.method, "POST");
    assert.ok(!c.url.includes(TOKEN), "token must not appear in a URL");
    assert.ok(c.signal, "every request has a timeout signal");
  }
  const council = calls.find((c) => c.url.endsWith("/council"));
  assert.deepEqual(council.body, { question: LINES.big_question, purpose: "chat" });
});

test("printed lines hold fixed fields only: no token, no transcript, no response text", async () => {
  const { fetchFn } = fakeWorker();
  const r = await run({ fetchFn });
  const text = r.results.map((x) => x.line).join("\n");
  assert.ok(!text.includes(TOKEN));
  assert.ok(!text.includes("synthetic reply text"));
  assert.ok(!text.includes(LINES.big_question));
  assert.ok(!text.includes(LINES.food_match));
  assert.match(text, /PASS POST \/log\/parse mismatch status=200 code=needs_choice/);
  assert.match(text, /PASS POST \/council status=200 sources=1 providers=nebius/);
});

test("a big question without council_suggested true fails that check", async () => {
  const { fetchFn } = fakeWorker((path, body) => (path === "/reply" && body.transcript === LINES.big_question
    ? new Response(JSON.stringify({ safety: "passed", council_suggested: false }), { status: 200 }) : null));
  const r = await run({ fetchFn });
  assert.equal(r.ok, false);
  const bad = r.results.filter((x) => !x.pass);
  assert.equal(bad.length, 1);
  assert.match(bad[0].line, /^FAIL POST \/reply big question status=200 council_suggested=false/);
});

test("council with no sources, or on another provider, fails", async () => {
  for (const council of [{ sources: [], providers: ["nebius"] }, { sources: [{}], providers: ["meta"] }]) {
    const { fetchFn } = fakeWorker((path) => (path === "/council"
      ? new Response(JSON.stringify(council), { status: 200 }) : null));
    const r = await run({ fetchFn });
    assert.equal(r.ok, false);
    assert.match(r.results.find((x) => x.route === "POST /council").line, /^FAIL/);
  }
});

test("a matching food line without check, or a mismatch without needs_choice, fails", async () => {
  const { fetchFn } = fakeWorker((path, body) => (path === "/log/parse"
    ? new Response(JSON.stringify({ ok: false, code: "bad_json" }), { status: 422 }) : null));
  const r = await run({ fetchFn });
  assert.equal(r.results.find((x) => x.route === "POST /log/parse match").pass, false);
  assert.equal(r.results.find((x) => x.route === "POST /log/parse mismatch").pass, false);
});

test("a network error or timeout fails that check with a fixed code, and the error text is not printed", async () => {
  const leaky = async (url, init) => {
    if (url.endsWith("/reply")) throw Object.assign(new Error(`socket for ${TOKEN}`), { name: "TypeError" });
    if (url.endsWith("/council")) throw Object.assign(new Error("slow"), { name: "TimeoutError" });
    return fakeWorker().fetchFn(url, init);
  };
  const r = await run({ fetchFn: leaky });
  const text = r.results.map((x) => x.line).join("\n");
  assert.equal(r.ok, false);
  assert.match(text, /FAIL POST \/reply plain error=network/);
  assert.match(text, /FAIL POST \/council error=timeout/);
  assert.ok(!text.includes(TOKEN));
});

test("a non-JSON answer fails with bad_json and a 500 body is never printed", async () => {
  const { fetchFn } = fakeWorker(() => new Response(`secret body ${TOKEN}`, { status: 500 }));
  const r = await run({ fetchFn });
  assert.equal(r.ok, false);
  assert.equal(r.results.length, 6);
  const text = r.results.map((x) => x.line).join("\n");
  assert.ok(!text.includes("secret body"));
  assert.ok(!text.includes(TOKEN));
  assert.match(text, /FAIL GET \/health error=bad_json/);
});

test("setup problems stop before any request: bad URL, missing or malformed token", async () => {
  let calls = 0;
  const fetchFn = async () => { calls += 1; return new Response("{}"); };
  const bad = await runSmoke({ baseUrl: "http://worker.example.test", token: TOKEN, lines: LINES, fetchFn });
  assert.equal(bad.ok, false);
  assert.match(bad.problems[0], /base_url/);
  const none = await runSmoke({ baseUrl: BASE, token: "", lines: LINES, fetchFn });
  assert.match(none.problems[0], /ILLUNIS_DEVICE_TOKEN missing/);
  const shape = await runSmoke({ baseUrl: BASE, token: "has space", lines: LINES, fetchFn });
  assert.match(shape.problems[0], /wrong shape/);
  assert.equal(calls, 0);
});

test("CLI: missing token exits 1 without printing the token; missing URL is a usage error", async () => {
  const out = []; const err = [];
  const code = await smokeCli(["--smoke", BASE], {}, (s) => out.push(s), (s) => err.push(s));
  assert.equal(code, 1);
  assert.match(err.join("\n"), /ILLUNIS_DEVICE_TOKEN missing/);
  const usage = [];
  assert.equal(await smokeCli(["--smoke"], { ILLUNIS_DEVICE_TOKEN: TOKEN }, () => {}, (s) => usage.push(s)), 1);
  assert.match(usage.join("\n"), /usage:/);
});

test("CLI process: a refused connection exits 1 with fixed codes only, and the token never appears", () => {
  const res = spawnSync(process.execPath, [SCRIPT, "--smoke", "http://127.0.0.1:1"], {
    env: { PATH: process.env.PATH, ILLUNIS_DEVICE_TOKEN: TOKEN },
    encoding: "utf8",
    timeout: 60_000,
  });
  assert.equal(res.status, 1);
  assert.match(res.stdout, /FAIL POST \/reply plain error=network/);
  assert.match(res.stderr, /FAIL \(6 of 6 checks\)/);
  assert.ok(!(res.stdout + res.stderr).includes(TOKEN));
});

test("CLI process: the static scan still runs by default and passes on server/", () => {
  const res = spawnSync(process.execPath, [SCRIPT, SERVER], { encoding: "utf8", timeout: 60_000 });
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /check-deploy: OK/);
});
