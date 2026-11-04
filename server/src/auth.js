// Device auth. Token = `<deviceId>.<iat>.<exp>.<hmac>`; iat and exp are Unix seconds and
// hmac = base64url(HMAC-SHA256(secret, `<deviceId>.<iat>.<exp>`)), so editing the
// expiry breaks the signature. The secret is DEVICE_TOKEN_SECRET (a platform secret,
// never in the repo). Requires the Worker `nodejs_compat` flag for node:crypto.
import { createHmac, timingSafeEqual } from "node:crypto";
import { MemoryBacking } from "./quota-store.js";

export const DEVICE_ID = /^[A-Za-z0-9_-]{1,64}$/;
export const MIN_SECRET_LENGTH = 32;
export const DEFAULT_TTL_DAYS = 90;
// Tolerated clock difference between the issuer and the Worker.
export const CLOCK_SKEW_S = 60;
const STAMP = /^\d{1,12}$/;

function usableSecret(secret) {
  return typeof secret === "string" && secret.length >= MIN_SECRET_LENGTH;
}

function sign(payload, secret) {
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

// TOKEN_TTL_DAYS when it is a positive integer, otherwise 90.
export function tokenTtlDays(env = {}) {
  const n = Number(env.TOKEN_TTL_DAYS);
  return Number.isInteger(n) && n > 0 ? n : DEFAULT_TTL_DAYS;
}

// Pure for a given `now`. Throws on a bad device id, weak secret or bad ttl.
export function issueToken(deviceId, secret, { now = Date.now(), ttlDays = DEFAULT_TTL_DAYS } = {}) {
  if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) throw new Error("device id invalid");
  if (!usableSecret(secret)) throw new Error("secret too short");
  if (!Number.isInteger(ttlDays) || ttlDays <= 0) throw new Error("ttl invalid");
  const iat = Math.floor(now / 1000);
  const exp = iat + ttlDays * 86_400;
  const payload = `${deviceId}.${iat}.${exp}`;
  return `${payload}.${sign(payload, secret)}`;
}

// Pure. Returns { deviceId, iat, exp } or { code } with code token_invalid or
// token_expired. Time is checked only after the signature, so codes leak nothing
// to someone without a valid token. Never throws.
export function checkToken(token, secret, now = Date.now()) {
  const invalid = { code: "token_invalid" };
  if (!usableSecret(secret) || typeof token !== "string") return invalid;
  const parts = token.split(".");
  if (parts.length !== 4) return invalid;
  const [deviceId, iatText, expText, mac] = parts;
  if (!DEVICE_ID.test(deviceId) || !STAMP.test(iatText) || !STAMP.test(expText)) return invalid;
  const given = Buffer.from(mac, "utf8");
  const expected = Buffer.from(sign(`${deviceId}.${iatText}.${expText}`, secret), "utf8");
  // timingSafeEqual needs equal lengths; the length of an HMAC is not secret.
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return invalid;
  const iat = Number(iatText);
  const exp = Number(expText);
  const nowS = Math.floor(now / 1000);
  if (exp <= iat || iat > nowS + CLOCK_SKEW_S) return invalid;
  if (nowS >= exp) return { code: "token_expired" };
  return { deviceId, iat, exp };
}

// Device id for a valid, unexpired token, otherwise null.
export function verifyToken(token, secret, now = Date.now()) {
  return checkToken(token, secret, now).deviceId ?? null;
}

// Revocation list over the backing interface in quota-store.js (get/put/delete).
// The default MemoryBacking is per isolate and lost on restart; a Durable Object's
// storage keeps it.
export class RevocationList {
  constructor(backing = new MemoryBacking()) {
    this.backing = backing;
  }
  async isRevoked(deviceId) {
    return (await this.backing.get(`revoked:${deviceId}`)) === true;
  }
  async revoke(deviceId) {
    await this.backing.put(`revoked:${deviceId}`, true);
  }
}

// Script pair. env carries DEVICE_TOKEN_SECRET and optional TOKEN_TTL_DAYS
// (for example process.env). Neither function prints anything.
export function issueDeviceToken(deviceId, env = {}, now = Date.now()) {
  return issueToken(deviceId, env.DEVICE_TOKEN_SECRET, { now, ttlDays: tokenTtlDays(env) });
}
export async function revokeDevice(deviceId, revocations) {
  if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) throw new Error("device id invalid");
  await revocations.revoke(deviceId);
}

// Reads `Authorization: Bearer <token>`. Returns { deviceId } or { code };
// code is null when no bearer token was sent.
export async function authenticate(request, env = {}, { revocations, now = Date.now() } = {}) {
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer ([^\s]+)$/.exec(header);
  if (!match) return { code: null };
  const out = checkToken(match[1], env.DEVICE_TOKEN_SECRET, now);
  if (!out.deviceId) return out;
  if (revocations && (await revocations.isRevoked(out.deviceId))) return { code: "device_revoked" };
  return { deviceId: out.deviceId };
}
