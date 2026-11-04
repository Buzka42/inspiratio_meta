// Food calorie check in /log/parse (contract C6). The model call and Tavily are fakes; no network. Keys are
// generated per run and never printed. DATA_MODE=synthetic lets Tavily run (owner_real refuses it).
import { test } from "node:test";
import assert from "node:assert/strict";
import { runLogParse } from "../src/logs/parse.js";
import { foodCheck, foodQuery, kcalMatches } from "../src/logs/food-check.js";
import { LOG_SCHEMA } from "../src/logs/schemas.js";

const NB_KEY = `nebius-test-${crypto.randomUUID()}`;
const TV_KEY = `tvly-test-${crypto.randomUUID()}`;
const NOW = Date.parse("2026-10-28T09:00:00Z");
const ENV = { NEBIUS_API_KEY: NB_KEY, LOG_LLM_MODEL: "synthetic/log-model", TAVILY_API_KEY: TV_KEY, DATA_MODE: "synthetic" };
const noNet = () => { throw new Error("network touched"); };

// Fake model returning `output` as JSON.
// Fake model: a parse request gets `output`; an extraction request (kcal_per_100) gets the first calorie figure in the
// snippets, the way a careful model would, with its snippet index.
const callFn = (output) => async (messages) => {
  if (String(messages?.[0]?.content ?? "").includes("kcal_per_100")) {
    const { snippets } = JSON.parse(messages[1].content);
    for (const { index, text } of snippets) {
      const m = /(\d+(?:\.\d+)?)\s*(?:kcal|calories)/i.exec(text);
      if (m) return { content: JSON.stringify({ kcal_per_100: Number(m[1]), snippet: index }), tool_calls: [] };
    }
    return { content: JSON.stringify({ kcal_per_100: null, snippet: null }), tool_calls: [] };
  }
  return { content: JSON.stringify(output), tool_calls: [] };
};

// Fake Tavily: `hits(query)` gives the results for a query; every call is recorded.
function tavily({ hits = () => [], status = null, throws = false } = {}) {
  const queries = [];
  const fetchFn = async (url, init) => {
    if (url !== "https://api.tavily.com/search") throw new Error("unexpected host");
    if (throws) throw new TypeError("fetch failed");
    const q = JSON.parse(init.body).query;
    queries.push(q);
    if (status) return new Response("", { status });
    return new Response(JSON.stringify({ answer: "", results: hits(q) }), { status: 200, headers: { "content-type": "application/json" } });
  };
  return { fetchFn, queries };
}

const run = (body, output, { env = ENV, fetchFn = noNet, searchFn } = {}) =>
  runLogParse(body, env, { callFn: callFn(output), fetchFn, searchFn, now: () => NOW });

const EGGS_TEXT = "two eggs 140 kcal for breakfast";
const EGGS = { meal: "breakfast", items: [{ name: "eggs", quantity: 2, unit: "piece", kcal: 140 }] };
const EGG_HITS = (q) => (q === "eggs calories per piece" ? [{ title: "Egg facts", url: "https://food.example/egg", content: "One egg has 70 calories." }] : []);

test("a matching kcal passes with check status match and the source", async () => {
  const t = tavily({ hits: EGG_HITS });
  const out = await run({ kind: "food", text: EGGS_TEXT, date: "2026-10-27" }, EGGS, { fetchFn: t.fetchFn });
  assert.equal(out.status, 200);
  assert.equal(out.code, "food_checked");
  assert.equal(out.body.ok, true);
  assert.equal(out.body.schema, LOG_SCHEMA);
  assert.equal(out.body.date, "2026-10-27");
  assert.deepEqual(out.body.entry, { meal: "breakfast", items: [{ name: "eggs", quantity: 2, unit: "piece", kcal: 140 }] });
  assert.deepEqual(out.body.check, [{ item_index: 0, status: "match", source_url: "https://food.example/egg", source_title: "Egg facts" }]);
  assert.deepEqual(t.queries, ["eggs calories per piece"]);
});

test("a mismatch returns needs_choice with pending, and nothing has ok true", async () => {
  const t = tavily({ hits: EGG_HITS });
  const out = await run({ kind: "food", text: "two eggs 300 kcal for breakfast" }, { meal: "breakfast", items: [{ name: "eggs", quantity: 2, unit: "piece", kcal: 300 }] }, { fetchFn: t.fetchFn });
  assert.equal(out.status, 200);
  assert.equal(out.code, "food_needs_choice");
  assert.equal(out.body.ok, false);
  assert.equal(out.body.code, "needs_choice");
  assert.equal(out.body.pending.schema, LOG_SCHEMA);
  assert.equal(out.body.pending.kind, "food");
  assert.equal(out.body.pending.entry.items[0].kcal, 300);
  assert.deepEqual(out.body.needs_choice, [
    { item_index: 0, field: "kcal", user_value: 300, found_value: 140, source_url: "https://food.example/egg", source_title: "Egg facts" },
  ]);
  assert.ok(!JSON.stringify(out.body).includes('"ok":true'));
  assert.equal("check" in out.body, false);
});

test("no Tavily key gives an unchanged success with no check and no search", async () => {
  const t = tavily({ hits: EGG_HITS });
  const env = { NEBIUS_API_KEY: NB_KEY, LOG_LLM_MODEL: "synthetic/log-model", DATA_MODE: "synthetic" };
  const out = await run({ kind: "food", text: EGGS_TEXT }, EGGS, { env, fetchFn: t.fetchFn });
  assert.equal(out.code, null);
  assert.equal(out.body.ok, true);
  assert.equal("check" in out.body, false);
  assert.equal(t.queries.length, 0);
});

test("owner_real refuses Tavily, so the food check is skipped", async () => {
  const t = tavily({ hits: EGG_HITS });
  const env = { ...ENV, DATA_MODE: undefined };
  const out = await run({ kind: "food", text: EGGS_TEXT }, EGGS, { env, fetchFn: t.fetchFn });
  assert.equal(out.body.ok, true);
  assert.equal("check" in out.body, false);
  assert.equal(t.queries.length, 0);
});

test("a Tavily error gives an unverified success, not a rejection", async () => {
  for (const t of [tavily({ status: 500 }), tavily({ throws: true })]) {
    const out = await run({ kind: "food", text: EGGS_TEXT }, EGGS, { fetchFn: t.fetchFn });
    assert.equal(out.status, 200);
    assert.equal(out.body.ok, true);
    assert.equal(out.code, "food_unverified");
    assert.deepEqual(out.body.check, [{ item_index: 0, status: "unverified" }]);
  }
});

test("no result with a kcal figure is unverified", async () => {
  const t = tavily({ hits: () => [{ title: "t", url: "https://food.example/x", content: "No numbers here." }] });
  const out = await run({ kind: "food", text: EGGS_TEXT }, EGGS, { fetchFn: t.fetchFn });
  assert.deepEqual(out.body.check, [{ item_index: 0, status: "unverified" }]);
});

test("an item without kcal gets a labelled estimate; stated items are still checked", async () => {
  const output = { items: [{ name: "toast" }, { name: "eggs", quantity: 2, unit: "piece", kcal: 140 }] };
  const TOAST_HITS = (q) => (q === "toast calories per serving" ? [{ title: "Toast facts", url: "https://food.example/toast", content: "One slice of toast has 80 calories." }] : EGG_HITS(q));
  const t = tavily({ hits: TOAST_HITS });
  const out = await run({ kind: "food", text: "toast and two eggs 140 kcal" }, output, { fetchFn: t.fetchFn });
  assert.deepEqual(t.queries, ["toast calories per serving", "eggs calories per piece"]);
  assert.deepEqual(out.body.check.map((c) => c.item_index), [1]);
  const toast = out.body.entry.items[0];
  assert.equal(toast.kcal_estimated, true);
  assert.equal(typeof toast.kcal, "number");
  assert.equal(out.body.entry.items[1].kcal_estimated, undefined);
});

test("an estimate with no usable figure stays without calories", async () => {
  const output = { items: [{ name: "mystery stew" }] };
  const t = tavily({ hits: [] });
  const out = await run({ kind: "food", text: "a bowl of mystery stew" }, output, { fetchFn: t.fetchFn });
  assert.equal(out.body.entry.items[0].kcal, undefined);
  assert.equal(out.body.entry.items[0].kcal_estimated, undefined);
});

test("at most 3 searches are made", async () => {
  const names = ["apple", "pear", "plum", "fig", "kiwi"];
  const output = { items: names.map((name) => ({ name, kcal: 10 })) };
  const t = tavily({});
  const out = await run({ kind: "food", text: "five fruits, 10 kcal each" }, output, { fetchFn: t.fetchFn });
  assert.equal(t.queries.length, 3);
  assert.equal(out.body.check.length, 3);
  assert.deepEqual(t.queries, ["apple calories per serving", "pear calories per serving", "plum calories per serving"]);
});

test("found_value is scaled from the figure in the source text", async () => {
  const t = tavily({ hits: (q) => (q === "rice calories per 100 g" ? [{ title: "Rice", url: "https://food.example/rice", content: "Cooked rice: 130 kcal per 100 g." }] : []) });
  const out = await run(
    { kind: "food", text: "200 g rice 300 kcal" },
    { items: [{ name: "rice", quantity: 200, unit: "g", kcal: 300 }] },
    { fetchFn: t.fetchFn },
  );
  assert.equal(out.code, "food_needs_choice");
  assert.equal(out.body.needs_choice[0].found_value, Math.round(130 * (200 / 100)));
  assert.equal(out.body.needs_choice[0].found_value, 260);
});

test("results without a kcal figure are skipped for the first one that has one", async () => {
  const hits = (q) => [{ title: "Intro", url: "https://food.example/intro", content: "Eggs are good." }, ...EGG_HITS(q)];
  const t = tavily({ hits });
  const out = await run({ kind: "food", text: EGGS_TEXT }, EGGS, { fetchFn: t.fetchFn });
  assert.equal(out.body.check[0].source_title, "Egg facts");
});

test("the match tolerance is max(25, 15% of the found value)", () => {
  assert.equal(kcalMatches(140, 140), true);
  assert.equal(kcalMatches(165, 140), true); // 25 apart, floor 25
  assert.equal(kcalMatches(166, 140), false);
  assert.equal(kcalMatches(450, 400), true); // 50 apart, 15% of 400 is 60
  assert.equal(kcalMatches(470, 400), false); // 70 apart
});

test("queries: per 100 g or ml for a stated quantity, else per unit or serving", () => {
  assert.equal(foodQuery({ name: "rice", quantity: 200, unit: "g" }), "rice calories per 100 g");
  assert.equal(foodQuery({ name: "milk", quantity: 250, unit: "ml" }), "milk calories per 100 ml");
  assert.equal(foodQuery({ name: "eggs", quantity: 2, unit: "piece" }), "eggs calories per piece");
  assert.equal(foodQuery({ name: "toast" }), "toast calories per serving");
  assert.equal(foodQuery({ name: "rice", unit: "g" }), "rice calories per serving");
});

test("non-food kinds are unchanged and never searched", async () => {
  const t = tavily({ hits: EGG_HITS });
  const out = await run(
    { kind: "activity", text: "walk 30 min", date: "2026-10-27" },
    { type: "walk", duration: { min: 30 } },
    { fetchFn: t.fetchFn },
  );
  assert.equal(out.code, null);
  assert.deepEqual(out.body, { ok: true, schema: LOG_SCHEMA, kind: "activity", date: "2026-10-27", source: "typed", entry: { type: "walk", duration_s: 1800 } });
  assert.equal(t.queries.length, 0);
});

// Live check 2026-10-29: a per-cup figure (205 kcal in 1 cup, 158 g) must not be scaled to 200 g (it gave 410).
test("food check: a gram item ignores a per-cup figure and is unverified rather than wrong", async () => {
  const entry = { items: [{ name: "cooked white rice", quantity: 200, unit: "g", kcal: 260 }] };
  const search = async () => ({ answer: "", results: [{ title: "Rice", url: "https://example.test/rice", content: "White rice, cooked: 205 calories in 1 cup (158 g)." }] });
  const out = await foodCheck(entry, search);
  assert.equal(out[0].status, "unverified");
});

test("food check: a gram item uses a per-100 g figure and scales it", async () => {
  const entry = { items: [{ name: "chicken breast", quantity: 150, unit: "g", kcal: 250 }] };
  const search = async () => ({ answer: "", results: [{ title: "Chicken", url: "https://example.test/c", content: "Chicken breast, per 100 g: 165 calories." }] });
  const out = await foodCheck(entry, search);
  assert.equal(out[0].status, "match");
});

test("food check: the kcal figure must be near the per-100 g basis, not a per-cup figure in the same snippet", async () => {
  const entry = { items: [{ name: "cooked white rice", quantity: 200, unit: "g", kcal: 260 }] };
  const content = "White rice, cooked Calories: 205 in 1 cup (158 g). Nutrition per 100 g: 130 calories.";
  const out = await foodCheck(entry, async () => ({ answer: "", results: [{ title: "Rice", url: "https://example.test/r", content }] }));
  assert.equal(out[0].status, "match");
});

// Live check 2026-10-30: a per-banana figure next to a "100 g" mention must not be used as a per-100 g figure.
test("food check: a per-banana or per-piece figure is not a per-100 g figure, even with 100 g nearby", async () => {
  const entry = { items: [{ name: "banana", quantity: 120, unit: "g", kcal: 400 }] };
  const content = "A medium banana has 66 kcal. The fruit itself is 89 calories per 100 g of edible flesh.";
  const out = await foodCheck(entry, async () => ({ answer: "", results: [{ title: "Banana", url: "https://example.test/b", content }] }));
  assert.equal(out[0].status, "mismatch");
  assert.equal(out[0].found_value, 107);
});

// Model extraction (2026-10-30): the number must really appear in the snippet the model names.
test("model extraction: a figure that is not in the named snippet is rejected (unverified)", async () => {
  const { extractPer100 } = await import("../src/logs/food-check.js");
  const item = { name: "banana", quantity: 120, unit: "g" };
  const liar = async () => ({ content: JSON.stringify({ kcal_per_100: 89, snippet: 0 }) });
  const hit = await extractPer100(item, [{ title: "B", url: "https://e.test/b", content: "A medium banana has 66 kcal." }], liar);
  assert.equal(hit, null);
  const good = async () => ({ content: JSON.stringify({ kcal_per_100: 89, snippet: 0 }) });
  const ok = await extractPer100(item, [{ title: "B", url: "https://e.test/b", content: "Banana: 89 kcal per 100 g." }], good);
  assert.equal(ok.value, 107);
});
