// Reading companion records in Durable Object storage (any {get, put} store). Plain data, no model text.
// Keys: read:notes [note], read:pos {[source_id]: {part, updated_at}}, read:open_q [question].
// Every read prunes records older than the retention window, so no alarm is needed.

const DAY_MS = 86_400_000;
export const NOTES_MAX = 200;
export const OPEN_Q_MAX = 20;
const K = Object.freeze({ notes: "read:notes", pos: "read:pos", openQ: "read:open_q" });

const hex16 = () => [...crypto.getRandomValues(new Uint8Array(8))].map((b) => b.toString(16).padStart(2, "0")).join("");
const fresh = (at, cutoff) => Number.isFinite(at) && at >= cutoff;

export class ReadingStore {
  // storage: {get(key), put(key, value), delete?(key)}; now: () => epoch ms; retentionDays: from spec.memory.
  constructor(storage, { now = Date.now, retentionDays = 30 } = {}) {
    this.storage = storage;
    this.now = now;
    this.retentionMs = Math.max(1, retentionDays | 0) * DAY_MS;
  }

  cutoff() {
    return this.now() - this.retentionMs;
  }

  async list(key) {
    const v = await this.storage.get(key);
    const c = this.cutoff();
    return (Array.isArray(v) ? v : []).filter((r) => fresh(r?.created_at, c));
  }

  async notes() {
    return this.list(K.notes);
  }

  async addNote(fields) {
    const notes = await this.notes();
    if (notes.length >= NOTES_MAX) return null;
    const note = { id: `rn_${hex16()}`, ...fields, created_at: this.now() };
    await this.storage.put(K.notes, [...notes, note]);
    return note;
  }

  async deleteNote(id) {
    const notes = await this.notes();
    const kept = notes.filter((n) => n.id !== id);
    await this.storage.put(K.notes, kept);
    return kept.length < notes.length;
  }

  async positions() {
    const v = (await this.storage.get(K.pos)) ?? {};
    const c = this.cutoff();
    return Object.fromEntries(Object.entries(v).filter(([, p]) => fresh(p?.updated_at, c)));
  }

  async setPosition(sourceId, part) {
    const pos = await this.positions();
    pos[sourceId] = { part, updated_at: this.now() };
    await this.storage.put(K.pos, pos);
    return { source_id: sourceId, ...pos[sourceId] };
  }

  // The most recently updated position, or null.
  async lastPosition() {
    const entries = Object.entries(await this.positions());
    if (!entries.length) return null;
    const [sourceId, p] = entries.reduce((a, b) => (b[1].updated_at > a[1].updated_at ? b : a));
    return { source_id: sourceId, ...p };
  }

  async openQuestions() {
    return this.list(K.openQ);
  }

  async addOpenQuestion(fields) {
    const item = { ...fields, created_at: this.now() };
    const kept = [...(await this.openQuestions()), item].slice(-OPEN_Q_MAX);
    await this.storage.put(K.openQ, kept);
    return item;
  }

  async deleteAll() {
    for (const key of Object.values(K)) await this.storage.put(key, key === K.pos ? {} : []);
  }
}
