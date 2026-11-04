// Spoken digest from templates. No model call in this wave.
import { NOT_MEDICAL_ADVICE, gateText, touchesHealth } from "./safety.js";

const OPENERS = {
  calm_guide: "Good morning. Take a slow breath.",
  personal_coach: "Morning. Here is where you stand.",
  productivity_advisor: "Good morning. Here is your brief.",
  socratic_tutor: "Good morning. Let us look at what the data raises.",
};
const DEFAULT_OPENER = "Good morning.";

const SUGGESTIONS = {
  breathwork: "Consider two minutes of slow breathing before you start.",
  training: "Consider a light session if you feel up to it.",
  motivation: "Consider picking one small task and starting it.",
  productivity: "Consider choosing your top priority first.",
};

// A finding: {text, kind?: "health"|..., confidence?}. Phrased as observations.
export function buildDigest({ personality_id, skill_pack_id, findings }) {
  const list = findings.map((f) => `One observation: ${f.text}.`);
  const suggestion = SUGGESTIONS[skill_pack_id] ?? "Consider what matters most today.";
  const parts = [OPENERS[personality_id] ?? DEFAULT_OPENER, ...list, suggestion];
  const health = touchesHealth({ items: findings });
  return {
    text: gateText(parts.join(" ")),
    health,
    disclaimer: health ? NOT_MEDICAL_ADVICE : null,
  };
}
