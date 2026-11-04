// P1: request-time policy from the spec. A null spec keeps today's env-only behaviour.
import { test } from "node:test";
import assert from "node:assert/strict";
import { hostedPersonalAllowed, inWindow, inboxAllowed, memoryAllowed, skillOn } from "../src/spec/policy.js";
import { DEFAULT_SPEC, applyChange } from "../src/spec/schema.js";

const spec = (spec_patch = {}) => applyChange(structuredClone(DEFAULT_SPEC), { spec_patch });
const at = (hh, mm = 0) => Date.UTC(2026, 10, 3, hh, mm);

test("policy: skillOn follows the spec and fails closed", () => {
  const s = spec();
  assert.equal(skillOn(s, "breathwork"), true);
  assert.equal(skillOn(s, "diet"), false);
  assert.equal(skillOn(s, "medical"), false);
  assert.equal(skillOn(s, "unknown"), false);
  assert.equal(skillOn(s, "__proto__"), false);
  assert.equal(skillOn(spec({ skills: { breathwork: false } }), "breathwork"), false);
  assert.equal(skillOn(null, "medical"), true, "no spec: env decides");
});

test("policy: memoryAllowed per mode", () => {
  const table = { off: [], phone: ["phone", "server"], hermes: ["hermes"] };
  for (const [mode, allowed] of Object.entries(table)) {
    for (const where of ["phone", "server", "hermes", "other"]) {
      assert.equal(memoryAllowed(spec({ memory: { mode } }), where), allowed.includes(where), `${mode}/${where}`);
    }
  }
  const broken = spec();
  broken.memory.mode = "constructor";
  assert.equal(memoryAllowed(broken, "phone"), false);
  assert.equal(memoryAllowed(null, "hermes"), true);
});

test("policy: hosted personal data only after approval", () => {
  assert.equal(hostedPersonalAllowed(spec()), false);
  assert.equal(hostedPersonalAllowed(spec({ data: { hosted_personal: "approved" } })), true);
  assert.equal(hostedPersonalAllowed(null), true);
});

test("policy: notification window in local time, including overnight and all-day", () => {
  const s = spec();
  assert.equal(inWindow(s, at(7, 59)), false);
  assert.equal(inWindow(s, at(8, 0)), true);
  assert.equal(inWindow(s, at(20, 59)), true);
  assert.equal(inWindow(s, at(21, 0)), false);
  assert.equal(inWindow(s, at(6, 30), 120), true, "UTC+2: 08:30 local");
  assert.equal(inWindow(s, at(9, 0), -120), false, "UTC-2: 07:00 local");
  assert.equal(inWindow(s, at(0, 30), -60), false, "wraps to the previous day: 23:30");
  const night = spec({ notifications: { from: "22:00", to: "06:00" } });
  assert.equal(inWindow(night, at(23)), true);
  assert.equal(inWindow(night, at(5)), true);
  assert.equal(inWindow(night, at(12)), false);
  assert.equal(inWindow(spec({ notifications: { from: "09:00", to: "09:00" } }), at(3)), true);
  assert.equal(inWindow(s, NaN), false);
});

test("policy: inboxAllowed by kind, type switch, proactivity, memory mode and window", () => {
  const s = spec();
  const noon = at(12);
  for (const kind of ["message", "bot_reply", "reminder", "action_result", "digest"]) assert.equal(inboxAllowed({ kind }, s, noon, 0), true, kind);
  assert.equal(inboxAllowed({ kind: "reminder" }, s, at(23), 0), false, "quiet hours");
  assert.equal(inboxAllowed({ kind: "reminder" }, spec({ notifications: { types: { reminder: false } } }), noon, 0), false);
  assert.equal(inboxAllowed({ kind: "message" }, spec({ notifications: { types: { bot_reply: false } } }), noon, 0), false);
  assert.equal(inboxAllowed({ kind: "digest" }, spec({ proactivity: { mode: "never" } }), noon, 0), false);
  assert.equal(inboxAllowed({ kind: "memory" }, s, at(23), 0), true, "memory items are silent data");
  assert.equal(inboxAllowed({ kind: "memory" }, spec({ memory: { mode: "off" } }), noon, 0), false);
  assert.equal(inboxAllowed({ kind: "memory" }, spec({ memory: { mode: "hermes" } }), noon, 0), true);
  for (const kind of ["other", "__proto__", "toString", undefined]) assert.equal(inboxAllowed({ kind }, s, noon, 0), false);
  assert.equal(inboxAllowed(null, s, noon, 0), false);
  assert.equal(inboxAllowed({ kind: "reminder" }, null, at(23), 0), true);
});
