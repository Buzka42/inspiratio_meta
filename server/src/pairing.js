// Pairing a phone to a bot (HANDOFF: PLANNED -> BUILT). One bot per Worker.
// Flow: the phone (device token) asks for a short-lived code; the user reads the code to the bot;
// the bot makes an HMAC-signed claim; the phone polls and receives its credential exactly once.
// The bot never sees the credential. Unpairing clears the link only: no data wiped, no token revoked.
// Pure class over injected storage ({get,put,delete}, DO shape) so node tests drive it directly.
// Codes are stored only as an HMAC under DEVICE_TOKEN_SECRET (domain-separated). Every digest compare is constant-time.
import { timingSafeEqual } from "node:crypto";
import { canonicalJson, hmacHex, usableSecret } from "./assistants/contract.js";
import { DEVICE_ID } from "./auth.js";

export const PAIR_CODE_TTL_SECONDS = 600;
export const PAIR_MAX_ATTEMPTS = 5;
export const PAIR_CODES_PER_WINDOW = 3;
export const PAIR_WINDOW_SECONDS = 600;
export const PAIR_DOMAIN = "illunis-pair-v1";
export const PAIR_SOURCE = "hermes:illunis";
export const PAIR_GLOBAL_NAME = "pairing:global"; // the one ASSISTANT_DO object holding the link
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O, 1/I
export const PAIR_CODE = /^[A-HJ-NP-Z2-9]{8}$/;
const BOT_ID = /^[A-Za-z0-9][A-Za-z0-9_:\/-]{0,63}$/;
const KEY = "pair:record";
const rateKey = (deviceId) => `pair:codes:${deviceId}`; // per device

export const pairCodeHash = (secret, code) => {
  if (!usableSecret(secret)) throw new Error("pair secret missing");
  return hmacHex(secret, `illunis-pair-code-v1\n${String(code ?? "")}`);
};
const hexEq = (a, b) => {
  const x = Buffer.from(String(a ?? ""), "utf8");
  const y = Buffer.from(String(b ?? ""), "utf8");
  return x.length === y.length && timingSafeEqual(x, y);
};
export const randomPairCode = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return [...bytes].map((b) => ALPHABET[b % ALPHABET.length]).join("");
};

// Claim signature: hex(HMAC(secret, "illunis-pair-v1\n" + canonicalJson({bot_id, code, ts}))).
export const pairClaimMessage = ({ bot_id, code, ts }) => `${PAIR_DOMAIN}\n${canonicalJson({ bot_id, code, ts })}`;
export const signPairClaim = (secret, claim) => hmacHex(secret, pairClaimMessage(claim));
export function verifyPairClaim(secret, claim, sig, nowS) {
  if (!claim || typeof claim !== "object") return { code: "bad_claim" };
  const { bot_id, code, ts } = claim;
  if (typeof bot_id !== "string" || !BOT_ID.test(bot_id)) return { code: "bad_claim" };
  if (typeof code !== "string" || !PAIR_CODE.test(code)) return { code: "bad_claim" };
  if (!Number.isInteger(ts) || Math.abs(nowS - ts) > 300) return { code: "bad_claim" };
  if (!hexEq(String(sig ?? "").toLowerCase(), signPairClaim(secret, claim))) return { code: "bad_signature" };
  return { claim: { bot_id, code, ts } };
}

export class PairingState {
  // secret: DEVICE_TOKEN_SECRET. Methods take an optional nowMs so one instance serves every call.
  constructor(storage, { now = () => Date.now(), codeFn = randomPairCode, secret } = {}) {
    this.storage = storage;
    this.now = now;
    this.codeFn = codeFn;
    this.secret = secret;
    this.tail = Promise.resolve();
  }
  #serial(fn) {
    const run = this.tail.then(fn);
    this.tail = run.catch(() => {});
    return run;
  }
  #nowS(nowMs) { return Math.floor((Number.isFinite(nowMs) ? nowMs : this.now()) / 1000); }

  // Issues a fresh code for deviceId. A new code replaces any pending one. Refused once paired.
  createCode(deviceId, nowMs) {
    return this.#serial(async () => {
      if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) return { code: "bad_device" };
      const nowS = this.#nowS(nowMs);
      const rec = await this.storage.get(KEY);
      if (rec?.bot_id) return { code: "already_paired" };
      const recent = ((await this.storage.get(rateKey(deviceId))) ?? []).filter((t) => nowS - t < PAIR_WINDOW_SECONDS);
      if (recent.length >= PAIR_CODES_PER_WINDOW) return { code: "rate_limited" };
      const code = this.codeFn();
      const expires_at = nowS + PAIR_CODE_TTL_SECONDS;
      await this.storage.put(KEY, { code_hash: pairCodeHash(this.secret, code), device_id: deviceId, expires_at, attempts: 0, bot_id: null, claimed_at: null, delivered: false });
      await this.storage.put(rateKey(deviceId), [...recent, nowS]);
      return { pair_code: code, expires_at };
    });
  }

  // The bot's signed claim. Single use: success consumes the code. Wrong codes burn attempts.
  claim({ code, bot_id } = {}, nowMs) {
    return this.#serial(async () => {
      const nowS = this.#nowS(nowMs);
      const rec = await this.storage.get(KEY);
      if (!rec || rec.bot_id) return { code: "no_pending" };
      if (rec.expires_at <= nowS) { await this.storage.delete(KEY); return { code: "pair_expired" }; }
      if (rec.attempts >= PAIR_MAX_ATTEMPTS) { await this.storage.delete(KEY); return { code: "pair_burned" }; }
      if (!hexEq(pairCodeHash(this.secret, code), rec.code_hash)) {
        await this.storage.put(KEY, { ...rec, attempts: rec.attempts + 1 });
        return { code: "pair_mismatch" };
      }
      const next = { ...rec, code_hash: null, bot_id, claimed_at: nowS };
      await this.storage.put(KEY, next);
      return { ok: true, device_id: rec.device_id, bot_id };
    });
  }

  // Phone poll. The credential is released exactly once, by deliver(); status leaks neither code nor bot secret.
  status(deviceId, nowMs) {
    return this.#serial(async () => {
      const rec = await this.storage.get(KEY);
      if (!rec) return { status: "unpaired" };
      if (rec.device_id !== deviceId) return { status: "waiting" };
      if (!rec.bot_id) return { status: this.#nowS(nowMs) >= rec.expires_at ? "expired" : "waiting", expires_at: rec.expires_at };
      return { status: "paired", bot_id: rec.bot_id, claimed_at: rec.claimed_at, delivered: rec.delivered === true };
    });
  }

  // Marks the one-time credential release. Returns false when nothing new may be handed out.
  deliver(deviceId) {
    return this.#serial(async () => {
      const rec = await this.storage.get(KEY);
      if (!rec?.bot_id || rec.device_id !== deviceId || rec.delivered) return { ok: false };
      await this.storage.put(KEY, { ...rec, delivered: true });
      return { ok: true, bot_id: rec.bot_id };
    });
  }

  // Unpairing clears the link only: the phone's device token stays valid, so it can pair again.
  // Spec, memory and skill data in the same object are untouched.
  revoke(deviceId) {
    return this.#serial(async () => {
      const rec = await this.storage.get(KEY);
      if (!rec || rec.device_id !== deviceId) return { ok: false };
      await this.storage.delete(KEY); // the code-issue rate window is kept, so revoke cannot reset it
      return { ok: true, bot_id: rec.bot_id ?? null };
    });
  }
}

export const pairingStub = (namespace) => {
  if (!namespace?.idFromName) throw new Error("durable object namespace missing");
  return namespace.get(namespace.idFromName(PAIR_GLOBAL_NAME));
};
