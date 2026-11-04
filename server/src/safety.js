// Rule-based safety: crisis phrases and the output gate. No model calls.

export const CRISIS_PHRASES = [
  "kill myself", "end my life", "want to die", "suicide", "suicidal",
  "hurt myself", "self harm", "self-harm", "don't want to be here", "better off dead",
];

export const REFERRAL_TEXT =
  "I am not able to help with this safely. If you are in danger or thinking of harming yourself, " +
  "contact your local emergency number or a crisis line now, or reach a trusted person or clinician.";

export const NOT_MEDICAL_ADVICE =
  "This is not medical advice. Talk to a clinician about any health concern.";

// Council runs that consult a medical expert end with this path to care. No numbers, no condition words,
// so analysis comments still pass phrase.js.
export const CLINICIAN_PATH =
  "For a personal answer, book a visit with your GP or another clinician. If something feels severe or sudden, " +
  "call your local emergency number.";

// Decision D-D: what a model reply becomes when one repair call could not make it pass the gate.
export const SAFE_FALLBACK_TEXT =
  "Illunis cannot answer that safely here. For a personal answer, please talk to a clinician.";

// Output gate rules: directive language, diagnosis words, condition claims, prescriptions.
// `rule` is the sentence a repair call quotes back to the model; it never carries user text.
export const GATE_RULES = Object.freeze([
  { id: "directive", re: /\byou must\b/i, rule: "Never write 'you must'." },
  { id: "diagnosis", re: /\bdiagnos(e|ed|is|es)\b/i, rule: "Never use the words diagnose, diagnosis or diagnosed." },
  {
    id: "condition_claim",
    re: /\byou have (depression|diabetes|anxiety disorder|a disorder|an illness)\b/i,
    rule: "Never tell the user they have a condition or illness.",
  },
  { id: "prescription", re: /\bprescri(be|ption)\b/i, rule: "Never use the words prescribe or prescription." },
].map(Object.freeze));

// Goes into every base prompt (relay, expert, reply), so the model avoids the gate from the start.
export const GATE_RULE_PROMPT =
  "Never write 'you must'. Never use the words diagnose, diagnosis, diagnosed, prescribe or prescription. " +
  "Never tell the user they have a condition or illness.";

// Returns "crisis", the id of the first broken rule, or null when the text passes.
// The rules apply to claims, not words. Removed before the rule check, because they state no claim:
//   - a negated rule word ('not a diagnosis', 'I cannot diagnose', 'unable to prescribe');
//   - what a clinician does ('a doctor can diagnose this', 'your GP may prescribe');
//   - a denied condition claim ('this does not mean you have an illness').
// The crisis check runs on the whole text first and is never relaxed.
const RULE_WORD = "(?:diagnos[a-z]*|prescri[a-z]*)";
const NEGATED = new RegExp(
  `(?:\\bnot able to|\\bunable to|\\bcan ?not|\\bcan[’']t|\\bwon[’']t|\\bwill not|\\bnot|\\bno|\\bnever|\\bnor)\\s+(?:a |an |any |the )?${RULE_WORD}\\b`,
  "gi",
);
const CLINICIAN_ACT = new RegExp(
  `\\b(?:clinicians?|doctors?|gps?|pharmacists?|nurses?|specialists?)\\s+(?:can|could|may|might|will|would|is able to|are able to)\\s+(?:help\\s+)?${RULE_WORD}\\b`,
  "gi",
);
const DENIED_CLAIM = /(?:\bnot|n[’']t|\bnever)\s+(?:mean|meaning|saying|say|suggest|suggesting|claim|claiming)\s+(?:that\s+)?you have\b/gi;
export function gateViolation(text) {
  const s = String(text ?? "");
  if (isCrisis(s)) return "crisis";
  const checked = s.replace(NEGATED, " ").replace(CLINICIAN_ACT, " ").replace(DENIED_CLAIM, " ");
  return GATE_RULES.find((r) => r.re.test(checked))?.id ?? null;
}

// The repair turn: names the broken rule (id and text) and asks for a rewrite. Fixed text only, no user text.
export function repairInstruction(ruleId) {
  const rule = GATE_RULES.find((r) => r.id === ruleId);
  const broken = rule ? `Your reply broke the ${rule.id} rule: ${rule.rule}` : "Your reply broke a safety rule.";
  return `${broken} Rewrite it so it follows every rule: ${GATE_RULE_PROMPT} Keep the helpful content.`;
}

// Gate with at most one repair call. repairFn(ruleId) returns the rewritten text (or throws).
// Returns { text, safety: "passed" | "repaired" | "replaced", crisis }. crisis is true when the
// referral replaced the text. A repair that throws or still fails gives SAFE_FALLBACK_TEXT.
export async function gateWithRepair(text, repairFn) {
  const first = gateViolation(text);
  if (first === null) return { text, safety: "passed", crisis: false };
  if (first === "crisis") return { text: REFERRAL_TEXT, safety: "replaced", crisis: true };
  let repaired;
  try {
    repaired = await repairFn(first);
  } catch {
    return { text: SAFE_FALLBACK_TEXT, safety: "replaced", crisis: false };
  }
  const again = typeof repaired === "string" && repaired.trim() ? gateViolation(repaired) : "empty";
  if (again === null) return { text: repaired.trim(), safety: "repaired", crisis: false };
  if (again === "crisis") return { text: REFERRAL_TEXT, safety: "replaced", crisis: true };
  return { text: SAFE_FALLBACK_TEXT, safety: "replaced", crisis: false };
}

// The model decides when the medical line applies (owner, 2026-10-29). Only guidance whose wrong use could cause
// harm counts; general wellbeing talk does not. The reply model marks such answers with HEALTH_MARKER as its first
// tokens; the server strips the marker and appends NOT_MEDICAL_ADVICE after the gate. The council relay uses the
// same scope for its JSON `medical` flag. Everyday training questions (how often, how long, sets, rest, stretching)
// are wellbeing: live run 2026-10-30 marked "how long should I rest between hard workouts" as medical.
export const HEALTH_MARKER = "[[HEALTH]]";
export const HEALTH_HARM_SCOPE =
  "health guidance whose wrong use could cause harm (a medicine, a dose, a diagnosis, a symptom that may need care, " +
  "stopping or starting a treatment, a breathing or exercise practice for a person with a condition, or anything " +
  "about a serious or new symptom)";
export const HEALTH_WELLBEING_SCOPE =
  "general wellbeing talk (sleep habits, a walk, a breathing exercise to relax, journaling, a question about how someone feels, " +
  "or everyday training for a healthy adult: how often, how long, sets, rest days, running or stretching)";
export const HEALTH_MARKER_PROMPT =
  `When your answer gives ${HEALTH_HARM_SCOPE}, begin the reply with the marker ${HEALTH_MARKER} on its own, then the answer. ` +
  `For ${HEALTH_WELLBEING_SCOPE} do not use the marker. Never write a medical disclaimer yourself.`;

const MARKER_ANY = /\s*\[\[\s*health\s*\]\]\s*/gi;
const MARKER_START = /^\s*\[\[\s*health\s*\]\]/i;
// The start of a stream that may still become the marker: "", "[", "[[", "[[HEAL", "[[HEALTH]".
const MARKER_PARTIAL = /^\s*(?:\[(?:\[\s*[a-z]*\s*\]?)?)?$/i;

// Removes every marker from model text. Returns { text, health }; health is true when any marker was there.
export function stripHealthMarker(text) {
  const s = String(text ?? "");
  const out = s.replace(MARKER_ANY, " ").trim();
  return { text: out, health: out !== s.trim() };
}

// For a stream: null while the visible start may still be the marker, then { health, start }, where start is the
// index after the marker (0 without one). final: the stream ended, so a partial marker is plain text.
export function leadingHealthMarker(text, final = false) {
  const m = String(text ?? "").match(MARKER_START);
  if (m) return { health: true, start: m[0].length };
  if (!final && MARKER_PARTIAL.test(text)) return null;
  return { health: false, start: 0 };
}

// Keyword health detection. Not used for model replies or the council any more (the model decides there); kept for
// the digests (findings with kind "health") and the assistant inbox route, which has no marker. Errs wide.
export const HEALTH_KIND = "health";
const HEALTH_TERMS =
  /\b(?:health\w*|medic\w*|clinic\w*|doctor\w*|symptom\w*|sleep\w*|slept|insomnia|nap|tired|fatigue\w*|heart|pulse|hrv|blood|breath\w*|pain|painful|aches?|aching|injur\w*|sore|sick|illness|disease|diet\w*|calorie\w*|weight|workout\w*|exercis\w*|training|stress\w*|anxi\w*|panic\w*|depress\w*|mood|energ\w*|wellbeing|well-being|pill\w*|dose\w*|drugs?)\b/i;

export function touchesHealth({ items = [], texts = [] } = {}) {
  return items.some((i) => i?.kind === HEALTH_KIND) || texts.some((t) => HEALTH_TERMS.test(String(t ?? "")));
}

// Appends the disclaimer once. Call after the gate so the gate can never remove it.
export function withHealthLine(text) {
  return text.includes(NOT_MEDICAL_ADVICE) ? text : `${text} ${NOT_MEDICAL_ADVICE}`;
}

export function isCrisis(text) {
  const t = String(text ?? "").toLowerCase();
  return CRISIS_PHRASES.some((p) => t.includes(p));
}

// Template paths (digest, analysis, assistants, summaries) keep the plain pass/replace gate.
export function passesGate(text) {
  return gateViolation(text) === null;
}

export function gateText(text) {
  return passesGate(text) ? text : REFERRAL_TEXT;
}
