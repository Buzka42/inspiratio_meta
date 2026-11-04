// Shared number check (docs/DESIGN.md section 4: the model extracts, plain code computes).
// numbersIn is the exact check analysis/phrase.js has always used: digit runs with an optional
// "." or "," decimal part, read with "," as the decimal mark.
export const NUMBER_RE = /\d+(?:[.,]\d+)?/g;

export const numbersIn = (text) => (String(text).match(NUMBER_RE) ?? []).map((n) => Number(n.replace(",", ".")));

// Numbers the user stated in their own text, for the log check (logs/schemas.js). Wider than numbersIn:
// "1,500" also counts as 1500, and simple English number words count ("two eggs" states 2).
const WORDS = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18,
  nineteen: 19, twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90,
  hundred: 100, a: 1, an: 1, single: 1, double: 2, couple: 2, dozen: 12, half: 0.5,
};
const WORD_RE = new RegExp(`\\b(?:${Object.keys(WORDS).join("|")})\\b`, "gi");

export function statedNumbers(text) {
  const s = String(text ?? "");
  const out = new Set(numbersIn(s));
  for (const m of s.match(NUMBER_RE) ?? []) if (m.includes(",")) out.add(Number(m.replace(",", "")));
  for (const m of s.match(WORD_RE) ?? []) out.add(WORDS[m.toLowerCase()]);
  return out;
}

// Every number in `values` (numbers, and digit runs inside strings) must be in `allowed`.
export function numbersOutside(values, allowed) {
  const found = [];
  for (const v of values) {
    if (typeof v === "number") found.push(v);
    else if (typeof v === "string") found.push(...numbersIn(v));
  }
  return found.filter((n) => !allowed.has(n));
}
