// searchWeb (contract C3): Meta first, then Tavily, then null; Tavily refused under owner_real. Fake fetch only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { searchWeb, WEB_TEXT_MAX } from "../src/council/web.js";

const META_KEY = `meta-test-${crypto.randomUUID()}`;
const TAVILY_KEY = `tvly-test-${crypto.randomUUID()}`;
const META_ENV = { META_API_KEY: META_KEY, META_MODEL: "synthetic/meta-test" };
const TAVILY_ENV = { TAVILY_API_KEY: TAVILY_KEY };
const SYNTH = { DATA_MODE: "synthetic" };

// Routes by host: Meta's Responses endpoint and Tavily's search endpoint.
function router({ meta, tavily }) {
  const calls = [];
  const fetchFn = async (url, init) => {
    calls.push({ url, init });
    const handler = url.startsWith("https://api.meta.ai") ? meta : tavily;
    if (!handler) throw new Error("unexpected host");
    return handler(url, init);
  };
  return { fetchFn, calls };
}
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const metaOk = () =>
  json({
    output: [
      {
        type: "message",
        content: [
          {
            type: "output_text",
            text: "Adults should aim for steady sleep.",
            annotations: [{ type: "url_citation", url: "https://www.who.int/sleep", title: "WHO sleep" }],
          },
        ],
      },
    ],
  });
const tavilyOk = () =>
  json({ answer: "Sleep is restorative.", results: [{ title: "NHS", url: "https://www.nhs.uk/sleep", content: "Sleep details." }] });

test("Meta is used when configured", async () => {
  const { fetchFn, calls } = router({ meta: metaOk, tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /^https:\/\/api\.meta\.ai\/v1\/responses$/);
  assert.equal(out.text, "Adults should aim for steady sleep.");
  assert.deepEqual(out.results, [
    { title: "WHO sleep", url: "https://www.who.int/sleep", content: "Adults should aim for steady sleep." },
  ]);
});

test("Tavily is used when only Tavily is configured", async () => {
  const { fetchFn, calls } = router({ tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.tavily.com/search");
  assert.equal(out.text, "Sleep is restorative.");
  assert.deepEqual(out.results, [{ title: "NHS", url: "https://www.nhs.uk/sleep", content: "Sleep details." }]);
});

test("null when neither is configured, with no call", async () => {
  const { fetchFn, calls } = router({});
  assert.equal(await searchWeb("sleep", {}, { fetchFn }), null);
  assert.equal(calls.length, 0);
});

test("Tavily is refused under DATA_MODE=owner_real: null and no call", async () => {
  const { fetchFn, calls } = router({ tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...TAVILY_ENV, DATA_MODE: "owner_real" }, { fetchFn });
  assert.equal(out, null);
  assert.equal(calls.length, 0);
});

test("under owner_real Meta answers and Tavily is never called", async () => {
  const { fetchFn, calls } = router({ meta: metaOk, tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV }, { fetchFn });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url.startsWith("https://api.meta.ai"), true);
  assert.equal(out.text, "Adults should aim for steady sleep.");
});

test("a failing Meta call falls through to Tavily", async () => {
  const { fetchFn, calls } = router({ meta: () => new Response("", { status: 500 }), tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(calls.length, 2);
  assert.equal(out.text, "Sleep is restorative.");
});

test("a failing Tavily call gives null, and the key is never in the result", async () => {
  const { fetchFn } = router({ tavily: () => new Response(`bad ${TAVILY_KEY}`, { status: 500 }) });
  const out = await searchWeb("sleep", { ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out, null);
});

test("text is capped at 1200 characters", async () => {
  const long = "word ".repeat(600);
  const { fetchFn } = router({
    tavily: () => json({ answer: long, results: [] }),
  });
  const out = await searchWeb("sleep", { ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out.text.length, WEB_TEXT_MAX);
  assert.equal(WEB_TEXT_MAX, 1200);
});

test("with no answer, Tavily text is the joined result contents", async () => {
  const { fetchFn } = router({
    tavily: () => json({ answer: "", results: [{ title: "a", url: "https://a.org", content: "First." }, { title: "b", url: "https://b.org", content: "Second." }] }),
  });
  const out = await searchWeb("sleep", { ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out.text, "First. Second.");
});

test("no key appears in the returned value", async () => {
  const { fetchFn } = router({ meta: metaOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...SYNTH }, { fetchFn });
  assert.ok(!JSON.stringify(out).includes(META_KEY));
});

const metaWith = (text, annotations) => () =>
  json({ output: [{ type: "message", content: [{ type: "output_text", text, annotations }] }] });
const cite = (url, title) => ({ type: "url_citation", url, title });

test("Meta with a kept citation returns via meta", async () => {
  const { fetchFn } = router({ meta: metaOk, tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out.via, "meta");
});

test("Meta text with zero citations falls through to Tavily", async () => {
  const { fetchFn, calls } = router({ meta: metaWith("Uncited narration.", []), tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(calls.length, 2);
  assert.equal(out.via, "tavily");
  assert.equal(out.text, "Sleep is restorative.");
});

test("Meta whose only citations are excluded falls through to Tavily", async () => {
  const { fetchFn } = router({ meta: metaWith("Forum view.", [cite("https://www.reddit.com/r/x", "r/x")]), tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out.via, "tavily");
});

test("Meta uncited with no Tavily gives null, never via meta", async () => {
  const { fetchFn } = router({ meta: metaWith("Uncited narration.", []) });
  assert.equal(await searchWeb("sleep", { ...META_ENV, ...SYNTH }, { fetchFn }), null);
});

test("Meta throwing falls through to Tavily", async () => {
  const { fetchFn } = router({ meta: () => { throw new TypeError("network down"); }, tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out.via, "tavily");
});

test("a deadline already passed returns null with no fetch", async () => {
  const { fetchFn, calls } = router({ meta: metaOk, tavily: tavilyOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...TAVILY_ENV, ...SYNTH }, { fetchFn, deadlineAt: Date.now() - 1 });
  assert.equal(out, null);
  assert.equal(calls.length, 0);
});

test("a future deadline still searches", async () => {
  const { fetchFn } = router({ meta: metaOk });
  const out = await searchWeb("sleep", { ...META_ENV, ...SYNTH }, { fetchFn, deadlineAt: Date.now() + 5000, timeoutMs: 60_000 });
  assert.equal(out.via, "meta");
});

test("the summary appears on only one source", async () => {
  const text = "Sleep seven to nine hours.";
  const { fetchFn } = router({
    meta: metaWith(text, [cite("https://www.who.int/a", "A"), cite("https://www.nhs.uk/b", "B"), cite("https://www.cdc.gov/c", "C")]),
  });
  const out = await searchWeb("sleep", { ...META_ENV, ...SYNTH }, { fetchFn });
  assert.equal(out.results.length, 3);
  assert.equal(out.results.filter((r) => r.content === text).length, 1);
  assert.equal(out.results[0].content, text);
  assert.deepEqual(out.results.slice(1).map((r) => r.content), ["", ""]);
});
