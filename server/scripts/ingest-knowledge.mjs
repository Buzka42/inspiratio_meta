#!/usr/bin/env node
// Ingests knowledge/<expert>/*.md through the Worker: POST {ILLUNIS_SERVER_URL}/knowledge/ingest in batches of 20
// (the Worker embeds with the active provider and upserts into the "illunis-knowledge" index, C7/C8).
// Frontmatter (required): source_id, title, url (https), licence, retrieved (YYYY-MM-DD).
// Bodies are chunked to about 800 tokens (~3200 characters, split on paragraphs).
// Env (names only, never printed): ILLUNIS_SERVER_URL (https), ILLUNIS_DEVICE_TOKEN (the ingest device's token).
// Usage: node scripts/ingest-knowledge.mjs [--dir ../examples/illunis/knowledge] [--dry-run] [--only diet,training] [--verify]
// Prints counts, file names and fixed codes only, never note text or credentials.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { EXPERT_IDS } from "../src/council/experts.js";

export const CHUNK_CHARS = 3200;
export const BATCH = 20;
export const VERIFY_TRIES = 3;
export const VERIFY_GAP_MS = 10_000;
const REQUIRED = ["source_id", "title", "url", "licence", "retrieved"];

// Minimal YAML frontmatter: `key: value` lines between --- fences, optional quotes.
export function parseFrontmatter(text) {
  const m = String(text).replace(/^﻿/, "").match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { meta: null, body: String(text) };
  const meta = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z_][\w-]*)\s*:\s*(.*)$/);
    if (kv) meta[kv[1]] = kv[2].trim().replace(/^(["'])(.*)\1$/, "$2");
  }
  return { meta, body: m[2].trim() };
}

// Returns a list of problems (field names only).
export function metaProblems(meta) {
  if (!meta) return ["frontmatter missing"];
  const out = REQUIRED.filter((k) => typeof meta[k] !== "string" || !meta[k]).map((k) => `${k} missing`);
  if (meta.source_id && !/^[A-Za-z0-9_.-]{1,64}$/.test(meta.source_id)) out.push("source_id must match [A-Za-z0-9_.-]{1,64}");
  if (meta.url && !/^https:\/\/\S+$/.test(meta.url)) out.push("url must be https");
  if (meta.retrieved && !/^\d{4}-\d{2}-\d{2}$/.test(meta.retrieved)) out.push("retrieved must be YYYY-MM-DD");
  return out;
}

// Paragraph-packed chunks of at most `max` characters; an oversize paragraph is cut at spaces.
export function chunkText(body, max = CHUNK_CHARS) {
  const pieces = [];
  for (const para of String(body).split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean)) {
    let rest = para;
    while (rest.length > max) {
      const cut = rest.lastIndexOf(" ", max);
      const at = cut > 0 ? cut : max;
      pieces.push(rest.slice(0, at).trim());
      rest = rest.slice(at).trim();
    }
    if (rest) pieces.push(rest);
  }
  const chunks = [];
  for (const p of pieces) {
    if (chunks.length && chunks.at(-1).length + 2 + p.length <= max) chunks[chunks.length - 1] += `\n\n${p}`;
    else chunks.push(p);
  }
  return chunks;
}

// Vector ids stay short and stable: expert, a hash of the source id, the chunk index.
export const vectorId = (expert, sourceId, i) =>
  `${expert}:${createHash("sha256").update(sourceId).digest("hex").slice(0, 16)}:${i}`;

// Reads the tree. Returns { records: [{id, namespace, text, metadata}], files: {expert: n}, problems: [string] }.
// metadata holds the fields the Worker stores (C7); the Worker adds text and the embed tag itself.
export function buildRecords(dir, experts = EXPERT_IDS) {
  const records = [];
  const files = {};
  const problems = [];
  const seen = new Set();
  if (!existsSync(dir)) return { records, files, problems: ["knowledge folder missing"] };
  for (const expert of readdirSync(dir).sort()) {
    const sub = join(dir, expert);
    if (!statSync(sub).isDirectory()) continue;
    if (!experts.includes(expert)) {
      problems.push(`${expert}/: not an expert id`);
      continue;
    }
    for (const file of readdirSync(sub).filter((f) => f.endsWith(".md")).sort()) {
      const { meta, body } = parseFrontmatter(readFileSync(join(sub, file), "utf8"));
      const bad = metaProblems(meta);
      if (bad.length) {
        problems.push(...bad.map((b) => `${expert}/${file}: ${b}`));
        continue;
      }
      const key = `${expert}/${meta.source_id}`;
      if (seen.has(key)) {
        problems.push(`${expert}/${file}: duplicate source_id`);
        continue;
      }
      seen.add(key);
      files[expert] = (files[expert] ?? 0) + 1;
      chunkText(body).forEach((text, i) =>
        records.push({
          id: vectorId(expert, meta.source_id, i),
          namespace: expert,
          text,
          metadata: { expert, source_id: meta.source_id, title: meta.title, url: meta.url, licence: meta.licence, retrieved: meta.retrieved },
        }),
      );
    }
  }
  return { records, files, problems };
}

// Posts records in batches of 20. Returns the number of records the Worker accepted. Throws fixed codes only.
export async function postRecords(records, { serverUrl, token, fetchFn = fetch, batch = BATCH }) {
  let upserted = 0;
  for (let i = 0; i < records.length; i += batch) {
    const res = await knowledgePost(serverUrl, "/knowledge/ingest", token, { records: records.slice(i, i + batch) }, fetchFn);
    upserted += res.upserted ?? 0;
  }
  return upserted;
}

// Counts per bank from the Worker's stats route. Returns the banks whose source count differs from `expected`.
export function mismatches(namespaces, expected) {
  return Object.entries(expected)
    .filter(([bank, n]) => namespaces?.[bank]?.sources !== n)
    .map(([bank]) => bank);
}

// Polls /knowledge/stats up to VERIFY_TRIES times, VERIFY_GAP_MS apart (sleep injected for tests).
// Returns { ok, bad: [bank] }.
export async function verifyCounts(expected, { serverUrl, token, fetchFn = fetch, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) }) {
  let bad = Object.keys(expected);
  for (let attempt = 1; attempt <= VERIFY_TRIES; attempt++) {
    if (attempt > 1) await sleep(VERIFY_GAP_MS);
    const res = await knowledgePost(serverUrl, "/knowledge/stats", token, { namespaces: Object.keys(expected) }, fetchFn);
    bad = mismatches(res.namespaces, expected);
    if (!bad.length) return { ok: true, bad };
  }
  return { ok: false, bad };
}

// One JSON POST to the Worker. Throws an Error whose message is a fixed code: never the body or the token.
async function knowledgePost(serverUrl, path, token, payload, fetchFn) {
  let res;
  try {
    res = await fetchFn(`${serverUrl}${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch {
    throw new Error("network");
  }
  if (!res.ok) throw new Error(`http_${res.status}`);
  return res.json();
}

function parseArgs(argv) {
  const get = (name) => {
    const at = argv.indexOf(name);
    return at >= 0 ? argv[at + 1] : undefined;
  };
  const only = get("--only");
  return {
    dir: get("--dir"),
    only: only ? only.split(",").map((s) => s.trim()).filter(Boolean) : null,
    dryRun: argv.includes("--dry-run"),
    verify: argv.includes("--verify"),
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const dir = resolve(args.dir ?? join(dirname(fileURLToPath(import.meta.url)), "..", "..", "examples", "illunis", "knowledge"));
  if (args.only?.some((b) => !EXPERT_IDS.includes(b))) {
    console.error("ingest-knowledge: --only names an unknown expert");
    return 2;
  }
  const built = buildRecords(dir);
  const banks = args.only ?? Object.keys(built.files).sort();
  const records = built.records.filter((r) => banks.includes(r.namespace));
  const expected = Object.fromEntries(banks.map((b) => [b, built.files[b] ?? 0]));
  for (const p of built.problems) console.error(`ingest-knowledge: skip ${p}`);
  const summary = banks.map((b) => `${b} ${expected[b]} files`).join(", ") || "none";
  console.log(`ingest-knowledge: ${basename(dir)}/ ${summary}; ${records.length} chunks`);
  if (args.dryRun) return built.problems.length ? 1 : 0;
  if (built.problems.length) {
    console.error("ingest-knowledge: fix the skipped notes before ingest");
    return 1;
  }
  const serverUrl = (process.env.ILLUNIS_SERVER_URL ?? "").replace(/\/+$/, "");
  const token = process.env.ILLUNIS_DEVICE_TOKEN ?? "";
  if (!/^https:\/\/[^/\s]+$/.test(serverUrl) || !token) {
    console.error("ingest-knowledge: ILLUNIS_SERVER_URL (https) and ILLUNIS_DEVICE_TOKEN required");
    return 2;
  }
  try {
    const upserted = await postRecords(records, { serverUrl, token });
    console.log(`ingest-knowledge: upserted ${upserted} chunks`);
    if (args.verify) {
      const v = await verifyCounts(expected, { serverUrl, token });
      if (!v.ok) {
        console.error(`ingest-knowledge: VERIFY FAIL counts differ for ${v.bad.join(", ")}`);
        return 1;
      }
      console.log("ingest-knowledge: verify ok");
    }
  } catch (err) {
    // Fixed codes only: never the response body.
    console.error(`ingest-knowledge: FAIL ${/^[\w ]+$/.test(err?.message ?? "") ? err.message : "error"}`);
    return 1;
  }
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main();
}
