// Tavily client (contract C2): request shape, https-only results, fixed error codes, key never in an error.
// Fake fetch only; the key is generated per run and never printed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TAVILY_URL, searchTavily, tavilyConfigProblem } from "../src/providers/tavily.js";

const KEY = `tvly-test-${crypto.randomUUID()}`;
const ENV = { TAVILY_API_KEY: KEY, DATA_MODE: "synthetic" };

function fakeFetch(handler) {
  const calls = [];
  const fetchFn = async (url, init) => {
    calls.push({ url, init });
    return handler(url, init);
  };
  return { fetchFn, calls };
}
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// Asserts a rejection with one fixed code and that the key appears nowhere in the error.
async function assertCode(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code);
    assert.equal(err.message, code);
    assert.ok(!err.message.includes(KEY));
    assert.ok(!JSON.stringify(err).includes(KEY));
    assert.ok(!String(err.stack ?? "").includes(KEY));
    return true;
  });
}

test("request: POST to the fixed URL with bearer auth and the C2 body", async () => {
  const { fetchFn, calls } = fakeFetch(() => json({ answer: "", results: [] }));
  await searchTavily("eggs calories per piece", ENV, { fetchFn, maxResults: 3 });
  assert.equal(TAVILY_URL, "https://api.tavily.com/search");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.tavily.com/search");
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers["Content-Type"], "application/json");
  assert.equal(calls[0].init.headers.Authorization, `Bearer ${KEY}`);
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    query: "eggs calories per piece",
    search_depth: "basic",
    max_results: 3,
    include_answer: true,
    include_raw_content: false,
  });
});

test("request: query is capped at 400 characters and max_results at 10", async () => {
  const { fetchFn, calls } = fakeFetch(() => json({ results: [] }));
  await searchTavily("x".repeat(900), ENV, { fetchFn, maxResults: 50 });
  const sent = JSON.parse(calls[0].init.body);
  assert.equal(sent.query.length, 400);
  assert.equal(sent.max_results, 10);
});

test("results: only https URLs are kept, with bounded title and content", async () => {
  const long = "c".repeat(2000);
  const { fetchFn } = fakeFetch(() =>
    json({
      answer: " an answer ",
      results: [
        { title: "Good", url: "https://example.org/a", content: long },
        { title: "Plain http", url: "http://example.org/b", content: "no" },
        { title: "Script", url: "javascript:alert(1)", content: "no" },
        { title: "", url: "https://example.org/c", content: "ok" },
        null,
      ],
    }),
  );
  const out = await searchTavily("q", ENV, { fetchFn });
  assert.equal(out.answer, "an answer");
  assert.deepEqual(out.results.map((r) => r.url), ["https://example.org/a", "https://example.org/c"]);
  assert.equal(out.results[0].content.length, 1500);
  assert.equal(out.results[1].title, "https://example.org/c");
});

test("status codes map to their fixed codes", async () => {
  const cases = [
    [401, "tavily_unauthorized"],
    [403, "tavily_unauthorized"],
    [429, "tavily_rate_limited"],
    [432, "tavily_rate_limited"],
    [433, "tavily_rate_limited"],
    [400, "tavily_status_4xx"],
    [404, "tavily_status_4xx"],
    [500, "tavily_status_5xx"],
    [503, "tavily_status_5xx"],
  ];
  for (const [status, code] of cases) {
    const { fetchFn } = fakeFetch(() => new Response(`upstream says ${KEY}`, { status }));
    await assertCode(searchTavily("q", ENV, { fetchFn }), code);
  }
});

test("network failure and timeout map to their codes", async () => {
  await assertCode(
    searchTavily("q", ENV, { fetchFn: async () => { throw new TypeError(`fetch failed for ${KEY}`); } }),
    "tavily_network",
  );
  const timeout = Object.assign(new Error("timed out"), { name: "TimeoutError" });
  await assertCode(searchTavily("q", ENV, { fetchFn: async () => { throw timeout; } }), "tavily_timeout");
});

test("a body that is not JSON or not an object is tavily_bad_response", async () => {
  const notJson = fakeFetch(() => new Response("<html>", { status: 200 }));
  await assertCode(searchTavily("q", ENV, { fetchFn: notJson.fetchFn }), "tavily_bad_response");
  const array = fakeFetch(() => json([1, 2]));
  await assertCode(searchTavily("q", ENV, { fetchFn: array.fetchFn }), "tavily_bad_response");
});

test("missing key is tavily_not_configured and makes no call", async () => {
  const { fetchFn, calls } = fakeFetch(() => json({ results: [] }));
  await assert.rejects(searchTavily("q", { DATA_MODE: "synthetic" }, { fetchFn }), (e) => e.code === "tavily_not_configured");
  assert.equal(calls.length, 0);
});

test("owner_real refuses Tavily with the fixed message and makes no call", async () => {
  assert.equal(tavilyConfigProblem({ TAVILY_API_KEY: KEY }, "log"), "tavily refused for log under DATA_MODE=owner_real");
  assert.equal(tavilyConfigProblem({ TAVILY_API_KEY: KEY }), "tavily refused for search under DATA_MODE=owner_real");
  assert.equal(tavilyConfigProblem({}), "TAVILY_API_KEY missing");
  assert.equal(tavilyConfigProblem({ TAVILY_API_KEY: KEY, DATA_MODE: "synthetic" }), null);
  assert.equal(tavilyConfigProblem({ TAVILY_API_KEY: KEY, DATA_MODE: "owner_any" }), null);
  const { fetchFn, calls } = fakeFetch(() => json({ results: [] }));
  await assert.rejects(searchTavily("q", { TAVILY_API_KEY: KEY }, { fetchFn }), (e) => e.code === "tavily_refused");
  assert.equal(calls.length, 0);
});

test("no error text or return value ever contains the key", async () => {
  const { fetchFn } = fakeFetch(() => json({ answer: "a", results: [{ title: "t", url: "https://e.org", content: "c" }] }));
  const out = await searchTavily("q", ENV, { fetchFn });
  assert.ok(!JSON.stringify(out).includes(KEY));
});
