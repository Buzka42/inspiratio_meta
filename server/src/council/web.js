// Web search for the council relay (contract C3). Meta's Responses web search first when Meta is usable,
// else Tavily, else null. Search failures return null (or fall through to the next source): the relay
// must still answer without web sources. Imports only providers/meta.js, providers/tavily.js and data-mode.js.
// Forums, video and social sites are never council sources (live run 2026-10-30 cited r/Fitness and a YouTube
// short for a stretching answer): Tavily is asked to leave them out, and any that still come back are dropped.
import { META_PROVIDER, metaConfigProblem, metaModel, webSearchMeta } from "../providers/meta.js";
import { searchTavily, tavilyConfigProblem } from "../providers/tavily.js";
import { dataModeProblem } from "../data-mode.js";

export const WEB_TEXT_MAX = 1200;
export const EXCLUDED_DOMAINS = Object.freeze([
  "reddit.com", "youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com", "x.com", "twitter.com",
  "quora.com", "pinterest.com", "medium.com",
]);

const clip = (s) => String(s ?? "").trim().slice(0, WEB_TEXT_MAX);

// True for a URL on an excluded domain or one of its subdomains; an unparsable URL counts as excluded.
export function excludedSource(url) {
  let host;
  try {
    host = new URL(String(url)).hostname.toLowerCase().replace(/\.$/, "");
  } catch {
    return true;
  }
  return EXCLUDED_DOMAINS.some((d) => host === d || host.endsWith(`.${d}`));
}
const kept = (results) => (Array.isArray(results) ? results : []).filter((r) => !excludedSource(r?.url));

// Per-provider timeouts when the caller gives none (the providers' own defaults).
const META_TIMEOUT_MS = 20_000;
const TAVILY_TIMEOUT_MS = 8000;

// Returns { text, results: [{title, url, content}], via: "meta" | "tavily" } or null.
// deadlineAt (epoch ms, optional): each attempt gets min(timeoutMs ?? provider default, deadlineAt - now);
// with no time left, null is returned and nothing more is called. Without deadlineAt, timeoutMs works as before.
export async function searchWeb(query, env = {}, { fetchFn = fetch, timeoutMs, deadlineAt } = {}) {
  const budget = (def) => {
    if (deadlineAt == null) return timeoutMs;
    const left = Number(deadlineAt) - Date.now();
    return left > 0 ? Math.min(timeoutMs ?? def, left) : null;
  };
  const metaOk = !metaConfigProblem(env) && !dataModeProblem(env, { provider: META_PROVIDER, model: metaModel(env), role: "council" });
  if (metaOk) {
    const t = budget(META_TIMEOUT_MS);
    if (t === null) return null;
    try {
      const got = await webSearchMeta(query, env, { fetchFn, timeoutMs: t });
      const text = clip(got?.text);
      const sources = kept(got?.results);
      // Meta counts only with text and at least one kept citation; an uncited summary falls through to Tavily.
      // The summary is attached once, to the first source, so it is not repeated per source; the others carry
      // their own snippet when the provider gave one (Meta's citations are url and title only), else "".
      if (text && sources.length) {
        const results = sources.map((r, i) => ({ title: r.title, url: r.url, content: i === 0 ? text : clip(r.content) }));
        return { text, results, via: "meta" };
      }
    } catch {
      // Meta unavailable or incomplete: try Tavily below.
    }
  }
  if (!tavilyConfigProblem(env, "council")) {
    const t = budget(TAVILY_TIMEOUT_MS);
    if (t === null) return null;
    try {
      const got = await searchTavily(query, env, { fetchFn, timeoutMs: t, role: "council", excludeDomains: EXCLUDED_DOMAINS });
      const results = kept(got.results);
      const text = clip(got.answer || results.map((r) => r.content).join(" "));
      // Tavily sources keep their own per-result snippets; the summary is the answer and is not copied onto them.
      if (text) return { text, results: results.map(({ title, url, content }) => ({ title, url, content })), via: "tavily" };
    } catch {
      return null;
    }
  }
  return null;
}
