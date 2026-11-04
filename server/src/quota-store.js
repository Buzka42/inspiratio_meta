// Storage behind quotas and the device revocation list.
//
// Backing interface (the async subset of Durable Object storage):
//   get(key) -> value | undefined, put(key, value), delete(key)
// MemoryBacking implements it over a Map. A Durable Object's `ctx.storage`
// has the same shape, so the same store classes run on either.
//
// QuotaStore interface: hit(key, day) -> count after this hit.
// Counters are keyed by `quota:<UTC day>:<deviceId>:<bucket>`.

export class MemoryBacking {
  constructor() {
    this.map = new Map();
  }
  async get(key) {
    return this.map.get(key);
  }
  async put(key, value) {
    this.map.set(key, value);
  }
  async delete(key) {
    return this.map.delete(key);
  }
}

// Counters over any backing. Survives a new QuotaStore instance as long as the
// backing survives. get then put is not atomic across isolates; inside one
// Durable Object, storage calls are serialised, so it is atomic there.
export class QuotaStore {
  constructor(backing = new MemoryBacking()) {
    this.backing = backing;
  }
  async hit(key, day) {
    const k = `quota:${day}:${key}`;
    const n = ((await this.backing.get(k)) ?? 0) + 1;
    await this.backing.put(k, n);
    return n;
  }
}

// Default: counters live in the isolate's memory. They RESET WHENEVER THE
// ISOLATE RESTARTS and are not shared across isolates, so this is a soft limit.
// Owns its backing, so it drops yesterday's counters to keep memory bounded.
export class InMemoryQuotaStore extends QuotaStore {
  constructor() {
    super(new MemoryBacking());
    this.day = null;
  }
  async hit(key, day) {
    if (day !== this.day) {
      this.day = day;
      this.backing.map.clear();
    }
    return super.hit(key, day);
  }
}

// Durable Object adapter: hard quotas that survive isolate restarts and are
// shared by every isolate. The class that extends DurableObject lives in
// src/worker.js (the Worker entry, binding QUOTA_DO); its body is
// DeviceQuotaCounter below, kept free of the runtime so node tests drive it.
//
// One object per device id (idFromName(deviceId)), not one per device per day:
// the object holds a single record { day, counts } under one storage key, so a
// new UTC day replaces yesterday's counts in the same write (no list or cleanup,
// no abandoned per-day objects left holding storage).

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const KEY = /^[A-Za-z0-9_-]{1,64}:[a-z]{1,16}$/;
const RECORD = "quota";

export class DeviceQuotaCounter {
  constructor(storage) {
    this.storage = storage;
    // Hits run one after another inside the object, so get then put is never
    // interleaved, whatever the storage does between the two awaits.
    this.tail = Promise.resolve();
  }
  hit(key, day) {
    const run = this.tail.then(() => this.#hit(key, day));
    this.tail = run.catch(() => {});
    return run;
  }
  async #hit(key, day) {
    if (typeof key !== "string" || !KEY.test(key)) throw new Error("quota key invalid");
    if (typeof day !== "string" || !DAY.test(day)) throw new Error("quota day invalid");
    const saved = await this.storage.get(RECORD);
    // A hit stamped with an older day (isolate clock behind) counts against the
    // newer saved day rather than resetting it.
    const current = saved && saved.day >= day ? saved : { day, counts: {} };
    const n = (current.counts[key] ?? 0) + 1;
    await this.storage.put(RECORD, { day: current.day, counts: { ...current.counts, [key]: n } });
    return n;
  }
}

// Worker-side adapter: routes each hit to the device's object by RPC.
// key is `<deviceId>:<bucket>`; device ids never contain ":" (auth.DEVICE_ID).
export class DurableObjectQuotaStore {
  constructor(namespace) {
    if (!namespace?.idFromName) throw new Error("durable object namespace missing");
    this.namespace = namespace;
  }
  async hit(key, day) {
    const deviceId = key.slice(0, key.lastIndexOf(":"));
    return this.namespace.get(this.namespace.idFromName(deviceId)).hit(key, day);
  }
}
