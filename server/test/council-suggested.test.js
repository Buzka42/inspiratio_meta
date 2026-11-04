// council_suggested (contract C5): the server copy of the client's council trigger, on /reply and /reply/stream.
// Synthetic only: fake fetch, invented text, no live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { councilSuggested, councilTrigger, normaliseSpoken } from "../src/council-trigger.js";
import { createHandler } from "../src/index.js";
import { issueToken } from "../src/auth.js";
import { InMemoryStore } from "../src/memory.js";
import { InMemoryQuotaStore } from "../src/quota.js";
import { runReply } from "../src/reply.js";
import { runReplyStream } from "../src/reply-stream.js";

// Shared with client/test/voice/council_trigger_parity_test.dart (P4). Keep both tables identical.
const PARITY = [
  ["why do I keep waking up at 3am every night", "offer"],
  ["what should I eat before a long run", "offer"],
  ["is it normal to feel tired after lunch", "offer"],
  ["ask the council about my sleep", "explicit"],
  ["I slept badly", "none"],
  ["hello there", "none"],
  ["tell me a story about the sea please", "none"],
];

const SECRET = `${crypto.randomUUID()}${crypto.randomUUID()}`;
const ENV = { DEVICE_TOKEN_SECRET: SECRET, REPLY_LLM_BASE_URL: "http://llm.selfhosted.test:8000/v1", REPLY_LLM_MODEL: "local-model" };
const PLAN = { crisis: false, personality_id: "calm_guide", skill_id: null, escalate: false };
const BIG = PARITY[0][0];
const json = (content) => new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
const always = (content) => async () => json(content);

test("C5 parity cases", () => {
  for (const [text, expected] of PARITY) assert.equal(councilTrigger(text), expected, text);
});

test("trigger: normaliser and edge cases follow the Dart rule", () => {
  assert.equal(normaliseSpoken("  Why DON'T I sleep?! "), "why dont i sleep");
  assert.equal(normaliseSpoken("It’s `fine`"), "its fine");
  assert.equal(councilTrigger(""), "none");
  assert.equal(councilTrigger(null), "none");
  assert.equal(councilTrigger("why sleep so bad"), "none", "under 5 words");
  assert.equal(councilTrigger("why is my sleep so bad"), "offer");
  assert.equal(councilTrigger("can you run this by the experts"), "explicit");
  assert.equal(councilTrigger("please consult my council"), "explicit");
  assert.equal(councilTrigger("what should I do about the garden fence"), "none", "depth without a topic");
  assert.equal(councilSuggested(BIG, "passed"), true);
  assert.equal(councilSuggested(BIG, "repaired"), true);
  assert.equal(councilSuggested(BIG, "replaced"), false);
  assert.equal(councilSuggested("ask the council about my sleep", "passed"), false, "explicit asks are not offers");
});

test("/reply: a big question sets council_suggested; an ordinary line does not", async () => {
  const h = createHandler({ fetchFn: always("Synthetic: a calm evening routine may help."), store: new InMemoryStore(), quotaStore: new InMemoryQuotaStore(), logger: { warn() {}, error() {}, log() {} } });
  const post = (transcript) =>
    h(new Request("https://x.test/reply", {
      method: "POST",
      headers: { Authorization: `Bearer ${issueToken("device-cs", SECRET)}` },
      body: JSON.stringify({ plan: PLAN, transcript }),
    }), ENV);
  for (const [text, expected] of PARITY) {
    const body = await (await post(text)).json();
    assert.equal(body.council_suggested, expected === "offer", text);
    assert.equal(body.safety, "passed");
  }
});

test("/reply: council_suggested is false on crisis and replaced replies, true on repaired", async () => {
  const crisis = await runReply({ plan: PLAN, transcript: "why do I keep feeling suicidal every night", env: ENV, fetchFn: always("unused") });
  assert.equal(crisis.body.council_suggested, false);
  const replaced = await runReply({ plan: PLAN, transcript: BIG, env: ENV, fetchFn: always("You must sleep earlier.") });
  assert.equal(replaced.body.safety, "replaced");
  assert.equal(replaced.body.council_suggested, false);
  let n = 0;
  const repairedFetch = async () => json(n++ === 0 ? "You must sleep earlier." : "Synthetic: an earlier night may help.");
  const repaired = await runReply({ plan: PLAN, transcript: BIG, env: ENV, fetchFn: repairedFetch });
  assert.equal(repaired.body.safety, "repaired");
  assert.equal(repaired.body.council_suggested, true);
});

test("/reply/stream: council_suggested rides on the done event", async () => {
  const enc = new TextEncoder();
  const fetchFn = async () =>
    new Response(new ReadableStream({
      start(c) {
        const text = "Synthetic-a Waking at night is common after stress. Synthetic-b A calm evening may help.";
        c.enqueue(enc.encode(`data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\ndata: [DONE]\n\n`));
        c.close();
      },
    }), { status: 200 });
  const doneOf = async (transcript) => {
    const out = await runReplyStream({ plan: PLAN, transcript, env: ENV, fetchFn });
    const blocks = (await new Response(out.stream).text()).split("\n\n").filter(Boolean);
    return JSON.parse(blocks.at(-1).split("\n")[1].slice(6));
  };
  assert.equal((await doneOf(BIG)).council_suggested, true);
  assert.equal((await doneOf("hello there my friend how are you")).council_suggested, false);
  assert.equal((await doneOf("synthetic: I want to die")).council_suggested, false);
});
