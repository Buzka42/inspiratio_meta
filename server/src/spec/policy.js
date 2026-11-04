import { validateSpecRequest } from "../assistants/contract.js";

// What a spec allows at request time. A null spec means today's env-only behaviour (everything the deploy allows),
// so callers that pass no spec keep working. Unknown values fail closed.

// skillId: a registry skill id (breathwork, sleep, diet, training, medical). Missing from the spec: off.
export function skillOn(spec, skillId) {
  if (!spec) return true;
  return Object.hasOwn(spec.skills ?? {}, skillId) && spec.skills[skillId] === true;
}

// Fixed topic phrase per spec skill: the whitelist the off-line is built from (no spec or user text reaches it).
const SKILL_TOPIC = Object.freeze({ breathwork: "breathwork", sleep: "sleep", diet: "diet", training: "training", medical: "medical", reading: "reading", habits: "habits", focus: "focus" });
// Content skill (plan.skill_id) -> the spec switch that governs it. Unlisted content skills have no switch.
const CONTENT_SWITCH = Object.freeze({ breathwork: "breathwork", wind_down_routine: "sleep", weight_training: "training", habit_building: "habits" });
export const contentSkillOn = (spec, contentId) => !Object.hasOwn(CONTENT_SWITCH, contentId) || skillOn(spec, CONTENT_SWITCH[contentId]);

// Data-only prompt line naming the skills the spec turns off. Null spec or nothing off: "" (prompt unchanged).
export function offSkillsLine(spec) {
  const off = spec ? Object.keys(SKILL_TOPIC).filter((id) => !skillOn(spec, id)).map((id) => SKILL_TOPIC[id]) : [];
  return off.length ? `Skills that are off: ${off.join(", ")}. Do not offer advice on these topics.` : "";
}

// Where memories may live, per memory.mode. "server" is the Worker store behind /memory/*, which serves the phone.
const MEMORY_WHERE = Object.freeze({ off: [], phone: ["phone", "server"], hermes: ["hermes"] });
export function memoryAllowed(spec, where) {
  if (!spec) return true;
  const mode = spec.memory?.mode;
  return Object.hasOwn(MEMORY_WHERE, mode) && MEMORY_WHERE[mode].includes(where);
}

// Memories, summaries, signals and findings may go to hosted models only after the user approved it.
export function hostedPersonalAllowed(spec) {
  return !spec || spec.data?.hosted_personal === "approved";
}

const minutes = (hhmm) => {
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(String(hhmm ?? ""));
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
};

// Inside the notification window, in the user's local time (UTC + tzMin minutes). from === to: all day.
export function inWindow(spec, nowMs, tzMin = 0) {
  const from = minutes(spec.notifications?.from);
  const to = minutes(spec.notifications?.to);
  if (from === null || to === null || !Number.isFinite(nowMs) || !Number.isFinite(tzMin)) return false;
  if (from === to) return true;
  const day = 24 * 60;
  const local = ((Math.floor(nowMs / 60000) + Math.trunc(tzMin)) % day + day) % day;
  return from < to ? local >= from && local < to : local >= from || local < to;
}

// Inbox kind -> notification type. "memory" items follow memory.mode instead; "digest" also needs proactivity.
const KIND_TYPE = Object.freeze({ message: "bot_reply", bot_reply: "bot_reply", reminder: "reminder", action_result: "action_result", digest: "digest" });

const CHANGE_ID = /^[0-9a-f]{32}$/;
// spec_proposal: the Worker already turned the bot's change into a pending diff at push time. It reaches
// the phone only with a live pending change; approval still goes through POST /spec/apply.
export function specProposalAllowed(item, spec, nowMs) {
  const p = item?.proposal;
  return Boolean(spec) && typeof p?.change_id === "string" && CHANGE_ID.test(p.change_id)
    && Number.isFinite(p?.expires_at) && p.expires_at > nowMs && typeof p?.readback === "string" && Array.isArray(p?.diff);
}

// spec_request (the user's words, relayed by the bot) needs a spec to change; the phone turns it into a card.
export function inboxAllowed(item, spec, nowMs, tzMin = 0) {
  const kind = item?.kind;
  if (kind === "spec_proposal") return specProposalAllowed(item, spec, nowMs);
  if (kind === "spec_request") return Boolean(spec) && validateSpecRequest(item).length === 0;
  if (!spec) return true;
  if (kind === "memory") return ["phone", "hermes"].includes(spec.memory?.mode);
  if (!Object.hasOwn(KIND_TYPE, kind)) return false;
  const type = KIND_TYPE[kind];
  if (spec.notifications?.types?.[type] !== true) return false;
  if (type === "digest" && spec.proactivity?.mode === "never") return false;
  return inWindow(spec, nowMs, tzMin);
}
