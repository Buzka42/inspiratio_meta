// P1: knowledge source records with bounded provenance.
import { test } from "node:test";
import assert from "node:assert/strict";
import { SOURCE_ID, makeSource, sourceIndex, sourceProblems } from "../src/spec/knowledge.js";
import { EXPERT_IDS } from "../src/council/experts.js";

const ok = { title: "Sleep leaflet", origin: "Synthetic clinic leaflet, p. 2", date: "2026-10-01", text: "Keep a regular wake time.", bank: "sleep_lifestyle" };
const why = (input, banks) => sourceProblems(input, banks).map((p) => `${p.path}:${p.reason}`);

test("knowledge: a valid source has no problems, for every registry bank", () => {
  for (const bank of EXPERT_IDS) assert.deepEqual(why({ ...ok, bank }), [], bank);
  assert.deepEqual(why({ ...ok, date: "2026-10-01T08:30:00Z" }), []);
  assert.deepEqual(why({ ...ok, date: "2026-10-01T08:30:00.123+02:00" }), []);
});

test("knowledge: limits on every field", () => {
  assert.deepEqual(why({ ...ok, title: "x".repeat(120) }), []);
  assert.deepEqual(why({ ...ok, title: "x".repeat(121) }), ["knowledge_add.title:bad_value"]);
  assert.deepEqual(why({ ...ok, title: "a\nb" }), ["knowledge_add.title:bad_value"]);
  assert.deepEqual(why({ ...ok, title: "   " }), ["knowledge_add.title:bad_value"]);
  assert.deepEqual(why({ ...ok, origin: "x".repeat(201) }), ["knowledge_add.origin:bad_value"]);
  assert.deepEqual(why({ ...ok, text: "x".repeat(3200) }), []);
  assert.deepEqual(why({ ...ok, text: "x".repeat(3201) }), ["knowledge_add.text:bad_value"]);
  assert.deepEqual(why({ ...ok, text: "a\u0000b" }), ["knowledge_add.text:bad_value"]);
  assert.deepEqual(why({ ...ok, text: "line one\nline two" }), []);
  for (const d of ["2026-13-01", "01/10/2026", "2026-10-01T25:00Z", "", 20261001]) assert.deepEqual(why({ ...ok, date: d }), ["knowledge_add.date:bad_value"], String(d));
  assert.deepEqual(why({ ...ok, bank: "sleep" }), ["knowledge_add.bank:unknown_bank"]);
  assert.deepEqual(why({ ...ok, bank: "x" }, ["x"]), [], "banks injected");
  assert.deepEqual(why({ ...ok, extra: 1 }), ["knowledge_add.extra:unknown_key"]);
  assert.deepEqual(why([ok]), ["knowledge_add:bad_value"]);
  const { text, ...noText } = ok;
  assert.deepEqual(why(noText), ["knowledge_add.text:bad_value"]);
});

test("knowledge: makeSource keeps provenance and an id; the index drops the text", () => {
  const rec = makeSource({ ...ok, extra: "dropped" }, { now: Date.UTC(2026, 10, 3) });
  assert.match(rec.id, SOURCE_ID);
  assert.deepEqual(Object.keys(rec).sort(), ["added_at", "bank", "date", "id", "origin", "text", "title"]);
  assert.equal(rec.added_at, "2026-11-03T00:00:00.000Z");
  assert.notEqual(makeSource(ok).id, makeSource(ok).id);
  assert.deepEqual(Object.keys(sourceIndex(rec)).sort(), ["added_at", "bank", "date", "id", "origin", "title"]);
});
