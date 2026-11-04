#!/usr/bin/env node
// Manual probe (owner runs it): BASETEN_API_KEY from the environment only. Calls chatBaseten twice (JSON asked for
// in the prompt, then with a tool) and prints fixed labels and codes. Never prints content, tool arguments or the key.
import { chatBaseten, basetenConfigProblem } from "../src/providers/baseten.js";

const env = { BASETEN_API_KEY: process.env.BASETEN_API_KEY, BASETEN_MODEL: process.env.BASETEN_MODEL };
const TOOL = { type: "function", function: { name: "consult", description: "Ask an expert.", parameters: { type: "object", properties: { expert: { type: "string" } }, required: ["expert"] } } };
const CASES = [
  ["prompt_json", [{ role: "user", content: 'Reply with only this JSON object and nothing else: {"ok": true}' }], {}],
  ["tools", [{ role: "user", content: "Use the consult tool to ask the sleep expert about going to bed earlier." }], { tools: [TOOL] }],
];

// Wraps fetch to read only the fixed finish_reason label from a copy of the response.
const FINISH = new Set(["stop", "length", "tool_calls", "content_filter"]);
function watch(seen) {
  return async (url, init) => {
    const res = await fetch(url, init);
    const j = await res.clone().json().catch(() => null);
    const f = j?.choices?.[0]?.finish_reason;
    seen.finish = FINISH.has(f) ? f : f == null ? "none" : "other";
    return res;
  };
}

async function probe([label, messages, opts]) {
  const t = Date.now();
  const seen = { finish: "none" };
  try {
    const r = await chatBaseten(messages, env, { ...opts, fetchFn: watch(seen), role: "relay", maxTokens: 3000, timeoutMs: 60_000 });
    console.log(`${label}: ok tool_calls_seen=${r.tool_calls.length ? "yes" : "no"} finish_reason=${seen.finish} content_length=${r.content.length} latency_ms=${Date.now() - t}`);
  } catch (err) {
    const code = /^baseten_[a-z0-9_]+$/.test(err?.code ?? "") ? err.code : "baseten_unknown";
    console.log(`${label}: error code=${code} finish_reason=${seen.finish} latency_ms=${Date.now() - t}`);
    return code;
  }
}

const problem = basetenConfigProblem(env);
if (problem) {
  console.log(`probe: not configured (${problem.includes("KEY") ? "BASETEN_API_KEY missing" : "config refused"})`);
  process.exitCode = 2;
} else {
  for (const c of CASES) await probe(c);
}
