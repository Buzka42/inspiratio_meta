// Turn pipeline: crisis check, route, recall, reply plan. No model call here;
// the returned plan is the input for the later model call.
import { route } from "./router.js";
import { GATE_RULE_PROMPT, HEALTH_MARKER_PROMPT, NOT_MEDICAL_ADVICE, REFERRAL_TEXT, gateText, touchesHealth } from "./safety.js";
import { getPersonality, getSkill } from "./content.js";

export const RECALL_LIMIT = 5;

// Memory kind -> label shown to the model. Hypotheses are never facts.
const LABELS = { fact: "fact", note: "note", hypothesis: "observation" };

const MEMORY_RULE =
  "Memories labelled observation are tentative findings, not facts or conclusions. " +
  "Describe them as observations only.";

function labelMemory(m) {
  const label = LABELS[m.kind];
  if (!label) return null;
  return { id: m.id, text: m.text, label, confidence: m.confidence, source: m.source, created_at: m.created_at };
}

const notExpired = (now) => (m) => !m.expires_at || Date.parse(m.expires_at) > now;

// Replies are spoken and shown as plain text in a calm voice: no markdown, no lists, short.
export const PLAIN_PROSE_RULE = "Write plain prose only: no markdown, no bold, no headings, no bullet points. At most five short sentences.";

export function buildSystemPrompt(personality, skill) {
  const parts = [personality.system_prompt, ...personality.safety_notes];
  if (skill) parts.push(`Skill: ${skill.name}. ${skill.description}`, ...skill.safety_notes);
  // The gate rules go into the base prompt so the model avoids them before the output gate (contract C4).
  // The marker rule lets the model decide when the medical line applies (reply.js, reply-stream.js).
  parts.push(GATE_RULE_PROMPT, HEALTH_MARKER_PROMPT, MEMORY_RULE, PLAIN_PROSE_RULE);
  return parts.join("\n");
}

// Server-side recall shared by /turn and /reply. Expiry is re-checked because remote
// adapters may not filter. Only store items reach a prompt; client text never does.
export async function recallMemories({ memoryStore, query, now = Date.now() }) {
  const recalled = (await memoryStore.recall({ query, limit: RECALL_LIMIT, now })) ?? [];
  return recalled.filter(notExpired(now)).map(labelMemory).filter(Boolean).slice(0, RECALL_LIMIT);
}

export async function runTurn({ transcript, context = {}, memoryStore, now = Date.now() }) {
  // (a) Crisis: fixed referral, no recall, no plan.
  const routed = route(transcript);
  if (routed.crisis) {
    return { crisis: true, escalate: true, response: REFERRAL_TEXT, personality_id: null, skill_id: null, memories: [] };
  }
  // (b) Route to content. A router id without content falls back to no skill / calm guide.
  const personality = getPersonality(routed.personality_id) ?? getPersonality("calm_guide");
  const skill = routed.skill_id ? getSkill(routed.skill_id) : null;
  // (c) Recall.
  const query = typeof context.query === "string" ? context.query : transcript;
  const memories = await recallMemories({ memoryStore, query, now });
  // (d) Plan.
  return {
    crisis: false,
    personality_id: personality.id,
    skill_id: skill?.id ?? null,
    system_prompt: buildSystemPrompt(personality, skill),
    memories,
    escalate: routed.escalate || (routed.skill_id != null && !skill),
  };
}

// Digest variant whose greeting carries the content personality's voice_style.
// Same disclaimer rule as digest.js: health findings carry NOT_MEDICAL_ADVICE.
export function buildVoiceDigest({ personality_id, skill_pack_id, findings }) {
  const personality = getPersonality(personality_id);
  if (!personality) return null;
  const skill = skill_pack_id ? getSkill(skill_pack_id) : null;
  const suggestion = skill ? `Consider this: ${skill.steps[0].text}` : "Consider what matters most today.";
  const parts = [`Good morning. ${personality.voice_style}`, ...findings.map((f) => `One observation: ${f.text}.`), suggestion];
  const health = touchesHealth({ items: findings });
  return {
    personality_id: personality.id,
    voice_style: personality.voice_style,
    text: gateText(parts.join(" ")),
    health,
    disclaimer: health ? NOT_MEDICAL_ADVICE : null,
  };
}
