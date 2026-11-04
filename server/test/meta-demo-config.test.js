// Meta demo deploy: tools/meta/deploy-demo.sh dry run and check-deploy --meta-demo. No network; all data synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DEMO_SCRIPT, judgeDemoVars, judgeMetaDemo, loadDemoLines, runSmoke } from "../scripts/check-deploy.mjs";
import { readFileSync } from "node:fs";
import { activeExpertIds } from "../src/council/experts.js";

const here = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(here, "..", "..", "tools", "meta", "deploy-demo.sh");
const LINES = loadDemoLines();

const dryRun = (env = {}, args = []) =>
  spawnSync("bash", [SCRIPT, ...args], { encoding: "utf8", env: { PATH: process.env.PATH, ...env } });
const varsOf = (out) => Object.fromEntries([...out.matchAll(/--var (\w+):([^\s)]+)/g)].map((m) => [m[1], m[2]]));

test("deploy-demo.sh without 'deploy' prints one command line and runs nothing", () => {
  for (const args of [[], ["--yes"], ["Deploy"]]) {
    const r = dryRun({}, args);
    assert.equal(r.status, 0);
    assert.equal(r.stderr, "");
    const lines = r.stdout.trim().split("\n");
    assert.equal(lines.length, 1);
    assert.match(lines[0], /^\(cd server && npx wrangler deploy /);
  }
});

test("deploy-demo.sh vars: demo settings plus every live plain var, medical unset, quota default 50, no secret", () => {
  const out = dryRun().stdout;
  assert.deepEqual(varsOf(out), {
    DATA_MODE: "synthetic", COUNCIL_COACHING: "off", META_MODEL: "muse-spark-1.3", QUOTA_COUNCIL_PER_DAY: "50",
    // Live Worker plain vars; a redeploy drops any not passed again.
    COUNCIL_NEBIUS_MODEL: "nvidia/nemotron-3-super-120b-a12b",
    KNOWLEDGE_EMBED_MODEL: "Qwen/Qwen3-Embedding-8B",
    KNOWLEDGE_EMBED_PROVIDER: "nebius",
    REPLY_PROVIDER: "meta",
    REPLY_LLM_MODEL: "nvidia/Nemotron-3-Ultra-550b-a55b",
    // Owner device for settings and pairing; without it the spec routes answer 503.
    ASSISTANT_OWNER_DEVICE_ID: "phone-owner-test",
  });
  assert.doesNotMatch(out, /KEY|SECRET|TOKEN|PASSWORD|COUNCIL_MEDICAL/);
  // The roster these vars give has no coaching or medical expert.
  const ids = activeExpertIds(varsOf(out));
  assert.ok(ids.length > 0);
  for (const id of ["diet", "training"]) assert.ok(!ids.includes(id), id);
  assert.deepEqual(activeExpertIds({ ...varsOf(out), COUNCIL_COACHING: "on" }).filter((i) => !ids.includes(i)).sort(), ["diet", "training"]);
});

test("deploy-demo.sh takes QUOTA_COUNCIL_PER_DAY and refuses a non-number", () => {
  assert.equal(varsOf(dryRun({ QUOTA_COUNCIL_PER_DAY: "5" }).stdout).QUOTA_COUNCIL_PER_DAY, "5");
  const bad = dryRun({ QUOTA_COUNCIL_PER_DAY: "5; rm -rf /" });
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, "");
});

test("judgeMetaDemo: providers must include meta; roster must hold no diet, training or medical expert", () => {
  const ok = judgeMetaDemo({ providers: ["meta"], experts_consulted: ["sleep_lifestyle", "breath_stress"] });
  assert.deepEqual(ok, { pass: true, fields: { providers: "meta", roster: "clean" } });
  assert.equal(judgeMetaDemo({ providers: ["meta", "nebius"], experts_consulted: [] }).pass, true);
  assert.deepEqual(judgeMetaDemo({ providers: ["nebius"], experts_consulted: [] }).fields.providers, "no_meta");
  assert.deepEqual(judgeMetaDemo({ experts_consulted: [] }).fields.providers, "no_meta");
  assert.equal(judgeMetaDemo({ providers: ["meta"], experts_consulted: ["sleep_lifestyle", "diet"] }).fields.roster, "coaching");
  assert.equal(judgeMetaDemo({ providers: ["meta"], experts_consulted: ["training"] }).fields.roster, "coaching");
  assert.equal(judgeMetaDemo({ providers: ["meta"] }).fields.roster, "missing");
  assert.equal(judgeMetaDemo({ providers: ["meta"], experts_consulted: ["cardiology"] }).fields.roster, "medical");
  assert.equal(judgeMetaDemo(null).pass, false);
});

// Healthy fake Worker; `council` is the /council answer.
function fakeWorker(council) {
  return async (url, init = {}) => {
    const { pathname } = new URL(url);
    const body = init.body ? JSON.parse(init.body) : {};
    const json = (o) => new Response(JSON.stringify(o), { status: 200, headers: { "Content-Type": "application/json" } });
    if (pathname === "/health") return json({ ok: true });
    if (pathname === "/reply") return json({ safety: "passed", council_suggested: body.transcript === LINES.big_question });
    if (pathname === "/council") return json(council);
    if (body.text === LINES.food_mismatch) return json({ ok: false, code: "needs_choice" });
    return json({ ok: true, check: [] });
  };
}
const sources = [{ id: "x", title: "t", url: "https://a.test", kind: "bank" }];
const smoke = (council, metaDemo) =>
  runSmoke({ baseUrl: "https://worker.example.test", token: "synthetic.device.7f3a9c", lines: LINES, fetchFn: fakeWorker(council), metaDemo });
const councilLine = (r) => r.results.find((x) => x.route === "POST /council").line;

test("smoke --meta-demo passes a Meta council with a clean roster and fails otherwise", async () => {
  const meta = { sources, providers: ["meta"], experts_consulted: ["sleep_lifestyle"] };
  const good = await smoke(meta, true);
  assert.equal(good.ok, true);
  assert.equal(councilLine(good), "PASS POST /council status=200 sources=1 providers=meta roster=clean");

  const nebius = await smoke({ ...meta, providers: ["nebius"] }, true);
  assert.equal(nebius.ok, false);
  assert.match(councilLine(nebius), /providers=no_meta/);

  const coaching = await smoke({ ...meta, experts_consulted: ["sleep_lifestyle", "training"] }, true);
  assert.equal(coaching.ok, false);
  assert.match(councilLine(coaching), /roster=coaching/);
});

test("smoke without --meta-demo keeps the Nebius-only council check", async () => {
  assert.equal((await smoke({ sources, providers: ["nebius"] }, false)).ok, true);
  assert.equal((await smoke({ sources, providers: ["meta"], experts_consulted: [] }, false)).ok, false);
});

test("judgeDemoVars: the demo script must set REPLY_PROVIDER:meta and COUNCIL_COACHING:off", () => {
  assert.equal(DEMO_SCRIPT, SCRIPT);
  assert.deepEqual(judgeDemoVars(readFileSync(SCRIPT, "utf8")), { pass: true, fields: { reply_provider: "meta", coaching: "off" } });
  const both = "--var REPLY_PROVIDER:meta\n--var COUNCIL_COACHING:off";
  assert.equal(judgeDemoVars(both).pass, true);
  assert.deepEqual(judgeDemoVars(both.replace(":meta", ":nebius")).fields, { reply_provider: "not_meta", coaching: "off" });
  assert.deepEqual(judgeDemoVars(both.replace(":off", ":on")).fields, { reply_provider: "meta", coaching: "not_off" });
  assert.equal(judgeDemoVars("").pass, false);
});
