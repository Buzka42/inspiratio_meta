import { test } from "node:test";
import assert from "node:assert/strict";
import { REFERRAL_TEXT, NOT_MEDICAL_ADVICE } from "../src/safety.js";
import {
  NOT_IN_DOCS, answer, noteAdd, noteList, noteDelete, resumeGet, resumeSet,
  openQuestionAdd, openQuestionList, readingStore,
} from "../src/skills/reading.js";

const PASSAGE = "The lighthouse keeper rowed out every evening to light the lamp before the storm arrived.";
const spec = (over = {}) => ({
  skills: { reading: true }, memory: { mode: "phone", retention_days: 30 }, data: { hosted_personal: "approved" }, ...over,
});

function memStorage() {
  const m = new Map();
  return { get: async (k) => structuredClone(m.get(k)), put: async (k, v) => void m.set(k, structuredClone(v)), m };
}

function fakeBrain(reply) {
  const calls = [];
  const fn = async (messages, env, opts) => {
    calls.push({ messages, opts });
    if (reply instanceof Error) throw reply;
    return { content: typeof reply === "string" ? reply : JSON.stringify(reply) };
  };
  return Object.assign(fn, { calls });
}

const fakeRetrieve = (passages, code = null) => async () => ({ passages, code });
const hit = (over = {}) => ({ source_id: "src_a", title: "Keeper", text: PASSAGE, score: 0.8, part: 2, ...over });

function deps(brainReply, { passages = [hit()], s = spec(), storage = memStorage() } = {}) {
  const brain = fakeBrain(brainReply);
  return { spec: s, env: {}, brain, retrieve: fakeRetrieve(passages), sources: ["src_a"], store: readingStore(storage, s), storage };
}

test("crisis question returns the referral with zero brain calls", async () => {
  const d = deps({ answer: "x", cites: [] });
  const r = await answer("I want to die tonight", d);
  assert.equal(r.text, REFERRAL_TEXT);
  assert.equal(d.brain.calls.length, 0);
});

test("valid cite passes; a made-up cite id is dropped", async () => {
  const d = deps({
    answer: "He rowed out each evening.",
    cites: [{ id: "p1", quote: "rowed out every evening" }, { id: "p9", quote: "rowed out every evening" }],
    note: { id: "p1", text: "Routine matters.", quote: "light the lamp" },
    question: "Why did he go before the storm?",
  });
  const r = await answer("When did the keeper go out?", d);
  assert.equal(r.code, null);
  assert.equal(r.text, "He rowed out each evening.");
  assert.deepEqual(r.cites.map((c) => [c.id, c.source_id, c.part]), [["p1", "src_a", 2]]);
  assert.equal(d.brain.calls.length, 1);
  assert.equal(d.brain.calls[0].opts.json, true);
  assert.equal(r.note.text, "Routine matters.");
  assert.equal((await resumeGet(d)).position.part, 2);
  assert.equal((await openQuestionList(d)).questions.length, 1);
});

test("only made-up cites, or a claim with no quote, is refused", async () => {
  for (const cites of [[{ id: "p7", quote: "rowed out every evening" }], [{ id: "p1" }], []]) {
    const r = await answer("When?", deps({ answer: "He went at dawn.", cites }));
    assert.equal(r.text, NOT_IN_DOCS);
    assert.deepEqual(r.cites, []);
  }
});

test("a quote that is not word for word is refused", async () => {
  const r = await answer("When?", deps({ answer: "Evening.", cites: [{ id: "p1", quote: "rowed out each evening" }] }));
  assert.equal(r.text, NOT_IN_DOCS);
});

test("no passage above the floor, or none from the user's sources: fixed text, zero brain calls", async () => {
  for (const passages of [[], [hit({ score: 0.2 })], [hit({ source_id: "src_other" })]]) {
    const d = deps({ answer: "x", cites: [] }, { passages });
    const r = await answer("What about whales?", d);
    assert.equal(r.text, NOT_IN_DOCS);
    assert.equal(d.brain.calls.length, 0);
  }
});

test("hosted_ask unless hosted_personal is approved", async () => {
  const d = deps({ answer: "x", cites: [] }, { s: spec({ data: { hosted_personal: "ask" } }) });
  assert.deepEqual(await answer("When?", d), { code: "hosted_ask" });
  assert.equal(d.brain.calls.length, 0);
});

test("brain and retrieval errors become fixed codes", async () => {
  const r = await answer("When?", deps(new Error("secret upstream text")));
  assert.deepEqual(r, { code: "brain_failed" });
  const d = deps({});
  d.retrieve = fakeRetrieve([], "knowledge_not_bound");
  assert.deepEqual(await answer("When?", d), { code: "retrieve_failed" });
  d.retrieve = async () => { throw new Error("boom"); };
  assert.deepEqual(await answer("When?", d), { code: "retrieve_failed" });
});

test("health words get the health line; gate failures get the fallback", async () => {
  const r = await answer("Does sleep help?", deps({ answer: "He slept after.", cites: [{ id: "p1", quote: "light the lamp" }] }));
  assert.ok(r.text.endsWith(NOT_MEDICAL_ADVICE));
  const g = await answer("When?", deps({ answer: "You must row.", cites: [{ id: "p1", quote: "light the lamp" }] }));
  assert.notEqual(g.text, "You must row.");
});

test("memory_off refuses notes, resume and open questions and writes nothing", async () => {
  const d = deps({}, { s: spec({ memory: { mode: "off", retention_days: 30 } }) });
  const note = { source_id: "src_a", part: 1, quote: "light the lamp", text: "nice" };
  for (const r of [
    await noteAdd(note, d), await noteList(d), await noteDelete("rn_x", d),
    await resumeGet(d), await resumeSet({ source_id: "src_a", part: 1 }, d),
    await openQuestionAdd({ source_id: "src_a", part: 1, text: "why?" }, d), await openQuestionList(d),
  ]) assert.deepEqual(r, { code: "memory_off" });
  assert.equal(d.storage.m.size, 0);
});

test("note add, list, delete and limits", async () => {
  const d = deps({});
  const { note } = await noteAdd({ source_id: "src_a", part: 3, quote: "light the lamp", text: "A good line." }, d);
  assert.match(note.id, /^rn_[0-9a-f]{16}$/);
  assert.equal((await noteList(d)).notes.length, 1);
  assert.equal((await noteDelete(note.id, d)).deleted, true);
  assert.equal((await noteList(d)).notes.length, 0);
  assert.equal((await noteAdd({ source_id: "src_a", part: 3, quote: "q".repeat(201), text: "x" }, d)).code, "bad_note");
  assert.equal((await noteAdd({ source_id: "src_a", part: 3, quote: "q", text: "x".repeat(501) }, d)).code, "bad_note");
});

test("resume round trip keeps the latest position", async () => {
  let t = 1_000_000;
  const s = spec();
  const d = { spec: s, store: readingStore(memStorage(), s, { now: () => t }) };
  assert.equal((await resumeGet(d)).position, null);
  await resumeSet({ source_id: "src_a", part: 1 }, d);
  t += 10;
  await resumeSet({ source_id: "src_b", part: 4 }, d);
  assert.deepEqual((await resumeGet(d)).position, { source_id: "src_b", part: 4, updated_at: t });
  assert.equal((await resumeSet({ source_id: "src_b", part: -1 }, d)).code, "bad_position");
});

test("records older than retention_days are pruned on access", async () => {
  let t = 0;
  const s = spec({ memory: { mode: "phone", retention_days: 1 } });
  const d = { spec: s, store: readingStore(memStorage(), s, { now: () => t }) };
  await noteAdd({ source_id: "src_a", part: 0, quote: "light the lamp", text: "n" }, d);
  t = 2 * 86_400_000;
  assert.equal((await noteList(d)).notes.length, 0);
});
