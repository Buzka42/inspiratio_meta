// A reply written twice (live run 2026-10-30, coach): /reply and /reply/stream keep one copy. Fake fetch only,
// synthetic text, per-run key.
import { test } from "node:test";
import assert from "node:assert/strict";
import { cutRepeat, dropRepeatedReply, openingSentence, runReply } from "../src/reply.js";
import { runReplyStream } from "../src/reply-stream.js";
import { NEBIUS_PROVIDER } from "../src/nebius.js";
import { NOT_MEDICAL_ADVICE } from "../src/safety.js";

const ENV = { REPLY_PROVIDER: NEBIUS_PROVIDER, NEBIUS_API_KEY: `nebius-test-${crypto.randomUUID()}`, REPLY_LLM_MODEL: "synthetic/chat-model-test" };
const PLAN = { personality_id: "personal_coach", skill_id: "weight_training" };
const TRANSCRIPT = "synthetic-transcript-5b1e should I stretch before or after a workout";
const COPY =
  "Do dynamic stretches for five to ten minutes before you train. Hold static stretches afterwards. " +
  "Try one leg swing before your next session.";

const ok = (content) => async () => new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
const enc = new TextEncoder();
const chunk = (content) => `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`;
const streamed = (text) => async () =>
  new Response(new ReadableStream({
    start(c) {
      for (const p of text.match(/.{1,7}/gs)) c.enqueue(enc.encode(chunk(p)));
      c.enqueue(enc.encode("data: [DONE]\n\n"));
      c.close();
    },
  }), { status: 200, headers: { "Content-Type": "text/event-stream" } });
const events = async (out) =>
  (await new Response(out.stream).text()).split("\n\n").filter(Boolean).map((b) => {
    const [ev, data] = b.split("\n");
    return { event: ev.replace(/^event: /, ""), data: JSON.parse(data.replace(/^data: /, "")) };
  });

test("cutRepeat: cuts where the opening sentence comes back, with or without a space", () => {
  assert.equal(openingSentence(COPY), "Do dynamic stretches for five to ten minutes before you train.");
  assert.equal(dropRepeatedReply(`${COPY} ${COPY}`), COPY);
  assert.equal(dropRepeatedReply(`${COPY}${COPY}`), COPY);
  assert.equal(dropRepeatedReply(COPY), COPY, "a single copy is unchanged");
  assert.equal(cutRepeat("Short one. Short one.", "Short one."), "Short one. Short one.", "openings under 20 characters are left alone");
  assert.equal(dropRepeatedReply("No ending punctuation at all"), "No ending punctuation at all");
});

test("/reply: a reply written twice, the second copy after the marker, keeps one copy and the health line", async () => {
  const out = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: ok(`${COPY}[[HEALTH]]${COPY}`) });
  assert.equal(out.status, 200);
  assert.equal(out.body.text, `${COPY} ${NOT_MEDICAL_ADVICE}`);
  assert.equal(out.body.health, true);
  const plain = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: ok(`${COPY}${COPY}`) });
  assert.equal(plain.body.text, COPY);
  assert.equal(plain.body.health, false);
});

test("/reply/stream: once the opening sentence comes back, the rest is not sent", async () => {
  for (const text of [`${COPY}${COPY}`, `${COPY} [[HEALTH]]${COPY}`, `${COPY} ${COPY}`]) {
    const out = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: streamed(text) });
    const evs = await events(out);
    const sentences = evs.filter((e) => e.event === "sentence").map((e) => e.data.text);
    const done = evs.find((e) => e.event === "done").data;
    const spoken = [...sentences, done.text.replace(` ${NOT_MEDICAL_ADVICE}`, "")].join(" ");
    assert.equal(spoken, COPY, text);
    assert.equal(done.safety, "passed");
  }
});
