// Policy proxy on all bot output (HANDOFF proposal 4): every bot reply and push passes the Worker's
// spec gates before the phone sees it, whatever the bot believes its settings are. Enforcement never
// depends on the bot reading SETUP.md correctly. Pure: fixed codes and fixed replacement text only.
import { REFERRAL_TEXT, gateViolation } from "../safety.js";
import { inboxAllowed, memoryAllowed, skillOn } from "../spec/policy.js";

export const PROXY_KINDS = Object.freeze(["message", "bot_reply", "reminder", "action_result", "memory", "digest"]);

// Kinds that speak to the user get the text gate; memory items are data and are checked by mode only.
// Returns { allowed, text, safety, reasons }: safety is "passed" | "replaced" | "withheld".
// A withheld item has no text: the phone never sees it.
export function proxyBotOutput({ kind, text } = {}, spec, { nowMs = Date.now(), tzMin = 0 } = {}) {
  const reasons = [];
  if (!PROXY_KINDS.includes(kind)) return { allowed: false, text: null, safety: "withheld", reasons: ["bad_kind"] };
  if (kind === "memory") {
    const ok = memoryAllowed(spec, "hermes") || memoryAllowed(spec, "server");
    return ok ? { allowed: true, text, safety: "passed", reasons } : { allowed: false, text: null, safety: "withheld", reasons: ["memory_mode"] };
  }
  // Push kinds also obey the spec's notification rules (type switches, window, proactivity).
  if (kind !== "message" && spec && !inboxAllowed({ kind, text }, spec, nowMs, tzMin)) {
    return { allowed: false, text: null, safety: "withheld", reasons: ["notifications"] };
  }
  if (typeof text !== "string" || !text.trim()) return { allowed: false, text: null, safety: "withheld", reasons: ["empty"] };
  // Same replacement the phone already speaks for gated bot text (safety.js gateText).
  const violation = gateViolation(text);
  if (violation) return { allowed: true, text: REFERRAL_TEXT, safety: "replaced", reasons: [violation] };
  return { allowed: true, text, safety: "passed", reasons };
}

// A bot may only speak for a skill the spec leaves on. kind "message" carries the skill it serves.
export function proxySkill(spec, skillId) {
  return skillOn(spec, skillId) ? { allowed: true, reasons: [] } : { allowed: false, reasons: ["skill_off"] };
}
