// Food calorie check for /log/parse (contract C6). Plain code only: queries Tavily for each item the user gave
// kcal for (at most 3 searches), reads the first kcal figure in the results, scales it to the user's quantity,
// and compares. A mismatch is never applied here: the caller returns it as a choice. No logging.
export const FOOD_CHECK_MAX = 3;
const KCAL_RE = /(\d{1,3}(?:,\d{3})+|\d+(?:[.,]\d+)?)\s*(?:kcal|calories)\b/i;
const MATCH_FLOOR = 25;
const MATCH_RATIO = 0.15;

// "1,200" is a thousands mark; "1,2" and "1.2" are decimals.
const parseKcal = (raw) => (/^\d{1,3}(?:,\d{3})+$/.test(raw) ? Number(raw.replace(/,/g, "")) : Number(raw.replace(",", ".")));

const bulk = (unit) => unit === "g" || unit === "ml";
const per100 = (item) => bulk(item.unit) && item.quantity !== undefined;

// Query per C6: per 100 g/ml for a stated gram or ml quantity, else per the unit (or serving).
export function foodQuery(item) {
  if (per100(item)) return `${item.name} calories per 100 ${item.unit}`;
  return `${item.name} calories per ${bulk(item.unit) || item.unit === undefined ? "serving" : item.unit}`;
}

// Factor from the found figure to the user's quantity.
const scaleOf = (item) => (per100(item) ? item.quantity / 100 : (item.quantity ?? 1));

// First result whose text states kcal or calories: { value (scaled, rounded), url, title } or null.
// A gram or millilitre item is only compared with a figure stated per 100 g or 100 ml, so a per-cup or
// per-piece number is never multiplied by the quantity (live check 2026-10-29: 205 kcal per cup became 410).
const PER_100 = /\b100\s*(?:g|grams?|ml|millilitres?|milliliters?)\b/i;
// The kcal figure must sit within 60 characters of a per-100 g or per-100 ml basis: a per-cup figure elsewhere in
// the same snippet is skipped.
const BASIS_100 = /(?:per|\/|for|every)\s*100\s*(?:g|grams?|ml|millilitres?|milliliters?)\b/i;
// A figure next to a per-serving or per-piece phrase is a different basis, even when "100 g" is also nearby
// (live check 2026-10-30: a Dole page gave 66 kcal per banana as if it were per 100 g).
const OTHER_BASIS = /(?:per|a|one|1|each|medium|large|small)\s+(?:medium|large|small|whole|cup|cups|piece|pieces|slice|slices|serving|servings|banana|bananas|egg|eggs|tbsp|tablespoon|tsp|teaspoon|fruit|portion)\b|\b(?:medium|large|small)\s+(?:banana|apple|egg|orange|pear)\b/i;
function kcalPer100(text) {
  const re = new RegExp(KCAL_RE.source, "gi");
  let m;
  while ((m = re.exec(text))) {
    // The basis closest to the figure decides: per 100 g only when it is nearer than any per-serving phrase.
    const from = Math.max(0, m.index - 40);
    const near = text.slice(from, m.index + m[0].length + 40);
    const center = m.index - from + m[0].length / 2;
    const nearest = (re) => {
      const g = new RegExp(re.source, "gi");
      let best = Infinity, x;
      while ((x = g.exec(near))) best = Math.min(best, Math.abs(x.index + x[0].length / 2 - center));
      return best;
    };
    if (nearest(BASIS_100) < nearest(OTHER_BASIS)) return m;
  }
  return null;
}
function pick(results, item) {
  const scale = scaleOf(item);
  // Every result that states a usable figure votes; the median is compared with the user's number, so one
  // wrong site cannot decide the check. The source shown is the result closest to the median.
  const votes = [];
  for (const r of results) {
    const text = String(r?.content ?? "");
    const m = per100(item) ? kcalPer100(text) : KCAL_RE.exec(text);
    if (!m) continue;
    const n = parseKcal(m[1]);
    if (!Number.isFinite(n)) continue;
    votes.push({ value: Math.round(n * scale), url: r.url, title: r.title });
  }
  if (!votes.length) return null;
  const sorted = [...votes].sort((a, b) => a.value - b.value);
  const median = sorted[Math.floor((sorted.length - 1) / 2)].value;
  const best = votes.reduce((a, b) => (Math.abs(b.value - median) < Math.abs(a.value - median) ? b : a));
  return { value: median, url: best.url, title: best.title };
}

export const kcalMatches = (user, found) => Math.abs(user - found) <= Math.max(MATCH_FLOOR, MATCH_RATIO * found);

// Model extraction for gram and millilitre items (decision 2026-10-30, live checks): the model reads the snippets and
// proposes the energy per 100 g or 100 ml. Code keeps the figure only if the number really appears in the snippet it
// names, and never uses a per-serving figure. A null answer means unverified, not a guess.
export async function extractPer100(item, results, callFn) {
  const snippets = (results ?? []).map((r) => String(r?.content ?? "").slice(0, 1200)).filter(Boolean).slice(0, 5);
  if (!snippets.length) return null;
  const messages = [
    { role: "system", content: 'Reply with JSON only: {"kcal_per_100": number or null, "snippet": number or null}. Use only the energy stated PER 100 g or PER 100 ml of the food. Never use a figure per piece, serving, cup, slice or portion. If no such figure is stated, reply null for both.' },
    { role: "user", content: JSON.stringify({ food: item.name, snippets: snippets.map((text, index) => ({ index, text })) }) },
  ];
  let out;
  try {
    out = await callFn(messages);
  } catch {
    return null;
  }
  let answer;
  try {
    answer = JSON.parse(String(out?.content ?? "").replace(/<think>[\s\S]*?<\/think>/gi, "").match(/\{[\s\S]*\}/)?.[0] ?? "null");
  } catch {
    return null;
  }
  const value = Number(answer?.kcal_per_100);
  const idx = Number.isInteger(answer?.snippet) ? answer.snippet : -1;
  if (!Number.isFinite(value) || value <= 0 || value > 900 || idx < 0 || idx >= snippets.length) return null;
  const text = snippets[idx];
  const shown = new RegExp(`(^|[^0-9.])${String(answer.kcal_per_100).replace(".", "\\.")}([^0-9]|$)`);
  if (!shown.test(text)) return null;
  const scaled = Math.round(value * scaleOf(item));
  const r = (results ?? [])[idx];
  return { value: scaled, url: r?.url, title: r?.title };
}

// The figure used for a check: the model's per-100 g extraction for gram and millilitre items, else the regex pick.
async function pickFor(item, results, extractFn) {
  if (per100(item) && extractFn) return extractFn(item, results);
  return pick(results, item);
}

async function checkItem(item, item_index, searchFn, extractFn) {
  let results;
  try {
    results = (await searchFn(foodQuery(item))).results ?? [];
  } catch {
    return { item_index, status: "unverified" };
  }
  const found = await pickFor(item, results, extractFn);
  if (!found) return { item_index, status: "unverified" };
  const source = { source_url: found.url, source_title: found.title };
  if (kcalMatches(item.kcal, found.value)) return { item_index, status: "match", ...source };
  return { item_index, status: "mismatch", field: "kcal", user_value: item.kcal, found_value: found.value, ...source };
}

// Returns one row per checked item: status "match" | "unverified" | "mismatch" (mismatch rows carry the choice).
// searchFn(query) -> {results}; it may throw, which makes the item "unverified".
export async function foodCheck(entry, searchFn, extractFn) {
  // Estimated items (kcal_estimated) were filled from the same search, so they are not checked again.
  const picks = (entry.items ?? []).map((item, i) => ({ item, i })).filter(({ item }) => item.kcal !== undefined && !item.kcal_estimated).slice(0, FOOD_CHECK_MAX);
  return Promise.all(picks.map(({ item, i }) => checkItem(item, i, searchFn, extractFn)));
}

// Estimates for foods logged without a stated figure (owner, 2026-10-30): the same search and the same per-100 g
// rule. An estimate is written as kcal with kcal_estimated true and its source, never as a stated figure, so the
// phone can label it. Items with no usable figure stay without calories.
export async function estimateFood(entry, searchFn, extractFn) {
  const todo = (entry.items ?? []).map((item, i) => ({ item, i })).filter(({ item }) => item.kcal === undefined && item.name).slice(0, FOOD_CHECK_MAX);
  const results = await Promise.all(todo.map(async ({ item, i }) => {
    let found = null;
    try {
      found = await searchFn(foodQuery(item));
    } catch {
      return { item_index: i, status: "unverified" };
    }
    const hit = await pickFor(item, found?.results ?? found ?? [], extractFn);
    if (!hit) return { item_index: i, status: "unverified" };
    item.kcal = hit.value;
    item.kcal_estimated = true;
    item.kcal_source = { source_url: hit.url, source_title: hit.title };
    return { item_index: i, status: "estimated", source_url: hit.url, source_title: hit.title };
  }));
  return results;
}
