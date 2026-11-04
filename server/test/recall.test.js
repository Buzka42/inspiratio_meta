import { test } from "node:test";
import assert from "node:assert/strict";
import { InMemoryStore, ZepStore, tokenize } from "../src/memory.js";

// Synthetic fixtures only.
const NOW = Date.parse("2026-10-23T08:00:00Z");
const mem = (id, text, expires_at = null) =>
  ({ id, text, kind: "fact", source: "test", confidence: 0.5, created_at: "2026-10-20T00:00:00Z", expires_at });

async function storeWith(...items) {
  const store = new InMemoryStore();
  for (const m of items) await store.write(m);
  return store;
}
const ids = (items) => items.map((m) => m.id);

test("recall: a full sentence recalls the memory sharing content words", async () => {
  const store = await storeWith(mem("sleep", "Sleep is shorter on weekdays"), mem("lift", "Squat felt heavy last week"));
  const out = await store.recall({ query: "Why do I feel so tired after my weekday sleep?", now: NOW });
  assert.deepEqual(ids(out), ["sleep"]);
});

test("recall: stopword-only overlap returns nothing", async () => {
  const store = await storeWith(mem("a", "The walk is in the park"));
  assert.deepEqual(await store.recall({ query: "what is the plan for it", now: NOW }), []);
  assert.deepEqual(await store.recall({ query: "the and of", now: NOW }), []);
});

test("recall: better match ranks first, zero overlap dropped", async () => {
  const store = await storeWith(
    mem("one", "evening walk helps"),
    mem("none", "protein at breakfast"),
    mem("two", "evening walk improves sleep"),
  );
  const out = await store.recall({ query: "does an evening walk improve my sleep", now: NOW });
  assert.deepEqual(ids(out), ["two", "one"]);
});

test("recall: expired items never return", async () => {
  const store = await storeWith(mem("old", "sleep debt high", "2026-10-22T00:00:00Z"), mem("ok", "sleep steady"));
  const out = await store.recall({ query: "how is my sleep", now: NOW });
  assert.deepEqual(ids(out), ["ok"]);
  assert.deepEqual(ids(await store.recall({ now: NOW })), ["ok"]);
});

test("recall: limit respected", async () => {
  const items = Array.from({ length: 8 }, (_, i) => mem(`s${i}`, `sleep note ${i}`));
  const store = await storeWith(...items);
  assert.equal((await store.recall({ query: "my sleep last night", limit: 3, now: NOW })).length, 3);
});

test("recall: Polish diacritics stay inside one token", async () => {
  assert.deepEqual(tokenize("Wartość snu, źródło: łóżko!"), ["wartość", "snu", "źródło", "łóżko"]);
  assert.deepEqual(tokenize("Jak się czuję, gdy nie śpię?"), ["czuję", "śpię"]);
  const store = await storeWith(mem("pl", "Wartość snu spada w tygodniu"), mem("en", "value of rest"));
  const out = await store.recall({ query: "Jaka jest wartość mojego snu?", now: NOW });
  assert.deepEqual(ids(out), ["pl"]);
});

test("recall: Zep stub still refuses when not configured", async () => {
  await assert.rejects(new ZepStore({}).recall({ query: "sleep" }), /not configured/);
});
