// Strict parsing of the session summary model output: balanced extraction, required shape, never the raw text.
import { test } from "node:test";
import assert from "node:assert/strict";
import { firstObject, parseSummary, summarizeSession } from "../src/session-summary.js";

const TURNS = [{ role: "user", text: "synthetic text" }];
const run = async (content) => {
  const logs = [];
  const opts = { roles: [] };
  const callFn = async (_msgs, _env, o) => (opts.roles.push(o.role), opts.maxTokens = o.maxTokens, { content, provider: "meta" });
  const out = await summarizeSession({ turns: TURNS }, {}, { callFn, logger: { warn: (...a) => logs.push(a) } });
  return { out, logs, opts };
};
const EMPTY = { summary: null, topics: [], safety: "empty", provider: "meta" };

test("fenced JSON parses", async () => {
  const { out, opts } = await run('```json\n{"summary":"Synthetic: user plans a walk.","topics":["walk"]}\n```');
  assert.deepEqual(out, { summary: "Synthetic: user plans a walk.", topics: ["walk"], safety: "passed", provider: "meta" });
  assert.deepEqual(opts.roles, ["summary"]);
  assert.equal(opts.maxTokens, 600);
});

test("prose with braces before the object still parses; braces inside strings are kept", async () => {
  const { out } = await run('Plan {draft} and } stray. {"summary":"Synthetic {braced} note.","topics":["a}b"]} trailing }');
  assert.equal(out.summary, "Synthetic {braced} note.");
  assert.deepEqual(out.topics, ["a}b"]);
  assert.deepEqual(firstObject('x {"a":"\\"}"} y {"b":1}'), { a: '"}' });
});

test("invalid JSON gives the empty result, never the raw text, and logs only the fixed code", async () => {
  const raw = "Synthetic raw model prose {not json";
  const { out, logs } = await run(raw);
  assert.deepEqual(out, EMPTY);
  assert.ok(!JSON.stringify(out).includes("Synthetic"));
  assert.deepEqual(logs, [["summary_parse_failed"]]);
  assert.deepEqual(await run("plain prose, no object").then((r) => r.out), EMPTY);
});

test("missing or mistyped fields give the empty result", async () => {
  for (const c of ['{"topics":["a"]}', '{"summary":"Synthetic."}', '{"summary":5,"topics":[]}', '{"summary":"Synthetic.","topics":"a"}', '{"summary":"Synthetic.","topics":[1]}', '["summary"]']) {
    assert.equal(parseSummary(c), null, c);
    assert.deepEqual((await run(c)).out, EMPTY, c);
  }
});
