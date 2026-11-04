// C8: Nebius embeddings client, the embedding provider switch and the retrieve tag check. Fake fetch and fake
// bindings only; the key is per run and never printed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { embedNebius, NEBIUS_BASE_URL } from "../src/nebius.js";
import { EMBED_DIMS, EMBED_MODEL, embedTag, embedTexts, retrieve } from "../src/knowledge/retrieve.js";

const KEY = `nebius-embed-${crypto.randomUUID()}`;
const MODEL = "Qwen/Qwen3-Embedding-8B";
const NEBIUS = { NEBIUS_API_KEY: KEY, KNOWLEDGE_EMBED_PROVIDER: "nebius", KNOWLEDGE_EMBED_MODEL: MODEL };
const vec = (seed) => Array.from({ length: EMBED_DIMS }, (_, i) => (i === 0 ? seed : 0.5));

// Nebius answers in OpenAI shape: data[] of {index, embedding}.
function nebiusFetch(rowsFor = (texts) => texts.map((_, index) => ({ index, embedding: vec(index + 1) }))) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ object: "list", model: MODEL, data: rowsFor(calls.at(-1).body.input) }), { status: 200 });
  };
  return { fn, calls };
}

function workersAi() {
  const runs = [];
  return {
    runs,
    AI: {
      run: async (model, { text }) => {
        runs.push({ model, n: text.length });
        return { data: text.map(() => vec(0.2)) };
      },
    },
  };
}

test("embedNebius: POST /embeddings with model, input and dimensions 1024; bearer key only in the header", async () => {
  const { fn, calls } = nebiusFetch();
  const out = await embedNebius(["alpha", "beta"], NEBIUS, { fetchFn: fn });
  assert.equal(out.code, undefined);
  assert.equal(out.vectors.length, 2);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `${NEBIUS_BASE_URL}/embeddings`);
  assert.equal(calls[0].url, "https://api.tokenfactory.nebius.com/v1/embeddings");
  assert.deepEqual(calls[0].body, { model: MODEL, input: ["alpha", "beta"], dimensions: 1024 });
  assert.equal(calls[0].init.headers.Authorization, `Bearer ${KEY}`);
  assert.ok(!JSON.stringify(calls[0].body).includes(KEY));
});

test("embedNebius: vectors follow data[].index, not the order of the rows", async () => {
  const { fn } = nebiusFetch((texts) => texts.map((_, index) => ({ index, embedding: vec(index + 1) })).reverse());
  const out = await embedNebius(["a", "b", "c"], NEBIUS, { fetchFn: fn });
  assert.deepEqual(out.vectors.map((v) => v[0]), [1, 2, 3]);
});

test("embedNebius: a wrong length, a bad index or a duplicate index gives knowledge_bad_embedding", async () => {
  const short = nebiusFetch(() => [{ index: 0, embedding: vec(1) }]);
  assert.deepEqual(await embedNebius(["a", "b"], NEBIUS, { fetchFn: short.fn }), { code: "knowledge_bad_embedding" });
  const wrongDims = nebiusFetch((t) => t.map((_, index) => ({ index, embedding: [1, 2, 3] })));
  assert.deepEqual(await embedNebius(["a"], NEBIUS, { fetchFn: wrongDims.fn }), { code: "knowledge_bad_embedding" });
  const dup = nebiusFetch((t) => t.map(() => ({ index: 0, embedding: vec(1) })));
  assert.deepEqual(await embedNebius(["a", "b"], NEBIUS, { fetchFn: dup.fn }), { code: "knowledge_bad_embedding" });
});

test("embedNebius: transport or status failures give knowledge_embed_failed and never echo the body", async () => {
  const boom = async () => {
    throw new TypeError("socket closed");
  };
  assert.deepEqual(await embedNebius(["a"], NEBIUS, { fetchFn: boom }), { code: "knowledge_embed_failed" });
  const err = async () => new Response(`secret echo ${KEY}`, { status: 500 });
  const out = await embedNebius(["a"], NEBIUS, { fetchFn: err });
  assert.deepEqual(out, { code: "knowledge_embed_failed" });
  assert.ok(!JSON.stringify(out).includes(KEY));
});

test("embedNebius: missing key, missing model, refused base or a contributor model is not_configured with no call", async () => {
  const { fn, calls } = nebiusFetch();
  const cases = [
    { ...NEBIUS, NEBIUS_API_KEY: "" },
    { ...NEBIUS, KNOWLEDGE_EMBED_MODEL: "" },
    { ...NEBIUS, NEBIUS_BASE_URL: "https://evil.test/v1" },
    { ...NEBIUS, KNOWLEDGE_EMBED_MODEL: "vendor/contributor-embed" },
  ];
  for (const env of cases) assert.deepEqual(await embedNebius(["a"], env, { fetchFn: fn }), { code: "knowledge_not_configured" });
  assert.equal(calls.length, 0);
});

test("embedTag and embedTexts: unset uses Workers AI bge-m3 with the untagged tag; nebius uses its model tag", async () => {
  assert.equal(embedTag({}), "");
  assert.equal(embedTag({ KNOWLEDGE_EMBED_PROVIDER: "nebius", KNOWLEDGE_EMBED_MODEL: MODEL }), `nebius:${MODEL}`);
  assert.equal(embedTag({ KNOWLEDGE_EMBED_PROVIDER: "openai" }), null);

  const w = workersAi();
  const out = await embedTexts(["q"], { AI: w.AI });
  assert.equal(out.tag, "");
  assert.equal(out.vectors.length, 1);
  assert.deepEqual(w.runs, [{ model: EMBED_MODEL, n: 1 }]);
  assert.equal(EMBED_MODEL, "@cf/baai/bge-m3");
});

test("embedTexts: nebius selected never calls Workers AI; unknown provider is not_configured", async () => {
  const w = workersAi();
  const { fn, calls } = nebiusFetch();
  const out = await embedTexts(["q"], { ...NEBIUS, AI: w.AI }, { fetchFn: fn });
  assert.equal(out.tag, `nebius:${MODEL}`);
  assert.equal(calls.length, 1);
  assert.equal(w.runs.length, 0);
  assert.deepEqual(await embedTexts(["q"], { KNOWLEDGE_EMBED_PROVIDER: "openai", AI: w.AI }), { code: "knowledge_not_configured" });
});

// A retrieve() fixture whose matches carry an embed tag (or none) and a valid expert/source.
function bank(matches) {
  const queries = [];
  return {
    queries,
    AI: { run: async (_m, { text }) => ({ data: text.map(() => vec(0.3)) }) },
    KNOWLEDGE: {
      async query(vector, opts) {
        queries.push({ len: vector.length, ...opts });
        return { matches };
      },
    },
  };
}
const match = (id, embed) => ({
  id,
  score: 0.8,
  metadata: {
    expert: "diet",
    source_id: `src-${id}`,
    title: `Synthetic ${id}`,
    url: `https://example.test/${id}`,
    licence: "OGL-3.0",
    text: `synthetic passage ${id}`,
    ...(embed === undefined ? {} : { embed }),
  },
});

test("retrieve: under nebius, a match with another tag or no tag is dropped with knowledge_embed_mismatch", async () => {
  const tag = `nebius:${MODEL}`;
  const b = bank([match("ok", tag), match("old", ""), match("other", "nebius:other/model")]);
  const { fn } = nebiusFetch();
  const out = await retrieve("diet", "synthetic", { ...b, ...NEBIUS }, { k: 3, fetchFn: fn });
  assert.deepEqual(out.passages.map((p) => p.source_id), ["src-ok"]);
  assert.equal(out.code, "knowledge_embed_mismatch");
  assert.equal(b.queries[0].len, EMBED_DIMS);
  assert.equal(b.queries[0].namespace, "diet");
});

test("retrieve: under the Workers AI path, untagged matches are kept and tagged ones dropped", async () => {
  const b = bank([match("legacy"), match("tagged", `nebius:${MODEL}`)]);
  const out = await retrieve("diet", "synthetic", b);
  assert.deepEqual(out.passages.map((p) => p.source_id), ["src-legacy"]);
  assert.equal(out.code, "knowledge_embed_mismatch");
});

test("retrieve: all matches with the active tag give code null", async () => {
  const b = bank([match("a", `nebius:${MODEL}`)]);
  const { fn } = nebiusFetch();
  const out = await retrieve("diet", "synthetic", { ...b, ...NEBIUS }, { fetchFn: fn });
  assert.equal(out.code, null);
  assert.equal(out.passages.length, 1);
});
