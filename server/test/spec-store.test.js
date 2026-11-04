// P1: SpecState over injected storage. Compare-and-set, 300 s TTL, single-use change ids, knowledge sources.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_SOURCES, MemoryStorage, PENDING_TTL_MS, SpecState } from "../src/spec/store.js";
import { DEFAULT_SPEC } from "../src/spec/schema.js";

const make = (t0 = 1_000_000) => {
  const clock = { t: t0 };
  const state = new SpecState(new MemoryStorage(), { now: () => clock.t });
  return { state, clock };
};
const add = { title: "Sleep leaflet", origin: "Synthetic leaflet", date: "2026-10-01", text: "Keep a regular wake time.", bank: "sleep_lifestyle" };

test("store: get returns the default spec, a fresh copy each time", async () => {
  const { state } = make();
  const a = await state.get();
  assert.deepEqual(a, DEFAULT_SPEC);
  a.skills.diet = true;
  assert.equal((await state.get()).skills.diet, false);
  assert.deepEqual(await state.sources(), []);
});

test("store: propose then apply raises the version and stores the spec", async () => {
  const { state } = make();
  const p = await state.propose({ base_version: 1, spec_patch: { skills: { breathwork: false } } });
  assert.match(p.change_id, /^[0-9a-f]{32}$/);
  assert.deepEqual(p.diff, [{ path: "skills.breathwork", from: true, to: false }]);
  assert.equal(p.readback, "Illunis will turn breathwork off.");
  assert.equal(p.expires_at, 1_000_000 + PENDING_TTL_MS);
  assert.equal((await state.get()).version, 1, "propose changes nothing");
  const r = await state.apply(p.change_id);
  assert.deepEqual(r.problems, []);
  assert.equal(r.spec.version, 2);
  assert.equal((await state.get()).skills.breathwork, false);
});

test("store: refusals and problems come back without a change id", async () => {
  const { state } = make();
  const r = await state.propose({ base_version: 1, spec_patch: { disclaimer: false } });
  assert.deepEqual(r.refused, [{ path: "spec_patch.disclaimer", reason: "guardrail" }]);
  assert.equal(r.change_id, undefined);
  assert.deepEqual((await state.propose({ base_version: 1, spec_patch: { brain: "auto" } })).problems, ["no_change"]);
  assert.deepEqual((await state.propose({ base_version: 7, spec_patch: { brain: "meta" } })).problems, ["stale_version"]);
});

test("store: a change id is single use", async () => {
  const { state } = make();
  const p = await state.propose({ base_version: 1, spec_patch: { brain: "meta" } });
  assert.deepEqual((await state.apply(p.change_id)).problems, []);
  assert.deepEqual((await state.apply(p.change_id)).problems, ["unknown_change"]);
  for (const id of ["", "x", null, 5, "__proto__", "0".repeat(32)]) assert.deepEqual((await state.apply(id)).problems, ["unknown_change"]);
});

test("store: an expired change id is refused and consumed", async () => {
  const { state, clock } = make();
  const p = await state.propose({ base_version: 1, spec_patch: { brain: "meta" } });
  clock.t += PENDING_TTL_MS;
  assert.deepEqual((await state.apply(p.change_id)).problems, ["expired_change"]);
  clock.t -= PENDING_TTL_MS;
  assert.deepEqual((await state.apply(p.change_id)).problems, ["unknown_change"]);
  assert.equal((await state.get()).brain, "auto");
});

test("store: compare-and-set; the second of two pending changes is stale", async () => {
  const { state } = make();
  const a = await state.propose({ base_version: 1, spec_patch: { brain: "meta" } });
  const b = await state.propose({ base_version: 1, spec_patch: { brain: "nebius" } });
  assert.deepEqual((await state.apply(a.change_id)).problems, []);
  assert.deepEqual((await state.apply(b.change_id)).problems, ["stale_version"]);
  assert.deepEqual((await state.apply(b.change_id)).problems, ["unknown_change"], "consumed even when stale");
  assert.equal((await state.get()).brain, "meta");
});

test("store: change ids are random, and pending entries are capped", async () => {
  const { state } = make();
  const ids = new Set();
  for (let i = 0; i < 20; i++) ids.add((await state.propose({ base_version: 1, spec_patch: { brain: "meta" } })).change_id);
  assert.equal(ids.size, 20);
  const pending = await state.storage.get("spec:pending");
  assert.equal(Object.keys(pending).length, 8);
});

test("store: knowledge add and remove keep provenance and raise the version", async () => {
  const { state } = make(Date.UTC(2026, 10, 3));
  const p = await state.propose({ base_version: 1, knowledge_add: add });
  assert.deepEqual(p.diff, [{ path: "knowledge.add", from: null, to: "sleep_lifestyle" }]);
  assert.equal(p.readback, "Illunis will add a knowledge source.");
  const r = await state.apply(p.change_id);
  assert.equal(r.spec.version, 2);
  assert.equal(r.added.text, add.text, "the route embeds the text");
  const [src] = await state.sources();
  assert.deepEqual(src, { id: r.added.id, title: add.title, origin: add.origin, date: add.date, bank: add.bank, added_at: "2026-11-03T00:00:00.000Z" });

  assert.deepEqual((await state.propose({ base_version: 2, knowledge_remove: "src_0000000000000000" })).problems, ["unknown_source"]);
  const q = await state.propose({ base_version: 2, knowledge_remove: src.id });
  assert.deepEqual(q.diff, [{ path: "knowledge.remove", from: "sleep_lifestyle", to: null }]);
  const s = await state.apply(q.change_id);
  assert.equal(s.removed, src.id);
  assert.equal(s.spec.version, 3);
  assert.deepEqual(await state.sources(), []);
});

test("store: the source list is capped", async () => {
  const { state } = make();
  await state.storage.put("spec:sources", Array.from({ length: MAX_SOURCES }, (_, i) => ({ id: `src_${String(i).padStart(16, "0")}`, bank: "diet" })));
  assert.deepEqual((await state.propose({ base_version: 1, knowledge_add: add })).problems, ["too_many_sources"]);
});

test("store: the registry can be injected", async () => {
  const state = new SpecState(new MemoryStorage(), { skills: ["breathwork"] });
  assert.deepEqual((await state.propose({ base_version: 1, spec_patch: { skills: { sleep: false } } })).refused,
    [{ path: "spec_patch.skills.sleep", reason: "unknown_skill" }]);
});
