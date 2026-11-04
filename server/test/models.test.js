import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { COUNCIL_MODELS, COUNCIL_PROVIDER, MODELS, OPENROUTER_MEMBERS } from "../src/models.js";
import { POC_DEFAULT_MODEL, POC_PROVIDER, replyEndpoint } from "../src/reply.js";
import { NEBIUS_PROVIDER, nebiusConfigProblem } from "../src/nebius.js";
import { MEMORY_POC_DEFAULT_EMBED_MODEL, MEMORY_POC_DEFAULT_LLM, MEMORY_POC_PROVIDER, embed, extractFact } from "../src/memory-poc.js";
import { DEFAULT_MEMBERS } from "../src/council.js";
import { metaConfigProblem, metaModel } from "../src/providers/meta.js";

const captureBody = () => {
  const calls = [];
  const fetchFn = async (_url, init) => {
    calls.push(JSON.parse(init.body));
    return new Response("{}", { status: 200 });
  };
  return { calls, fetchFn };
};

test("models.js table matches the defaults the code uses", async () => {
  // Reply (daily talk): OpenCode PoC default, Nebius has no default.
  assert.equal(MODELS.reply.provider, POC_PROVIDER);
  assert.equal(POC_DEFAULT_MODEL, MODELS.reply.model);
  assert.equal(replyEndpoint({ DATA_MODE: "synthetic", REPLY_PROVIDER: POC_PROVIDER, OPENCODE_API_KEY: "k" }).model, MODELS.reply.model);
  assert.equal(replyEndpoint({ REPLY_PROVIDER: POC_PROVIDER, OPENCODE_API_KEY: "k", REPLY_LLM_MODEL: "x" }).model, "x");
  assert.equal(MODELS.reply_nebius.provider, NEBIUS_PROVIDER);
  assert.equal(MODELS.reply_nebius.model, null);
  assert.match(nebiusConfigProblem({ NEBIUS_API_KEY: "k" }), /REPLY_LLM_MODEL missing/);

  // Memory PoC: the request bodies carry the table defaults, env still overrides.
  assert.equal(MEMORY_POC_DEFAULT_LLM, MODELS.memory_llm.model);
  assert.equal(MEMORY_POC_DEFAULT_EMBED_MODEL, MODELS.memory_embed.model);
  const env = { DATA_MODE: "synthetic", MEMORY_PROVIDER: MEMORY_POC_PROVIDER, OPENCODE_API_KEY: "k", NEBIUS_API_KEY: "k" };
  const { calls, fetchFn } = captureBody();
  await extractFact("note", env, { fetchFn });
  await embed("note", env, { fetchFn });
  await embed("note", { ...env, MEMORY_EMBED_MODEL: "y" }, { fetchFn });
  assert.deepEqual(calls.map((b) => b.model), [MODELS.memory_llm.model, MODELS.memory_embed.model, "y"]);

  // Council members.
  assert.equal(COUNCIL_PROVIDER, "opencode");
  assert.deepEqual(Object.fromEntries(DEFAULT_MEMBERS.map((m) => [m.id, m.model])), COUNCIL_MODELS);

  // Council v2 brain: no model id in code (D-E). META_MODEL is required with META_API_KEY; COUNCIL_NEBIUS_MODEL too.
  assert.equal(MODELS.council_primary.model, null);
  assert.equal(metaModel({ META_API_KEY: "k" }), null);
  assert.equal(metaConfigProblem({ META_API_KEY: "k" }), "META_MODEL missing");
  assert.equal(MODELS.council_nebius.model, null);
});

test("no model id is hard-coded in server/src outside models.js", () => {
  const ids = [...Object.values(MODELS).map((r) => r.model).filter(Boolean), ...Object.values(COUNCIL_MODELS), ...Object.values(OPENROUTER_MEMBERS)];
  // Recursive: council/, providers/, knowledge/ and analysis/ are covered too.
  const dir = new URL("../src/", import.meta.url);
  for (const name of readdirSync(dir, { recursive: true }).filter((n) => n.endsWith(".js") && n !== "models.js")) {
    const text = readFileSync(new URL(name, dir), "utf8");
    for (const id of ids) assert.ok(!text.includes(`"${id}"`), `${name} hard-codes ${id}`);
  }
});
