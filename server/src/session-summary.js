// POST /session/summary: stateless. The phone sends one finished session and keeps the summary in its
// short-term memory (last N sessions). Nothing is stored here. The council brain (council/provider.js: Meta when configured, then Nebius;
// the summary_test row on OpenRouter while testing) writes it, so the DATA_MODE guard applies. Crisis sessions get a fixed summary with no model call.
import { gateText, isCrisis } from "./safety.js";
import { callBrain } from "./council/provider.js";

export const MAX_TURNS = 80;
export const MAX_TURN_TEXT = 4000;
export const MAX_TOTAL = 24_000;
export const MAX_SUMMARY = 600;
export const SUMMARY_TIMEOUT_MS = 15_000;
export const CRISIS_SUMMARY = "The user raised a safety concern in this session and was given the crisis referral.";

const SYSTEM =
  "Summarise this conversation for the assistant's short-term memory in at most three short sentences " +
  "(under 400 characters). Keep what the user said about themselves, their plans and open questions. " +
  "Mark guesses as tentative. No diagnosis, no advice, no directive words. " +
  'Reply with JSON only: {"summary":string,"topics":[up to 5 short strings]}.';

// Returns an error string or null.
export function validateSession(turns) {
  if (!Array.isArray(turns) || !turns.length || turns.length > MAX_TURNS) return `turns must be an array of 1 to ${MAX_TURNS}`;
  let total = 0;
  for (const t of turns) {
    if (!t || (t.role !== "user" && t.role !== "assistant")) return "turn role must be user or assistant";
    if (typeof t.text !== "string" || t.text.length > MAX_TURN_TEXT) return `turn text must be a string of at most ${MAX_TURN_TEXT}`;
    total += t.text.length;
  }
  return total > MAX_TOTAL ? `session text over ${MAX_TOTAL} characters` : null;
}

// The balanced {...} that opens at text[start], or null. Braces inside JSON strings are ignored.
function balancedAt(text, start) {
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
    } else if (c === '"') inStr = true;
    else if (c === "{") depth++;
    else if (c === "}" && !--depth) return text.slice(start, i + 1);
  }
  return null;
}

// First complete {...} in the text that is valid JSON (fences and prose braces before it are skipped), or undefined.
export function firstObject(text) {
  for (let i = text.indexOf("{"); i !== -1; i = text.indexOf("{", i + 1)) {
    const raw = balancedAt(text, i);
    if (!raw) continue;
    try {
      return JSON.parse(raw);
    } catch {}
  }
  return undefined;
}

// Strict shape: {summary: string, topics: string[]}. Anything else is null; the raw text is never used.
export function parseSummary(content) {
  const o = firstObject(String(content ?? ""));
  if (!o || typeof o !== "object" || Array.isArray(o) || typeof o.summary !== "string") return null;
  if (!Array.isArray(o.topics) || !o.topics.every((t) => typeof t === "string")) return null;
  return { summary: o.summary, topics: o.topics };
}

// Returns { summary, topics, safety, provider } (summary null when the gate replaced it).
export async function summarizeSession({ turns }, env, { fetchFn = fetch, callFn = callBrain, logger = console } = {}) {
  if (turns.some((t) => isCrisis(t.text))) return { summary: CRISIS_SUMMARY, topics: [], safety: "crisis", provider: null };
  const out = await callFn(
    [
      { role: "system", content: SYSTEM },
      { role: "user", content: JSON.stringify({ turns: turns.map((t) => ({ role: t.role, text: t.text })) }) },
    ],
    env,
    // 600 tokens: room for a reasoning model's preamble before the JSON (reasoning is off on the test path).
    { fetchFn, json: true, maxTokens: 600, timeoutMs: SUMMARY_TIMEOUT_MS, role: "summary" },
  );
  const o = parseSummary(out.content);
  // Fixed code only: the model text never reaches the log or the response.
  if (!o) logger.warn("summary_parse_failed");
  const summary = o ? o.summary.trim().slice(0, MAX_SUMMARY) : "";
  const topics = o ? o.topics.map((t) => t.slice(0, 40)).slice(0, 5) : [];
  if (!summary) return { summary: null, topics: [], safety: "empty", provider: out.provider };
  if (gateText(summary) !== summary || topics.some((t) => gateText(t) !== t)) {
    return { summary: null, topics: [], safety: "replaced", provider: out.provider };
  }
  return { summary, topics, safety: "passed", provider: out.provider };
}
