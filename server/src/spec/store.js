// SpecState: the spec, pending changes and knowledge sources for one device. Pure class over injected storage
// with the Durable Object storage shape ({ get, put, delete }, async). P5 wires it into AssistantInbox.
// A pending change is single use, lives 300 s, and is applied only if base_version still matches (compare-and-set).
import { createHash } from "node:crypto";
import { canonicalJson } from "../assistants/contract.js";
import { DEFAULT_SPEC, applyChange, diffSpecs, readback, validateChange } from "./schema.js";
import { makeSource, randomHex, sourceIndex } from "./knowledge.js";

export const PENDING_TTL_MS = 300_000;
const MAX_PENDING = 8; // with 8 KiB per change, well under a DO value limit
export const MAX_BOT_PENDING = 2; // bot proposals: own cap, so they never evict the owner's pending changes
export const MAX_SOURCES = 50;
export const MAX_HISTORY = 10; // bounded: older snapshots fall off, so undo is recent-only by design
const CHANGE_ID = /^[0-9a-f]{32}$/;
const KEY = { spec: "spec:current", pending: "spec:pending", sources: "spec:sources", history: "spec:history" };
const GENESIS = "0".repeat(64);
export const specEntryHash = (prev, spec) => createHash("sha256").update(`${prev}\n${canonicalJson(spec)}`, "utf8").digest("hex");

// For tests and local runs: a Map with the DO storage method names.
export class MemoryStorage {
  #m = new Map();
  async get(k) { return structuredClone(this.#m.get(k)); }
  async put(k, v) { this.#m.set(k, structuredClone(v)); }
  async delete(k) { return this.#m.delete(k); }
}

export class SpecState {
  constructor(storage, { now = () => Date.now(), randomId = () => randomHex(16), skills, banks } = {}) {
    this.storage = storage;
    this.now = now;
    this.randomId = randomId;
    this.opts = { ...(skills && { skills }), ...(banks && { banks }) };
  }

  async get() {
    return (await this.storage.get(KEY.spec)) ?? structuredClone(DEFAULT_SPEC);
  }

  async sources() {
    return ((await this.storage.get(KEY.sources)) ?? []).map(sourceIndex);
  }

  // Hash-chained history (bounded to MAX_HISTORY). The listing never carries a snapshot or user text:
  // version, time, hashes and the fixed-phrase readback only. Snapshots stay in storage for revert.
  async history() {
    const list = (await this.storage.get(KEY.history)) ?? [];
    return list.map(({ version, ts, hash, prev, readback: rb }) => ({ version, ts, hash, prev, readback: rb }));
  }

  async #appendHistory(spec, rb) {
    const list = (await this.storage.get(KEY.history)) ?? [];
    const prev = list.at(-1)?.hash ?? GENESIS;
    const entry = { version: spec.version, ts: this.now(), prev, hash: specEntryHash(prev, spec), readback: rb, spec: structuredClone(spec) };
    await this.storage.put(KEY.history, [...list, entry].slice(-MAX_HISTORY));
    return entry;
  }

  // Verifies the chain over the retained window. The first retained entry chains from an evicted one,
  // so only links inside the window are checked.
  async verifyHistory() {
    const list = (await this.storage.get(KEY.history)) ?? [];
    for (let i = 0; i < list.length; i++) {
      if (specEntryHash(list[i].prev, list[i].spec) !== list[i].hash) return { ok: false, at: list[i].version };
      if (i > 0 && list[i].prev !== list[i - 1].hash) return { ok: false, at: list[i].version };
    }
    return { ok: true, entries: list.length };
  }

  // One-tap undo, through the same approval: mints a pending restore that only /spec/apply can consume.
  async proposeRevert(version) {
    const list = (await this.storage.get(KEY.history)) ?? [];
    const target = list.find((e) => e.version === version);
    if (!target) return { problems: ["unknown_version"], refused: [] };
    const spec = await this.get();
    const diff = diffSpecs(spec, target.spec);
    if (!diff.length) return { problems: ["no_change"], refused: [] };
    const { change_id, expires_at } = await this.#addPending({ restore: version }, false);
    return { problems: [], refused: [], change_id, base_version: spec.version, diff, readback: readback(diff), expires_at };
  }

  // Diff entries for the knowledge part of a change; only the bank (an enum) is carried, never bot text.
  #knowledgeDiff(change, list) {
    const out = [];
    if (change.knowledge_add) out.push({ path: "knowledge.add", from: null, to: change.knowledge_add.bank });
    if (change.knowledge_remove) {
      out.push({ path: "knowledge.remove", from: list.find((s) => s.id === change.knowledge_remove)?.bank ?? null, to: null });
    }
    return out;
  }

  #check(change, spec, list) {
    const { problems, refused } = validateChange(change, spec, this.opts);
    if (problems.length || refused.length) return { problems, refused };
    if (change.knowledge_add && list.length >= MAX_SOURCES) return { problems: ["too_many_sources"], refused };
    if (change.knowledge_remove && !list.some((s) => s.id === change.knowledge_remove)) return { problems: ["unknown_source"], refused };
    const diff = [...diffSpecs(spec, applyChange(spec, change)), ...this.#knowledgeDiff(change, list)];
    return diff.length ? { problems, refused, diff } : { problems: ["no_change"], refused };
  }

  // Stores a live pending entry; expired ones drop, and eviction stays within the caller's class (bot or owner).
  async #addPending(entry, bot) {
    const now = this.now();
    const live = Object.entries((await this.storage.get(KEY.pending)) ?? {})
      .filter(([, p]) => p.expires_at > now)
      .sort(([, a], [, b]) => a.expires_at - b.expires_at);
    const same = live.filter(([, p]) => Boolean(p.bot) === bot).slice(-((bot ? MAX_BOT_PENDING : MAX_PENDING) - 1));
    const other = live.filter(([, p]) => Boolean(p.bot) !== bot);
    const change_id = this.randomId();
    const expires_at = now + PENDING_TTL_MS;
    const added = [change_id, { ...entry, ...(bot && { bot: true }), expires_at }];
    await this.storage.put(KEY.pending, Object.fromEntries([...other, ...same, added]));
    return { change_id, expires_at };
  }

  // via: "bot" for a bot-initiated proposal (assistants/routes.js), anything else is the owner's.
  async propose(change, { via } = {}) {
    const spec = await this.get();
    const list = (await this.storage.get(KEY.sources)) ?? [];
    const out = this.#check(change, spec, list);
    if (!out.diff) return out;
    const { change_id, expires_at } = await this.#addPending({ change: structuredClone(change) }, via === "bot");
    return { problems: [], refused: [], change_id, base_version: spec.version, diff: out.diff, readback: readback(out.diff), expires_at };
  }

  // Consumes the change_id first, so a replay or a failed apply can never reuse it.
  async apply(changeId) {
    if (typeof changeId !== "string" || !CHANGE_ID.test(changeId)) return { problems: ["unknown_change"], refused: [] };
    const all = (await this.storage.get(KEY.pending)) ?? {};
    const entry = Object.hasOwn(all, changeId) ? all[changeId] : null;
    if (!entry) return { problems: ["unknown_change"], refused: [] };
    delete all[changeId];
    await this.storage.put(KEY.pending, all);
    if (entry.expires_at <= this.now()) return { problems: ["expired_change"], refused: [] };

    const spec = await this.get();
    // A pending restore (proposeRevert): the snapshot comes back under a fresh version, chained as usual.
    if (Number.isInteger(entry.restore)) {
      const history = (await this.storage.get(KEY.history)) ?? [];
      const target = history.find((e) => e.version === entry.restore);
      if (!target) return { problems: ["unknown_version"], refused: [] };
      const diff = diffSpecs(spec, target.spec);
      if (!diff.length) return { problems: ["no_change"], refused: [] };
      const next = { ...structuredClone(target.spec), version: spec.version + 1 };
      await this.storage.put(KEY.spec, next);
      const rb = readback(diff);
      await this.#appendHistory(next, rb);
      return { problems: [], refused: [], spec: next, diff, readback: rb, added: null, removed: null, restored_from: entry.restore };
    }
    let list = (await this.storage.get(KEY.sources)) ?? [];
    const out = this.#check(entry.change, spec, list);
    if (!out.diff) return { problems: out.problems, refused: out.refused };
    const next = applyChange(spec, entry.change);
    let added = null;
    if (entry.change.knowledge_add) {
      added = makeSource(entry.change.knowledge_add, { now: this.now(), id: `src_${this.randomId().slice(0, 16)}` });
      list = [...list, added];
    }
    const removed = entry.change.knowledge_remove ?? null;
    if (removed) list = list.filter((s) => s.id !== removed);
    if (added || removed) await this.storage.put(KEY.sources, list);
    await this.storage.put(KEY.spec, next);
    const rb = readback(out.diff);
    await this.#appendHistory(next, rb);
    return { problems: [], refused: [], spec: next, diff: out.diff, readback: rb, added, removed };
  }
}
