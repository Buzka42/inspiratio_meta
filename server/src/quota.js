// Per-device, per-UTC-day quotas on the costly routes.
// Counters sit behind the QuotaStore interface in quota-store.js:
// hit(key, day) -> count after this hit. The default, InMemoryQuotaStore, resets
// when the isolate restarts (soft limit). DurableObjectQuotaStore (used when the
// QUOTA_DO binding is present) keeps counts across restarts and isolates.
export {
  MemoryBacking, QuotaStore, InMemoryQuotaStore, DeviceQuotaCounter, DurableObjectQuotaStore,
} from "./quota-store.js";

export const ROUTE_BUCKETS = {
  "/turn": "turn",
  "/council": "council",
  "/analysis/21d": "council", // the analysis comment is a council run
  "/session/summary": "session",
  "/digest": "digest",
  "/digest/voice": "digest",
  "/reply": "reply",
  // Hermes bridge: every route that calls the owner's Hermes shares one bucket; the inbox poll has its own.
  "/assistant/message": "assistant",
  "/assistant/memory/write": "assistant",
  "/assistant/memory/recall": "assistant",
  "/assistant/action/propose": "assistant",
  "/assistant/action/confirm": "assistant",
  "/assistant/inbox": "inbox", // GET only; the HMAC push from Hermes is not device-metered
};

const LIMITS = {
  turn: { env: "QUOTA_TURNS_PER_DAY", fallback: 200 },
  council: { env: "QUOTA_COUNCIL_PER_DAY", fallback: 5 },
  digest: { env: "QUOTA_DIGESTS_PER_DAY", fallback: 20 },
  reply: { env: "QUOTA_REPLIES_PER_DAY", fallback: 200 },
  session: { env: "QUOTA_SESSION_SUMMARIES_PER_DAY", fallback: 10 },
  assistant: { env: "QUOTA_ASSISTANT_PER_DAY", fallback: 300 },
  inbox: { env: "QUOTA_INBOX_POLLS_PER_DAY", fallback: 2000 },
};

export function quotaLimit(bucket, env = {}) {
  const { env: name, fallback } = LIMITS[bucket];
  const n = Number(env[name]);
  return Number.isInteger(n) && n >= 0 ? n : fallback;
}

const DAY_MS = 86_400_000;
export const utcDay = (now) => new Date(now).toISOString().slice(0, 10);
const secondsToNextDay = (now) => Math.max(1, Math.ceil((DAY_MS - (now % DAY_MS)) / 1000));

// Returns null when the route has no quota or is under it,
// otherwise { bucket, limit, retry_after } (seconds until the next UTC day).
export async function checkQuota({ deviceId, pathname, env = {}, store, now = Date.now() }) {
  const bucket = ROUTE_BUCKETS[pathname];
  if (!bucket) return null;
  const limit = quotaLimit(bucket, env);
  const day = utcDay(now);
  const count = await store.hit(`${deviceId}:${bucket}`, day);
  return count > limit ? { bucket, limit, retry_after: secondsToNextDay(now) } : null;
}
