// Expert registry for council v2. Experts never talk to the user: their JSON goes to the relay only.
// bank: the Vectorize namespace holding the expert's knowledge (knowledge/<bank>/*.md).
// skill: the spec switch that turns the expert on or off (spec/schema.js SKILL_IDS); default its id. Every medical
// expert shares the one "medical" skill.
import { GATE_RULE_PROMPT } from "../safety.js";
import { skillOn } from "../spec/policy.js";

export const EXPERT_REPLY_CONTRACT =
  'Reply with JSON only: {"points":[{"text":string,"source_ids":[string]}],"caveats":[string],' +
  '"confidence":number between 0 and 1,"search_query":string or null}. ' +
  "Cite in source_ids only the ids of the sources given to you. Use at most 4 points of one or two sentences. " +
  "If the sources do not cover the question, say so in caveats and set search_query to a short web query.";

const SHARED =
  "You are one expert on a wellbeing council. You answer the council's relay, never the user. " +
  "Describe observations and general options; the user decides. " +
  `${GATE_RULE_PROMPT} `;

const MEDICAL =
  "Give general health information only. Never diagnose, never name a condition the user has, never give " +
  "medicine names with doses or any prescription. Every point must cite a given source id. " +
  "If something needs a clinician, say that it is worth discussing with a clinician. ";

// Wellbeing experts answer the question asked (live run 2026-10-30: "how much strength training" came back as
// general options without the figures the sources gave).
export const ANSWER_DIRECTLY =
  "Answer the relay's question directly. Your first point gives the concrete figures your sources state for it " +
  "(for example days a week, minutes, sets, repetitions or rest days), with the source ids. " +
  "If your sources lack a figure the question asks for, say so in caveats and set search_query to find it. " +
  "Leave out general advice the question did not ask for. ";

const wellbeing = (id, field, scope, skill = id) => ({
  id, field, kind: "wellbeing", scope, bank: id, skill,
  systemPrompt: `${SHARED}${ANSWER_DIRECTLY}Your field: ${field}. Scope: ${scope}. ${EXPERT_REPLY_CONTRACT}`,
});

const medical = (id, field, scope) => ({
  id, field, kind: "medical", scope, bank: id, skill: "medical",
  systemPrompt: `${SHARED}${MEDICAL}Your field: ${field}. Scope: ${scope}. ${EXPERT_REPLY_CONTRACT}`,
});

export const EXPERTS = Object.freeze([
  wellbeing("diet", "diet and nutrition", "eating patterns, hydration, meal timing, general nutrition guidelines"),
  wellbeing("training", "training and movement",
    "weekly exercise amounts, strength and muscle training, running, workout recovery and rest days, stretching, walking"),
  wellbeing("breath_stress", "breathing, meditation and stress", "breathwork, relaxation, mindfulness, daily stress load",
    "breathwork"),
  wellbeing("sleep_lifestyle", "sleep and lifestyle", "sleep habits, light, caffeine and alcohol timing, routines",
    "sleep"),
  medical("cardiology", "heart and circulation", "resting heart rate, heart rate variability, blood pressure basics"),
  medical("endocrinology_metabolism", "hormones and metabolism", "blood sugar, weight regulation, thyroid basics"),
  medical("gastroenterology", "digestion", "gut comfort, bowel habits, digestion and food tolerance basics"),
  medical("musculoskeletal_physio", "muscles, joints and physiotherapy", "aches, injuries, posture, return to activity"),
  medical("mental_health", "mental health", "mood, energy, low mood and anxiety information, when to seek support"),
  medical("womens_health", "women's health", "menstrual cycle, pregnancy and menopause general information"),
  medical("respiratory", "breathing and lungs", "breathlessness, asthma and respiratory infection basics"),
  medical("dermatology", "skin", "skin care, rashes and sun protection basics"),
  medical("general_medicine", "general medicine", "common symptoms, prevention, when to see a doctor"),
].map(Object.freeze));

const BY_ID = new Map(EXPERTS.map((e) => [e.id, e]));
export const getExpert = (id) => (typeof id === "string" ? BY_ID.get(id) ?? null : null);
export const EXPERT_IDS = EXPERTS.map((e) => e.id);
// Skills that are not council experts (never in EXPERTS, so never consulted). Only the reading companion owns a bank.
export const SKILLS = Object.freeze([{ id: "reading", bank: "reading" }, { id: "habits", bank: null }, { id: "focus", bank: null }].map(Object.freeze));
export const BANK_IDS = Object.freeze([...EXPERT_IDS, ...SKILLS.filter((s) => s.bank).map((s) => s.bank)]);
export const isMedical = (id) => getExpert(id)?.kind === "medical";
export const skillOf = (e) => e?.skill ?? e?.id;

// Flags (plan B4, 2026-10-28). The registry above never changes; these only pick who the relay may consult.
// COUNCIL_MEDICAL=on turns the medical experts on (default off). COUNCIL_COACHING=off drops diet and training
// (the Meta demo); default on. Values are compared trimmed and case-insensitive.
export const COACHING_IDS = Object.freeze(["diet", "training"]);
const flag = (env, name) => String(env?.[name] ?? "").trim().toLowerCase();
export const medicalOn = (env = {}) => flag(env, "COUNCIL_MEDICAL") === "on";
export const coachingOn = (env = {}) => flag(env, "COUNCIL_COACHING") !== "off";

// COUNCIL_EXPERTS (META_SLICE): optional comma-separated allowlist of expert ids, trimmed and lowercased.
// It only narrows what the group flags allow; unset or empty means no narrowing. Unknown ids are ignored.
const allowlist = (env) => flag(env, "COUNCIL_EXPERTS").split(",").map((s) => s.trim()).filter(Boolean);
export const unknownExpertIds = (env = {}) => [...new Set(allowlist(env).filter((id) => !BY_ID.has(id)))];

// spec (optional, spec/schema.js): narrows further; an expert whose skill is off in it is dropped. null: env only.
export function activeExperts(env = {}, spec = null) {
  const medical = medicalOn(env);
  const coaching = coachingOn(env);
  const allow = allowlist(env);
  return EXPERTS.filter((e) => (e.kind === "medical" ? medical : coaching || !COACHING_IDS.includes(e.id)))
    .filter((e) => !allow.length || allow.includes(e.id))
    .filter((e) => skillOn(spec, skillOf(e)));
}
export const activeExpertIds = (env = {}, spec = null) => activeExperts(env, spec).map((e) => e.id);
export const isActive = (id, env = {}, spec = null) => activeExperts(env, spec).some((e) => e.id === id);
