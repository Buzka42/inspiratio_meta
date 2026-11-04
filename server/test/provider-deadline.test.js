// callBrain keeps one absolute deadline per call: the fallback gets only the time left, none under 1000 ms,
// and hard configuration errors stop before any call. Every network call is a fake; all text is synthetic.
import { test } from "node:test";
import assert from "node:assert/strict";
import { callBrain } from "../src/council/provider.js";
import { META_BASE_REFUSED, META_CONTRIBUTOR_REFUSED, META_MODEL_MISSING } from "../src/providers/meta.js";

const KEY = `meta-test-${crypto.randomUUID()}`;
const META = { META_API_KEY: KEY, META_MODEL: "synthetic/meta-model-test" };
const NEBIUS = { NEBIUS_API_KEY: `nebius-test-${crypto.randomUUID()}`, COUNCIL_NEBIUS_MODEL: "synthetic/brain-test" };
const OPENROUTER = { COUNCIL_TEST_PROVIDER: "openrouter_poc", OPENROUTER_API_KEY: `or-test-${crypto.randomUUID()}`, DATA_MODE: "owner_any" };
const MSG = [{ role: "user", content: "synthetic" }];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Hangs until the caller's abort signal fires, then rejects the way fetch does.
const hang = (signal) => new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));

// Meta answers 502 after metaMs; every other host hangs until its signal aborts. Records when each call ended.
function fake(metaMs) {
  const calls = [];
  const fn = async (url, init) => {
    const call = { url, start: Date.now() };
    calls.push(call);
    try {
      if (url.startsWith("https://api.meta.ai/")) {
        await sleep(metaMs);
        return new Response("x", { status: 502 });
      }
      return await hang(init.signal);
    } finally {
      call.end = Date.now();
    }
  };
  return { fn, calls };
}

for (const [name, env, code] of [["Nebius", { ...META, ...NEBIUS }, "nebius_timeout"], ["OpenRouter", { ...META, ...OPENROUTER }, "openrouter_timeout"]]) {
  test(`callBrain: the ${name} fallback gets only the time left on the deadline`, async () => {
    const { fn, calls } = fake(400);
    const started = Date.now();
    await assert.rejects(callBrain(MSG, env, { fetchFn: fn, timeoutMs: 2500 }), (e) => e.code === code);
    const total = Date.now() - started;
    assert.equal(calls.length, 2);
    assert.ok(!calls[1].url.startsWith("https://api.meta.ai/"));
    assert.ok(total < 2500 + 300, `whole call ${total} ms stayed within one deadline`);
    assert.ok(calls[1].end - calls[1].start < 2300, "fallback ran on the remaining time, not a fresh timeout");
  });
}

test("callBrain: an explicit deadlineAt caps the first attempt and the fallback", async () => {
  const calls = [];
  const hangAll = async (url, init) => { calls.push({ url }); return hang(init.signal); };
  const started = Date.now();
  await assert.rejects(callBrain(MSG, { ...META, ...NEBIUS }, { fetchFn: hangAll, timeoutMs: 20_000, deadlineAt: started + 600 }), (e) => e.code === "meta_timeout");
  assert.ok(Date.now() - started < 900, "first attempt aborted at the deadline");
  assert.equal(calls.length, 1, "no fallback with under 1000 ms left");
});

test("callBrain: no fallback when under 1000 ms is left; the original error is thrown", async () => {
  const { fn, calls } = fake(900);
  await assert.rejects(callBrain(MSG, { ...META, ...NEBIUS }, { fetchFn: fn, deadlineAt: Date.now() + 1500 }), (e) => e.code === "meta_status_5xx");
  assert.equal(calls.length, 1);
});

test("callBrain: hard configuration errors stop before any call, even with a deadline", async () => {
  const noNet = () => { throw new Error("network touched"); };
  const cases = [
    [{ ...NEBIUS, META_API_KEY: KEY }, META_MODEL_MISSING],
    [{ ...NEBIUS, ...META, META_MODEL: "synthetic/model-contributor" }, META_CONTRIBUTOR_REFUSED],
    [{ ...NEBIUS, ...META, META_BASE_URL: "https://evil.example.test/v1" }, META_BASE_REFUSED],
  ];
  for (const [env, detail] of cases) {
    await assert.rejects(callBrain(MSG, env, { fetchFn: noNet, deadlineAt: Date.now() + 5000 }), (e) => e.message === "not configured" && e.detail === detail);
  }
});
