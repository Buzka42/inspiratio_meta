// C7: POST /knowledge/ingest and /knowledge/stats in src/knowledge/ingest.js. Fake fetch and fake bindings only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleKnowledge, MAX_TEXT } from "../src/knowledge/ingest.js";
import { EXPERT_IDS } from "../src/council/experts.js";
import { EMBED_DIMS } from "../src/knowledge/retrieve.js";

const KEY = `nebius-ingest-${crypto.randomUUID()}`;
const MODEL = "Qwen/Qwen3-Embedding-8B";
const DEVICE = "ingest-device-test";
const ENV = { KNOWLEDGE_INGEST_DEVICE_ID: DEVICE, NEBIUS_API_KEY: KEY, KNOWLEDGE_EMBED_PROVIDER: "nebius", KNOWLEDGE_EMBED_MODEL: MODEL };
const HEX = "0123456789abcdef";
const rec = (ns = "diet", over = {}) => ({
  id: `${ns}:${HEX}:0`,
  namespace: ns,
  text: "Synthetic paragraph for the ingest route.",
  metadata: { expert: ns, source_id: "synthetic-src-1", title: "Synthetic", url: "https://example.test/a", licence: "OGL-3.0", retrieved: "2026-10-25" },
  ...over,
});

function nebius() {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body });
    const data = body.input.map((_, index) => ({ index, embedding: Array.from({ length: EMBED_DIMS }, () => 0.1) }));
    return new Response(JSON.stringify({ data }), { status: 200 });
  };
  return { fn, calls };
}

function knowledge({ upsertFails = false, queryFails = false, matches = () => [] } = {}) {
  const upserts = [];
  const queries = [];
  return {
    upserts,
    queries,
    upsert: async (vectors) => {
      if (upsertFails) throw new Error("upsert boom");
      upserts.push(...vectors);
      return { mutationId: "m" };
    },
    query: async (vector, opts) => {
      if (queryFails) throw new Error("query boom");
      queries.push({ len: vector.length, first: vector[0], ...opts });
      return { matches: matches(opts.namespace) };
    },
  };
}

const run = (path, body, env = ENV, deviceId = DEVICE, { fetchFn, KNOWLEDGE = knowledge() } = {}) => {
  const n = fetchFn ?? nebius().fn;
  return handleKnowledge(path, body, { ...env, KNOWLEDGE }, deviceId, { fetchFn: n });
};

test("routes: unknown path is 404; unset device id is 503; another device is 403; no binding is 503", async () => {
  assert.equal((await run("/knowledge/other", { records: [rec()] })).status, 404);
  const unset = await handleKnowledge("/knowledge/ingest", { records: [rec()] }, { KNOWLEDGE: knowledge() }, DEVICE, {});
  assert.deepEqual([unset.status, unset.body], [503, { error: "not_configured", detail: "KNOWLEDGE_INGEST_DEVICE_ID missing" }]);
  const other = await run("/knowledge/ingest", { records: [rec()] }, ENV, "someone-else");
  assert.deepEqual([other.status, other.body, other.code], [403, { error: "ingest_forbidden" }, "ingest_forbidden"]);
  const noBinding = await handleKnowledge("/knowledge/stats", {}, { ...ENV }, DEVICE, {});
  assert.deepEqual([noBinding.status, noBinding.body.detail], [503, "KNOWLEDGE binding missing"]);
});

test("ingest validation: each rule gives 400 bad_request with a fixed detail", async () => {
  const cases = [
    [{}, "records must be an array of 1 to 20"],
    [{ records: [] }, "records must be an array of 1 to 20"],
    [{ records: Array.from({ length: 21 }, () => rec()) }, "records must be an array of 1 to 20"],
    [{ records: [rec("astrology")] }, "record 0: namespace not an expert"],
    [{ records: [rec("diet", { id: "diet:short:0" })] }, "record 0: id invalid"],
    [{ records: [rec("diet", { id: `training:${HEX}:0` })] }, "record 0: id invalid"],
    [{ records: [rec("diet", { metadata: { ...rec().metadata, expert: "training" } })] }, "record 0: metadata.expert must equal namespace"],
    [{ records: [rec("diet", { metadata: { ...rec().metadata, source_id: "" } })] }, "record 0: source_id missing"],
    [{ records: [rec("diet", { metadata: { ...rec().metadata, url: "http://example.test/a" } })] }, "record 0: url must be https"],
    [{ records: [rec("diet", { text: "   " })] }, `record 0: text must be 1 to ${MAX_TEXT} characters`],
    [{ records: [rec("diet", { text: "x".repeat(MAX_TEXT + 1) })] }, `record 0: text must be 1 to ${MAX_TEXT} characters`],
  ];
  for (const [body, detail] of cases) {
    const out = await run("/knowledge/ingest", body);
    assert.deepEqual([out.status, out.body], [400, { error: "bad_request", detail }], detail);
  }
  const notObject = await run("/knowledge/ingest", "not json");
  assert.equal(notObject.status, 400);
});

test("ingest success: server sets metadata.text and metadata.embed, and counts per namespace", async () => {
  const { fn, calls } = nebius();
  const K = knowledge();
  const records = [rec("diet"), rec("diet", { id: `diet:${HEX}:1` }), rec("training", { id: `training:${HEX}:0` })];
  const out = await run("/knowledge/ingest", { records }, ENV, DEVICE, { fetchFn: fn, KNOWLEDGE: K });
  assert.deepEqual(out, { status: 200, body: { ok: true, upserted: 3, namespaces: { diet: 2, training: 1 } }, code: "ok" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.tokenfactory.nebius.com/v1/embeddings");
  assert.deepEqual(calls[0].body.input, records.map((r) => r.text));
  assert.equal(K.upserts.length, 3);
  const first = K.upserts[0];
  assert.equal(first.id, records[0].id);
  assert.equal(first.namespace, "diet");
  assert.equal(first.values.length, EMBED_DIMS);
  assert.equal(first.metadata.text, records[0].text);
  assert.equal(first.metadata.embed, `nebius:${MODEL}`);
  assert.equal(first.metadata.source_id, "synthetic-src-1");
  assert.ok(!JSON.stringify(K.upserts).includes(KEY));
});

test("ingest: a string body is parsed; an embed failure is 502 and nothing is upserted", async () => {
  const K = knowledge();
  const ok = await run("/knowledge/ingest", JSON.stringify({ records: [rec()] }), ENV, DEVICE, { fetchFn: nebius().fn, KNOWLEDGE: K });
  assert.equal(ok.status, 200);
  const failFn = async () => new Response("nope", { status: 503 });
  const K2 = knowledge();
  const out = await run("/knowledge/ingest", { records: [rec()] }, ENV, DEVICE, { fetchFn: failFn, KNOWLEDGE: K2 });
  assert.deepEqual([out.status, out.body], [502, { error: "ingest_failed", code: "knowledge_embed_failed" }]);
  assert.equal(K2.upserts.length, 0);
});

test("ingest: an upsert failure is 502 knowledge_upsert_failed", async () => {
  const out = await run("/knowledge/ingest", { records: [rec()] }, ENV, DEVICE, { fetchFn: nebius().fn, KNOWLEDGE: knowledge({ upsertFails: true }) });
  assert.deepEqual([out.status, out.body], [502, { error: "ingest_failed", code: "knowledge_upsert_failed" }]);
});

test("stats: counts distinct source_ids per bank, queries with the unit vector and topK 50", async () => {
  const K = knowledge({
    matches: (ns) =>
      ns === "diet"
        ? [1, 2, 3].map((i) => ({ id: `diet:${i}`, metadata: { expert: "diet", source_id: i <= 2 ? "src-a" : "src-b" } }))
        : [{ id: "x", metadata: { expert: "training", source_id: "t1" } }, { id: "y", metadata: { expert: "diet", source_id: "wrong" } }],
  });
  const out = await run("/knowledge/stats", { namespaces: ["diet", "training"] }, ENV, DEVICE, { KNOWLEDGE: K });
  assert.deepEqual(out.body, {
    ok: true,
    namespaces: { diet: { sources: 2, chunks: 3, capped: false }, training: { sources: 1, chunks: 1, capped: false } },
  });
  assert.equal(out.code, "ok");
  assert.deepEqual(K.queries[0], { len: EMBED_DIMS, first: 1, topK: 50, namespace: "diet", returnMetadata: "all" });
});

test("stats: 50 matches is capped; default banks are all experts; a bad bank is 400", async () => {
  const many = Array.from({ length: 50 }, (_, i) => ({ id: `d:${i}`, metadata: { expert: "diet", source_id: `s${i}` } }));
  const K = knowledge({ matches: (ns) => (ns === "diet" ? many : []) });
  const out = await run("/knowledge/stats", {}, ENV, DEVICE, { KNOWLEDGE: K });
  assert.equal(out.body.namespaces.diet.capped, true);
  assert.equal(out.body.namespaces.diet.sources, 50);
  assert.deepEqual(Object.keys(out.body.namespaces).sort(), [...EXPERT_IDS].sort());
  const bad = await run("/knowledge/stats", { namespaces: ["astrology"] }, ENV, DEVICE, { KNOWLEDGE: K });
  assert.deepEqual([bad.status, bad.body.error], [400, "bad_request"]);
});

test("stats: a query failure is 502 knowledge_query_failed", async () => {
  const out = await run("/knowledge/stats", { namespaces: ["diet"] }, ENV, DEVICE, { KNOWLEDGE: knowledge({ queryFails: true }) });
  assert.deepEqual([out.status, out.body], [502, { error: "ingest_failed", code: "knowledge_query_failed" }]);
});
