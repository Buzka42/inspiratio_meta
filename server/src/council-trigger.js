// Server copy of client/lib/voice/council_trigger.dart (contract C5). Keep the two in step: same normaliser,
// topic words, depth phrases, explicit regex and 5-word minimum. Pure, no I/O.
//   "explicit": the user asked for the council by name; "offer": a big question; "none": an ordinary line.
// /reply and /reply/stream send council_suggested = councilTrigger(transcript) === "offer".

// Dart normaliseSpoken: lowercase, drop apostrophes and backticks, anything else outside [a-z0-9] to one space.
export const normaliseSpoken = (raw) =>
  String(raw ?? "")
    .toLowerCase()
    .replace(/[’'`]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

export const COUNCIL_TOPIC_WORDS = new Set([
  // Sleep and lifestyle.
  "sleep", "sleeping", "slept", "insomnia", "waking", "awake", "snoring", "nightmares", "nap", "naps", "tired", "fatigue", "exhausted", "energy",
  "caffeine", "coffee", "alcohol", "screen", "jetlag",
  // Diet and nutrition.
  "diet", "eating", "eat", "food", "nutrition", "protein", "calories", "carbs", "sugar", "fasting", "weight",
  "vitamin", "vitamins", "supplement", "supplements", "hydration", "snacking",
  // Training and movement.
  "training", "workout", "workouts", "exercise", "running", "run", "lifting", "strength", "cardio", "muscle",
  "muscles", "stretching", "recovery", "steps", "injury", "sore", "soreness",
  // Breath, stress and the mind.
  "stress", "stressed", "anxiety", "anxious", "panic", "burnout", "mood", "meditation", "breathing", "breath",
  "focus", "overwhelmed", "low", "lonely",
  // Medical fields (general information only, never a diagnosis).
  "heart", "pulse", "hrv", "blood", "pressure", "cholesterol", "glucose", "diabetes", "thyroid", "hormone",
  "hormones", "period", "periods", "menstrual", "pregnancy", "menopause", "fertility", "digestion", "gut",
  "bloating", "stomach", "constipation", "reflux", "asthma", "lungs", "cough", "skin", "rash", "acne", "eczema",
  "headache", "headaches", "migraine", "migraines", "pain", "back", "knee", "knees", "shoulder", "joints",
  "posture", "dizzy", "dizziness",
]);

export const COUNCIL_DEPTH_PHRASES = Object.freeze([
  "why", "should i", "what should", "how should", "how can i", "how do i", "best way", "is it normal",
  "is it bad", "is it safe", "is it ok", "is that normal", "what causes", "causing", "keep", "keeps",
  "always", "every night", "every day", "every morning", "for weeks", "for months", "lately", "long term",
  "plan", "routine", "program", "improve", "compare", "versus", "difference between", "what can i do",
  "worried", "worse", "getting better", "cant", "cannot", "struggle", "struggling",
]);

const EXPLICIT =
  /\b(?:ask|consult|check with|run (?:it|this|that) by|get) (?:the |my |your )?(?:council|experts|specialists|expert council)\b/;

// Returns "none", "offer" or "explicit".
export function councilTrigger(raw) {
  const n = normaliseSpoken(raw);
  if (!n) return "none";
  if (EXPLICIT.test(n)) return "explicit";
  const words = n.split(" ");
  if (words.length < 5) return "none";
  if (!words.some((w) => COUNCIL_TOPIC_WORDS.has(w))) return "none";
  const padded = ` ${n} `;
  return COUNCIL_DEPTH_PHRASES.some((p) => padded.includes(` ${p} `)) ? "offer" : "none";
}

// The flag for a reply: only a passed or repaired answer to a big question offers the council.
export const councilSuggested = (transcript, safety) =>
  (safety === "passed" || safety === "repaired") && councilTrigger(transcript) === "offer";
