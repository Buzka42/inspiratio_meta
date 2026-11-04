// Cross-check (src/council/check.js) wired into the relay: a different provider labels each expert
// point against its cited passage. Unsupported points never reach the relay. Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkerPrefer, crossCheck, passageHash } from "../src/council/check.js";
import { runCouncilV2 } from "../src/council/relay.js";
import { DEFAULT_SPEC } from "../src/spec/schema.js";

const PASSAGE = "Adults benefit from two to three strength sessions per week, with rest days between.";
const passages = new Map([["src_a", { text: PASSAGE }]]);
const points = [
  { text: "Two to three strength sessions per week.", source_ids: ["src_a"], expert_id: "training" },
  { text: "Five ice baths daily are required.", source_ids: ["src_a"], expert_id: "training" },
  { text: "Rest days matter between sessions.", source_ids: ["src_a"], expert_id: "training" },
];
const checkerReply = (content) => async () => ({ content, provider: "nebius", tool_calls: [] });

test("checkerPrefer never grades its own provider", () => {
  assert.equal(checkerPrefer(["meta"]), "baseten");
  assert.equal(checkerPrefer(["meta", "baseten"]), "nebius");
  assert.equal(checkerPrefer([]), "meta");
});

test("crossCheck drops unsupported, flags contested, pins passage hashes", async () => {
  const reply = JSON.stringify({
    checks: [
      { point: 1, label: "supported", quote: "two to three strength sessions per week" },
      { point: 2, label: "unsupported", quote: "" },
      { point: 3, label: "contested", quote: "rest days between" },
    ],
  });
  const seen = [];
  const out = await crossCheck(structuredClone(points), passages, {
    callFn: async (messages, env, opts) => { seen.push(opts); return { content: reply, provider: "nebius", tool_calls: [] }; },
    producerProviders: ["meta"],
  });
  assert.equal(seen[0].prefer, "baseten");
  assert.equal(seen[0].role, "check");
  assert.deepEqual(out.kept.map((p) => p.text), [points[0].text, points[2].text]);
  assert.equal(out.kept[1].contested, true);
  assert.deepEqual(out.dropped.map((p) => p.text), [points[1].text]);
  assert.equal(out.checks[0].passage_hash, passageHash(PASSAGE));
  assert.deepEqual(out.checks.map((c) => c.label), ["supported", "unsupported", "contested"]);
});

test("crossCheck abstains on checker failure: every point is kept", async () => {
  const out = await crossCheck(structuredClone(points), passages, {
    callFn: async () => { throw new Error("down"); },
  });
  assert.equal(out.code, "check_unavailable");
  assert.equal(out.kept.length, 3);
  void checkerReply;
});

test("relay: cross-check runs only when COUNCIL_CROSSCHECK=on, and why/checks ride the result", async () => {
  const retrieveFn = async () => ({ passages: [{ source_id: "src_a", title: "Strength basics", url: "https://x.test", text: PASSAGE }] });
  const brain = async (messages, env, opts) => {
    const sys = messages[0].content;
    if (opts.role === "check") {
      return { content: JSON.stringify({ checks: [{ point: 1, label: "supported", quote: "two to three" }, { point: 2, label: "unsupported", quote: "" }] }), provider: "nebius", tool_calls: [] };
    }
    if (sys.includes("one expert on a wellbeing council")) {
      return { content: JSON.stringify({ points: [points[0], points[1]].map(({ expert_id, ...p }) => p), caveats: [], confidence: 0.8, search_query: null }), provider: "meta", tool_calls: [] };
    }
    const toolResult = messages.find((m) => m.role === "tool");
    if (!toolResult) {
      return { content: "", provider: "meta", tool_calls: [{ id: "c1", name: "consult", arguments: JSON.stringify({ expert_id: "training", question: "How often should I train?" }) }] };
    }
    const got = JSON.parse(toolResult.content);
    assert.equal(got.points.length, 1, "unsupported point dropped before the relay sees it");
    return { content: JSON.stringify({ synthesis: "Two to three strength sessions per week.", sources: ["src_a"], medical: false }), provider: "meta", tool_calls: [] };
  };
  const spec = structuredClone(DEFAULT_SPEC);
  spec.version = 3;
  spec.skills.training = true;
  const deps = { fetchFn: async () => { throw new Error("net"); }, retrieveFn, callFn: brain, now: () => 1_000_000, spec };
  const META = { META_API_KEY: "k".repeat(40), META_MODEL: "synthetic/meta-model-test" };
  const off = await runCouncilV2({ question: "How often should I train?" }, META, deps);
  assert.deepEqual(off.checks, []);
  assert.equal(off.why.spec_version, 3);
  assert.deepEqual(off.why.skills_consulted, ["training"]);
  const on = await runCouncilV2({ question: "How often should I train?" }, { ...META, COUNCIL_CROSSCHECK: "on" }, deps);
  assert.deepEqual(on.checks.map((c) => c.label), ["supported", "unsupported"]);
  assert.ok(on.limits_hit.includes("check_dropped"));
  assert.deepEqual(on.why.gates.checks, ["supported", "unsupported"]);
});

// One relay run with the cross-check on; checker(opts) answers the role "check" call.
async function relayWithChecker(checker) {
  const retrieveFn = async () => ({ passages: [{ source_id: "src_a", title: "Strength basics", url: "https://x.test", text: PASSAGE }] });
  const brain = async (messages, env, opts) => {
    if (opts.role === "check") return checker(opts);
    if (messages[0].content.includes("one expert on a wellbeing council")) {
      return { content: JSON.stringify({ points: [{ text: points[0].text, source_ids: ["src_a"] }], caveats: [], confidence: 0.8, search_query: null }), provider: "meta", tool_calls: [] };
    }
    if (!messages.find((m) => m.role === "tool")) {
      return { content: "", provider: "meta", tool_calls: [{ id: "c1", name: "consult", arguments: JSON.stringify({ expert_id: "training", question: "How often?" }) }] };
    }
    return { content: JSON.stringify({ synthesis: "Two to three sessions.", sources: ["src_a"], medical: false }), provider: "meta", tool_calls: [] };
  };
  const spec = structuredClone(DEFAULT_SPEC);
  spec.skills.training = true;
  const env = { META_API_KEY: "k".repeat(40), META_MODEL: "synthetic/meta-model-test", COUNCIL_CROSSCHECK: "on" };
  return runCouncilV2({ question: "How often should I train?" }, env, { fetchFn: async () => { throw new Error("net"); }, retrieveFn, callFn: brain, now: () => 1_000_000, spec });
}

test("relay: the cross-check call gets the run's remaining time and its deadline", async () => {
  const seen = [];
  await relayWithChecker((opts) => { seen.push(opts); return { content: JSON.stringify({ checks: [{ point: 1, label: "supported", quote: "" }] }), provider: "nebius", tool_calls: [] }; });
  assert.equal(seen.length, 1);
  assert.equal(seen[0].deadlineAt, 1_000_000 + 45_000);
  assert.ok(seen[0].timeoutMs > 0 && seen[0].timeoutMs <= 20_000);
  const none = await crossCheck(structuredClone(points), passages, { callFn: async () => assert.fail("no call"), timeoutMs: 0 });
  assert.equal(none.code, "check_unavailable");
});

test("relay: a failed cross-check adds check_unavailable to the trace notes", async () => {
  const out = await relayWithChecker(() => { throw new Error("down"); });
  assert.ok(out.limits_hit.includes("check_unavailable"));
  assert.ok(out.trace.some((e) => e.note === "check_unavailable"));
});
