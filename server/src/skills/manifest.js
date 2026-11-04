// Skill manifests (HANDOFF proposal 8): each skill declares what it may do, the Worker enforces the
// declaration, and the app shows it like phone permissions. A skill that acts outside its manifest is
// refused. Derived from the one registry (council/experts.js), so a skill cannot drift from its entry.
import { EXPERTS, SKILLS, BANK_IDS, skillOf } from "../council/experts.js";

const caps = (o) => Object.freeze({ model: false, memory_write: false, banks: Object.freeze([]), notifications: false, ...o, banks: Object.freeze([...(o.banks ?? [])]) });

// Non-council skills declare by hand; council skills derive from their experts (model + own banks).
const DECLARED = Object.freeze({
  reading: caps({ model: true, memory_write: true, banks: ["reading"] }),
  habits: caps({ model: false, memory_write: true, notifications: true }),
  focus: caps({ model: false, memory_write: true }),
});

function build() {
  const out = {};
  for (const e of EXPERTS) {
    const id = skillOf(e);
    const prev = out[id] ?? caps({ model: true });
    out[id] = caps({ model: true, banks: [...new Set([...prev.banks, e.bank])] });
  }
  for (const s of SKILLS) out[s.id] = DECLARED[s.id] ?? caps({});
  return Object.freeze(Object.fromEntries(Object.entries(out).map(([k, v]) => [k, Object.freeze(v)])));
}
export const SKILL_MANIFESTS = build();
export const manifestFor = (skillId) => SKILL_MANIFESTS[skillId] ?? null;

// Consistency: every registered skill has a manifest, every declared bank exists, shapes are boolean.
// Returns a list of problems (empty = valid). Run at startup in tests; a drift fails loudly.
export function validateManifests() {
  const problems = [];
  for (const [id, m] of Object.entries(SKILL_MANIFESTS)) {
    for (const k of ["model", "memory_write", "notifications"]) if (typeof m[k] !== "boolean") problems.push(`${id}.${k}`);
    for (const b of m.banks) if (!BANK_IDS.includes(b)) problems.push(`${id}.banks.${b}`);
  }
  for (const s of SKILLS) if (!SKILL_MANIFESTS[s.id]) problems.push(`${s.id} missing`);
  for (const e of EXPERTS) if (!SKILL_MANIFESTS[skillOf(e)]) problems.push(`${e.id} missing`);
  return problems;
}

// The permission line shown in a diff, fixed phrases only.
export function manifestLine(skillId) {
  const m = manifestFor(skillId);
  if (!m) return null;
  const parts = [m.model ? "uses a model" : "no model", m.memory_write ? "writes memory" : "no memory writes"];
  if (m.banks.length) parts.push(`reads ${m.banks.join(", ")}`);
  if (m.notifications) parts.push("may remind");
  return `${skillId}: ${parts.join("; ")}`;
}

// Enforcement point for skill routes: the action must be inside the manifest.
// action: "model" | "memory_write" | "notifications" | "run" (plain run needs no capability).
export function enforceManifest(skillId, action) {
  const m = manifestFor(skillId);
  if (!m) return { allowed: false, code: "unknown_skill" };
  if (action === "run") return { allowed: true };
  return m[action] === true ? { allowed: true } : { allowed: false, code: "capability_refused" };
}
