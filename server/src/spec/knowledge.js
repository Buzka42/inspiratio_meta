// Knowledge source records: one per approved knowledge_add. Vectorize holds the chunks (namespace = bank);
// the record keeps provenance. Input is untrusted (it may come from a bot), so every field is bounded.
import { BANK_IDS } from "../council/experts.js";

export const SOURCE_KEYS = Object.freeze(["title", "origin", "date", "text", "bank"]);
export const SOURCE_ID = /^src_[0-9a-f]{16}$/;
const LIMITS = { title: 120, origin: 200, text: 3200 };
const DATE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2}))?$/;
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;

const isPlain = (v) => v !== null && typeof v === "object" && [Object.prototype, null].includes(Object.getPrototypeOf(v));
const isoDate = (v) => typeof v === "string" && DATE.test(v) && !Number.isNaN(Date.parse(v));
const boundedText = (v, max, oneLine) =>
  typeof v === "string" && v.trim().length > 0 && v.length <= max && !CONTROL.test(v) && !(oneLine && /[\r\n]/.test(v));

export const randomHex = (bytes) => [...crypto.getRandomValues(new Uint8Array(bytes))]
  .map((b) => b.toString(16).padStart(2, "0")).join("");

// Refusals for a knowledge_add body, as [{path, reason}]. Keys are checked by the caller's key rules first.
export function sourceProblems(input, banks = BANK_IDS, at = "knowledge_add") {
  if (!isPlain(input)) return [{ path: at, reason: "bad_value" }];
  const out = [];
  for (const k of Object.keys(input)) if (!SOURCE_KEYS.includes(k)) out.push({ path: `${at}.${k}`, reason: "unknown_key" });
  if (!boundedText(input.title, LIMITS.title, true)) out.push({ path: `${at}.title`, reason: "bad_value" });
  if (!boundedText(input.origin, LIMITS.origin, true)) out.push({ path: `${at}.origin`, reason: "bad_value" });
  if (!isoDate(input.date)) out.push({ path: `${at}.date`, reason: "bad_value" });
  if (!boundedText(input.text, LIMITS.text, false)) out.push({ path: `${at}.text`, reason: "bad_value" });
  if (!banks.includes(input.bank)) out.push({ path: `${at}.bank`, reason: "unknown_bank" });
  return out;
}

// A stored record. Call only after sourceProblems returned [].
export function makeSource(input, { now = Date.now(), id = `src_${randomHex(8)}` } = {}) {
  const { title, origin, date, text, bank } = input;
  return { id, title, origin, date, text, bank, added_at: new Date(now).toISOString() };
}

// The listing shape: provenance without the text.
export const sourceIndex = ({ text, ...meta }) => meta;
