import { test } from "node:test";
import assert from "node:assert/strict";
import { META_CONTRIBUTOR_REFUSED, META_MINIMAL_EFFORT_ROLES, chatMeta, metaConfigProblem, readResponses, webSearchMeta } from "../src/providers/meta.js";

const META = { META_API_KEY: "synthetic-key", META_MODEL: "synthetic-muse-1" };
const json = (body) => new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
const recorder = (reply) => {
  const bodies = [];
  const fn = async (_url, init) => { bodies.push(JSON.parse(init.body)); return json(reply); };
  return { fn, bodies };
};
const chatReply = { choices: [{ message: { role: "assistant", content: "ok" } }] };

test("meta: role-keyed max_tokens floors, caller value wins when higher", async () => {
  const floors = { relay: 2000, final: 3000, plan: 1500, expert: 2000, repair: 2000, summary: 1500, web: 3000, reply: 2000, mystery: 2000, [undefined]: 2000 };
  for (const [role, floor] of Object.entries(floors)) {
    const { fn, bodies } = recorder(chatReply);
    await chatMeta([{ role: "user", content: "synthetic" }], META, { fetchFn: fn, role: role === "undefined" ? undefined : role, maxTokens: 400 });
    assert.equal(bodies[0].max_tokens, floor, role);
  }
  const { fn, bodies } = recorder(chatReply);
  await chatMeta([], META, { fetchFn: fn, role: "plan", maxTokens: 5000 });
  assert.equal(bodies[0].max_tokens, 5000);
});

test("meta: reasoning_effort minimal only for plan, expert and summary", async () => {
  const tools = [{ type: "function", function: { name: "synthetic_tool", parameters: { type: "object" } } }];
  const cases = [["plan"], ["expert", { json: true }], ["summary"], ["relay", { tools }], ["final"], ["repair"], ["reply"], ["web"], [undefined]];
  for (const [role, extra] of cases) {
    const { fn, bodies } = recorder(chatReply);
    await chatMeta([{ role: "user", content: "synthetic" }], META, { fetchFn: fn, role, ...extra });
    assert.equal(bodies[0].reasoning_effort, META_MINIMAL_EFFORT_ROLES.has(role) ? "minimal" : undefined, String(role));
  }
  assert.deepEqual([...META_MINIMAL_EFFORT_ROLES], ["plan", "expert", "summary"]);
  const { fn, bodies } = recorder({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: "ok" }] }] });
  await webSearchMeta("synthetic query", META, { fetchFn: fn });
  assert.equal("reasoning_effort" in bodies[0], false);
});

test("meta: web_search asks for 3000 output tokens; narration-only incomplete response is meta_incomplete", async () => {
  const { fn, bodies } = recorder({
    status: "incomplete", incomplete_details: { reason: "max_output_tokens" },
    output: [{ type: "message", content: [{ type: "output_text", text: "I will search the web now.", annotations: [] }] }],
  });
  await assert.rejects(webSearchMeta("synthetic query", META, { fetchFn: fn }), (e) => e.code === "meta_incomplete" && e.fallback === true);
  assert.equal(bodies[0].max_output_tokens, 3000);
  assert.throws(() => readResponses({ incomplete_details: { reason: "max_output_tokens" }, output: [] }), (e) => e.code === "meta_incomplete");
});

test("meta: only the final message's cited parts reach the result", () => {
  const cite = (url) => ({ type: "url_citation", url, title: `T ${url}` });
  const out = readResponses({
    status: "completed",
    output: [
      { type: "message", content: [{ type: "output_text", text: "Earlier message.", annotations: [cite("https://early.test/x")] }] },
      { type: "web_search_call" },
      { type: "message", content: [
        { type: "output_text", text: "Let me look that up.", annotations: [] },
        { type: "output_text", text: "Synthetic cited fact.", annotations: [cite("https://a.test/1"), cite("http://insecure.test/2")] },
        { type: "output_text", text: "Second cited fact.", annotations: [cite("https://a.test/1"), ...[3, 4, 5, 6, 7, 8].map((n) => cite(`https://b.test/${n}`))] },
      ] },
    ],
  });
  assert.equal(out.text, "Synthetic cited fact. Second cited fact.");
  assert.equal(out.complete, true);
  assert.deepEqual(out.results.map((r) => r.url), ["https://a.test/1", "https://b.test/3", "https://b.test/4", "https://b.test/5", "https://b.test/6"]);
  const none = readResponses({ output: [{ type: "message", content: [{ type: "output_text", text: "Uncited answer." }] }] });
  assert.deepEqual(none, { text: "Uncited answer.", results: [], complete: true });
});

test("meta: contributor models refused under owner_real, synthetic and owner_any", async () => {
  for (const DATA_MODE of [undefined, "owner_real", "synthetic", "owner_any"]) {
    const env = { ...META, META_MODEL: "Synthetic-Muse-CONTRIBUTOR", DATA_MODE };
    assert.equal(metaConfigProblem(env), META_CONTRIBUTOR_REFUSED, String(DATA_MODE));
    let calls = 0;
    const fn = async () => { calls++; return json(chatReply); };
    await assert.rejects(chatMeta([], env, { fetchFn: fn }), (e) => e.code === "meta_contributor_refused");
    await assert.rejects(chatMeta([], { ...META, DATA_MODE }, { fetchFn: fn, model: "x-contributor" }), (e) => e.code === "meta_contributor_refused");
    await assert.rejects(webSearchMeta("q", env, { fetchFn: fn }), (e) => e.code === "meta_contributor_refused");
    assert.equal(calls, 0);
  }
});
