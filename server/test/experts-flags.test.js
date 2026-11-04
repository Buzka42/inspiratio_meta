// Plan B4: COUNCIL_MEDICAL (default off) and COUNCIL_COACHING (default on) pick the active experts.
// The registry is unchanged. Model and retrieval calls are injected fakes; all text is synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { EXPERTS, EXPERT_IDS, activeExpertIds, activeExperts, getExpert, isActive, unknownExpertIds } from "../src/council/experts.js";
import { consultTool, relaySystem, runCouncilV2 } from "../src/council/relay.js";

const WELLBEING = ["diet", "training", "breath_stress", "sleep_lifestyle"];
const MEDICAL = EXPERTS.filter((e) => e.kind === "medical").map((e) => e.id);
const META = { META_API_KEY: `meta-test-${crypto.randomUUID()}`, META_MODEL: "synthetic/meta-model-test" };
const enumOf = (env) => consultTool(env).function.parameters.properties.expert_id.enum;

test("flags: medical experts are off by default, coaching on", () => {
  assert.deepEqual(activeExpertIds({}), WELLBEING);
  assert.deepEqual(activeExpertIds(), WELLBEING);
  assert.equal(EXPERTS.length, 13, "registry unchanged");
  assert.equal(EXPERT_IDS.length, 13);
});

test("flags: COUNCIL_MEDICAL=on turns the medical experts on; other values leave them off", () => {
  assert.deepEqual(activeExpertIds({ COUNCIL_MEDICAL: "on" }), EXPERT_IDS);
  assert.deepEqual(activeExpertIds({ COUNCIL_MEDICAL: " ON " }), EXPERT_IDS);
  for (const v of ["", "off", "true", "1", "yes"]) assert.deepEqual(activeExpertIds({ COUNCIL_MEDICAL: v }), WELLBEING, v);
});

test("flags: COUNCIL_COACHING=off drops diet and training only", () => {
  assert.deepEqual(activeExpertIds({ COUNCIL_COACHING: "off" }), ["breath_stress", "sleep_lifestyle"]);
  assert.deepEqual(activeExpertIds({ COUNCIL_COACHING: "off", COUNCIL_MEDICAL: "on" }), ["breath_stress", "sleep_lifestyle", ...MEDICAL]);
  assert.deepEqual(activeExpertIds({ COUNCIL_COACHING: "on" }), WELLBEING);
  assert.ok(activeExperts({ COUNCIL_COACHING: "off" }).every((e) => e.kind === "wellbeing"));
});

test("flags: the consult enum and the relay roster list only active experts", () => {
  assert.deepEqual(enumOf({}), WELLBEING);
  assert.deepEqual(enumOf({ COUNCIL_MEDICAL: "on" }), EXPERT_IDS);
  assert.deepEqual(enumOf({ COUNCIL_COACHING: "off" }), ["breath_stress", "sleep_lifestyle"]);
  const roster = relaySystem("chat", {});
  assert.ok(!roster.includes("- cardiology"), "medical not in default roster");
  assert.ok(roster.includes("- diet"));
  assert.ok(relaySystem("chat", { COUNCIL_MEDICAL: "on" }).includes("- cardiology (medical)"));
  assert.ok(!relaySystem("chat", { COUNCIL_COACHING: "off" }).includes("- training"));
});

// Fake relay: asks for `ids` on the first turn, then answers the final JSON. Records every call.
function fakes(ids) {
  const calls = [];
  const retrieved = [];
  const callFn = async (messages, env, opts) => {
    calls.push({ messages, opts });
    if (opts.role === "expert") return { content: JSON.stringify({ points: [], caveats: [], confidence: 0.5 }), tool_calls: [], provider: "meta" };
    if (messages.some((m) => m.role === "tool") || !opts.tools) {
      return { content: JSON.stringify({ synthesis: "Synthetic synthesis.", experts_consulted: [], sources: [], medical: false }), tool_calls: [], provider: "meta" };
    }
    return {
      content: "",
      tool_calls: ids.map((id, i) => ({ id: `c${i}`, name: "consult", arguments: JSON.stringify({ expert_id: id, question: "synthetic question" }) })),
      provider: "meta",
    };
  };
  const retrieveFn = async (bank) => {
    retrieved.push(bank);
    return { passages: [] };
  };
  const toolResults = () => calls.flatMap((c) => c.messages.filter((m) => m.role === "tool").map((m) => JSON.parse(m.content))).slice(-ids.length);
  return { callFn, retrieveFn, calls, retrieved, toolResults };
}

test("flags: the relay refuses a consult for an inactive expert, before retrieval or a call", async () => {
  const f = fakes(["cardiology", "sleep_lifestyle"]);
  const out = await runCouncilV2({ question: "synthetic sleep question" }, META, { callFn: f.callFn, retrieveFn: f.retrieveFn });
  assert.deepEqual(f.calls[0].opts.tools[0].function.parameters.properties.expert_id.enum, WELLBEING);
  assert.deepEqual(f.toolResults()[0], { error: "expert_inactive" });
  assert.equal(f.toolResults()[1].expert_id, "sleep_lifestyle");
  assert.deepEqual(f.retrieved, ["sleep_lifestyle"]);
  assert.deepEqual(out.experts_consulted, ["sleep_lifestyle"]);
  assert.equal(out.consults, 1);
  assert.equal(out.medical, false);
});

test("flags: with COUNCIL_MEDICAL=on the medical consult runs; with COUNCIL_COACHING=off diet is refused", async () => {
  const on = fakes(["cardiology"]);
  const outOn = await runCouncilV2({ question: "synthetic pulse question" }, { ...META, COUNCIL_MEDICAL: "on" }, { callFn: on.callFn, retrieveFn: on.retrieveFn });
  assert.deepEqual(outOn.experts_consulted, ["cardiology"]);
  assert.equal(outOn.medical, true);

  const off = fakes(["diet", "training", "breath_stress"]);
  const outOff = await runCouncilV2({ question: "synthetic question" }, { ...META, COUNCIL_COACHING: "off" }, { callFn: off.callFn, retrieveFn: off.retrieveFn });
  assert.deepEqual(off.calls[0].opts.tools[0].function.parameters.properties.expert_id.enum, ["breath_stress", "sleep_lifestyle"]);
  assert.deepEqual(off.toolResults().map((r) => r.error ?? r.expert_id), ["expert_inactive", "expert_inactive", "breath_stress"]);
  assert.deepEqual(outOff.experts_consulted, ["breath_stress"]);
});

test("allowlist: COUNCIL_EXPERTS narrows the roster, trimmed and case-insensitive", () => {
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: "sleep_lifestyle,breath_stress" }), ["breath_stress", "sleep_lifestyle"]);
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: " Sleep_Lifestyle , ,DIET " }), ["diet", "sleep_lifestyle"]);
  assert.equal(isActive("training", { COUNCIL_EXPERTS: "diet" }), false);
  assert.equal(isActive("diet", { COUNCIL_EXPERTS: "diet" }), true);
  assert.equal(getExpert("training").id, "training", "registry lookup ignores the allowlist");
  assert.deepEqual(enumOf({ COUNCIL_EXPERTS: "diet" }), ["diet"]);
});

test("allowlist: cannot enable a medical expert without COUNCIL_MEDICAL=on", () => {
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: "cardiology,sleep_lifestyle" }), ["sleep_lifestyle"]);
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: "cardiology" }), []);
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: "cardiology,sleep_lifestyle", COUNCIL_MEDICAL: "on" }), ["sleep_lifestyle", "cardiology"]);
});

test("allowlist: cannot enable diet when COUNCIL_COACHING=off", () => {
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: "diet,training,breath_stress", COUNCIL_COACHING: "off" }), ["breath_stress"]);
  assert.equal(isActive("diet", { COUNCIL_EXPERTS: "diet", COUNCIL_COACHING: "off" }), false);
});

test("allowlist: unknown ids are ignored and reported once", () => {
  const env = { COUNCIL_EXPERTS: "diet, Astrology ,astrology,tarot" };
  assert.deepEqual(activeExpertIds(env), ["diet"]);
  assert.deepEqual(unknownExpertIds(env), ["astrology", "tarot"]);
  assert.deepEqual(unknownExpertIds({ COUNCIL_EXPERTS: "diet,cardiology" }), [], "known but gated ids are not unknown");
  assert.deepEqual(unknownExpertIds({}), []);
  assert.deepEqual(unknownExpertIds(), []);
});

test("allowlist: unset or empty COUNCIL_EXPERTS leaves behaviour unchanged", () => {
  for (const base of [{}, { COUNCIL_MEDICAL: "on" }, { COUNCIL_COACHING: "off" }, { COUNCIL_COACHING: "off", COUNCIL_MEDICAL: "on" }]) {
    for (const v of [undefined, "", "  ", " , ,"]) {
      assert.deepEqual(activeExpertIds({ ...base, COUNCIL_EXPERTS: v }), activeExpertIds(base), JSON.stringify([base, v]));
    }
  }
  assert.deepEqual(activeExpertIds({ COUNCIL_EXPERTS: "" }), WELLBEING);
});
