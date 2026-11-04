// Rule-based router. First matching rule wins. Crisis is checked before the table.
import { isCrisis, REFERRAL_TEXT } from "./safety.js";

export const DEFAULT_ROUTE = { personality_id: "calm_guide", skill_id: null };

// Easy-to-read table: keywords -> personality and skill.
export const RULES = [
  { keywords: ["breathe", "breathing", "panic", "calm down", "anxious"], personality_id: "calm_guide", skill_id: "breathwork" },
  { keywords: ["workout", "training", "exercise", "lift", "run today", "strength", "muscle"], personality_id: "personal_coach", skill_id: "weight_training" },
  // Running and stretching go to the coach without the resistance-training skill (live run 2026-10-30: "how many
  // days a week should I run" reached the calm guide).
  { keywords: ["running", "should i run", "start to run", "jogging", "stretch", "cardio"], personality_id: "personal_coach", skill_id: null },
  { keywords: ["motivation", "unmotivated", "procrastinat", "can't start"], personality_id: "personal_coach", skill_id: "motivation" },
  { keywords: ["plan my day", "priorities", "todo", "to-do", "schedule"], personality_id: "productivity_advisor", skill_id: "habit_building" },
  { keywords: ["why do", "explain", "teach me", "quiz me"], personality_id: "socratic_tutor", skill_id: null },
];

export function route(transcript) {
  if (isCrisis(transcript)) {
    return { crisis: true, personality_id: null, skill_id: null, escalate: true, response: REFERRAL_TEXT };
  }
  const t = String(transcript ?? "").toLowerCase();
  const rule = RULES.find((r) => r.keywords.some((k) => t.includes(k)));
  if (rule) return { personality_id: rule.personality_id, skill_id: rule.skill_id, escalate: false };
  // No rule matched: default route; escalate flags the later small-model call.
  return { ...DEFAULT_ROUTE, escalate: true };
}
