// Routes for council v2: /council, /digest (council run), /analysis/21d, /session/summary, quotas, logs.
// Fake fetch only; per-run secrets; synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { computeAnalysis } from "../src/analysis/run21d.js";
import { CRISIS_SUMMARY } from "../src/session-summary.js";
import { NOT_MEDICAL_ADVICE, REFERRAL_TEXT } from "../src/safety.js";

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const KEY = `meta-test-${crypto.randomUUID()}`;
const META = { META_API_KEY: KEY, META_MODEL: "synthetic/meta-model-test" };
const NO_QUOTA = { QUOTA_COUNCIL_PER_DAY: "100000", QUOTA_DIGESTS_PER_DAY: "100000", QUOTA_SESSION_SUMMARIES_PER_DAY: "100000" };
const NOW = Date.parse("2026-10-25T09:00:00Z");
const noNet = () => { throw new Error("network touched"); };

const res = (body, status = 200) => new Response(JSON.stringify(body), { status });
const chat = (content, tool_calls) => res({ choices: [{ message: { content, ...(tool_calls ? { tool_calls } : {}) } }] });
const finalJson = (synthesis, o = {}) => JSON.stringify({ synthesis, experts_consulted: [], sources: [], medical: false, ...o });

function recorder(answer) {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body });
    return answer(body, calls.length - 1);
  };
  return { fn, calls };
}

function handler(fetchFn, { quotaStore = new InMemoryQuotaStore(), logger } = {}) {
  const h = createHandler({ fetchFn, store: new InMemoryStore(), quotaStore, now: () => NOW, ...(logger ? { logger } : {}) });
  const token = issueToken("device-v2", SECRET, { now: NOW });
  return (path, body, env = {}) =>
    h(new Request(`https://x.test${path}`, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }),
      { DEVICE_TOKEN_SECRET: SECRET, ...NO_QUOTA, ...env });
}

// ---- /council ----

test("/council v2: default route is the brain relay with the v2 response shape", async () => {
  const { fn, calls } = recorder(() => chat(finalJson("Synthetic: consider a regular wind-down.")));
  const post = handler(fn);
  const out = await (await post("/council", { question: "synthetic question about my evenings", purpose: "chat", context: { short_term_summary: "synthetic" } }, META)).json();
  for (const k of ["synthesis", "experts_consulted", "sources", "medical", "providers"]) assert.ok(k in out, k);
  assert.deepEqual(out.providers, ["meta"]);
  assert.equal(calls[0].url, "https://api.meta.ai/v1/chat/completions");
  assert.ok(!("rounds" in out));
});

test("/council v2: validation, unknown provider, not configured, legacy refused under owner_real", async () => {
  const post = handler(noNet);
  assert.equal((await post("/council", { question: "q", purpose: "gossip" }, META)).status, 400);
  assert.equal((await post("/council", { question: "q", context: "text" }, META)).status, 400);
  assert.equal((await post("/council", { question: "q", context: { short_term_summary: "x".repeat(2001) } }, META)).status, 400);
  assert.equal((await post("/council", { question: "q", personas: [{ id: "a", model: "deepseek-v4.1-flash-free" }] }, META)).status, 400);
  const none = await post("/council", { question: "q" }, {});
  assert.equal(none.status, 503);
  assert.match((await none.json()).detail, /META_API_KEY missing/);
  const unknown = await post("/council", { question: "q" }, { ...META, COUNCIL_PROVIDER: "openai" });
  assert.equal(unknown.status, 503);
  const legacy = await post("/council", { question: "q" }, { COUNCIL_PROVIDER: "opencode", OPENCODE_API_KEY: "k" });
  assert.equal(legacy.status, 503);
  assert.match((await legacy.json()).detail, /opencode refused for council under DATA_MODE=owner_real/);
});

test("/council v2: crisis question gets the referral with no call", async () => {
  const out = await (await handler(noNet)("/council", { question: "I want to die" }, META)).json();
  assert.equal(out.synthesis, REFERRAL_TEXT);
});

test("/council v2: upstream failure is a fixed 502 with no key or body in the response or logs", async () => {
  const lines = [];
  const capture = (...a) => lines.push(a.join(" "));
  const leaky = async () => new Response(`echo ${KEY}`, { status: 500 });
  const post = handler(leaky, { logger: { warn: capture, error: capture, log: capture } });
  const r = await post("/council", { question: "synthetic-question-marker" }, META);
  assert.equal(r.status, 502);
  const text = await r.text();
  for (const s of [text, ...lines]) {
    assert.ok(!s.includes(KEY));
    assert.ok(!s.includes("synthetic-question-marker"));
  }
  assert.ok(lines.some((l) => l === "route_error /council device-v2 upstream_error"));
});

// ---- quotas ----

test("quotas: /analysis/21d shares the council bucket; /session/summary has its own", async () => {
  const quotaStore = new InMemoryQuotaStore();
  const { fn } = recorder(() => chat('{"summary":"Synthetic summary.","topics":[]}'));
  const post = handler(fn, { quotaStore });
  const env = { ...META, QUOTA_COUNCIL_PER_DAY: "1", QUOTA_SESSION_SUMMARIES_PER_DAY: "1" };
  assert.equal((await post("/council", { question: "I want to die" }, env)).status, 200);
  const over = await post("/analysis/21d", { start: "2026-10-01", checkins: [] }, env);
  assert.equal(over.status, 429);
  assert.equal((await over.json()).bucket, "council");
  const turns = [{ role: "user", text: "synthetic" }];
  assert.equal((await post("/session/summary", { turns }, env)).status, 200);
  const s2 = await post("/session/summary", { turns }, env);
  assert.equal(s2.status, 429);
  assert.equal((await s2.json()).bucket, "session");
});

// ---- /digest ----

test("/digest: runs the council with purpose digest when configured; template kept", async () => {
  const { fn, calls } = recorder(() => chat(finalJson("Synthetic digest synthesis.")));
  const post = handler(fn);
  const body = { personality_id: "calm_guide", findings: [{ text: "synthetic sleep observation", kind: "health" }] };
  const out = await (await post("/digest", body, META)).json();
  assert.match(out.text, /observation/);
  assert.match(out.council.synthesis, /^Synthetic digest synthesis/);
  assert.equal(out.council_code, null);
  assert.match(calls[0].body.messages[0].content, /morning digest/);
  const off = await (await post("/digest", { ...body, council: false }, META)).json();
  assert.ok(!("council" in off));
  assert.equal(calls.length, 1);
});

test("/digest: no brain config, council quota or crisis findings skip the council without failing", async () => {
  const post = handler(noNet);
  const body = { personality_id: "calm_guide", findings: [{ text: "synthetic" }] };
  assert.equal((await (await post("/digest", body, {})).json()).council_code, "council_not_configured");
  assert.equal((await (await post("/digest", body, { ...META, QUOTA_COUNCIL_PER_DAY: "0" })).json()).council_code, "council_quota");
  const crisis = await (await post("/digest", { ...body, findings: [{ text: "I want to die" }] }, META)).json();
  assert.equal(crisis.council_code, "council_crisis");
});

// ---- /analysis/21d ----

const DAY = 86_400_000;
const START = "2026-09-01";
const MOODS = [4, 4.5, 4, 3.5, 4, 4.5, 4, 3, 3, 3.5, 3, 2.5, 3, 3, 2, 2.5, 2, 1.5, 2, 2.5, 2];
const checkins = MOODS.map((mood, i) => ({ at: new Date(Date.parse(`${START}T12:00:00Z`) + i * DAY).toISOString(), mood }));
const signals = JSON.parse(readFileSync(new URL("../analysis/fixtures/steady_shift.json", import.meta.url))).series;

test("/analysis/21d: findings from plain code; the council sees only structured findings; numbers checked", async () => {
  const pre = computeAnalysis({ checkins, start: START, signals }, NOW);
  const mood = pre.structured.checkins.find((f) => f.signal === "mood");
  assert.ok(mood?.effect, "fixture has a mood effect");
  const good = `In these check-ins your mood ratings were about ${mood.effect.points} points lower lately; a tentative observation.`;
  let relayInput;
  const { fn } = recorder((body) => {
    relayInput = JSON.parse(body.messages[1].content);
    return chat(finalJson(good));
  });
  const out = await (await handler(fn)("/analysis/21d", { checkins, start: START, tz: "UTC", signals }, META)).json();
  assert.equal(out.comment_code, null);
  assert.ok(out.comment.startsWith(good));
  assert.ok(out.comment.includes(NOT_MEDICAL_ADVICE));
  assert.equal(out.findings.length, 3);
  assert.ok(out.hypotheses.length >= 1);
  assert.equal(out.vitals.findings[0].metric, "resting_hr");
  assert.equal(relayInput.purpose, "analysis");
  assert.deepEqual(relayInput.context.findings, pre.structured);
  const sent = JSON.stringify(relayInput);
  assert.ok(!sent.includes(START) && !sent.includes("2026-01-0"), "no dates or raw series reach the council");
});

test("/analysis/21d: a comment with a number not in the findings is dropped", async () => {
  const { fn } = recorder(() => chat(finalJson("Your mood dropped by 9.9 points.")));
  const out = await (await handler(fn)("/analysis/21d", { checkins, start: START }, META)).json();
  assert.equal(out.comment, null);
  assert.equal(out.comment_code, "comment_number_not_in_input");
  assert.ok(out.findings.length === 3);
});

test("/analysis/21d: not configured still returns findings; bad input is 400; crisis notes get the referral", async () => {
  const post = handler(noNet);
  const out = await (await post("/analysis/21d", { checkins, start: START }, {})).json();
  assert.equal(out.comment_code, "council_not_configured");
  assert.ok(out.hypotheses.length >= 1);
  assert.equal((await post("/analysis/21d", { checkins, start: "Sept 1" }, {})).status, 400);
  assert.equal((await post("/analysis/21d", { checkins, start: START, tz: "Mars/Base" }, {})).status, 400);
  assert.equal((await post("/analysis/21d", { checkins, start: START, signals: [] }, {})).status, 400);
  const crisis = await (await post("/analysis/21d", { checkins: [{ at: NOW, mood: 1, note: "I want to die" }], start: START }, META)).json();
  assert.deepEqual(crisis, { crisis: true, text: REFERRAL_TEXT });
  const empty = await (await post("/analysis/21d", { checkins: [], start: START }, META)).json();
  assert.equal(empty.comment_code, "nothing_to_comment");
});

// ---- /session/summary ----

test("/session/summary: short output through the council provider, gated, provider recorded", async () => {
  const { fn, calls } = recorder(() => chat('{"summary":"User planned an early night; tentative: tired after work.","topics":["sleep","work"]}'));
  const turns = [{ role: "user", text: "synthetic: I will go to bed early" }, { role: "assistant", text: "synthetic reply" }];
  const out = await (await handler(fn)("/session/summary", { turns }, META)).json();
  assert.deepEqual(out, { summary: "User planned an early night; tentative: tired after work.", topics: ["sleep", "work"], safety: "passed", provider: "meta" });
  assert.equal(calls[0].body.max_tokens, 1500); // Meta summary floor (META_TOKEN_FLOORS)
  assert.equal(calls[0].body.response_format.type, "json_object");
});

test("/session/summary: crisis, validation, gate and config", async () => {
  const post = handler(noNet);
  const crisis = await (await post("/session/summary", { turns: [{ role: "user", text: "I feel suicidal" }] }, META)).json();
  assert.equal(crisis.summary, CRISIS_SUMMARY);
  for (const turns of [undefined, [], [{ role: "system", text: "x" }], [{ role: "user", text: "x".repeat(4001) }], Array(81).fill({ role: "user", text: "x" })]) {
    assert.equal((await post("/session/summary", { turns }, META)).status, 400);
  }
  assert.equal((await post("/session/summary", { turns: [{ role: "user", text: "x" }] }, {})).status, 503);
  const { fn } = recorder(() => chat('{"summary":"You must see a doctor, this is a diagnosis.","topics":[]}'));
  const gated = await (await handler(fn)("/session/summary", { turns: [{ role: "user", text: "synthetic" }] }, META)).json();
  assert.equal(gated.summary, null);
  assert.equal(gated.safety, "replaced");
});
