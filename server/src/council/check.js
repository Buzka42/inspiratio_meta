// Second-model cross-check of council points (HANDOFF proposals 3 + 10): after the council, a model
// from a different provider than the one that produced the points checks each point against the
// passage it cites and labels it supported, unsupported or contested. Unsupported points are dropped;
// contested ones are kept but flagged, so disagreement is shown rather than hidden.
// One batched checker call for the whole run. Sources are pinned by content hash at ingest time
// (passageHash), so a point is checked against exactly the text the expert saw.
// Pure apart from the injected checker call: labels come back as data and are re-validated here.
import { createHash } from "node:crypto";
import { jsonIn } from "./relay.js";
import { GATE_RULE_PROMPT } from "../safety.js";

export const CHECK_LABELS = Object.freeze(["supported", "unsupported", "contested"]);
export const CHECK_MAX_POINTS = 12;
export const passageHash = (text) => createHash("sha256").update(String(text ?? ""), "utf8").digest("hex");

// The provider order is meta, baseten, nebius: the checker takes the next one after the producer's,
// so the check is never the same provider grading its own work. Unknown producer: nebius (last resort).
export function checkerPrefer(producerProviders = []) {
  const order = ["meta", "baseten", "nebius"];
  const used = order.filter((p) => producerProviders.includes(p));
  return order.find((p) => !used.includes(p)) ?? "nebius";
}

export const CHECK_SYSTEM =
  "You check wellbeing council points against the passages they cite. For each point, decide whether " +
  "the cited passage text actually supports the claim: supported (the passage states it), unsupported " +
  "(the passage does not state it, or states something else), contested (the passage is ambiguous or " +
  "partly supports it). Judge only from the passage text given; use no outside knowledge. " +
  `${GATE_RULE_PROMPT} ` +
  'Reply with JSON only: {"checks":[{"point":point number,"label":"supported"|"unsupported"|"contested","quote":short exact quote from the passage or ""}]}.';

export function checkMessages(points) {
  return [
    { role: "system", content: CHECK_SYSTEM },
    {
      role: "user",
      content: JSON.stringify({
        points: points.map((p, i) => ({ point: i + 1, claim: p.text, passage: p.passage_text, passage_hash: p.passage_hash })),
      }),
    },
  ];
}

// Parses the checker reply into [{point (0-based), label, quote}] with only valid rows kept.
export function parseChecks(content, pointCount) {
  const o = jsonIn(content);
  const rows = Array.isArray(o?.checks) ? o.checks : [];
  const out = new Map();
  for (const r of rows) {
    const n = Number(r?.point);
    if (!Number.isInteger(n) || n < 1 || n > pointCount || !CHECK_LABELS.includes(r?.label)) continue;
    out.set(n - 1, { label: r.label, quote: typeof r.quote === "string" ? r.quote.slice(0, 200) : "" });
  }
  return out;
}

// points: [{text, source_ids, expert_id?}] with passages: Map<source_id, {text}>. callFn is a callBrain
// shape restricted to the checker's provider via prefer. Returns { kept, dropped, checks } where each
// check is { expert_id, label, source_id, passage_hash }. A checker failure keeps every point and
// reports code "check_unavailable": the cross-check may abstain, it may not take the answer down.
// timeoutMs and deadlineAt come from the run's budget (relay.js) and ride the checker call; no time left: abstain.
export async function crossCheck(points, passages, { callFn, producerProviders = [], env = {}, timeoutMs, deadlineAt, fetchFn } = {}) {
  const flat = [];
  for (const p of points ?? []) {
    for (const id of p.source_ids ?? []) {
      const passage = passages?.get?.(id);
      if (passage && flat.length < CHECK_MAX_POINTS) {
        flat.push({ text: p.text, expert_id: p.expert_id ?? null, source_id: id, passage_text: String(passage.text ?? "").slice(0, 1500), passage_hash: passageHash(passage.text), point: p });
      }
    }
  }
  if (!flat.length || typeof callFn !== "function") return { kept: points ?? [], dropped: [], checks: [], code: "no_points" };
  if (Number.isFinite(timeoutMs) && timeoutMs <= 0) return { kept: points ?? [], dropped: [], checks: [], code: "check_unavailable" };
  let labels;
  try {
    const budget = { ...(Number.isFinite(timeoutMs) && { timeoutMs }), ...(Number.isFinite(deadlineAt) && { deadlineAt }), ...(fetchFn && { fetchFn }) };
    const out = await callFn(checkMessages(flat), env, { json: true, maxTokens: 900, role: "check", prefer: checkerPrefer(producerProviders), ...budget });
    labels = parseChecks(out?.content, flat.length);
  } catch {
    return { kept: points ?? [], dropped: [], checks: [], code: "check_unavailable" };
  }
  if (!labels.size) return { kept: points ?? [], dropped: [], checks: [], code: "check_unavailable" };
  const checks = flat.map((f, i) => ({ expert_id: f.expert_id, source_id: f.source_id, passage_hash: f.passage_hash, label: labels.get(i)?.label ?? "contested" }));
  // A point survives when at least one of its citations is not unsupported; contested is kept and flagged.
  const droppedPoints = new Set();
  const byPoint = new Map();
  flat.forEach((f, i) => {
    if (!byPoint.has(f.point)) byPoint.set(f.point, []);
    byPoint.get(f.point).push(checks[i].label);
  });
  for (const [point, ls] of byPoint) if (ls.every((l) => l === "unsupported")) droppedPoints.add(point);
  const kept = (points ?? []).filter((p) => !droppedPoints.has(p));
  const dropped = (points ?? []).filter((p) => droppedPoints.has(p));
  for (const p of kept) {
    const ls = byPoint.get(p) ?? [];
    if (ls.includes("contested")) p.contested = true;
  }
  return { kept, dropped, checks, code: null };
}

// The flag: COUNCIL_CROSSCHECK=on enables the checker. Anything else is off (latency and cost stay opt-in).
export const crossCheckOn = (env = {}) => String(env?.COUNCIL_CROSSCHECK ?? "").trim().toLowerCase() === "on";
