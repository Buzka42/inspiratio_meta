// Proof-of-concept reply through OpenCode (REPLY_PROVIDER=opencode_poc). Testing only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { POC_DEFAULT_MODEL, POC_PROVIDER, replyConfigProblem, runReply } from "../src/reply.js";
import { OPENCODE_URL, SESSION_HEADER } from "../src/opencode.js";

const plan = { personality_id: "calm_guide", skill_id: null };
const okReply = (text) => async () => new Response(JSON.stringify({ choices: [{ message: { content: text } }] }), { status: 200 });

test("poc provider needs the OpenCode key and nothing else", () => {
  assert.equal(replyConfigProblem({ DATA_MODE: "synthetic", REPLY_PROVIDER: POC_PROVIDER, OPENCODE_API_KEY: "k" }), null);
  assert.match(replyConfigProblem({ DATA_MODE: "synthetic", REPLY_PROVIDER: POC_PROVIDER }), /OPENCODE_API_KEY missing/);
});

test("unknown provider is refused", () => {
  assert.match(replyConfigProblem({ REPLY_PROVIDER: "openai" }), /REPLY_PROVIDER unknown/);
});

test("default stays self-hosted: no provider means REPLY_LLM_BASE_URL is still required", () => {
  assert.match(replyConfigProblem({}), /REPLY_LLM_BASE_URL missing/);
});

test("poc call goes to OpenCode with key, session header and the default model", async () => {
  const calls = [];
  const fetchFn = async (url, init) => {
    calls.push({ url, init });
    return okReply("A calm reply.")(url, init);
  };
  const out = await runReply({
    plan, transcript: "I slept badly", fetchFn,
    env: { DATA_MODE: "synthetic", REPLY_PROVIDER: POC_PROVIDER, OPENCODE_API_KEY: "test-key" },
  });
  assert.equal(out.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, OPENCODE_URL);
  const headers = calls[0].init.headers;
  assert.equal(headers.Authorization, "Bearer test-key");
  assert.ok(headers[SESSION_HEADER].startsWith("illunis-reply-poc-"));
  assert.equal(JSON.parse(calls[0].init.body).model, POC_DEFAULT_MODEL);
});

test("poc reply still goes through the safety gate and fixed health line", async () => {
  const out = await runReply({
    plan, transcript: "I slept badly", fetchFn: okReply("A calm reply."),
    env: { DATA_MODE: "synthetic", REPLY_PROVIDER: POC_PROVIDER, OPENCODE_API_KEY: "test-key" },
  });
  assert.equal(out.body.safety, "passed");
  assert.equal(typeof out.body.health, "boolean");
});
