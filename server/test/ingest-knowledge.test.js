// scripts/ingest-knowledge.mjs: frontmatter, chunking, records, batched POSTs to the Worker and count checks.
// Fake fetch only; the CLI runs in dry-run or refuses before any network call.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BATCH, CHUNK_CHARS, buildRecords, chunkText, metaProblems, mismatches, parseFrontmatter, postRecords, vectorId, verifyCounts,
} from "../scripts/ingest-knowledge.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "..", "scripts", "ingest-knowledge.mjs");
const SERVER = "https://worker.test";
const TOKEN = `device-token-${crypto.randomUUID()}`;

const NOTE = (id, body = "Synthetic paragraph one.\n\nSynthetic paragraph two.") =>
  `---\nsource_id: ${id}\ntitle: "Synthetic ${id}"\nurl: https://example.test/${id}\nlicence: OGL-3.0\nretrieved: 2026-10-25\n---\n${body}\n`;

const rec = (i, ns = "diet") => ({ id: `${ns}:${i}:0`, namespace: ns, text: `t${i}`, metadata: { expert: ns, source_id: `s${i}` } });

test("frontmatter parsing and required fields", () => {
  const { meta, body } = parseFrontmatter(NOTE("nhs-sleep-1"));
  assert.deepEqual(meta, { source_id: "nhs-sleep-1", title: "Synthetic nhs-sleep-1", url: "https://example.test/nhs-sleep-1", licence: "OGL-3.0", retrieved: "2026-10-25" });
  assert.match(body, /^Synthetic paragraph one/);
  assert.deepEqual(metaProblems(meta), []);
  assert.deepEqual(metaProblems(null), ["frontmatter missing"]);
  assert.deepEqual(metaProblems({ ...meta, url: "http://x.test", source_id: "bad id", licence: "" }), [
    "licence missing", "source_id must match [A-Za-z0-9_.-]{1,64}", "url must be https",
  ]);
});

test("chunks stay under the size and pack paragraphs", () => {
  assert.deepEqual(chunkText("a\n\nb"), ["a\n\nb"]);
  const long = Array.from({ length: 3000 }, (_, i) => `w${i}`).join(" ");
  const chunks = chunkText(`${long}\n\nshort tail`);
  assert.ok(chunks.length >= 4);
  assert.ok(chunks.every((c) => c.length <= CHUNK_CHARS));
  assert.ok(vectorId("cardiology", "x".repeat(64), 99).length <= 64);
});

test("buildRecords: per expert namespace, file counts, metadata without text, skips bad notes", () => {
  const dir = mkdtempSync(join(tmpdir(), "illunis-knowledge-"));
  try {
    mkdirSync(join(dir, "diet"));
    mkdirSync(join(dir, "astrology"));
    writeFileSync(join(dir, "diet", "a.md"), NOTE("who-diet-1"));
    writeFileSync(join(dir, "diet", "b.md"), NOTE("who-diet-1"));
    writeFileSync(join(dir, "diet", "c.md"), "no frontmatter");
    writeFileSync(join(dir, "astrology", "x.md"), NOTE("x"));
    const { records, files, problems } = buildRecords(dir);
    assert.equal(records.length, 1);
    assert.equal(records[0].namespace, "diet");
    assert.deepEqual(files, { diet: 1 });
    assert.deepEqual(Object.keys(records[0].metadata).sort(), ["expert", "licence", "retrieved", "source_id", "title", "url"]);
    assert.deepEqual(problems, ["astrology/: not an expert id", "diet/b.md: duplicate source_id", "diet/c.md: frontmatter missing"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("postRecords: batches of 20 to /knowledge/ingest with the bearer token in the header", async () => {
  const calls = [];
  const fetchFn = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, init, body });
    return new Response(JSON.stringify({ ok: true, upserted: body.records.length }), { status: 200 });
  };
  const records = Array.from({ length: 45 }, (_, i) => rec(i));
  assert.equal(await postRecords(records, { serverUrl: SERVER, token: TOKEN, fetchFn }), 45);
  assert.equal(BATCH, 20);
  assert.deepEqual(calls.map((c) => c.body.records.length), [20, 20, 5]);
  assert.ok(calls.every((c) => c.url === `${SERVER}/knowledge/ingest`));
  assert.ok(calls.every((c) => c.init.headers.Authorization === `Bearer ${TOKEN}`));
  assert.ok(calls.every((c) => !c.init.body.includes(TOKEN)));
});

test("postRecords: a refused batch throws a fixed code without the body or the token", async () => {
  const fetchFn = async () => new Response(`echo ${TOKEN}`, { status: 403 });
  await assert.rejects(postRecords([rec(1)], { serverUrl: SERVER, token: TOKEN, fetchFn }), (e) => {
    assert.equal(e.message, "http_403");
    assert.ok(!e.message.includes(TOKEN));
    return true;
  });
  const down = async () => {
    throw new TypeError("refused");
  };
  await assert.rejects(postRecords([rec(1)], { serverUrl: SERVER, token: TOKEN, fetchFn: down }), /^Error: network$|^network$/);
});

test("verify: counts by source per bank; retries up to 3 times and fails on a persistent mismatch", async () => {
  assert.deepEqual(mismatches({ diet: { sources: 8 }, training: { sources: 6 } }, { diet: 8, training: 7 }), ["training"]);
  const stats = (sources) => async () =>
    new Response(JSON.stringify({ ok: true, namespaces: { diet: { sources, chunks: sources, capped: false } } }), { status: 200 });
  const sleeps = [];
  const sleep = async (ms) => sleeps.push(ms);
  const seq = [3, 8];
  let n = 0;
  const fetchFn = async (url, init) => {
    assert.equal(url, `${SERVER}/knowledge/stats`);
    assert.deepEqual(JSON.parse(init.body), { namespaces: ["diet"] });
    return stats(seq[Math.min(n++, seq.length - 1)])();
  };
  assert.deepEqual(await verifyCounts({ diet: 8 }, { serverUrl: SERVER, token: TOKEN, fetchFn, sleep }), { ok: true, bad: [] });
  assert.deepEqual(sleeps, [10_000]);

  const never = { serverUrl: SERVER, token: TOKEN, fetchFn: stats(3), sleep };
  const out = await verifyCounts({ diet: 8 }, never);
  assert.deepEqual(out, { ok: false, bad: ["diet"] });
  assert.equal(sleeps.length, 1 + 2);
});

test("CLI: dry-run counts the real knowledge folder per bank and never prints the token", () => {
  const out = execFileSync(process.execPath, [SCRIPT, "--dry-run", "--only", "diet,training,breath_stress,sleep_lifestyle"], {
    env: { PATH: process.env.PATH, ILLUNIS_DEVICE_TOKEN: TOKEN },
    encoding: "utf8",
  });
  assert.match(out, /diet 8 files/);
  assert.match(out, /training 7 files/);
  assert.match(out, /breath_stress 8 files/);
  assert.match(out, /sleep_lifestyle 7 files/);
  assert.ok(!out.includes(TOKEN));
});

test("CLI: a real run needs an https server URL and a token, and refuses before any network call", () => {
  const dir = mkdtempSync(join(tmpdir(), "illunis-cli-"));
  try {
    mkdirSync(join(dir, "diet"));
    writeFileSync(join(dir, "diet", "a.md"), NOTE("cli-src-1"));
    const run = (env, args = []) =>
      spawnSync(process.execPath, [SCRIPT, "--dir", dir, ...args], { env: { PATH: process.env.PATH, ...env }, encoding: "utf8" });
    const noEnv = run({});
    assert.equal(noEnv.status, 2);
    const insecure = run({ ILLUNIS_SERVER_URL: "http://worker.test", ILLUNIS_DEVICE_TOKEN: TOKEN });
    assert.equal(insecure.status, 2);
    assert.ok(!`${insecure.stdout}${insecure.stderr}`.includes(TOKEN));
    const unknown = run({}, ["--only", "astrology"]);
    assert.equal(unknown.status, 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
