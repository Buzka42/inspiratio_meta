// Gate repair (contract C4): one repair call on a non-crisis gate failure, in /reply, /reply/stream and the
// council synthesis. Synthetic only: fake fetch or fake brain, invented text, no live call.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  GATE_RULES, GATE_RULE_PROMPT, NOT_MEDICAL_ADVICE, REFERRAL_TEXT, SAFE_FALLBACK_TEXT, gateText, gateViolation, passesGate,
  repairInstruction,
} from "../src/safety.js";
import { runReply } from "../src/reply.js";
import { STREAM_REPAIR_TAIL, runReplyStream } from "../src/reply-stream.js";
import { LIMITS, relaySystem, runCouncilV2 } from "../src/council/relay.js";
import { EXPERTS } from "../src/council/experts.js";
import { buildSystemPrompt } from "../src/turn.js";
import { getPersonality } from "../src/content.js";

const ENV = { REPLY_LLM_BASE_URL: "http://llm.selfhosted.test:8000/v1", REPLY_LLM_MODEL: "local-model" };
const PLAN = { crisis: false, personality_id: "calm_guide", skill_id: null, escalate: false };
const TRANSCRIPT = "synthetic-transcript-61aa plan my day around three meetings";
const GOOD = "synthetic-reply-good Start with the first meeting and keep a short gap.";
const BAD = "synthetic-reply-bad You must start with the first meeting.";

const json = (content) => new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 });
// Answers call i with replies[i] (a string, or a function returning a Response).
function seq(...replies) {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, body });
    const r = replies[Math.min(calls.length - 1, replies.length - 1)];
    return typeof r === "function" ? r(body) : json(r);
  };
  return { fn, calls };
}

// ---- safety.js ----

test("gate: rules, violation ids, prompt and fallback text are fixed", () => {
  assert.deepEqual(GATE_RULES.map((r) => r.id), ["directive", "diagnosis", "condition_claim", "prescription"]);
  assert.equal(gateViolation("Consider a short walk."), null);
  assert.equal(gateViolation("You must rest."), "directive");
  assert.equal(gateViolation("That sounds like a diagnosis."), "diagnosis");
  assert.equal(gateViolation("You have depression."), "condition_claim");
  assert.equal(gateViolation("I would prescribe rest."), "prescription");
  assert.equal(gateViolation("You must rest, I feel suicidal."), "crisis", "crisis wins over any rule");
  assert.equal(
    GATE_RULE_PROMPT,
    "Never write 'you must'. Never use the words diagnose, diagnosis, diagnosed, prescribe or prescription. " +
      "Never tell the user they have a condition or illness.",
  );
  assert.equal(SAFE_FALLBACK_TEXT, "Illunis cannot answer that safely here. For a personal answer, please talk to a clinician.");
  assert.equal(gateViolation(SAFE_FALLBACK_TEXT), null);
  assert.equal(gateViolation(GATE_RULE_PROMPT) !== null, true, "the prompt itself names the words; it is never output");
});

test("gate: rules apply to the claim, not the word; crisis is never relaxed", () => {
  const pass = [
    "This is not a diagnosis, only an observation.",
    "I cannot diagnose this, but rest may help.",
    "I can't diagnose anything from a check-in.",
    "I am not able to prescribe anything.",
    "I'm unable to diagnose that here.",
    "A doctor can diagnose this properly.",
    "Your GP may prescribe something if it is needed.",
    "Only a clinician could help diagnose the cause.",
    "This does not mean you have an illness.",
    "I am not saying you have depression.",
  ];
  for (const t of pass) assert.equal(gateViolation(t), null, t);
  const fail = [
    ["I diagnose insomnia.", "diagnosis"],
    ["You have been diagnosed with stress.", "diagnosis"],
    ["I can prescribe rest.", "prescription"],
    ["This does not help, you have depression.", "condition_claim"],
    ["You must not skip meals.", "directive"],
    ["I cannot diagnose this, but you feel suicidal.", "crisis"],
    ["A doctor can diagnose it. I want to die.", "crisis"],
  ];
  for (const [t, id] of fail) assert.equal(gateViolation(t), id, t);
});

test("gate: repairInstruction names the broken rule and carries no user text", () => {
  for (const r of GATE_RULES) {
    const text = repairInstruction(r.id);
    assert.ok(text.includes(r.rule), r.id);
    assert.ok(text.startsWith(`Your reply broke the ${r.id} rule: `), r.id);
    assert.ok(text.includes(GATE_RULE_PROMPT));
  }
  assert.match(repairInstruction("unknown"), /broke a safety rule/);
});

test("gate: template paths keep the plain pass/replace gate", () => {
  assert.equal(gateText("Consider a walk."), "Consider a walk.");
  for (const bad of ["You must rest", "that is a diagnosis", "I feel suicidal"]) {
    assert.equal(passesGate(bad), false);
    assert.equal(gateText(bad), REFERRAL_TEXT);
  }
});

test("gate: the rule prompt is in every base prompt (relay, expert, reply)", () => {
  assert.ok(relaySystem("chat").includes(GATE_RULE_PROMPT));
  for (const e of EXPERTS) assert.ok(e.systemPrompt.includes(GATE_RULE_PROMPT), e.id);
  assert.ok(buildSystemPrompt(getPersonality("calm_guide"), null).includes(GATE_RULE_PROMPT));
});

// ---- /reply ----

test("reply: 'you must' gets one repair call and returns safety repaired", async () => {
  const f = seq(BAD, GOOD);
  const out = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: f.fn });
  assert.equal(out.status, 200);
  assert.deepEqual(out.body, { text: GOOD, personality_id: "calm_guide", safety: "repaired", health: false, council_suggested: false });
  assert.equal(out.code, "reply_repaired");
  assert.equal(f.calls.length, 2);
  const repair = f.calls[1].body.messages;
  assert.deepEqual(repair.at(-2), { role: "assistant", content: BAD });
  assert.equal(repair.at(-1).role, "user");
  assert.equal(repair.at(-1).content, repairInstruction("directive"));
  assert.ok(!repair.at(-1).content.includes(TRANSCRIPT), "the instruction carries no user text");
});

test("reply: a second failure returns the safe fallback, replaced", async () => {
  const f = seq(BAD, "synthetic: I diagnose a busy week.");
  const out = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: f.fn });
  assert.equal(out.body.text, SAFE_FALLBACK_TEXT);
  assert.equal(out.body.health, false, "health comes from the model's marker, not the fixed fallback");
  // A sleep transcript alone adds no line; a reply the model marked keeps the line after the gate.
  const plain = await runReply({ plan: PLAN, transcript: "synthetic: I slept badly", env: ENV, fetchFn: seq(BAD, BAD).fn });
  assert.equal(plain.body.text, SAFE_FALLBACK_TEXT);
  const h = await runReply({ plan: PLAN, transcript: "synthetic: I slept badly", env: ENV, fetchFn: seq(`[[HEALTH]] ${BAD}`, BAD).fn });
  assert.equal(h.body.text, `${SAFE_FALLBACK_TEXT} ${NOT_MEDICAL_ADVICE}`);
  assert.equal(h.body.health, true);
  assert.equal(out.body.safety, "replaced");
  assert.equal(out.body.council_suggested, false);
  assert.equal(out.code, "reply_replaced");
  assert.equal(f.calls.length, 2, "never more than one repair call");
});

test("reply: a repair call that errors returns the safe fallback", async () => {
  for (const second of [() => new Response("synthetic-err", { status: 500 }), () => { throw new Error("synthetic-net"); }]) {
    const f = seq(BAD, second);
    const out = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: f.fn });
    assert.equal(out.status, 200);
    assert.ok(out.body.text.startsWith(SAFE_FALLBACK_TEXT));
    assert.equal(out.body.safety, "replaced");
  }
});

test("reply: a crisis phrase in model output returns the referral, initially and after repair", async () => {
  const first = seq("synthetic: some people feel suicidal at work.");
  const a = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: first.fn });
  assert.equal(a.body.text, REFERRAL_TEXT);
  assert.equal(a.body.safety, "replaced");
  assert.equal(a.code, "reply_crisis");
  assert.equal(first.calls.length, 1, "no repair call on a crisis phrase");
  const after = seq(BAD, "synthetic: you might want to die of boredom.");
  const b = await runReply({ plan: PLAN, transcript: TRANSCRIPT, env: ENV, fetchFn: after.fn });
  assert.equal(b.body.text, REFERRAL_TEXT);
  assert.equal(b.body.safety, "replaced");
  assert.equal(b.code, "reply_crisis");
});

test("reply: a crisis transcript makes no model call", async () => {
  const f = seq(GOOD);
  const out = await runReply({ plan: PLAN, transcript: "synthetic: I want to die", env: ENV, fetchFn: f.fn });
  assert.equal(out.body.text, REFERRAL_TEXT);
  assert.equal(out.body.council_suggested, false);
  assert.equal(f.calls.length, 0);
});

// ---- /reply/stream ----

const S1 = "Synthetic-s1 Start with the first meeting at nine.";
const S2 = "Synthetic-s2 Keep a short gap after it for notes.";
const enc = new TextEncoder();
const chunk = (content) => `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`;
const sseResponse = (text) =>
  new Response(new ReadableStream({
    start(c) {
      for (const t of text.match(/.{1,7}/gs)) c.enqueue(enc.encode(chunk(t)));
      c.enqueue(enc.encode("data: [DONE]\n\n"));
      c.close();
    },
  }), { status: 200 });
const SENV = { REPLY_PROVIDER: "nebius", NEBIUS_API_KEY: `nebius-test-${crypto.randomUUID()}`, REPLY_LLM_MODEL: "synthetic/chat" };
const events = async (out) =>
  (await new Response(out.stream).text()).split("\n\n").filter(Boolean).map((b) => {
    const [ev, data] = b.split("\n");
    return { event: ev.slice(7), data: JSON.parse(data.slice(6)) };
  });

// streamed: the model's streamed text; repair: the non-stream repair answer (string or Response function).
function streamFake(streamed, repair) {
  const calls = [];
  const fn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push(body);
    if (body.stream) return sseResponse(streamed);
    return typeof repair === "function" ? repair() : json(repair);
  };
  return { fn, calls };
}

test("stream: the repair continuation arrives in done; sentences already sent are not repeated", async () => {
  const bad = "Synthetic-bad You must book the room before noon.";
  const fix = "Synthetic-fix Booking the room before noon may help.";
  // The model repeats S1 and S2 before its fix; both were sent already, so they are dropped.
  const f = streamFake(`${S1} ${S2} ${bad} More text after.`, `${S1} ${S2} ${fix}`);
  let code;
  const out = await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: SENV, fetchFn: f.fn, onFinish: (c) => { code = c; } });
  const ev = await events(out);
  assert.deepEqual(ev.map((e) => [e.event, e.data.text]), [["sentence", S1], ["sentence", S2], ["done", fix]]);
  assert.equal(ev.at(-1).data.safety, "repaired");
  assert.equal(ev.at(-1).data.council_suggested, false);
  assert.ok(!JSON.stringify(ev).includes("Synthetic-bad"), "the failing sentence is never sent");
  assert.equal(code, "reply_repaired");
  assert.equal(f.calls.length, 2);
  const repair = f.calls[1].messages;
  assert.equal(f.calls[1].stream, undefined, "the repair call is not streamed");
  assert.deepEqual(repair.at(-2), { role: "assistant", content: `${S1} ${S2} ${bad}` });
  assert.equal(repair.at(-1).content, `${repairInstruction("directive")} ${STREAM_REPAIR_TAIL}`);
});

test("stream: a failing repair gives the safe fallback; a crisis phrase gets the referral with no repair", async () => {
  const bad = "Synthetic-bad I would prescribe an early night.";
  const failed = streamFake(`${S1} ${S2} ${bad} More.`, "Synthetic-again You must sleep early.");
  const ev = await events(await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: SENV, fetchFn: failed.fn }));
  assert.equal(ev.at(-1).event, "done");
  assert.ok(ev.at(-1).data.text.startsWith(SAFE_FALLBACK_TEXT));
  assert.equal(ev.at(-1).data.safety, "replaced");
  assert.ok(!JSON.stringify(ev).includes("Synthetic-again"));

  const crisis = streamFake(`${S1} ${S2} Synthetic-c Some people want to die after a long week. More.`, "unused");
  let code;
  const ev2 = await events(await runReplyStream({ plan: PLAN, transcript: TRANSCRIPT, env: SENV, fetchFn: crisis.fn, onFinish: (c) => { code = c; } }));
  assert.equal(ev2.at(-1).data.text, REFERRAL_TEXT);
  assert.equal(ev2.at(-1).data.safety, "replaced");
  assert.equal(crisis.calls.length, 1, "no repair call on a crisis phrase");
  assert.equal(code, "reply_crisis");
});

// ---- council synthesis ----

const NEBIUS = { NEBIUS_API_KEY: `nebius-test-${crypto.randomUUID()}`, COUNCIL_NEBIUS_MODEL: "synthetic/brain-test" };
const finalJson = (synthesis) => JSON.stringify({ synthesis, experts_consulted: [], sources: [], medical: false });

test("council: the synthesis repair sets gate repaired", async () => {
  const roles = [];
  const callFn = async (messages, env, opts) => {
    roles.push(opts.role);
    if (opts.role === "repair") {
      assert.ok(messages.at(-1).content.startsWith(repairInstruction("directive")));
      return { content: finalJson("Synthetic plan: a short walk could help."), tool_calls: [], provider: "nebius" };
    }
    return { content: finalJson("You must plan the week first."), tool_calls: [], provider: "nebius" };
  };
  const out = await runCouncilV2({ question: "synthetic planning question" }, NEBIUS, { callFn, fetchFn: () => assert.fail("no fetch") });
  assert.equal(out.synthesis, "Synthetic plan: a short walk could help.");
  assert.equal(out.gate, "repaired");
  assert.ok(out.limits_hit.includes("gate_repaired"));
  assert.deepEqual(roles, ["relay", "repair"]);
});

test("council: with under 2 s left there is no repair call", async () => {
  let t = 0;
  const roles = [];
  const callFn = async (messages, env, opts) => {
    roles.push(opts.role);
    t += LIMITS.timeLimitMs - 1_500; // the relay answer leaves 1.5 s of the budget
    return { content: finalJson("You must plan the week first."), tool_calls: [], provider: "nebius" };
  };
  const out = await runCouncilV2({ question: "synthetic planning question" }, NEBIUS, { callFn, now: () => t });
  assert.deepEqual(roles, ["relay"]);
  assert.ok(out.synthesis.startsWith(SAFE_FALLBACK_TEXT));
  assert.equal(out.gate, "replaced");
  assert.ok(out.limits_hit.includes("gate_replaced"));
});

test("council: a passing synthesis reports gate passed", async () => {
  const callFn = async () => ({ content: finalJson("Synthetic: a short walk could help."), tool_calls: [], provider: "nebius" });
  const out = await runCouncilV2({ question: "synthetic planning question" }, NEBIUS, { callFn });
  assert.equal(out.gate, "passed");
  assert.ok(!out.limits_hit.some((h) => h.startsWith("gate_")));
});
