// Training answers (live run 2026-10-30): the council consults the training expert, keeps bank sources, answers
// directly with the figures, never flags a training question as medical, and never cites forums or video sites.
// The coach reply path routes training questions to the coach with the guideline figures. All fakes, synthetic text.
import { test } from "node:test";
import assert from "node:assert/strict";
import { ANSWER_DIRECTLY, EXPERTS, getExpert } from "../src/council/experts.js";
import { CHAT_ANSWER_RULE, SOURCES_RULE, relaySystem, runCouncilV2 } from "../src/council/relay.js";
import { EXCLUDED_DOMAINS, excludedSource, searchWeb } from "../src/council/web.js";
import { HEALTH_MARKER_PROMPT, HEALTH_WELLBEING_SCOPE } from "../src/safety.js";
import { route } from "../src/router.js";
import { buildSystemPrompt } from "../src/turn.js";
import { getPersonality, getSkill } from "../src/content.js";

const META = { META_API_KEY: `meta-test-${crypto.randomUUID()}`, META_MODEL: "synthetic/meta-model-test" };
const QUESTIONS = [
  "How much strength training should I do each week for muscle?",
  "How many days a week should I run if I'm a beginner?",
  "How long should I rest between hard workouts to recover?",
  "Should I stretch before or after a workout, and for how long?",
];

test("experts: wellbeing experts answer directly with the figures; medical prompts unchanged", () => {
  for (const e of EXPERTS) {
    if (e.kind === "wellbeing") assert.ok(e.systemPrompt.includes(ANSWER_DIRECTLY), e.id);
    else assert.ok(!e.systemPrompt.includes(ANSWER_DIRECTLY), e.id);
  }
  assert.match(ANSWER_DIRECTLY, /first point gives the concrete figures/);
  assert.match(ANSWER_DIRECTLY, /lack a figure the question asks for.*set search_query/);
});

test("experts: the training scope names strength, running, recovery and stretching, and the relay roster shows it", () => {
  const { scope } = getExpert("training");
  for (const word of ["strength", "muscle", "running", "recovery", "rest days", "stretching"]) assert.ok(scope.includes(word), word);
  assert.ok(relaySystem("chat").includes(`- training (wellbeing): training and movement; ${scope}`));
});

test("relay: chat answers open with the figures in plain prose; sources list bank ids first", () => {
  const chat = relaySystem("chat");
  assert.ok(chat.includes(CHAT_ANSWER_RULE));
  assert.match(CHAT_ANSWER_RULE, /first sentence answers the question directly, with the figures/);
  assert.match(CHAT_ANSWER_RULE, /Use only figures that appear in the experts' points or their web results; never add one of your own/);
  assert.match(CHAT_ANSWER_RULE, /never about the experts or what they did not say/);
  assert.match(CHAT_ANSWER_RULE, /no markdown, no lists/);
  for (const p of ["chat", "digest", "analysis"]) assert.ok(relaySystem(p).includes(SOURCES_RULE), p);
  assert.ok(!relaySystem("digest").includes(CHAT_ANSWER_RULE), "digest keeps its own line");
  assert.ok(!relaySystem("analysis").includes(CHAT_ANSWER_RULE), "analysis keeps its own line");
});

test("medical scope: everyday training is wellbeing, for both the relay flag and the reply marker", () => {
  assert.match(HEALTH_WELLBEING_SCOPE, /everyday training for a healthy adult: how often, how long, sets, rest days, running or stretching/);
  assert.ok(HEALTH_MARKER_PROMPT.includes(`For ${HEALTH_WELLBEING_SCOPE} do not use the marker`));
  assert.ok(relaySystem("chat").includes(`Set it false for ${HEALTH_WELLBEING_SCOPE}`));
});

test("council: a training question consults training, keeps cited bank sources and a trace, medical false", async () => {
  const calls = [];
  const callFn = async (messages, env, opts) => {
    calls.push({ messages, opts });
    if (opts.role === "expert") {
      const { sources } = JSON.parse(messages[1].content);
      return {
        content: JSON.stringify({ points: [{ text: "Strength work on at least 2 days a week.", source_ids: [sources[0].id] }], caveats: [], confidence: 0.8 }),
        tool_calls: [], provider: "meta",
      };
    }
    if (!messages.some((m) => m.role === "tool")) {
      return {
        content: "",
        tool_calls: [{ id: "c0", name: "consult", arguments: JSON.stringify({ expert_id: "training", question: "Weekly strength training for muscle?" }) }],
        provider: "meta",
      };
    }
    return {
      content: JSON.stringify({ synthesis: "Do strength work on at least two days a week.", experts_consulted: ["training"], sources: ["nhs-guidelines"], medical: false }),
      tool_calls: [], provider: "meta",
    };
  };
  const retrieveFn = async (bank) => ({
    passages: [
      { source_id: "nhs-guidelines", title: "NHS: Physical activity guidelines", url: "https://example.test/nhs", text: `synthetic ${bank} passage` },
      { source_id: "medlineplus-basics", title: "MedlinePlus: Exercise basics", url: "https://example.test/mp", text: "synthetic passage" },
    ],
  });
  const searchFn = async () => {
    throw new Error("no web search for a bank with two sources");
  };
  const out = await runCouncilV2({ question: QUESTIONS[0], purpose: "chat" }, META, { callFn, retrieveFn, searchFn });
  assert.deepEqual(out.experts_consulted, ["training"]);
  assert.equal(out.medical, false);
  assert.equal(out.gate, "passed");
  assert.deepEqual(out.sources.map((s) => [s.id, s.kind]), [["nhs-guidelines", "bank"]]);
  assert.equal(out.trace[0].expert, "training");
  assert.deepEqual(out.trace[0].sources.map((s) => s.kind), ["bank", "bank"]);
  assert.equal(out.trace[0].answered, true);
  assert.equal(out.synthesis, "Do strength work on at least two days a week.");
  const expertCall = calls.find((c) => c.opts.role === "expert");
  assert.ok(expertCall.messages[0].content.includes(ANSWER_DIRECTLY));
  assert.ok(calls[0].messages[0].content.includes(CHAT_ANSWER_RULE));
});

test("web: forums, video and social sites are never council sources", () => {
  for (const url of [
    "https://www.reddit.com/r/Fitness/comments/x", "https://old.reddit.com/r/x", "https://www.youtube.com/shorts/abc",
    "https://youtu.be/abc", "https://www.tiktok.com/@x", "https://www.quora.com/q", "not a url",
  ]) assert.equal(excludedSource(url), true, url);
  for (const url of ["https://www.nhs.uk/live-well/", "https://www.mayoclinic.org/x", "https://notreddit.com.example/x", "https://myreddit.com/x"]) {
    assert.equal(excludedSource(url), false, url);
  }
});

test("web: Tavily is asked to exclude those domains, and any that still come back are dropped", async () => {
  const sent = [];
  const fetchFn = async (url, init) => {
    sent.push(JSON.parse(init.body));
    return new Response(JSON.stringify({
      answer: "Stretch after a workout.",
      results: [
        { title: "r/Fitness thread", url: "https://www.reddit.com/r/Fitness/1", content: "forum text" },
        { title: "Short", url: "https://www.youtube.com/shorts/2", content: "video text" },
        { title: "Mayo Clinic", url: "https://www.mayoclinic.org/stretching", content: "Stretch after exercise." },
      ],
    }), { status: 200 });
  };
  const out = await searchWeb("stretch before or after", { TAVILY_API_KEY: `tvly-test-${crypto.randomUUID()}`, DATA_MODE: "synthetic" }, { fetchFn });
  assert.deepEqual(sent[0].exclude_domains, [...EXCLUDED_DOMAINS]);
  assert.equal(out.via, "tavily");
  assert.deepEqual(out.results.map((r) => r.title), ["Mayo Clinic"]);
});

test("router: the four training questions reach the personal coach", () => {
  const routed = QUESTIONS.map((q) => route(q));
  for (const r of routed) assert.equal(r.personality_id, "personal_coach");
  assert.deepEqual(routed.map((r) => r.skill_id), ["weight_training", null, "weight_training", "weight_training"]);
  assert.deepEqual(route("I keep jogging in the evening"), { personality_id: "personal_coach", skill_id: null, escalate: false });
  assert.equal(route("help me with my breathing").personality_id, "calm_guide", "breathing still goes to the calm guide");
});

test("coach: answers a direct training question first, with the NHS guideline figures", () => {
  const coach = getPersonality("personal_coach");
  assert.match(coach.system_prompt, /Answer a direct training question in your first sentence/);
  assert.match(coach.system_prompt, /For how much or how often to train, give the NHS adult guideline/);
  assert.match(coach.system_prompt, /at least 2 days a week/);
  assert.match(coach.system_prompt, /150 minutes of moderate or 75 minutes of vigorous activity/);
  // Live run 2026-10-30: "a concrete figure" clashed with the weight_training note (no rest times until review)
  // and the model wrote its deliberation into the reply. The coach asks only for the guideline figures.
  assert.ok(!/concrete figure/.test(coach.system_prompt));
  assert.match(getSkill("weight_training").safety_notes.join(" "), /No specific loads, sets, repetitions or rest times/);
  assert.match(coach.system_prompt, /clinician only for pain, injury or a health condition/);
  const prompt = buildSystemPrompt(coach, getSkill("weight_training"));
  assert.ok(prompt.startsWith(coach.system_prompt));
  assert.ok(prompt.includes(HEALTH_MARKER_PROMPT));
});
