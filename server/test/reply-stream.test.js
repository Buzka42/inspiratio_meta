// POST /reply/stream: SSE sentences through the /reply rules. Synthetic only: fake fetch with a
// streamed body, per-run key, invented transcript. No live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { REFERRAL_TEXT, NOT_MEDICAL_ADVICE, SAFE_FALLBACK_TEXT } from "../src/safety.js";
import { NEBIUS_PROVIDER } from "../src/nebius.js";
import { POC_PROVIDER } from "../src/reply.js";
import { OPENCODE_URL } from "../src/opencode.js";
import { MIN_SENTENCE, splitSentences } from "../src/reply-stream.js";

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const KEY = `nebius-test-${crypto.randomUUID()}`;
const ENV = { DEVICE_TOKEN_SECRET: SECRET, REPLY_PROVIDER: NEBIUS_PROVIDER, NEBIUS_API_KEY: KEY, REPLY_LLM_MODEL: "synthetic/chat-model-test" };
const PLAN = { crisis: false, personality_id: "calm_guide", skill_id: null, escalate: false };
const TRANSCRIPT = "synthetic-transcript-77d1 plan my day around three meetings";
const S1 = "Synthetic-s1 Start with the first meeting at nine.";
const S2 = "Synthetic-s2 Keep a short gap after it for notes.";
const S3 = "Synthetic-s3 Finish the day with the easiest call.";

const enc = new TextEncoder();
const chunk = (content) => `data: ${JSON.stringify({ object: "chat.completion.chunk", choices: [{ delta: { content } }] })}\n\n`;
const sseBody = (parts) =>
  new ReadableStream({
    start(c) {
      for (const p of parts) c.enqueue(enc.encode(p));
      c.close();
    },
  });
// Splits text into small token-like pieces, as a model stream would.
const tokens = (text) => text.match(/.{1,7}/gs).map(chunk);
const streamOf = (text) => [...tokens(text), "data: [DONE]\n\n"];

function fakeFetch(respond) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return respond(url, init);
  };
  return { fn, calls };
}
const okStream = (parts) => () => new Response(sseBody(parts), { status: 200, headers: { "Content-Type": "text/event-stream" } });

const handler = (fetchFn, logger = console, quotaStore = new InMemoryQuotaStore()) =>
  createHandler({ fetchFn, logger, store: new InMemoryStore(), quotaStore });
const request = (body, path = "/reply/stream", token = issueToken("device-stream", SECRET)) =>
  new Request(`https://x.test${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
const post = (fetchFn, body = { plan: PLAN, transcript: TRANSCRIPT }, env = ENV, logger = console) =>
  handler(fetchFn, logger)(request(body), env);

function parseEvents(text) {
  return text
    .split("\n\n")
    .filter(Boolean)
    .map((block) => {
      const [ev, data] = block.split("\n");
      return { event: ev.replace(/^event: /, ""), data: JSON.parse(data.replace(/^data: /, "")) };
    });
}
const eventsOf = async (res) => parseEvents(await res.text());

async function captureConsole(fn) {
  const lines = [];
  const saved = {};
  for (const m of ["log", "info", "warn", "error", "debug"]) {
    saved[m] = console[m];
    console[m] = (...args) => lines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  }
  try {
    await fn();
  } finally {
    Object.assign(console, saved);
  }
  return lines;
}

test("stream: sentences come out in order, the last in done, model called with stream: true", async () => {
  const { fn, calls } = fakeFetch(okStream(streamOf(`${S1} ${S2} ${S3}`)));
  const res = await post(fn);
  assert.equal(res.status, 200);
  assert.match(res.headers.get("Content-Type"), /^text\/event-stream/);
  const events = await eventsOf(res);
  assert.deepEqual(events.map((e) => e.event), ["sentence", "sentence", "done"]);
  assert.deepEqual(events.slice(0, 2).map((e) => e.data.text), [S1, S2]);
  assert.deepEqual(events[2].data, { text: S3, personality_id: "calm_guide", safety: "passed", health: false, council_suggested: false });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.stream, true);
  assert.equal(calls[0].url, "https://api.tokenfactory.nebius.com/v1/chat/completions");
  assert.equal(calls[0].init.headers.Authorization, `Bearer ${KEY}`);
});

test("stream: hold-back releases a sentence only after the next one is complete", async () => {
  let up;
  const body = new ReadableStream({ start: (c) => (up = c) });
  const { fn } = fakeFetch(() => new Response(body, { status: 200 }));
  const res = await post(fn);
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  const nothingYet = async () => {
    const tick = new Promise((r) => setTimeout(() => r("none"), 40));
    const next = reader.read();
    const got = await Promise.race([next, tick]);
    return { got, next };
  };
  const push = (text) => up.enqueue(enc.encode(tokens(text).join("")));

  push(`${S1} `);
  let { got, next } = await nothingYet();
  assert.equal(got, "none", "a lone sentence is held back");
  push("Synthetic-s2 Keep a short gap");
  got = await Promise.race([next, new Promise((r) => setTimeout(() => r("none"), 40))]);
  assert.equal(got, "none", "a started but unfinished next sentence does not release it yet");
  push(" after it for notes. Fin");
  const first = parseEvents(dec.decode((await next).value));
  assert.deepEqual(first, [{ event: "sentence", data: { text: S1 } }]);
  up.enqueue(enc.encode("data: [DONE]\n\n"));
  up.close();
  let rest = "";
  for (;;) {
    const r = await reader.read();
    if (r.done) break;
    rest += dec.decode(r.value);
  }
  const tail = parseEvents(rest);
  assert.deepEqual(tail.map((e) => [e.event, e.data.text]), [["sentence", S2], ["done", "Fin"]]);
});

test("stream: a failing sentence whose repair fails stops the stream and done carries the safe fallback", async () => {
  const bad = "Synthetic-bad You must take this pill every day now.";
  // The repair call gets the same SSE body, which is not JSON: the repair fails.
  const { fn, calls } = fakeFetch(okStream(streamOf(`${S1} ${bad} ${S3}`)));
  const events = await eventsOf(await post(fn));
  // S1 was held back when the bad sentence arrived; on "replaced" it never goes out.
  assert.deepEqual(events.map((e) => e.event), ["done"]);
  assert.equal(events[0].data.safety, "replaced");
  assert.equal(events[0].data.council_suggested, false);
  assert.ok(events[0].data.text.startsWith(SAFE_FALLBACK_TEXT));
  assert.equal(calls.length, 2, "one repair call at most");
  assert.equal(calls[1].body.stream, undefined, "the repair call does not stream");
  assert.ok(!JSON.stringify(events).includes("Synthetic-bad"));
  assert.ok(!JSON.stringify(events).includes(S3));
});

test("stream: a failing last sentence is caught at the end of the stream", async () => {
  const { fn } = fakeFetch(okStream(streamOf(`${S1} ${S2} I can diagnose this for you`)));
  const events = await eventsOf(await post(fn));
  assert.deepEqual(events.map((e) => e.event), ["sentence", "done"]);
  assert.equal(events[0].data.text, S1);
  assert.equal(events[1].data.safety, "replaced");
  assert.ok(events[1].data.text.startsWith(SAFE_FALLBACK_TEXT));
});

test("stream: crisis input never calls the model and gets the fixed referral", async () => {
  for (const body of [
    { plan: { ...PLAN, crisis: true }, transcript: TRANSCRIPT },
    { plan: PLAN, transcript: "synthetic-crisis i want to die" },
  ]) {
    const { fn, calls } = fakeFetch(() => assert.fail("model must not be called"));
    const res = await post(fn, body);
    assert.equal(res.status, 200);
    const events = await eventsOf(res);
    assert.deepEqual(events, [{ event: "done", data: { text: REFERRAL_TEXT, personality_id: null, safety: "replaced", health: false, council_suggested: false } }]);
    assert.equal(calls.length, 0);
  }
});

test("stream: upstream error mid-stream gives one error event and no model text", async () => {
  const parts = [...tokens(`${S1} ${S2} ${S3}`), `data: ${JSON.stringify({ error: { message: "synthetic-upstream-secret" } })}\n\n`, "data: [DONE]\n\n"];
  const { fn } = fakeFetch(okStream(parts));
  const events = await eventsOf(await post(fn));
  assert.deepEqual(events.map((e) => e.event), ["sentence", "error"]);
  assert.deepEqual(events[1].data, { error: "reply_upstream" });
  assert.ok(!JSON.stringify(events[1]).toLowerCase().includes("synthetic"));
  // A broken body (connection drop) is the same.
  const broken = new ReadableStream({
    start(c) {
      c.enqueue(enc.encode(tokens(`${S1} `).join("")));
      c.error(new Error("synthetic-drop"));
    },
  });
  const ev2 = await eventsOf(await post(async () => new Response(broken, { status: 200 })));
  assert.deepEqual(ev2, [{ event: "error", data: { error: "reply_upstream" } }]);
  // Non-2xx status and an empty stream.
  for (const respond of [() => new Response("synthetic-err", { status: 500 }), okStream(["data: [DONE]\n\n"])]) {
    const ev = await eventsOf(await post(respond));
    assert.deepEqual(ev, [{ event: "error", data: { error: "reply_upstream" } }]);
  }
});

test("stream: a stalled upstream ends with reply_timeout and aborts the call", async () => {
  let signal;
  const fn = async (url, init) => {
    signal = init.signal;
    const body = new ReadableStream({
      start(c) {
        c.enqueue(enc.encode(tokens(`${S1} `).join("")));
        init.signal.addEventListener("abort", () => c.error(Object.assign(new Error("aborted"), { name: "AbortError" })));
      },
    });
    return new Response(body, { status: 200 });
  };
  const { runReplyStream } = await import("../src/reply-stream.js");
  const out = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: fn, timeoutMs: 30 });
  const events = parseEvents(await new Response(out.stream).text());
  assert.deepEqual(events, [{ event: "error", data: { error: "reply_timeout" } }]);
  assert.equal(signal.aborted, true);
});

test("stream: plain sleep or breathing replies get no medical line", async () => {
  const h1 = "Synthetic-h1 A short walk can help after poor sleep.";
  const h2 = "Synthetic-h2 A few slow breaths can help you relax.";
  const { fn } = fakeFetch(okStream(streamOf(`${h1} ${h2}`)));
  const events = await eventsOf(await post(fn, { plan: PLAN, transcript: "synthetic slept badly and stressed" }));
  assert.deepEqual(events.map((e) => [e.event, e.data.text]), [["sentence", h1], ["done", h2]]);
  assert.equal(events[1].data.health, false);
});

test("stream: the marker is stripped from the first sentence; the line comes once, on done only", async () => {
  const h1 = "Synthetic-h1 Stopping a medicine suddenly can be risky.";
  const h2 = "Synthetic-h2 A clinician can talk the options through with you.";
  // streamOf cuts the text into 7-character pieces, so the marker arrives split across chunks.
  for (const raw of [`[[HEALTH]]\n${h1} ${h2}`, `[[HEALTH]] ${h1} ${h2}`, `<think>synthetic plan</think>[[HEALTH]]${h1} ${h2}`]) {
    const { fn } = fakeFetch(okStream(streamOf(raw)));
    const events = await eventsOf(await post(fn, { plan: PLAN, transcript: "synthetic can I stop my tablets" }));
    assert.deepEqual(events.map((e) => [e.event, e.data.text]), [["sentence", h1], ["done", `${h2} ${NOT_MEDICAL_ADVICE}`]], raw);
    assert.equal(events[1].data.health, true);
    assert.ok(!/\[\[|health\]/i.test(JSON.stringify(events)), "marker never sent");
  }
  // A one-sentence marked reply: the marker is stripped from the done text too.
  const { fn } = fakeFetch(okStream(streamOf(`[[HEALTH]] ${h1}`)));
  const one = await eventsOf(await post(fn, { plan: PLAN, transcript: "synthetic can I stop my tablets" }));
  assert.deepEqual(one.map((e) => [e.event, e.data.text]), [["done", `${h1} ${NOT_MEDICAL_ADVICE}`]]);
});

test("stream: text that only starts like the marker is sent as is", async () => {
  const s = "[Synthetic note] Start with the first meeting at nine.";
  const { fn } = fakeFetch(okStream(streamOf(`${s} ${S2}`)));
  const events = await eventsOf(await post(fn));
  assert.deepEqual(events.map((e) => [e.event, e.data.text]), [["sentence", s], ["done", S2]]);
  assert.equal(events[1].data.health, false);
});

test("stream: <think> blocks are never sent", async () => {
  const { fn } = fakeFetch(okStream(streamOf(`<think>synthetic-think. You must diagnose. Plan it.</think>${S1} ${S2}`)));
  const events = await eventsOf(await post(fn));
  assert.deepEqual(events.map((e) => e.data.text), [S1, S2]);
  assert.equal(events[1].data.safety, "passed");
});

test("stream: same auth, input checks and config refusal as /reply, as JSON", async () => {
  const { fn, calls } = fakeFetch(() => assert.fail("no call"));
  const h = handler(fn);
  assert.equal((await h(request({ plan: PLAN, transcript: TRANSCRIPT }, "/reply/stream", "bad"), ENV)).status, 401);
  const bad = await h(request({ plan: PLAN, transcript: "" }), ENV);
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).error, "bad_request");
  const unconfigured = await h(request({ plan: PLAN, transcript: TRANSCRIPT }), { ...ENV, NEBIUS_API_KEY: "" });
  assert.equal(unconfigured.status, 503);
  assert.equal((await unconfigured.json()).error, "reply_not_configured");
  assert.equal(calls.length, 0);
});

test("stream: shares the reply quota with /reply, one hit per request", async () => {
  const quota = new InMemoryQuotaStore();
  const env = { ...ENV, QUOTA_REPLIES_PER_DAY: "2" };
  const h = handler((...a) => okStream(streamOf(`${S1} ${S2}`))(...a), console, quota);
  const res1 = await h(request({ plan: PLAN, transcript: TRANSCRIPT }), env);
  assert.equal(res1.status, 200);
  await res1.text();
  const res2 = await h(request({ plan: PLAN, transcript: TRANSCRIPT }, "/reply"), env);
  assert.equal(res2.status, 502); // the fake streams; /reply only wants JSON, but the quota was counted
  const res3 = await h(request({ plan: PLAN, transcript: TRANSCRIPT }), env);
  assert.equal(res3.status, 429);
  assert.equal((await res3.json()).bucket, "reply");
});

test("stream: opencode_poc also streams (UNVERIFIED against the live service)", async () => {
  const { fn, calls } = fakeFetch(okStream(streamOf(`${S1} ${S2}`)));
  const env = { DEVICE_TOKEN_SECRET: SECRET, DATA_MODE: "synthetic", REPLY_PROVIDER: POC_PROVIDER, OPENCODE_API_KEY: KEY };
  const events = await eventsOf(await post(fn, undefined, env));
  assert.deepEqual(events.map((e) => e.event), ["sentence", "done"]);
  assert.equal(calls[0].url, OPENCODE_URL);
  assert.equal(calls[0].body.stream, true);
});

test("stream: no logged line carries the key, transcript or model text", async () => {
  const bad = "Synthetic-bad You must take this pill every day now.";
  const lines = await captureConsole(async () => {
    await (await post(fakeFetch(okStream(streamOf(`${S1} ${S2}`))).fn)).text();
    await (await post(fakeFetch(okStream(streamOf(`${S1} ${bad}`))).fn)).text();
    await (await post(fakeFetch(okStream([...tokens(S1), `data: ${JSON.stringify({ error: { message: "synthetic-x" } })}\n\n`])).fn)).text();
    await (await post(fakeFetch(() => assert.fail()).fn, { plan: { ...PLAN, system_prompt: "synthetic-client-prompt" }, transcript: "synthetic i want to die" })).text();
  });
  assert.ok(lines.some((l) => l.includes("reply_replaced")));
  assert.ok(lines.some((l) => l.includes("reply_upstream")));
  assert.ok(lines.some((l) => l.includes("reply_crisis")));
  for (const l of lines) {
    assert.ok(!l.includes(KEY), "key never logged");
    assert.ok(!l.toLowerCase().includes("synthetic"), `no transcript or model text in: ${l}`);
  }
});

test("splitSentences: endings, Polish quotes, minimum length and run-on cut", () => {
  assert.deepEqual(splitSentences("Ok. Then we go now, all of us. Next"), { sentences: ["Ok. Then we go now, all of us."], rest: "Next" });
  assert.deepEqual(splitSentences("To jest pierwsze zdanie, prawda?» Drugie").sentences, ["To jest pierwsze zdanie, prawda?»"]);
  assert.deepEqual(splitSentences("Version 3.5 is out now for everyone. ").sentences, [], "no split without the next sentence");
  assert.deepEqual(splitSentences("We met e.g. yesterday at noon for a while. X").sentences, ["We met e.g. yesterday at noon for a while."]);
  const long = "word ".repeat(120);
  const { sentences, rest } = splitSentences(long);
  assert.ok(sentences.length >= 1 && sentences.every((s) => s.length <= 400) && rest.length <= 400);
  assert.ok(MIN_SENTENCE > 0);
});
