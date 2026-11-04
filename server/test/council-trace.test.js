// The council trace (T18): one entry per consult with the expert, the sources by kind and whether
// web search was used, unavailable or not needed; then a note when the run closed on a limit.
// Synthetic only: fake brain, fake retrieval, the real searchWeb over a fake Tavily fetch. No live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runCouncilV2 } from "../src/council/relay.js";
import { TAVILY_URL } from "../src/providers/tavily.js";

const NB_KEY = `nebius-test-${crypto.randomUUID()}`;
const TAVILY_KEY = `tvly-test-${crypto.randomUUID()}`;
const NEBIUS = { NEBIUS_API_KEY: NB_KEY, COUNCIL_NEBIUS_MODEL: "synthetic/brain-test", DATA_MODE: "synthetic" };
const TAVILY = { ...NEBIUS, TAVILY_API_KEY: TAVILY_KEY };
const tc = (id, expert_id, question) => ({ id, name: "consult", arguments: JSON.stringify({ expert_id, question }) });
const finalJson = () => JSON.stringify({ synthesis: "Synthetic synthesis: a calm evening may help.", sources: [], medical: false });
const passage = (bank, i) => ({ source_id: `${bank}-src-${i}`, title: `Synthetic ${bank} ${i}`, url: `https://example.test/${bank}/${i}`, text: `synthetic passage ${i}` });
const bank = (n) => async (b) => ({ passages: Array.from({ length: n }, (_, i) => passage(b, i + 1)), code: null });

// The relay asks for `consults` on its first turn, then closes. expert(input) answers each expert call.
function brain(consults, expert = (input) => ({ points: [{ text: "p", source_ids: input.sources.slice(0, 1).map((s) => s.id) }], confidence: 0.5 })) {
  let turns = 0;
  return async (messages, env, opts) => {
    if (opts.role === "expert") return { content: JSON.stringify(expert(JSON.parse(messages[1].content))), tool_calls: [], provider: "nebius" };
    return turns++ === 0 ? { content: "", tool_calls: consults, provider: "nebius" } : { content: finalJson(), tool_calls: [], provider: "nebius" };
  };
}

function tavily({ ok = true } = {}) {
  const calls = [];
  const fetchFn = async (url, init) => {
    assert.equal(url, TAVILY_URL, "only Tavily is fetched");
    calls.push(JSON.parse(init.body).query);
    if (!ok) return new Response("{}", { status: 503 });
    return new Response(
      JSON.stringify({ answer: "Synthetic web answer.", results: [{ title: "Synthetic web page", url: "https://web.example.test/1", content: "synthetic web content" }] }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  return { fetchFn, calls };
}

const consults = (out) => out.trace.filter((e) => e.expert);

test("trace: a bank-only consult lists its bank sources and web_search not_needed", async () => {
  const { fetchFn, calls } = tavily();
  const out = await runCouncilV2({ question: "synthetic sleep question" }, TAVILY, {
    callFn: brain([tc("c1", "sleep_lifestyle", "synthetic: why waking at 3am")]), retrieveFn: bank(3), fetchFn,
  });
  assert.deepEqual(calls, [], "no search for a bank with enough sources");
  assert.deepEqual(out.trace, [{
    expert: "sleep_lifestyle",
    field: "sleep and lifestyle",
    sources: [1, 2, 3].map((i) => ({ title: `Synthetic sleep_lifestyle ${i}`, kind: "bank" })),
    web_search: "not_needed",
    answered: true,
  }]);
});

test("trace: a Tavily-backed consult shows web_search used, web_via tavily and web sources", async () => {
  const { fetchFn, calls } = tavily();
  const out = await runCouncilV2({ question: "synthetic diet question" }, TAVILY, {
    callFn: brain([tc("c1", "diet", "synthetic diet question")]), retrieveFn: bank(1), fetchFn,
  });
  assert.deepEqual(calls, ["synthetic diet question"]);
  const [e] = consults(out);
  assert.equal(e.web_search, "used");
  assert.equal(e.web_via, "tavily");
  assert.deepEqual(e.sources, [{ title: "Synthetic diet 1", kind: "bank" }, { title: "Synthetic web page", kind: "web" }]);
});

test("trace: an expert's own search_query counts as used, and its results are web sources", async () => {
  const { fetchFn, calls } = tavily();
  const out = await runCouncilV2({ question: "synthetic training question" }, TAVILY, {
    callFn: brain([tc("c1", "training", "synthetic training question")], () => ({ points: [], confidence: 0.2, search_query: "synthetic follow-up" })),
    retrieveFn: bank(2),
    fetchFn,
  });
  assert.deepEqual(calls, ["synthetic follow-up"]);
  const [e] = consults(out);
  assert.equal(e.web_search, "used");
  assert.deepEqual(e.sources.map((s) => s.kind), ["bank", "bank", "web"]);
});

test("trace: Tavily not set up, or failing, gives web_search unavailable", async () => {
  for (const [env, ok] of [[NEBIUS, true], [TAVILY, false]]) {
    const { fetchFn } = tavily({ ok });
    const out = await runCouncilV2({ question: "synthetic diet question" }, env, {
      callFn: brain([tc("c1", "diet", "synthetic diet question")]), retrieveFn: bank(0), fetchFn,
    });
    const [e] = consults(out);
    assert.equal(e.web_search, "unavailable");
    assert.equal(e.web_via, undefined);
    assert.deepEqual(e.sources, []);
  }
});

test("trace: one entry per consult in call order; an expert that failed is answered false", async () => {
  const callFn = brain([tc("a", "diet", "synthetic q diet"), tc("b", "training", "synthetic q training")]);
  const failing = async (messages, env, opts) => {
    if (opts.role === "expert" && messages[1].content.includes("training")) throw new Error("synthetic upstream");
    return callFn(messages, env, opts);
  };
  const out = await runCouncilV2({ question: "synthetic big question" }, NEBIUS, { callFn: failing, retrieveFn: bank(2) });
  assert.deepEqual(out.trace.map((e) => [e.expert, e.answered]), [["diet", true], ["training", false]]);
});

test("trace: carries no question text (user or relay); no ids, urls or keys", async () => {
  const userQ = "synthetic private user question about my evenings";
  const relayQ = "synthetic relay question quoting my evenings";
  const { fetchFn } = tavily();
  const out = await runCouncilV2({ question: userQ }, TAVILY, {
    callFn: brain([tc("c1", "diet", relayQ)]), retrieveFn: bank(1), fetchFn,
  });
  const [e] = consults(out);
  const text = JSON.stringify(out.trace);
  for (const leak of [userQ, relayQ, "my evenings", "https://", "-src-", "web:", NB_KEY, TAVILY_KEY, "Synthetic web answer", "synthetic passage"]) {
    assert.ok(!text.includes(leak), leak);
  }
  assert.deepEqual(Object.keys(e).sort(), ["answered", "expert", "field", "sources", "web_search", "web_via"]);
});

test("trace: a run closed by the consult limit or the time limit ends with a note", async () => {
  const two = [tc("a", "diet", "synthetic q diet"), tc("b", "training", "synthetic q training")];
  const byCount = await runCouncilV2({ question: "synthetic question" }, NEBIUS, {
    callFn: brain(two), retrieveFn: bank(2), limits: { maxConsults: 1 },
  });
  assert.deepEqual(byCount.trace.map((e) => e.expert ?? e.note), ["diet", "consult_limit"]);

  let t = 0;
  const byTime = await runCouncilV2({ question: "synthetic question" }, NEBIUS, {
    callFn: brain(two),
    retrieveFn: async (b) => {
      t += 40_000; // the consults use up the time limit
      return bank(2)(b);
    },
    now: () => t,
  });
  assert.equal(byTime.trace.at(-1).note, "time_limit");
  assert.ok(byTime.limits_hit.includes("time_limit"));
});

test("trace: a crisis gets an empty trace", async () => {
  const out = await runCouncilV2({ question: "I want to kill myself" }, NEBIUS, { callFn: async () => assert.fail("no call") });
  assert.equal(out.crisis, true);
  assert.deepEqual(out.trace, []);
});
