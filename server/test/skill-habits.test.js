import test from "node:test";
import assert from "node:assert/strict";
import { habitAdd, habitList, habitPause, habitResume, habitDelete, checkIn, reminderDue, streak } from "../src/skills/habits.js";

const mem = () => { const m = new Map(); return { get: async (k) => m.get(k), set: async (k, v) => void m.set(k, structuredClone(v)) }; };
const NOW = Date.parse("2026-11-04T09:00:00Z"); // Wednesday
const spec = (over = {}) => ({
  skills: { habits: true }, memory: { mode: "phone" }, proactivity: { mode: "normal" },
  notifications: { from: "08:00", to: "22:00", types: { reminder: true } }, ...over,
});
const base = { name: "write 200 words", cadence: "daily", reminder_time: "09:00", timezone: "UTC" };
const add = async (s, o = {}) => (await habitAdd(s, spec(), { ...base, ...o }, NOW)).habit;

test("add validates input", async () => {
  const s = mem();
  assert.equal((await habitAdd(s, spec(), base, NOW)).ok, true);
  for (const [o, code] of [[{ name: "" }, "bad_name"], [{ name: "x".repeat(61) }, "bad_name"], [{ cadence: "hourly" }, "bad_cadence"],
    [{ reminder_time: "25:00" }, "bad_time"], [{ timezone: "Nope/Nowhere" }, "bad_timezone"], [{ timezone: "../etc" }, "bad_timezone"]]) {
    assert.equal((await habitAdd(s, spec(), { ...base, ...o }, NOW)).code, code);
  }
  assert.equal((await habitAdd(s, spec(), { ...base, timezone: -300 }, NOW)).ok, true);
});

test("list computes streak and week count", async () => {
  const s = mem(); const h = await add(s);
  for (const d of ["2026-11-02", "2026-11-03", "2026-11-04"]) await checkIn(s, spec(), h.id, d, d === "2026-11-02" ? Date.parse("2026-11-02T10:00:00Z") : d === "2026-11-03" ? Date.parse("2026-11-03T10:00:00Z") : NOW);
  const [x] = (await habitList(s, spec(), NOW)).habits;
  assert.equal(x.streak, 3); assert.equal(x.week, 3); assert.equal(x.status, "active");
  assert.equal(streak("daily", ["2026-11-02", "2026-11-03"], "2026-11-04"), 2); // ends yesterday
  assert.equal(streak("daily", ["2026-11-01"], "2026-11-04"), 0);
  assert.equal(streak("weekdays", ["2026-10-30", "2026-11-02"], "2026-11-03"), 2); // skips weekend
});

test("check-in date rules", async () => {
  const s = mem(); const h = await add(s);
  assert.equal((await checkIn(s, spec(), h.id, "2026-11-05", NOW)).code, "date_out_of_range");
  assert.equal((await checkIn(s, spec(), h.id, "2026-11-02", NOW)).code, "date_out_of_range");
  assert.equal((await checkIn(s, spec(), h.id, "garbage", NOW)).code, "bad_date");
  assert.equal((await checkIn(s, spec(), h.id, "2026-11-03", NOW)).recorded, true);
  assert.equal((await checkIn(s, spec(), h.id, "2026-11-03", NOW)).recorded, false);
  assert.equal((await s.get("habits:checkins"))[h.id].length, 1);
  assert.equal((await checkIn(s, spec(), "nope", "2026-11-04", NOW)).code, "not_found");
});

test("timezone decides today", async () => {
  const s = mem(); const h = await add(s, { timezone: "Pacific/Auckland" }); // UTC+13: Nov 5 locally
  assert.equal((await checkIn(s, spec(), h.id, "2026-11-05", NOW + 4 * 3600000)).recorded, true);
});

test("reminders: due, pause, resume, delete", async () => {
  const s = mem(); const h = await add(s);
  assert.deepEqual((await reminderDue(s, spec(), NOW)).due, [{ id: h.id, text: "Time for: write 200 words." }]);
  assert.equal((await reminderDue(s, spec(), NOW + 3600000)).due.length, 0);
  await habitPause(s, spec(), h.id);
  assert.equal((await reminderDue(s, spec(), NOW)).due.length, 0);
  await habitResume(s, spec(), h.id);
  assert.equal((await reminderDue(s, spec(), NOW + 86400000)).due.length, 1, "next day");
  await habitDelete(s, spec(), h.id);
  assert.equal((await habitList(s, spec(), NOW)).habits.length, 0);
});

test("reminders: due within 30 minutes of the time, once per local day", async () => {
  const s = mem(); const h = await add(s);
  const min = 60000;
  assert.equal((await reminderDue(s, spec(), NOW - min)).due.length, 0, "before the time");
  assert.equal((await reminderDue(s, spec(), NOW + 29 * min)).due.length, 1, "29 minutes late");
  assert.equal((await reminderDue(s, spec(), NOW + 5 * min)).due.length, 0, "already reported today");
  assert.deepEqual(await s.get("habits:due"), { [h.id]: "2026-11-04" });
  const s2 = mem(); await add(s2);
  assert.equal((await reminderDue(s2, spec(), NOW + 30 * min)).due.length, 0, "window closed");
  const s3 = mem(); await add(s3, { reminder_time: "23:50", timezone: 60 });
  const night = spec({ notifications: { from: "00:00", to: "00:00", types: { reminder: true } } });
  assert.equal((await reminderDue(s3, night, Date.parse("2026-11-04T23:10:00Z"))).due.length, 1, "past local midnight");
  assert.equal(Object.values(await s3.get("habits:due"))[0], "2026-11-04", "dated by the reminder's day");
});

test("reminders respect quiet hours, type and proactivity never", async () => {
  const s = mem(); await add(s, { reminder_time: "23:00" });
  const late = Date.parse("2026-11-04T23:00:00Z");
  assert.equal((await reminderDue(s, spec(), late)).due.length, 0);
  const s2 = mem(); await add(s2);
  assert.equal((await reminderDue(s2, spec({ proactivity: { mode: "never" } }), NOW)).due.length, 0);
  assert.equal((await reminderDue(s2, spec({ notifications: { from: "08:00", to: "22:00", types: { reminder: false } } }), NOW)).due.length, 0);
});

test("name refusal list", async () => {
  const s = mem();
  for (const name of ["see https://x.io", "mail me@x.com", "Diet plan", "track sleep", "medication", "dose", "count calories"]) {
    assert.equal((await habitAdd(s, spec(), { ...base, name }, NOW)).code, "name_refused", name);
  }
});

test("memory_off and skill_off", async () => {
  const s = mem();
  const off = spec({ memory: { mode: "off" } });
  const sk = spec({ skills: { habits: false } });
  for (const sp of [off, sk]) {
    const code = sp === off ? "memory_off" : "skill_off";
    assert.equal((await habitAdd(s, sp, base, NOW)).code, code);
    assert.equal((await habitList(s, sp, NOW)).code, code);
    assert.equal((await habitPause(s, sp, "a")).code, code);
    assert.equal((await habitResume(s, sp, "a")).code, code);
    assert.equal((await habitDelete(s, sp, "a")).code, code);
    assert.equal((await checkIn(s, sp, "a", "2026-11-04", NOW)).code, code);
    assert.equal((await reminderDue(s, sp, NOW)).code, code);
  }
});

test("check-in dates capped at 400", async () => {
  const s = mem(); const h = await add(s);
  const old = Array.from({ length: 400 }, (_, i) => new Date(Date.UTC(2025, 0, 1) + i * 86400000).toISOString().slice(0, 10));
  await s.set("habits:checkins", { [h.id]: old });
  await checkIn(s, spec(), h.id, "2026-11-04", NOW);
  const d = (await s.get("habits:checkins"))[h.id];
  assert.equal(d.length, 400); assert.equal(d.at(-1), "2026-11-04"); assert.notEqual(d[0], old[0]);
});
