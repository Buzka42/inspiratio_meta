// Relay hardening from the live Muse run (2 Nov 2026): hidden reasoning spends max_tokens, so a final JSON can come
// back as a fragment; it must never be spoken. Synthetic only: fake brain, fake retrieval, no network.
import { test } from "node:test";
import assert from "node:assert/strict";
import { CHAT_ANSWER_RULE, jsonIn, parseFinal, runCouncilV2 } from "../src/council/relay.js";
import { REFERRAL_TEXT } from "../src/safety.js";

const NEBIUS = { NEBIUS_API_KEY: `nebius-test-${crypto.randomUUID()}`, COUNCIL_NEBIUS_MODEL: "synthetic/brain-test" };
const tc = (id, expert_id, question) => ({ id, name: "consult", arguments: JSON.stringify({ expert_id, question }) });
const finalJson = (o = {}) => JSON.stringify({ synthesis: "Synthetic synthesis: walk twenty minutes.", experts_consulted: [], sources: [], medical: false, ...o });
const passage = (bank, i) => ({ source_id: `${bank}-src-${i}`, title: `Synthetic ${bank} ${i}`, url: `https://example.test/${bank}/${i}`, text: `synthetic ${i}` });
const bank = async (b) => ({ passages: [passage(b, 1), passage(b, 2)], code: null });
const none = async () => ({ passages: [], code: "knowledge_not_bound" });
const FRAGMENT = '{"synthesis":"Synthetic half an ans';

// Fake brain: first relay turn asks for `consults`, later relay turns give `final`; expert calls get `expert`.
function brain({ consults = [], expert = () => JSON.stringify({ points: [], caveats: [], confidence: 0 }), final = () => finalJson(), plan } = {}) {
  const calls = [];
  let relayTurns = 0;
  const callFn = async (messages, env, opts) => {
    calls.push(opts);
    if (opts.role === "expert") return { content: expert(JSON.parse(messages[1].content)), tool_calls: [], provider: "nebius" };
    if (plan && opts.tools) throw Object.assign(new Error("synthetic"), { status: 400 });
    if (opts.role === "plan") return { content: plan(), tool_calls: [], provider: "nebius" };
    if (opts.tools && relayTurns++ === 0) return { content: "", tool_calls: consults, provider: "nebius" };
    return { content: final(), tool_calls: [], provider: "nebius" };
  };
  return { callFn, calls };
}

test("parseFinal: unparseable or fragment JSON never returns the raw text", () => {
  for (const raw of [FRAGMENT, "Synthetic plain prose answer.", '{"answer":"no synthesis key"}', "", undefined]) {
    assert.deepEqual(parseFinal(raw), { synthesis: "", sources: [], medical: false, bad_json: true });
  }
  assert.equal(parseFinal(finalJson()).synthesis, "Synthetic synthesis: walk twenty minutes.");
});

test("jsonIn: balanced scan returns the first complete object; prose and string braces do not break it", () => {
  assert.deepEqual(jsonIn('Here {not json} then {"a":"x } y {","b":{"c":1}} and later {"d":2}'), { a: "x } y {", b: { c: 1 } });
  assert.deepEqual(jsonIn('<think>{"thought":1}</think>```json\n{"synthesis":"s \\" }"}\n```'), { synthesis: 's " }' });
  assert.equal(jsonIn(FRAGMENT), null);
  assert.equal(jsonIn("no braces"), null);
});

test("relay: a fragment final reply is not spoken; final_bad_json and NO_ANSWER", async () => {
  const { callFn } = brain({ consults: [tc("c1", "diet", "synthetic q")], final: () => FRAGMENT });
  const out = await runCouncilV2({ question: "synthetic question" }, NEBIUS, { callFn, retrieveFn: bank, searchFn: async () => null });
  assert.ok(out.limits_hit.includes("final_bad_json"));
  assert.ok(out.limits_hit.includes("no_synthesis"));
  assert.ok(!out.synthesis.includes("Synthetic half"));
  assert.equal(out.synthesis, "The council could not finish an answer this time.");
  assert.equal(out.gate, "passed");
});

test("relay: invalid expert JSON records expert_bad_json and answered false", async () => {
  const { callFn } = brain({ consults: [tc("c1", "diet", "synthetic q")], expert: () => '{"points":[{"text":"cut' });
  const out = await runCouncilV2({ question: "synthetic question" }, NEBIUS, { callFn, retrieveFn: bank, searchFn: async () => null });
  assert.ok(out.limits_hit.includes("expert_bad_json"));
  assert.equal(out.trace[0].answered, false);
});

test("relay: crisis text in signals or findings gets the referral before any call", async () => {
  for (const context of [{ signals: { note: "I want to kill myself" } }, { findings: ["synthetic", { text: "I want to kill myself" }] }]) {
    const out = await runCouncilV2({ question: "synthetic question", context }, NEBIUS, {
      callFn: async () => assert.fail("no model call"), retrieveFn: async () => assert.fail("no retrieval"),
    });
    assert.equal(out.crisis, true);
    assert.equal(out.synthesis, REFERRAL_TEXT);
  }
});

test("relay: no passages and no web results in the whole run records no_retrieval in hits and trace", async () => {
  const { callFn } = brain({ consults: [tc("c1", "diet", "synthetic q")] });
  const out = await runCouncilV2({ question: "synthetic question" }, NEBIUS, { callFn, retrieveFn: none, searchFn: async () => null });
  assert.ok(out.limits_hit.includes("no_retrieval"));
  assert.ok(out.trace.some((e) => e.note === "no_retrieval"));
  const withBank = await runCouncilV2({ question: "synthetic question" }, NEBIUS, { callFn: brain({ consults: [tc("c1", "diet", "q")] }).callFn, retrieveFn: bank });
  assert.ok(!withBank.limits_hit.includes("no_retrieval"));
});

test("relay: call-site roles and one shared deadlineAt", async () => {
  let t = 1_000;
  const now = () => t;
  const searched = [];
  const tools = brain({ consults: [tc("c1", "diet", "synthetic q")] });
  await runCouncilV2({ question: "synthetic question" }, NEBIUS, {
    callFn: tools.callFn, retrieveFn: none, now, searchFn: async (q, env, opts) => (searched.push(opts), null),
  });
  assert.deepEqual(tools.calls.map((c) => c.role), ["relay", "expert", "relay"]);
  assert.ok(tools.calls.every((c) => c.deadlineAt === 1_000 + 45_000));
  assert.equal(searched[0].deadlineAt, 46_000);

  const planned = brain({ plan: () => JSON.stringify({ consult: [{ expert_id: "diet", question: "synthetic q" }] }) });
  await runCouncilV2({ question: "synthetic question" }, NEBIUS, { callFn: planned.callFn, retrieveFn: bank, now });
  assert.deepEqual(planned.calls.map((c) => c.role), ["relay", "plan", "expert", "final"]);
  assert.ok(planned.calls.every((c) => c.maxTokens > 0));
});

test("CHAT_ANSWER_RULE: no surviving point means no sourced figure, never an invented one", () => {
  assert.match(CHAT_ANSWER_RULE, /no sourced figure/);
  assert.match(CHAT_ANSWER_RULE, /do not invent one/);
});

test("COUNCIL_EXPERTS with an unknown id records the fixed hit expert_ids_unknown", async () => {
  const seen = [];
  const out = await runCouncilV2({ question: "synthetic: how is my week", purpose: "chat" },
    { DATA_MODE: "synthetic", META_API_KEY: "synthetic-key", META_MODEL: "synthetic-model", COUNCIL_EXPERTS: "diet,astrology" },
    { fetchFn: async () => { throw new Error("no network in this test"); }, retrieveFn: async () => ({ passages: [], code: null }), searchFn: async () => null, callFn: async (m) => { seen.push(m); return { content: '{"consult":[]}', tool_calls: [], provider: "meta" }; } });
  assert.ok((out.limits_hit ?? []).includes("expert_ids_unknown") || JSON.stringify(out).includes("expert_ids_unknown"), "hit recorded");
  assert.ok(!JSON.stringify(out).includes("astrology"), "unknown id is never echoed");
});
