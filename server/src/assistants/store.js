// Assistant state for one device: the inbox pushed by Hermes, the inbox nonce log, and pending actions
// awaiting the spoken yes. AssistantState is the body of the AssistantInbox Durable Object (src/worker.js,
// binding ASSISTANT_DO, one object per device id); it is runtime-free so node tests drive it over a fake
// storage with the async get/put subset of ctx.storage. Calls are serialised inside the object, so each
// get-then-put is atomic.
//
// Records: "inbox" {seq, items:[{id, kind, text, ts, received_at}]}, "nonces" {nonce: ts},
// "pending" {action_id: {action, action_hash, expires_at}}. All times are unix seconds.
import { NONCE_TTL_SECONDS } from "./contract.js";

export const INBOX_MAX_ITEMS = 200;
export const TAKE_MAX = 20;
export const PENDING_TTL_SECONDS = 60;
export const PENDING_MAX = 10;
const ACTION_ID = /^act_[0-9a-f]{32}$/;

export class AssistantState {
  constructor(storage) {
    this.storage = storage;
    this.tail = Promise.resolve();
  }
  #serial(fn) {
    const run = this.tail.then(fn);
    this.tail = run.catch(() => {});
    return run;
  }

  // Stores a verified item unless its nonce was seen in the last 600 s. Returns {ok, id} or {code}.
  push(item, nowS) {
    return this.#serial(async () => {
      const nonces = Object.fromEntries(
        Object.entries((await this.storage.get("nonces")) ?? {}).filter(([, t]) => nowS - t <= NONCE_TTL_SECONDS),
      );
      if (nonces[item.nonce] !== undefined) return { code: "replay" };
      const inbox = (await this.storage.get("inbox")) ?? { seq: 0, items: [] };
      if (inbox.items.length >= INBOX_MAX_ITEMS) return { code: "inbox_full" };
      const id = inbox.seq + 1;
      nonces[item.nonce] = nowS;
      await this.storage.put("nonces", nonces);
      // proposal (spec_proposal only): the Worker's own pending change for this item (change_id, diff,
      // readback, expires_at), built at push time. Bot text is never stored for that kind.
      const proposal = item.kind === "spec_proposal" && item.proposal ? { proposal: item.proposal } : {};
      await this.storage.put("inbox", { seq: id, items: [...inbox.items, { id, kind: item.kind, text: item.text, ts: item.ts, received_at: nowS, ...proposal }] });
      return { ok: true, id };
    });
  }

  // Returns the oldest items in arrival order and removes them (read is the ack).
  take(limit = TAKE_MAX) {
    return this.#serial(async () => {
      const inbox = (await this.storage.get("inbox")) ?? { seq: 0, items: [] };
      const n = Math.max(1, Math.min(TAKE_MAX, Number.isInteger(limit) ? limit : TAKE_MAX));
      const items = inbox.items.slice(0, n);
      if (items.length) await this.storage.put("inbox", { seq: inbox.seq, items: inbox.items.slice(n) });
      return { items, more: inbox.items.length > n };
    });
  }

  // Stores a proposed action for 60 s. Keeps at most PENDING_MAX (oldest dropped).
  propose(actionId, action, hash, nowS) {
    return this.#serial(async () => {
      if (!ACTION_ID.test(actionId)) throw new Error("action id invalid");
      const live = Object.entries((await this.storage.get("pending")) ?? {})
        .filter(([, p]) => p.expires_at > nowS)
        .slice(-(PENDING_MAX - 1));
      const pending = Object.fromEntries([...live, [actionId, { action, action_hash: hash, expires_at: nowS + PENDING_TTL_SECONDS }]]);
      await this.storage.put("pending", pending);
      return { expires_at: nowS + PENDING_TTL_SECONDS };
    });
  }

  // Single use: the entry is removed whatever the outcome. Returns {action, action_hash} or {code}
  // with action_unknown (never proposed, or already used) or action_expired.
  claim(actionId, nowS) {
    return this.#serial(async () => {
      const pending = (await this.storage.get("pending")) ?? {};
      const hit = Object.hasOwn(pending, actionId) ? pending[actionId] : undefined;
      if (!hit) return { code: "action_unknown" };
      delete pending[actionId];
      await this.storage.put("pending", pending);
      if (hit.expires_at <= nowS) return { code: "action_expired" };
      return { action: hit.action, action_hash: hit.action_hash };
    });
  }
}

// Worker-side adapter: RPC to the device's object.
export function assistantStub(namespace, deviceId) {
  if (!namespace?.idFromName) throw new Error("durable object namespace missing");
  return namespace.get(namespace.idFromName(deviceId));
}
