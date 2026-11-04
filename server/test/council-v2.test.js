// Council v2: Meta client, brain fallback, DATA_MODE guard, relay bounds and gates, retrieval.
// Every network call is a fake; keys are generated per run; all text is synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { META_BASE_URL, chatMeta, metaConfigProblem, readResponses, webSearchMeta } from "../src/providers/meta.js";
import { callBrain, brainConfigProblem } from "../src/council/provider.js";
import { councilNebiusConfigProblem } from "../src/nebius.js";
import { dataModeProblem } from "../src/data-mode.js";
import { replyConfigProblem } from "../src/reply.js";
import { createStore, InMemoryStore } from "../src/memory.js";
import { councilConfigProblem } from "../src/council.js";
import { EXPERTS, EXPERT_IDS } from "../src/council/experts.js";
import { LIMITS, filterPoints, parseExpert, relaySystem, runCouncilV2 } from "../src/council/relay.js";
import { EMBED_DIMS, EMBED_MODEL, retrieve } from "../src/knowledge/retrieve.js";
import { CLINICIAN_PATH, NOT_MEDICAL_ADVICE, REFERRAL_TEXT, SAFE_FALLBACK_TEXT } from "../src/safety.js";
import { MODELS } from "../src/models.js";

const KEY = `meta-test-${crypto.randomUUID()}`;
const NB_KEY = `nebius-test-${crypto.randomUUID()}`;
const META = { META_API_KEY: KEY, META_MODEL: "synthetic/meta-model-test" };
const NEBIUS = { NEBIUS_API_KEY: NB_KEY, COUNCIL_NEBIUS_MODEL: "synthetic/brain-test" };
const BOTH = { ...META, ...NEBIUS };

const res = (body, status = 200) => new Response(JSON.stringify(body), { status });
const chat = (content, tool_calls) => res({ choices: [{ message: { content, ...(tool_calls ? { tool_calls } : {}) } }] });
const tc = (id, expert_id, question = "synthetic follow-up") => ({
  id, type: "function", function: { name: "consult", arguments: JSON.stringify({ expert_id, question }) },
});
const finalJson = (o) => JSON.stringify({ synthesis: "Synthetic synthesis: consider a short walk.", experts_consulted: [], sources: [], medical: false, ...o });
const noNet = () => { throw new Error("network touched"); };

// Fake brain endpoint. relay(body, n) answers relay calls; expert(question, expertSystem) answers expert calls.
function brainFake({ relay, expert = () => ({ points: [], caveats: [], confidence: 0.5 }), responses } = {}) {
  const calls = [];
  let n = 0;
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body, headers: init.headers });
    if (url.endsWith("/responses")) return responses ? responses(body) : res({ output: [] });
    if (body.messages[0].content.startsWith("You are one expert")) {
      return chat(JSON.stringify(expert(JSON.parse(body.messages[1].content), body.messages[0].content)));
    }
    return relay(body, n++);
  };
  return { fn, calls, relayCalls: () => calls.filter((c) => c.body.messages?.[0]?.content.startsWith("You are the relay")) };
}

// Fake bindings: every expert bank holds two synthetic sources.
function bindings({ dims = EMBED_DIMS } = {}) {
  const queries = [];
  return {
    queries,
    AI: { run: async (model, { text }) => ({ shape: [text.length, dims], data: text.map(() => Array.from({ length: dims }, () => 0.01)), model }) },
    KNOWLEDGE: {
      async query(vector, opts) {
        queries.push({ len: vector.length, ...opts });
        const ns = opts.namespace;
        return {
          matches: [1, 2].map((i) => ({
            id: `${ns}:${i}`, score: 0.9,
            metadata: { expert: ns, source_id: `${ns}-src-${i}`, title: `Synthetic ${ns} ${i}`, url: `https://example.test/${ns}/${i}`, licence: "OGL-3.0", text: `synthetic passage ${i}` },
          })),
        };
      },
    },
  };
}

// ---- Meta client ----

test("meta: base pinned to https api.meta.ai/v1, key required, contributor refused", () => {
  assert.equal(META_BASE_URL, "https://api.meta.ai/v1");
  assert.equal(metaConfigProblem(META), null);
  assert.match(metaConfigProblem({}), /^META_API_KEY missing$/);
  assert.equal(metaConfigProblem({ META_API_KEY: KEY }), "META_MODEL missing", "no model id in code");
  for (const bad of ["http://api.meta.ai/v1", "https://api.meta.ai.evil.test/v1", "https://evil.test/v1", "https://api.meta.ai:444/v1", "https://u:p@api.meta.ai/v1", "https://api.meta.ai/v2", "https://api.meta.ai/v1/chat/completions"]) {
    assert.match(metaConfigProblem({ ...META, META_BASE_URL: bad }), /META_BASE_URL refused/, bad);
  }
  assert.equal(metaConfigProblem({ ...META, META_BASE_URL: "https://api.meta.ai/v1/" }), null);
  assert.match(metaConfigProblem({ ...META, META_MODEL: "synthetic-meta-1-contributor" }), /contributor/);
  for (const v of [KEY]) assert.ok(!String(metaConfigProblem({ META_API_KEY: v, META_BASE_URL: "x" })).includes(v));
});

test("meta: chat completions request, default model, bearer key, tools passed; contributor never sent", async () => {
  const { fn, calls } = brainFake({ relay: () => chat("ok") });
  const out = await chatMeta([{ role: "user", content: "synthetic" }], META, { fetchFn: fn, tools: [{ type: "function", function: { name: "consult" } }] });
  assert.equal(out.content, "ok");
  assert.equal(calls[0].url, "https://api.meta.ai/v1/chat/completions");
  assert.equal(calls[0].headers.Authorization, `Bearer ${KEY}`);
  assert.equal(calls[0].body.model, META.META_MODEL);
  assert.equal(calls[0].body.tool_choice, "auto");
  assert.ok(!("response_format" in calls[0].body), "json mode is off when tools are offered");
  await assert.rejects(chatMeta([], META, { fetchFn: fn, model: "synthetic-meta-1-contributor" }), (e) => e.code === "meta_contributor_refused");
  assert.equal(calls.length, 1);
});

test("meta: upstream errors are fixed codes, never the body or key", async () => {
  const leaky = async () => new Response(`upstream echoes ${KEY}`, { status: 500 });
  await assert.rejects(chatMeta([], META, { fetchFn: leaky }), (e) => e.code === "meta_status_5xx" && e.fallback && !e.message.includes(KEY));
  await assert.rejects(chatMeta([], META, { fetchFn: async () => new Response("x", { status: 403 }) }), (e) => e.code === "meta_forbidden" && e.status === 403 && e.fallback);
  await assert.rejects(chatMeta([], META, { fetchFn: async () => new Response("x", { status: 400 }) }), (e) => e.code === "meta_status_4xx" && !e.fallback);
  const timeout = async () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); };
  await assert.rejects(chatMeta([], META, { fetchFn: timeout }), (e) => e.code === "meta_timeout");
});

test("meta: Responses web_search request and url_citation parsing", async () => {
  const { fn, calls } = brainFake({
    responses: () => res({
      output: [
        { type: "web_search_call" },
        { type: "message", content: [{ type: "output_text", text: "Synthetic web summary.", annotations: [
          { type: "url_citation", url: "https://who.example.test/a", title: "Synthetic A" },
          { type: "url_citation", url: "http://insecure.test/b", title: "dropped" },
          { type: "url_citation", url: "https://who.example.test/a", title: "dup" },
        ] }] },
      ],
    }),
  });
  const out = await webSearchMeta("synthetic sleep query", META, { fetchFn: fn });
  assert.equal(calls[0].url, "https://api.meta.ai/v1/responses");
  assert.deepEqual(calls[0].body.tools, [{ type: "web_search" }]);
  assert.deepEqual(out, { text: "Synthetic web summary.", results: [{ title: "Synthetic A", url: "https://who.example.test/a" }], complete: true });
  assert.throws(() => readResponses({ output: [] }), (e) => e.code === "meta_empty");
});

// ---- Brain provider fallback ----

test("callBrain: Meta answers first and is recorded", async () => {
  const { fn, calls } = brainFake({ relay: () => chat("meta answer") });
  const out = await callBrain([{ role: "user", content: "q" }], BOTH, { fetchFn: fn });
  assert.equal(out.provider, "meta");
  assert.equal(calls.length, 1);
});

test("callBrain: falls back to Nebius on not_configured, 5xx, 429, timeout and region refusal", async () => {
  const nebiusOk = (url) => url.startsWith("https://api.tokenfactory.nebius.com/") ? chat("nebius answer") : null;
  const cases = {
    not_configured: [NEBIUS, null],
    status_5xx: [BOTH, () => new Response("x", { status: 502 })],
    status_429: [BOTH, () => new Response("x", { status: 429 })],
    region: [BOTH, () => new Response("x", { status: 451 })],
    timeout: [BOTH, () => { throw Object.assign(new Error("t"), { name: "TimeoutError" }); }],
  };
  for (const [name, [env, metaReply]] of Object.entries(cases)) {
    const urls = [];
    const fn = async (url, init) => {
      urls.push(url);
      const body = JSON.parse(init.body);
      if (nebiusOk(url)) {
        assert.equal(body.model, NEBIUS.COUNCIL_NEBIUS_MODEL);
        assert.equal(init.headers.Authorization, `Bearer ${NB_KEY}`);
        return nebiusOk(url);
      }
      return metaReply();
    };
    const out = await callBrain([{ role: "user", content: "q" }], env, { fetchFn: fn });
    assert.equal(out.provider, "nebius", name);
    assert.equal(out.content, "nebius answer");
    assert.equal(urls.at(-1), "https://api.tokenfactory.nebius.com/v1/chat/completions");
  }
});

test("callBrain: a Meta 4xx does not fall back; no provider at all refuses before any call", async () => {
  const urls = [];
  const fn = async (url) => { urls.push(url); return new Response("x", { status: 400 }); };
  await assert.rejects(callBrain([], BOTH, { fetchFn: fn }), (e) => e.code === "meta_status_4xx");
  assert.equal(urls.length, 1);
  await assert.rejects(callBrain([], {}, { fetchFn: noNet }), (e) => e.message === "not configured" && /META_API_KEY missing.*COUNCIL_NEBIUS_MODEL|NEBIUS_API_KEY/.test(e.detail));
});

test("Nebius council fallback needs COUNCIL_NEBIUS_MODEL and refuses contributor ids", () => {
  assert.match(councilNebiusConfigProblem({ NEBIUS_API_KEY: NB_KEY }), /COUNCIL_NEBIUS_MODEL missing/);
  assert.equal(councilNebiusConfigProblem(NEBIUS), null);
  assert.match(councilNebiusConfigProblem({ ...NEBIUS, COUNCIL_NEBIUS_MODEL: "synthetic-contributor" }), /contributor/);
  assert.match(brainConfigProblem({ ...META, ...NEBIUS, COUNCIL_NEBIUS_MODEL: "x-contributor" }), /contributor/);
  assert.match(brainConfigProblem({ ...META, META_BASE_URL: "https://evil.test/v1", ...NEBIUS }), /META_BASE_URL refused/);
});

// ---- DATA_MODE guard ----

test("DATA_MODE: owner_real is the default and refuses contributor, OpenCode and OpenRouter free providers", () => {
  assert.equal(dataModeProblem({}, { provider: "meta", model: "synthetic-meta-1" }), null);
  assert.match(dataModeProblem({}, { model: "synthetic-meta-1-contributor" }), /contributor model refused/);
  for (const p of ["opencode", "opencode_poc", "openrouter_poc", "poc_opencode_nebius"]) {
    assert.match(dataModeProblem({ DATA_MODE: "owner_real" }, { provider: p }), /refused .* DATA_MODE=owner_real/, p);
    assert.equal(dataModeProblem({ DATA_MODE: "synthetic" }, { provider: p }), null, p);
  }
  assert.match(dataModeProblem({}, { provider: "nebius", model: "nvidia/x:free" }), /free-tier/);
  assert.match(dataModeProblem({ DATA_MODE: "demo" }, {}), /DATA_MODE unknown/);
});

test("DATA_MODE applies to the council, reply and memory paths", async () => {
  // Council: Meta contributor refused even under synthetic; legacy free councils only under synthetic.
  assert.match(brainConfigProblem({ ...META, META_MODEL: "synthetic-meta-1-contributor", DATA_MODE: "synthetic" }), /contributor/);
  assert.match(councilConfigProblem({ COUNCIL_PROVIDER: "opencode" }), /opencode refused for council/);
  assert.equal(councilConfigProblem({ COUNCIL_PROVIDER: "opencode", DATA_MODE: "synthetic" }), null);
  assert.match(councilConfigProblem({ COUNCIL_PROVIDER: "openrouter_poc", OPENROUTER_API_KEY: "k" }), /openrouter_poc refused/);
  assert.match(brainConfigProblem({ ...META, DATA_MODE: "bogus" }), /DATA_MODE unknown/);
  // Reply.
  assert.match(replyConfigProblem({ REPLY_PROVIDER: "opencode_poc", OPENCODE_API_KEY: "k" }), /opencode_poc refused for reply/);
  assert.match(replyConfigProblem({ REPLY_PROVIDER: "openrouter_poc", OPENROUTER_API_KEY: "k" }), /openrouter_poc refused for reply/);
  assert.match(replyConfigProblem({ REPLY_PROVIDER: "nebius", NEBIUS_API_KEY: "k", REPLY_LLM_MODEL: "x-contributor" }), /contributor/);
  assert.equal(replyConfigProblem({ REPLY_PROVIDER: "nebius", NEBIUS_API_KEY: "k", REPLY_LLM_MODEL: "synthetic/chat" }), null);
  // Memory PoC (OpenCode + Nebius) refuses under owner_real, before any call.
  const store = createStore({ MEMORY_PROVIDER: "poc_opencode_nebius", OPENCODE_API_KEY: "k", NEBIUS_API_KEY: "k" }, new InMemoryStore());
  await assert.rejects(store.write({ id: "1", text: "synthetic" }), (e) => /poc_opencode_nebius refused for memory/.test(e.detail));
});

// ---- Experts ----

test("experts: wellbeing and medical registry with the contract and medical limits", () => {
  assert.deepEqual(EXPERTS.filter((e) => e.kind === "wellbeing").map((e) => e.id), ["diet", "training", "breath_stress", "sleep_lifestyle"]);
  assert.deepEqual(EXPERTS.filter((e) => e.kind === "medical").map((e) => e.id), [
    "cardiology", "endocrinology_metabolism", "gastroenterology", "musculoskeletal_physio", "mental_health",
    "womens_health", "respiratory", "dermatology", "general_medicine",
  ]);
  for (const e of EXPERTS) {
    for (const k of ["id", "field", "kind", "scope", "systemPrompt", "bank"]) assert.ok(e[k], `${e.id}.${k}`);
    assert.match(e.systemPrompt, /"points"/);
    if (e.kind === "medical") assert.match(e.systemPrompt, /Never diagnose.*doses/);
  }
});

test("expert contract parsing and the source filter", () => {
  const p = parseExpert('<think>x</think>{"points":[{"text":"a","source_ids":["s1"]},{"text":7}],"caveats":["c"],"confidence":3,"search_query":" q "}');
  assert.deepEqual(p, { points: [{ text: "a", source_ids: ["s1"] }], caveats: ["c"], confidence: 1, search_query: "q" });
  assert.deepEqual(parseExpert("not json"), { points: [], caveats: [], confidence: 0, search_query: null });
  const pts = [
    { text: "cited", source_ids: ["s1"] },
    { text: "invented", source_ids: ["s1", "nope"] },
    { text: "uncited", source_ids: [] },
  ];
  const ids = new Set(["s1"]);
  // Decision 2026-10-29: uncited points are dropped for every kind.
  assert.deepEqual(filterPoints(pts, ids).map((x) => x.text), ["cited"]);
});

// ---- Relay ----

test("relay: consults experts via the tool, filters sources, synthesis only reaches the user", async () => {
  const env = { ...META, ...bindings() };
  const { fn, calls, relayCalls } = brainFake({
    relay: (body, n) => {
      if (n === 0) return chat("", [tc("c1", "sleep_lifestyle", "synthetic sleep question"), tc("c2", "diet")]);
      // The tool results carry only filtered points.
      const tools = body.messages.filter((m) => m.role === "tool").map((m) => JSON.parse(m.content));
      assert.equal(tools.length, 2);
      assert.deepEqual(tools[0].points.map((p) => p.text), ["EXPERT-POINT-KEPT"]);
      return chat(finalJson({ sources: ["sleep_lifestyle-src-1", "invented-id"] }));
    },
    expert: (q) => ({
      points: [
        { text: "EXPERT-POINT-KEPT", source_ids: [q.sources[0].id] },
        { text: "EXPERT-POINT-INVENTED", source_ids: ["made-up"] },
      ],
      caveats: [], confidence: 0.6,
    }),
  });
  const out = await runCouncilV2({ question: "How can I sleep better?", context: { short_term_summary: "synthetic summary" }, purpose: "chat" }, env, { fetchFn: fn });
  assert.equal(relayCalls().length, 2);
  // Medical experts are off by default (COUNCIL_MEDICAL unset): the enum lists the wellbeing experts only.
  assert.deepEqual(relayCalls()[0].body.tools[0].function.parameters.properties.expert_id.enum, ["diet", "training", "breath_stress", "sleep_lifestyle"]);
  assert.deepEqual(out.experts_consulted, ["sleep_lifestyle", "diet"]);
  assert.deepEqual(out.sources, [{ id: "sleep_lifestyle-src-1", title: "Synthetic sleep_lifestyle 1", url: "https://example.test/sleep_lifestyle/1", kind: "bank" }]);
  assert.equal(out.medical, false);
  assert.deepEqual(out.providers, ["meta"]);
  assert.match(out.synthesis, /^Synthetic synthesis/);
  assert.ok(!out.synthesis.includes(NOT_MEDICAL_ADVICE), "a sleep question with medical false gets no line");
  assert.ok(!JSON.stringify(out).includes("EXPERT-POINT"), "expert text never reaches the user directly");
  // Experts see the relay's question and their sources, never the user's context.
  const expertCall = calls.find((c) => c.body.messages[0].content.startsWith("You are one expert"));
  assert.ok(!JSON.stringify(expertCall.body).includes("synthetic summary"));
  assert.equal(expertCall.body.response_format.type, "json_object");
});

test("relay: at most 8 consults and 3 per expert, then a closing call without tools", async () => {
  const env = { ...META, ...bindings(), COUNCIL_MEDICAL: "on" };
  let expertCalls = 0;
  const { fn, relayCalls } = brainFake({
    relay: (body, n) => {
      if (!body.tools) return chat(finalJson({}));
      // Keep asking: four calls to one expert, then many to others.
      if (n === 0) return chat("", [1, 2, 3, 4].map((i) => tc(`a${i}`, "diet")));
      return chat("", EXPERT_IDS.slice(1, 7).map((id, i) => tc(`b${n}${i}`, id)));
    },
    expert: () => { expertCalls++; return { points: [], caveats: [], confidence: 0.5 }; },
  });
  const out = await runCouncilV2({ question: "synthetic big question about energy", purpose: "chat" }, env, { fetchFn: fn });
  assert.equal(expertCalls, LIMITS.maxConsults);
  assert.equal(out.consults, 8);
  assert.ok(out.limits_hit.includes("expert_limit"));
  assert.ok(out.limits_hit.includes("consult_limit"));
  assert.ok(!relayCalls().at(-1).body.tools, "the last relay call offers no tools");
  assert.ok(relayCalls().length <= LIMITS.maxConsults + 3);
});

test("relay: the time limit stops the loop", async () => {
  let t = 0;
  const now = () => t;
  const env = { ...META, ...bindings() };
  const { fn, calls } = brainFake({
    relay: () => { t += 10_000; return chat("", [tc(`c${t}`, "training")]); },
    expert: () => { t += 10_000; return { points: [], caveats: [], confidence: 0.5 }; },
  });
  const out = await runCouncilV2({ question: "synthetic question" }, env, { fetchFn: fn, now, limits: { timeLimitMs: 25_000 } });
  assert.ok(out.limits_hit.includes("time_limit"));
  assert.ok(calls.length <= 4, `calls ${calls.length}`);
  assert.equal(typeof out.synthesis, "string");
});

test("relay: any medical expert appends the not-medical-advice line and the clinician path", async () => {
  const env = { ...META, ...bindings(), COUNCIL_MEDICAL: "on" };
  const { fn } = brainFake({
    relay: (body, n) => (n === 0 ? chat("", [tc("m1", "cardiology")]) : chat(finalJson({ synthesis: "Synthetic heart rate note.", medical: false }))),
    expert: (q) => ({ points: [{ text: "general info", source_ids: [q.sources[0].id] }], caveats: [], confidence: 0.4 }),
  });
  const out = await runCouncilV2({ question: "synthetic pulse question" }, env, { fetchFn: fn });
  assert.equal(out.medical, true);
  assert.ok(out.synthesis.endsWith(`${NOT_MEDICAL_ADVICE} ${CLINICIAN_PATH}`));
  assert.equal(out.synthesis.split(NOT_MEDICAL_ADVICE).length, 2, "appended once");
});

test("relay: the relay's medical flag alone decides the line, never health words", async () => {
  const run = (medical, synthesis) => runCouncilV2({ question: "synthetic: why do I sleep badly and feel stressed?" }, NEBIUS, {
    callFn: async () => ({ content: finalJson({ synthesis, medical }), tool_calls: [], provider: "nebius" }),
    fetchFn: noNet,
  });
  const plain = await run(false, "Synthetic: a regular bedtime and slow breathing may help you relax.");
  assert.equal(plain.medical, false);
  assert.equal(plain.synthesis, "Synthetic: a regular bedtime and slow breathing may help you relax.");
  const marked = await run(true, "Synthetic: new chest pain at night is worth checking with a clinician.");
  assert.equal(marked.medical, true);
  assert.ok(marked.synthesis.endsWith(`${NOT_MEDICAL_ADVICE} ${CLINICIAN_PATH}`));
  assert.equal(marked.synthesis.split(NOT_MEDICAL_ADVICE).length, 2, "appended once");
  assert.match(relaySystem("chat"), /Set medical true only when the answer gives health guidance whose wrong use could cause harm/);
});

test("relay: crisis text gets the referral before any call, even unconfigured", async () => {
  for (const input of [{ question: "I want to die" }, { question: "fine", context: { short_term_summary: "they said suicidal things" } }]) {
    const out = await runCouncilV2(input, {}, { fetchFn: noNet });
    assert.equal(out.synthesis, REFERRAL_TEXT);
    assert.equal(out.crisis, true);
    assert.deepEqual(out.experts_consulted, []);
  }
});

test("relay: a synthesis that still fails after one repair call becomes the safe fallback", async () => {
  const { fn, relayCalls } = brainFake({ relay: () => chat(finalJson({ synthesis: "You must stop training, that is a diagnosis." })) });
  const out = await runCouncilV2({ question: "synthetic plan question" }, META, { fetchFn: fn });
  assert.ok(out.synthesis.startsWith(SAFE_FALLBACK_TEXT));
  assert.equal(out.gate, "replaced");
  assert.ok(out.limits_hit.includes("gate_replaced"));
  assert.equal(relayCalls().length, 2, "the first relay call and one repair call");
});

test("relay: an expert's search request runs the injected search; results cite as kind web", async () => {
  const env = { ...META, ...bindings() };
  const { fn, calls } = brainFake({
    relay: (body, n) => {
      if (n === 0) return chat("", [tc("w1", "breath_stress")]);
      const tool = JSON.parse(body.messages.find((m) => m.role === "tool").content);
      assert.equal(tool.web.sources[0].id, "web:1.1");
      assert.ok(!("given" in tool.web), "the relay sees ids and titles, not the raw results");
      return chat(finalJson({ sources: ["web:1.1"] }));
    },
    expert: () => ({ points: [], caveats: ["bank has nothing"], confidence: 0.2, search_query: "synthetic box breathing" }),
    responses: () => res({ output: [{ type: "message", content: [{ type: "output_text", text: "Synthetic.", annotations: [{ type: "url_citation", url: "https://nhs.example.test/x", title: "Synthetic NHS" }] }] }] }),
  });
  // The Meta Responses search, as council/web.js picks it when Meta is configured.
  const out = await runCouncilV2({ question: "synthetic breathing question" }, env, { fetchFn: fn, searchFn: webSearchMeta });
  assert.equal(calls.filter((c) => c.url.endsWith("/responses")).length, 1);
  assert.deepEqual(out.sources, [{ id: "web:1.1", title: "Synthetic NHS", url: "https://nhs.example.test/x", kind: "web" }]);
});

test("relay: on the Nebius path the search runs too; no search provider gives no web sources", async () => {
  const env = { ...NEBIUS, ...bindings() };
  const expert = () => ({ points: [], caveats: [], confidence: 0.2, search_query: "synthetic" });
  const relay = (body, n) => (n === 0 ? chat("", [tc("w1", "diet")]) : chat(finalJson({})));
  const searched = [];
  const searchFn = async (q) => { searched.push(q); return { text: "Synthetic web text.", results: [{ title: "Synthetic web", url: "https://web.example.test/a", content: "synthetic" }] }; };
  const a = brainFake({ relay, expert });
  const out = await runCouncilV2({ question: "synthetic diet question" }, env, { fetchFn: a.fn, searchFn });
  assert.deepEqual(out.providers, ["nebius"]);
  assert.deepEqual(searched, ["synthetic"]);
  assert.deepEqual(out.sources.map((x) => [x.id, x.kind]), [["web:1.1", "web"]]);
  const b = brainFake({ relay, expert });
  const none = await runCouncilV2({ question: "synthetic diet question" }, env, { fetchFn: b.fn, searchFn: async () => null });
  assert.equal(b.calls.filter((c) => c.url.endsWith("/responses")).length, 0);
  // No web provider: no web sources. With no surviving point, the bank passages the experts were shown are listed.
  assert.ok(none.sources.length > 0 && none.sources.every((x) => x.kind === "bank"));
});

// ---- Retrieval ----

test("retrieve: embeds with bge-m3, queries the expert namespace, maps metadata", async () => {
  const b = bindings();
  const out = await retrieve("diet", "synthetic question", b, { k: 3 });
  assert.equal(out.code, null);
  assert.equal(out.passages.length, 2);
  assert.deepEqual(b.queries[0], { len: EMBED_DIMS, topK: 3, namespace: "diet", returnMetadata: "all" });
  assert.deepEqual(Object.keys(out.passages[0]).sort(), ["licence", "score", "source_id", "text", "title", "url"]);
  assert.equal(EMBED_MODEL, "@cf/baai/bge-m3");
});

test("retrieve: missing bindings, wrong dimension and mismatched metadata give no passages", async () => {
  assert.deepEqual(await retrieve("diet", "q", {}), { passages: [], code: "knowledge_not_bound" });
  assert.equal((await retrieve("diet", "q", bindings({ dims: 768 }))).code, "knowledge_bad_embedding");
  const b = bindings();
  b.KNOWLEDGE.query = async () => ({ matches: [{ metadata: { expert: "cardiology", source_id: "x", url: "http://insecure.test" } }, { metadata: { expert: "diet", source_id: "y", url: "http://insecure.test" } }] });
  const out = await retrieve("diet", "q", b);
  assert.deepEqual(out.passages.map((p) => [p.source_id, p.url]), [["y", ""]]);
  assert.equal((await retrieve("diet", "", bindings())).code, "knowledge_bad_query");
});
