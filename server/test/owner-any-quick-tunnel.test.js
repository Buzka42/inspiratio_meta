import { test } from "node:test";
import assert from "node:assert/strict";
import { dataModeProblem } from "../src/data-mode.js";
import { metaConfigProblem } from "../src/providers/meta.js";
import { hermesConfigProblem } from "../src/assistants/hermes.js";

test("owner_any allows free-tier models off Meta; contributor models are refused in every mode", () => {
  const args = { provider: "openrouter_poc", model: "synthetic-meta-1-contributor" };
  for (const DATA_MODE of ["owner_any", "synthetic", "owner_real", undefined]) {
    assert.equal(dataModeProblem({ DATA_MODE }, args), "contributor model refused for model under every DATA_MODE");
  }
  assert.equal(dataModeProblem({ DATA_MODE: "owner_any" }, { provider: "openrouter_poc", model: "synthetic/x:free" }), null);
  assert.equal(dataModeProblem({ DATA_MODE: "synthetic" }, { provider: "openrouter_poc", model: "synthetic/x:free" }), null);
  assert.match(dataModeProblem({}, { provider: "openrouter_poc", model: "synthetic/x" }), /refused/);
  const env = { META_API_KEY: "k", META_MODEL: "synthetic-meta-1-contributor" };
  assert.match(metaConfigProblem(env), /contributor/);
  assert.match(metaConfigProblem({ ...env, DATA_MODE: "owner_any" }), /contributor/);
});

const hermes = { HERMES_BASE_URL: "https://a-b-c.trycloudflare.com", HERMES_API_KEY: "k", HERMES_SESSION_ID: "local-abc" };

test("quick_tunnel mode needs no Access secrets but only on trycloudflare.com", () => {
  assert.match(hermesConfigProblem(hermes), /CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET missing/);
  assert.equal(hermesConfigProblem({ ...hermes, HERMES_ACCESS_MODE: "quick_tunnel" }), null);
  assert.match(hermesConfigProblem({ ...hermes, HERMES_ACCESS_MODE: "quick_tunnel", HERMES_BASE_URL: "https://hermes.example.com" }), /trycloudflare/);
  assert.match(hermesConfigProblem({ ...hermes, HERMES_ACCESS_MODE: "open" }), /HERMES_ACCESS_MODE unknown/);
});

test("quick_tunnel requests carry no Access headers", async () => {
  const { callHermes } = await import("../src/assistants/hermes.js");
  let sent;
  const fetchFn = async (url, init) => { sent = init.headers; throw Object.assign(new Error("x"), { name: "TypeError" }); };
  await assert.rejects(callHermes("memory_recall", { query: "tea", limit: 3 }, { ...hermes, HERMES_ACCESS_MODE: "quick_tunnel" }, { fetchFn }));
  assert.equal(sent["CF-Access-Client-Id"], undefined);
  assert.match(sent.Authorization, /^Bearer /);
});

test("COUNCIL_TEST_PROVIDER=openrouter_poc runs the council on Nemotron via OpenRouter, not Nebius", async () => {
  const { callBrain, brainConfigProblem } = await import("../src/council/provider.js");
  const env = { COUNCIL_TEST_PROVIDER: "openrouter_poc", OPENROUTER_API_KEY: "k", DATA_MODE: "owner_any" };
  assert.equal(brainConfigProblem(env), null);
  assert.match(brainConfigProblem({ ...env, OPENROUTER_API_KEY: "" }), /OPENROUTER_API_KEY missing/);
  let url, body;
  const fetchFn = async (u, init) => {
    url = u; body = JSON.parse(init.body);
    return new Response(JSON.stringify({ choices: [{ message: { content: "ok" } }] }), { status: 200 });
  };
  const out = await callBrain([{ role: "user", content: "hi" }], env, { fetchFn });
  assert.equal(out.provider, "openrouter_poc");
  assert.match(url, /openrouter\.ai/);
  assert.match(body.model, /^nvidia\/nemotron/);
});
