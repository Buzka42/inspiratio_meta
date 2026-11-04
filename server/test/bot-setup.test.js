// Bot setup message, stateless envelope, policy proxy (src/bot/). Synthetic data only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  buildEnvelope, renderSetupMd, signEnvelope, signReceipt, signSetup, setupHash,
  verifyEnvelope, verifySetupReceipt, verifySetupSig,
} from "../src/bot/setup.js";
import { proxyBotOutput, proxySkill } from "../src/bot/policy.js";
import { specHash, validateInput, validateReply } from "../src/assistants/contract.js";
import { DEFAULT_SPEC, renderSpecMd } from "../src/spec/schema.js";
import { REFERRAL_TEXT } from "../src/safety.js";

const SECRET = "s".repeat(40);
const SPEC = { ...structuredClone(DEFAULT_SPEC), version: 7, guidelines: "Be brief.", skills: { ...DEFAULT_SPEC.skills, diet: true } };

test("setup: golden render is deterministic, guardrails first, signature pins the bytes", () => {
  const md = renderSetupMd(SPEC);
  assert.equal(md, renderSetupMd(structuredClone(SPEC)), "same spec, same bytes");
  assert.ok(md.startsWith("# Illunis bot setup (spec version 7)"));
  assert.ok(md.indexOf("## Guardrails") < md.indexOf("## Trust rules"));
  assert.ok(md.indexOf("## Trust rules") < md.indexOf("## Behaviour spec"));
  assert.ok(md.includes("Be brief."));
  const sig = signSetup(SECRET, 7, md);
  assert.equal(verifySetupSig(SECRET, 7, md, sig), true);
  assert.equal(verifySetupSig(SECRET, 7, `${md} `, sig), false, "one trailing space breaks it");
  assert.equal(verifySetupSig(SECRET, 8, md, sig), false);
  // Golden hash: any wording change in the fixed phrases must show up here on purpose.
  assert.equal(setupHash(md), createHash("sha256").update(md, "utf8").digest("hex"));
});

test("setup: receipt verifies only over the hashes the bot read back", () => {
  const md = renderSetupMd(SPEC);
  const receipt = { version: 7, setup_hash: setupHash(md), spec_hash: specHash(renderSpecMd(SPEC)) };
  receipt.sig = signReceipt(SECRET, receipt);
  assert.deepEqual(verifySetupReceipt(SECRET, receipt, { version: 7, setupMd: md }), { ok: true });
  assert.equal(verifySetupReceipt(SECRET, { ...receipt, setup_hash: "a".repeat(64) }, { version: 7, setupMd: md }).code, "receipt_setup_hash");
  assert.equal(verifySetupReceipt(SECRET, { ...receipt, version: 6 }, { version: 7, setupMd: md }).code, "receipt_version");
  assert.equal(verifySetupReceipt(SECRET, { ...receipt, sig: "b".repeat(64) }, { version: 7, setupMd: md }).code, "receipt_signature");
  assert.equal(verifySetupReceipt(SECRET, { ...receipt, prose: "looks good" }, { version: 7, setupMd: md }).code, "bad_receipt");
});

test("setup: contract shapes accept setup_apply and refuse loose receipts", () => {
  const md = renderSetupMd(SPEC);
  assert.deepEqual(validateInput("setup_apply", { version: 7, setup_md: md, sig: signSetup(SECRET, 7, md) }), []);
  assert.ok(validateInput("setup_apply", { version: 7, setup_md: md }).length);
  const receipt = { version: 7, setup_hash: setupHash(md), spec_hash: specHash(renderSpecMd(SPEC)) };
  receipt.sig = signReceipt(SECRET, receipt);
  const reply = { illunis: 1, op: "setup_apply", request_id: "req_12345678", ok: true, result: receipt };
  assert.deepEqual(validateReply(reply, { op: "setup_apply", requestId: "req_12345678" }), []);
  assert.ok(validateReply({ ...reply, result: { ...receipt, note: "done" } }).length);
});

test("envelope: full signed spec plus bounded memory slice; tampering refused", () => {
  const items = Array.from({ length: 60 }, (_, i) => ({ id: `${i}`, kind: "note", text: `note ${i}`, confidence: 0.5, created_at: "2026-11-01", expires_at: null, extra: "dropped" }));
  const env = buildEnvelope(SPEC, items);
  assert.equal(env.memory.length, 50);
  assert.ok(!("extra" in env.memory[0]));
  const sig = signEnvelope(SECRET, env);
  assert.equal(verifyEnvelope(SECRET, env, sig).envelope.spec_version, 7);
  const tampered = structuredClone(env);
  tampered.spec.skills.medical = true;
  assert.equal(verifyEnvelope(SECRET, tampered, sig).code, "envelope_signature");
  assert.equal(verifyEnvelope(SECRET, { ...env, memory: Array(51).fill(env.memory[0]) }, sig).code, "bad_envelope");
});

test("proxy: bot text is gated whatever the bot believes; pushes obey the spec", () => {
  const spec = structuredClone(DEFAULT_SPEC);
  assert.deepEqual(proxyBotOutput({ kind: "message", text: "A calm evening helps." }, spec), { allowed: true, text: "A calm evening helps.", safety: "passed", reasons: [] });
  const bad = proxyBotOutput({ kind: "message", text: "You must take this dose, you have depression." }, spec);
  assert.deepEqual([bad.allowed, bad.text, bad.safety], [true, REFERRAL_TEXT, "replaced"]);
  assert.equal(proxyBotOutput({ kind: "command", text: "hi" }, spec).allowed, false);

  // Notifications off for reminders in the spec: the push is withheld even though the text is clean.
  const quiet = structuredClone(spec);
  quiet.notifications.types.reminder = false;
  assert.equal(proxyBotOutput({ kind: "reminder", text: "Time for a walk." }, quiet, { nowMs: Date.parse("2026-11-03T12:00:00Z") }).allowed, false);
  assert.equal(proxyBotOutput({ kind: "reminder", text: "Time for a walk." }, spec, { nowMs: Date.parse("2026-11-03T12:00:00Z") }).allowed, true);

  // Memory pushes follow memory.mode, not the bot's belief.
  const off = structuredClone(spec);
  off.memory.mode = "off";
  assert.equal(proxyBotOutput({ kind: "memory", text: "a note" }, off).allowed, false);
  assert.equal(proxyBotOutput({ kind: "memory", text: "a note" }, spec).allowed, true);

  assert.equal(proxySkill(spec, "diet").allowed, false, "diet off in DEFAULT_SPEC");
  assert.equal(proxySkill(spec, "sleep").allowed, true);
});
