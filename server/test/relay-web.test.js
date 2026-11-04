// Relay side of web search (contract C3) and the brain routing with Meta unset (T2).
// Synthetic only: fake brain, fake retrieval, fake search, fake fetch. No live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { THIN_BANK, filterPoints, runCouncilV2 } from "../src/council/relay.js";
import { brainConfigProblem, callBrain } from "../src/council/provider.js";

const NB_KEY = `nebius-test-${crypto.randomUUID()}`;
const NEBIUS = { NEBIUS_API_KEY: NB_KEY, COUNCIL_NEBIUS_MODEL: "synthetic/brain-test" };
const tc = (id, expert_id, question) => ({ id, name: "consult", arguments: JSON.stringify({ expert_id, question }) });
const finalJson = (o = {}) => JSON.stringify({ synthesis: "Synthetic synthesis: a calm evening may help.", experts_consulted: [], sources: [], medical: false, ...o });
const passage = (bank, i) => ({ source_id: `${bank}-src-${i}`, title: `Synthetic ${bank} ${i}`, url: `https://example.test/${bank}/${i}`, licence: "OGL-3.0", text: `synthetic passage ${i}`, score: 0.9 });

// Fake brain: the relay asks for `consults` on its first turn, then gives the final JSON.
// expert(input) answers expert calls with the expert JSON; input is {question, sources}.
function brain({ consults, expert, final = () => finalJson() }) {
  const log = [];
  let relayTurns = 0;
  const callFn = async (messages, env, opts) => {
    if (opts.role === "expert") {
      const input = JSON.parse(messages[1].content);
      log.push(["expert", input]);
      return { content: JSON.stringify(expert(input)), tool_calls: [], provider: "nebius" };
    }
    log.push(["relay", messages]);
    if (relayTurns++ === 0) return { content: "", tool_calls: consults, provider: "nebius" };
    return { content: final(messages), tool_calls: [], provider: "nebius" };
  };
  return { callFn, log };
}

function searcher() {
  const queries = [];
  const searchFn = async (query) => {
    queries.push(query);
    const n = queries.length;
    return { text: "Synthetic web answer.", results: [1, 2].map((i) => ({ title: `Synthetic web ${n}.${i}`, url: `https://web.example.test/${n}/${i}`, content: `synthetic web content ${n}.${i}` })) };
  };
  return { searchFn, queries };
}

test("relay: a thin bank triggers a search before the expert call; a point citing web:1.1 survives", async () => {
  assert.equal(THIN_BANK, 2);
  const seen = [];
  const retrieveFn = async (bank, q, env, opts) => {
    seen.push(opts);
    return { passages: [passage(bank, 1)], code: null };
  };
  const { searchFn, queries } = searcher();
  const order = [];
  const search = async (...a) => { order.push("search"); return searchFn(...a); };
  const { callFn, log } = brain({
    consults: [tc("c1", "sleep_lifestyle", "synthetic: why waking at 3am")],
    expert: (input) => {
      order.push("expert");
      assert.deepEqual(input.sources.map((s) => s.id), ["sleep_lifestyle-src-1", "web:1.1", "web:1.2"]);
      assert.equal(input.sources[1].text, "synthetic web content 1.1");
      return { points: [{ text: "SYNTH-WEB-POINT", source_ids: ["web:1.1"] }], caveats: [], confidence: 0.5, search_query: null };
    },
    final: (messages) => {
      const tool = JSON.parse(messages.find((m) => m.role === "tool").content);
      assert.deepEqual(tool.points, [{ text: "SYNTH-WEB-POINT", source_ids: ["web:1.1"] }], "the web-cited point survives filterPoints");
      return finalJson();
    },
  });
  const fetchFn = async () => assert.fail("no network");
  const out = await runCouncilV2({ question: "synthetic sleep question" }, NEBIUS, { callFn, retrieveFn, searchFn: search, fetchFn });
  assert.deepEqual(order, ["search", "expert"]);
  assert.deepEqual(queries, ["synthetic: why waking at 3am"], "the consult question is searched");
  assert.equal(seen[0].k, 5);
  assert.equal(seen[0].fetchFn, fetchFn, "retrieve gets {k: 5, fetchFn}");
  assert.deepEqual(out.providers, ["nebius"]);
  // The relay named no sources: cited ids plus every web id.
  assert.deepEqual(out.sources.map((s) => [s.id, s.kind]), [["web:1.1", "web"], ["web:1.2", "web"]]);
  assert.equal(log.filter(([k]) => k === "expert").length, 1);
});

test("relay: a bank with enough sources is not searched before the expert call", async () => {
  const retrieveFn = async (bank) => ({ passages: [passage(bank, 1), passage(bank, 2)], code: null });
  const { searchFn, queries } = searcher();
  const { callFn } = brain({
    consults: [tc("c1", "diet", "synthetic diet question")],
    expert: (input) => ({ points: [{ text: "p", source_ids: [input.sources[0].id] }], caveats: [], confidence: 0.5 }),
  });
  const out = await runCouncilV2({ question: "synthetic diet question" }, NEBIUS, { callFn, retrieveFn, searchFn });
  assert.deepEqual(queries, []);
  assert.deepEqual(out.sources.map((s) => s.kind), ["bank"]);
});

test("relay: parallel thin consults keep the search bound and distinct web ids", async () => {
  const retrieveFn = async () => ({ passages: [], code: "knowledge_not_bound" });
  const { searchFn, queries } = searcher();
  const given = [];
  const { callFn } = brain({
    consults: [tc("a", "diet", "synthetic q diet"), tc("b", "training", "synthetic q training"), tc("c", "sleep_lifestyle", "synthetic q sleep")],
    expert: (input) => {
      given.push(input.sources.map((s) => s.id));
      return { points: [], caveats: [], confidence: 0.1, search_query: "synthetic follow-up" };
    },
  });
  const out = await runCouncilV2({ question: "synthetic big question" }, NEBIUS, { callFn, retrieveFn, searchFn });
  assert.equal(queries.length, 2, "maxSearches holds across parallel consults");
  // The consult without a search reaches its expert first; order between consults is not fixed.
  assert.deepEqual(given.map((g) => g.join(",")).sort(), ["", "web:1.1,web:1.2", "web:2.1,web:2.2"]);
  assert.deepEqual(out.sources.map((s) => s.id), ["web:1.1", "web:1.2", "web:2.1", "web:2.2"]);
});

test("relay: no search provider leaves a thin bank without web sources", async () => {
  const retrieveFn = async () => ({ passages: [], code: "knowledge_not_bound" });
  const { callFn } = brain({
    consults: [tc("c1", "diet", "synthetic diet question")],
    expert: (input) => {
      assert.deepEqual(input.sources, []);
      return { points: [], caveats: [], confidence: 0 };
    },
  });
  const out = await runCouncilV2({ question: "synthetic diet question" }, NEBIUS, { callFn, retrieveFn, searchFn: async () => null });
  assert.deepEqual(out.sources, []);
});

test("filterPoints: a web id in the retrieved set is citable", () => {
  const pts = [{ text: "a", source_ids: ["web:1.1"] }, { text: "b", source_ids: ["web:9.9"] }];
  assert.deepEqual(filterPoints(pts, new Set(["web:1.1"])).map((p) => p.text), ["a"]);
});

test("callBrain: with Meta unset the brain routes to Nebius (T2)", async () => {
  const urls = [];
  const fetchFn = async (url, init) => {
    urls.push(url);
    assert.equal(JSON.parse(init.body).model, NEBIUS.COUNCIL_NEBIUS_MODEL);
    return new Response(JSON.stringify({ choices: [{ message: { content: "synthetic" } }] }), { status: 200 });
  };
  for (const env of [NEBIUS, { ...NEBIUS, META_API_KEY: "" }, { ...NEBIUS, META_MODEL: "synthetic/meta-model" }]) {
    assert.equal(brainConfigProblem(env), null);
    const out = await callBrain([{ role: "user", content: "synthetic" }], env, { fetchFn });
    assert.equal(out.provider, "nebius");
  }
  assert.ok(urls.every((u) => u === "https://api.tokenfactory.nebius.com/v1/chat/completions"));
  // A Meta key without META_MODEL is a config error, not a silent fallback (no model id in code).
  assert.equal(brainConfigProblem({ ...NEBIUS, META_API_KEY: "synthetic" }), "META_MODEL missing");
});
