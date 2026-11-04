// Cloudflare entry (wrangler.jsonc "main"). Only this file imports the runtime
// module "cloudflare:workers", so src/index.js and the tests run under plain node.
import { DurableObject } from "cloudflare:workers";
import worker from "./index.js";
import { DeviceQuotaCounter } from "./quota-store.js";
import { AssistantState } from "./assistants/store.js";
import { SpecState } from "./spec/store.js";
import { SPEC_REGISTRY } from "./spec/routes.js";
import { PairingState } from "./pairing.js";
import { createBotBackend } from "./bot/backend.js";
import { callBrain } from "./council/provider.js";

const MIRROR_KEY = "spec:mirror";
const MIRROR_STATES = ["synced", "pending", "off"];
// The only keys the skill routes may read or write (src/skills/routes.js).
export const SKILL_KEYS = Object.freeze(["habits:list", "habits:checkins", "habits:due", "read:pos", "read:notes", "read:open_q", "focus:session", "focus:log"]);

// Binding QUOTA_DO, one object per device id. Counters in this.ctx.storage.
export class QuotaCounter extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.counter = new DeviceQuotaCounter(ctx.storage);
  }
  // RPC from DurableObjectQuotaStore. Returns the count after this hit.
  async hit(key, day) {
    return this.counter.hit(key, day);
  }
}

// Binding ASSISTANT_DO, one object per device id: the Hermes inbox (with its nonce log), pending
// actions awaiting the spoken yes, the user's spec with its knowledge sources (src/spec/store.js,
// "spec:" keys), and the reading and habits records (SKILL_KEYS). Bodies in src/assistants/store.js and src/spec/store.js.
export class AssistantInbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.state = new AssistantState(ctx.storage);
    this.specTail = Promise.resolve();
  }
  // Skills and banks come from the one registry list, so skills added there are allowed here too.
  #spec(nowMs) {
    const now = Number.isFinite(nowMs) ? () => nowMs : () => Date.now();
    return new SpecState(this.ctx.storage, { now, ...SPEC_REGISTRY });
  }
  // Propose and apply run one at a time: each is a read-then-write over several keys.
  #serial(fn) {
    const run = this.specTail.then(fn);
    this.specTail = run.catch(() => {});
    return run;
  }
  async specGet() {
    return { spec: await this.#spec().get(), mirror: (await this.ctx.storage.get(MIRROR_KEY)) ?? "off" };
  }
  async specPropose(change, nowMs, via) {
    return this.#serial(() => this.#spec(nowMs).propose(change, { via }));
  }
  async specApply(changeId, nowMs) {
    return this.#serial(() => this.#spec(nowMs).apply(changeId));
  }
  async specHistory() {
    return this.#spec().history();
  }
  async specRevert(version, nowMs) {
    return this.#serial(() => this.#spec(nowMs).proposeRevert(version));
  }
  async specMirror(state) {
    if (MIRROR_STATES.includes(state)) await this.ctx.storage.put(MIRROR_KEY, state);
  }
  async sources() {
    return this.#spec().sources();
  }
  async skillGet(key) {
    return SKILL_KEYS.includes(key) ? this.ctx.storage.get(key) : undefined;
  }
  async skillPut(key, value) {
    if (!SKILL_KEYS.includes(key)) throw new Error("skill key");
    await this.ctx.storage.put(key, value);
  }
  // Pairing (src/pairing.js): only the "pairing:global" object uses these; other instances just hold
  // an unused record slot. One bot per Worker is enforced by that singleton plus the single record.
  // One PairingState per object, so its serial queue orders every pairing call; codes are HMACs under DEVICE_TOKEN_SECRET.
  #pairing = null;
  #pair() {
    return (this.#pairing ??= new PairingState(this.ctx.storage, { secret: this.env?.DEVICE_TOKEN_SECRET }));
  }
  async pairCreate(deviceId, nowMs) {
    return this.#pair().createCode(deviceId, nowMs);
  }
  async pairClaim(claim, nowMs) {
    return this.#pair().claim(claim, nowMs);
  }
  async pairStatus(deviceId, nowMs) {
    return this.#pair().status(deviceId, nowMs);
  }
  async pairDeliver(deviceId) {
    return this.#pair().deliver(deviceId);
  }
  async pairRevoke(deviceId) {
    return this.#pair().revoke(deviceId);
  }
  // Worker-hosted Muse bot backend (src/bot/backend.js): only the "bot:global" object uses this.
  // It holds the setup, the spec mirror and bot memory in this object's storage; Muse calls go
  // through callBrain, so DATA_MODE and the provider order apply exactly as for the council.
  async botDispatch(op, input, requestId) {
    const handle = createBotBackend({
      storage: this.ctx.storage,
      secret: this.env.ILLUNIS_INBOX_SECRET,
      env: this.env,
      brain: (messages, env, opts) => callBrain(messages, env, opts),
    });
    return handle(op, input, requestId);
  }
  async push(item, nowS) {
    return this.state.push(item, nowS);
  }
  async take(limit) {
    return this.state.take(limit);
  }
  async propose(actionId, action, hash, nowS) {
    return this.state.propose(actionId, action, hash, nowS);
  }
  async claim(actionId, nowS) {
    return this.state.claim(actionId, nowS);
  }
}

export default worker;
