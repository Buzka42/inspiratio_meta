import { test } from "node:test";
import assert from "node:assert/strict";
import { InMemoryStore, RefusedStore, createStore, validateMemory } from "../src/memory.js";
import {
  MEMORY_POC_DEFAULT_EMBED_MODEL, MEMORY_POC_DEFAULT_LLM, MEMORY_POC_PROVIDER, NEBIUS_EMBED_URL,
  PocMemoryStore, cosine, embed, extractFact,
} from "../src/memory-poc.js";
import { OPENCODE_URL, SESSION_HEADER } from "../src/opencode.js";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";

// Synthetic fixtures and per-run synthetic keys only; never real data or credentials.
const OC_KEY = `synthetic-oc-${crypto.randomUUID()}`;
const NB_KEY = `synthetic-nb-${crypto.randomUUID()}`;
const ENV = { DATA_MODE: "synthetic", MEMORY_PROVIDER: MEMORY_POC_PROVIDER, OPENCODE_API_KEY: OC_KEY, NEBIUS_API_KEY: NB_KEY };
const NOW = Date.parse("2026-10-24T08:00:00Z");
const SECRET_TEXT = "synthetic-memory-text-9d41";

const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const chat = (content) => ok({ choices: [{ message: { content } }] });
const vec = (v) => ok({ data: [{ embedding: v }] });

// Fake fetch: OpenCode returns {"fact": <input>}; Nebius maps keywords to fixed vectors.
const VECTORS = { sleep: [1, 0, 0], squat: [0, 1, 0], protein: [0, 0, 1] };
function fakeFetch({ failEmbed = false, failLlm = false } = {}) {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, init, body });
    if (url === OPENCODE_URL) {
      if (failLlm) return { ok: false, status: 500, json: async () => ({ error: SECRET_TEXT }) };
      return chat(JSON.stringify({ fact: body.messages[1].content }));
    }
    if (failEmbed) return { ok: false, status: 503, json: async () => ({ error: SECRET_TEXT }) };
    const t = body.input.toLowerCase();
    const key = Object.keys(VECTORS).find((k) => t.includes(k));
    // Partial matches give graded similarity: "tired" sits between sleep and squat.
    return vec(key ? VECTORS[key] : t.includes("tired") ? [0.9, 0.4, 0] : [0.1, 0.1, 0.1]);
  };
  fn.calls = calls;
  return fn;
}
const silent = () => {
  const lines = [];
  return { lines, warn: (...a) => lines.push(a), error: (...a) => lines.push(a) };
};
const mem = (text, extra = {}) => validateMemory({ text, kind: "fact", source: "test", ...extra }, NOW).item;
const texts = (items) => items.map((m) => m.text);

test("memory poc: unset switch keeps the shared in-memory store, no fetch", async () => {
  const shared = new InMemoryStore();
  assert.equal(createStore({}, shared), shared);
  assert.equal(createStore({ MEMORY_PROVIDER: "" }, shared), shared);
  const fetchFn = fakeFetch();
  assert.deepEqual(await embed("x", {}, { fetchFn }), { code: "memory_provider_off" });
  assert.deepEqual(await extractFact("x", { OPENCODE_API_KEY: OC_KEY }, { fetchFn }), { code: "memory_provider_off" });
  assert.equal(fetchFn.calls.length, 0);
});

test("memory poc: unknown provider value refuses, no fetch", async () => {
  for (const v of ["opencode_poc", "POC_OPENCODE_NEBIUS", "nebius", "true"]) {
    const store = createStore({ ...ENV, MEMORY_PROVIDER: v }, new InMemoryStore());
    assert.ok(store instanceof RefusedStore);
    await assert.rejects(store.write(mem("x")), (e) => e.message === "not configured" && /MEMORY_PROVIDER unknown/.test(e.detail));
    await assert.rejects(store.recall({ query: "x" }), /not configured/);
  }
});

test("memory poc: missing keys or mixed Graphiti settings refuse, naming variables only", async () => {
  const shared = new InMemoryStore();
  const noNebius = createStore({ ...ENV, NEBIUS_API_KEY: "" }, shared);
  await assert.rejects(noNebius.recall({ query: "x" }), (e) => /NEBIUS_API_KEY missing/.test(e.detail) && !e.detail.includes(OC_KEY));
  const noOc = createStore({ ...ENV, OPENCODE_API_KEY: undefined }, shared);
  await assert.rejects(noOc.write(mem("x")), (e) => /OPENCODE_API_KEY missing/.test(e.detail));
  const mixed = createStore({ ...ENV, MEMORY_SERVER_URL: "https://memory.vps.test" }, shared);
  await assert.rejects(mixed.write(mem("x")), (e) => /both set/.test(e.detail));
  assert.equal(shared.items.length, 0);
  assert.ok(createStore(ENV, shared) instanceof PocMemoryStore);
});

test("memory poc: OpenCode call headers and body", async () => {
  const fetchFn = fakeFetch();
  const out = await extractFact(SECRET_TEXT, ENV, { fetchFn });
  assert.equal(out.value, SECRET_TEXT);
  const [{ url, init, body }] = fetchFn.calls;
  assert.equal(url, OPENCODE_URL);
  assert.equal(init.method, "POST");
  assert.equal(init.headers.Authorization, `Bearer ${OC_KEY}`);
  assert.equal(init.headers["Content-Type"], "application/json");
  assert.match(init.headers[SESSION_HEADER], /^illunis-memory-poc-[0-9a-f-]{36}$/);
  assert.equal(body.model, MEMORY_POC_DEFAULT_LLM);
  assert.equal(body.messages[0].role, "system");
  assert.deepEqual(body.messages[1], { role: "user", content: SECRET_TEXT });
  assert.deepEqual(body.response_format, { type: "json_object" });
  assert.ok(init.signal);
  // Model id is env-configurable.
  const f2 = fakeFetch();
  await extractFact("x", { ...ENV, MEMORY_LLM_MODEL: "beam-free" }, { fetchFn: f2 });
  assert.equal(f2.calls[0].body.model, "beam-free");
});

test("memory poc: OpenCode reasoning tags and bad output", async () => {
  const think = async () => chat('<think>{"fact":"no"}</think>{"fact":"Sleep is short"}');
  assert.deepEqual(await extractFact("x", ENV, { fetchFn: think }), { value: "Sleep is short" });
  const junk = async () => chat("not json");
  assert.deepEqual(await extractFact("x", ENV, { fetchFn: junk }), { code: "memory_llm_bad_output" });
});

test("memory poc: Nebius embeddings call sends model and text only", async () => {
  const fetchFn = fakeFetch();
  const out = await embed("sleep note", ENV, { fetchFn });
  assert.deepEqual(out.value, [1, 0, 0]);
  const [{ url, init, body }] = fetchFn.calls;
  assert.equal(url, NEBIUS_EMBED_URL);
  assert.equal(init.headers.Authorization, `Bearer ${NB_KEY}`);
  assert.equal(init.headers[SESSION_HEADER], undefined);
  assert.deepEqual(body, { model: MEMORY_POC_DEFAULT_EMBED_MODEL, input: "sleep note" });
  const f2 = fakeFetch();
  await embed("x", { ...ENV, MEMORY_EMBED_MODEL: "BAAI/bge-en-icl" }, { fetchFn: f2 });
  assert.equal(f2.calls[0].body.model, "BAAI/bge-en-icl");
  const bad = async () => ok({ data: [{ embedding: ["a"] }] });
  assert.deepEqual(await embed("x", ENV, { fetchFn: bad }), { code: "memory_embed_bad_output" });
});

test("memory poc: cosine similarity", () => {
  assert.equal(cosine([1, 0], [1, 0]), 1);
  assert.equal(cosine([1, 0], [0, 1]), 0);
  assert.equal(cosine([1, 0], [1, 0, 0]), 0);
  assert.equal(cosine([0, 0], [1, 0]), 0);
});

test("memory poc: recall ranks by cosine similarity, not token overlap", async () => {
  const fetchFn = fakeFetch();
  const store = new PocMemoryStore(ENV, new InMemoryStore(), { fetchFn, logger: silent() });
  for (const t of ["Squat felt heavy", "Sleep is shorter on weekdays", "Protein at breakfast"]) await store.write(mem(t));
  // "tired" shares no token with any memory; the vector puts sleep first, squat second, protein below threshold.
  const out = await store.recall({ query: "why am I tired", now: NOW });
  assert.deepEqual(texts(out), ["Sleep is shorter on weekdays", "Squat felt heavy"]);
  assert.deepEqual(texts(await store.recall({ query: "why am I tired", limit: 1, now: NOW })), ["Sleep is shorter on weekdays"]);
  // Expired items never return.
  await store.write(mem("sleep debt high", { expires_at: "2026-10-24T07:00:00Z" }));
  assert.ok(!texts(await store.recall({ query: "sleep", now: NOW })).includes("sleep debt high"));
  // Write embedded the extracted fact; each write made one LLM and one embed call.
  assert.equal(fetchFn.calls.filter((c) => c.url === OPENCODE_URL).length, 4);
});

test("memory poc: provider error falls back to token overlap with fixed codes, no text", async () => {
  const logger = silent();
  const shared = new InMemoryStore();
  const store = new PocMemoryStore(ENV, shared, { fetchFn: fakeFetch({ failEmbed: true, failLlm: true }), logger });
  const written = await store.write(mem(`${SECRET_TEXT} sleep shorter`));
  assert.equal(written.text, `${SECRET_TEXT} sleep shorter`);
  assert.equal(shared.items.length, 1);
  const out = await store.recall({ query: "my sleep", now: NOW });
  assert.deepEqual(texts(out), [`${SECRET_TEXT} sleep shorter`]);
  const codes = logger.lines.map((l) => l[3]);
  assert.deepEqual(codes, ["memory_llm_status", "memory_embed_status", "memory_embed_status", "memory_poc_fallback"]);
  const dump = JSON.stringify(logger.lines);
  for (const s of [SECRET_TEXT, OC_KEY, NB_KEY, "sleep"]) assert.ok(!dump.includes(s));
  for (const l of logger.lines) assert.deepEqual(l.slice(0, 3), ["memory_poc", l[1], MEMORY_POC_PROVIDER]);
  // Client results carry the fixed code only, never upstream text.
  const r = await embed("x", ENV, { fetchFn: fakeFetch({ failEmbed: true }) });
  assert.deepEqual(r, { code: "memory_embed_status" });
  const net = async () => { throw new Error(SECRET_TEXT); };
  assert.deepEqual(await embed("x", ENV, { fetchFn: net }), { code: "memory_embed_network" });
  assert.deepEqual(await extractFact("x", ENV, { fetchFn: net }), { code: "memory_llm_network" });
});

test("memory poc: unembedded items follow embedded ones", async () => {
  const shared = new InMemoryStore();
  const logger = silent();
  await new PocMemoryStore(ENV, shared, { fetchFn: fakeFetch({ failEmbed: true }), logger }).write(mem("sleep log offline"));
  const store = new PocMemoryStore(ENV, shared, { fetchFn: fakeFetch(), logger });
  await store.write(mem("Sleep is shorter on weekdays"));
  assert.deepEqual(texts(await store.recall({ query: "sleep", now: NOW })), ["Sleep is shorter on weekdays", "sleep log offline"]);
});

// Route level: /memory/write and /memory/recall pick the store from env.
const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const AUTH = { Authorization: `Bearer ${issueToken("test-device", SECRET, { now: Date.parse("2026-01-01T00:00:00Z"), ttlDays: 3650 })}` };
const call = (h, path, body, env) =>
  h(new Request(`https://x.test${path}`, { method: "POST", headers: AUTH, body: JSON.stringify(body) }), { DEVICE_TOKEN_SECRET: SECRET, ...env });

test("memory poc routes: unknown provider is 503 not_configured; unset is unchanged", async () => {
  const store = new InMemoryStore();
  const h = createHandler({ store, logger: silent(), fetchFn: () => { throw new Error("network touched"); } });
  const w = { text: "sleep shorter", kind: "note", source: "test" };
  const bad = await call(h, "/memory/write", w, { MEMORY_PROVIDER: "something" });
  assert.equal(bad.status, 503);
  assert.match((await bad.json()).detail, /MEMORY_PROVIDER unknown/);
  assert.equal(store.items.length, 0);
  const missing = await call(h, "/memory/recall", { query: "sleep" }, { DATA_MODE: "synthetic", MEMORY_PROVIDER: MEMORY_POC_PROVIDER });
  assert.equal(missing.status, 503);
  assert.match((await missing.json()).detail, /OPENCODE_API_KEY missing/);
  assert.equal((await call(h, "/memory/write", w, {})).status, 200);
  const items = (await (await call(h, "/memory/recall", { query: "sleep" }, {})).json()).items;
  assert.deepEqual(texts(items), ["sleep shorter"]);
});

test("memory poc routes: switch set uses the PoC path through global fetch", async () => {
  const original = globalThis.fetch;
  const fetchFn = fakeFetch();
  globalThis.fetch = fetchFn;
  const origWarn = console.warn;
  console.warn = () => {};
  try {
    const store = new InMemoryStore();
    const h = createHandler({ store, logger: silent() });
    await call(h, "/memory/write", { text: "Squat felt heavy", kind: "note", source: "test" }, ENV);
    await call(h, "/memory/write", { text: "Sleep is shorter", kind: "note", source: "test" }, ENV);
    const items = (await (await call(h, "/memory/recall", { query: "why am I tired" }, ENV)).json()).items;
    assert.deepEqual(texts(items), ["Sleep is shorter", "Squat felt heavy"]);
    assert.equal(fetchFn.calls.length, 5);
  } finally {
    globalThis.fetch = original;
    console.warn = origWarn;
  }
});
