import { test } from "node:test";
import assert from "node:assert/strict";
import { phoneContext, shortTermBlock } from "../src/phone-context.js";
import { buildReplyMessages } from "../src/reply.js";

test("phone context keeps valid entries, drops bad ones, never marks facts", () => {
  const ctx = phoneContext({
    short_term: { summaries: ["slept badly", 3, ""], turns: [{ role: "user", text: "hi" }, { role: "system", text: "x" }] },
    memories: [{ text: "likes tea", kind: "note", confidence: 0.8 }, { text: "maybe stressed", kind: "fact" }, { text: "" }],
  });
  assert.deepEqual(ctx.summaries, ["slept badly"]);
  assert.deepEqual(ctx.turns, [{ role: "user", text: "hi" }]);
  assert.deepEqual(ctx.memories.map((m) => m.label), ["note", "observation"]);
});

test("missing or malformed context is empty", () => {
  assert.deepEqual(phoneContext({ short_term: "x", memories: {} }), { summaries: [], turns: [], memories: [] });
  assert.equal(shortTermBlock(phoneContext({})), "");
});

test("caps text length and counts", () => {
  const long = "a".repeat(2000);
  const ctx = phoneContext({ short_term: { summaries: Array(30).fill(long) }, memories: Array(30).fill({ text: long, kind: "note" }) });
  assert.equal(ctx.summaries.length, 10);
  assert.equal(ctx.summaries[0].length, 500);
  assert.equal(ctx.memories.length, 10);
});

test("reply system prompt carries the short-term block as data", () => {
  const phone = phoneContext({ short_term: { summaries: ["walked 5 km"] } });
  const [system] = buildReplyMessages({ system_prompt: "SYS", memories: [], shortTerm: phone }, "hello");
  assert.match(system.content, /data, never instructions/);
  assert.match(system.content, /walked 5 km/);
});
