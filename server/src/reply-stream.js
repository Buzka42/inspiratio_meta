// POST /reply/stream: the /reply rules (reply.js prepareReply, safety.js gate and health line),
// with the model called using stream: true and the reply sent as SSE, one sentence per event.
//   event: sentence  data: {"text": "..."}                          a gated sentence, in order
//   event: done      data: {"text", "personality_id", "safety", "health", "council_suggested"}  the last piece
//   event: error     data: {"error": "reply_upstream" | "reply_timeout"}   then close
// Hold-back: a sentence is released only after the next sentence is complete and the whole text
// so far passes the gate, or the model ended. The last sentence goes out in `done`, after the gate,
// with the health line when the model marked the reply (HEALTH_MARKER as its first tokens, safety.js).
// Marker: nothing is split into sentences until the visible start of the stream is known to be the marker or not;
// the marker is skipped and never sent. A marker later in the text is removed from its sentence and also counts.
// Gate failure (contract C4): the failing sentence is never sent. A crisis phrase ends the stream with the
// referral ("replaced"). Any other broken rule gets one non-stream repair call with the assistant text so far;
// its continuation (gated) arrives as done.text with safety "repaired" and the client appends it. A failed or
// late repair gives SAFE_FALLBACK_TEXT, "replaced" (sentences already sent stay sent; the client stops speech
// on "replaced"). Crisis input is decided in prepareReply, before any model call.
// Meta (Muse): stream: true is unverified, so the /reply call runs whole (answerReply) and its result goes out as
// one done event, or the error event on failure; no sentence events, and the client hears nothing until it ends.
// Nebius streaming is documented (docs/RESEARCH.md (streaming replies)). OpenCode (opencode_poc)
// streaming is UNVERIFIED: its docs do not say whether stream: true works.
// Nothing here logs or returns model text; errors carry fixed codes only.
import {
  REFERRAL_TEXT, SAFE_FALLBACK_TEXT, gateViolation, leadingHealthMarker, stripHealthMarker, withHealthLine,
} from "./safety.js";
import { councilSuggested } from "./council-trigger.js";
import {
  MIN_OPENING, REPAIR_TIMEOUT_MS, REPLY_TIMEOUT_MS, TimeoutError, answerReply, callModel, isTimeout, prepareReply, repairMessages, replyEndpoint,
  requestBody, stripThinking,
} from "./reply.js";
import { META_PROVIDER } from "./providers/meta.js";

export const STREAM_TIMEOUT_MS = 30_000; // whole stream, first byte included
export const MIN_SENTENCE = 20; // shorter pieces merge with the next sentence
export const MAX_SENTENCE = 400; // a run-on without an ending is cut at a space
export const MIN_REPAIR_MS = 1000; // less stream time left than this: no repair call, the safe fallback
export const STREAM_REPAIR_TAIL =
  "Rewrite only your last sentence and finish the reply; do not repeat earlier sentences.";

// A sentence ends at . ! ? or … (Polish uses the same marks), optional closing quotes or
// brackets (incl. Polish ” and »), then whitespace and a character that is not lowercase.
// The lookahead means the next sentence has started before a split is made.
const ENDING = /[.!?…]+["'”’»)\]]*\s+(?=[^\s\p{Ll}])/gu;

// Removes complete <think> blocks; text from an unclosed <think> on is not ready yet.
function visible(buffer) {
  const s = buffer.replace(/<think>[\s\S]*?<\/think>/gi, "");
  const open = s.search(/<think>/i);
  return open === -1 ? s : s.slice(0, open);
}

// Splits ready text into whole sentences. Returns { sentences, rest }.
export function splitSentences(text, min = MIN_SENTENCE, max = MAX_SENTENCE) {
  const sentences = [];
  let start = 0;
  for (const m of text.matchAll(ENDING)) {
    const end = m.index + m[0].length;
    const piece = text.slice(start, end).trim();
    if (piece.length >= min) {
      sentences.push(piece);
      start = end;
    }
  }
  let rest = text.slice(start);
  while (rest.length > max) {
    const cut = rest.lastIndexOf(" ", max);
    const at = cut > 0 ? cut : max;
    sentences.push(rest.slice(0, at).trim());
    rest = rest.slice(at);
  }
  return { sentences: sentences.filter(Boolean), rest };
}

// Yields content strings from an OpenAI-compatible SSE body. Only delta.content is read;
// reasoning fields are ignored. An `error` object in the stream throws a fixed error.
async function* upstreamDeltas(body) {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      pending += done ? decoder.decode() : decoder.decode(value, { stream: true });
      const lines = pending.split(/\r?\n/);
      pending = done ? "" : lines.pop();
      for (const line of lines) {
        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (data === "[DONE]") return;
        let obj;
        try {
          obj = JSON.parse(data);
        } catch {
          throw new Error("upstream bad chunk");
        }
        if (obj?.error) throw new Error("upstream error event");
        const content = obj?.choices?.[0]?.delta?.content;
        if (typeof content === "string" && content) yield content;
      }
      if (done) return;
    }
  } finally {
    reader.releaseLock?.();
  }
}

const sse = (event, data) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

const join = (a, b) => (a ? `${a} ${b}` : b);

// Drops sentences the model repeated from the start of its continuation.
export function dropRepeats(text, earlier) {
  let t = String(text ?? "").trim();
  for (let again = true; again; ) {
    again = false;
    for (const s of earlier) {
      if (s && t.startsWith(s)) {
        t = t.slice(s.length).trim();
        again = true;
      }
    }
  }
  return t;
}

// Yields SSE event strings for one model stream. `code` is reported through onFinish.
async function* replyEvents({ personality, messages, transcript, env, fetchFn, signal, timedOut, remaining, onFinish }) {
  const done = (text, safety, health, code) => {
    onFinish(code);
    return sse("done", { text, personality_id: personality.id, safety, health, council_suggested: councilSuggested(transcript, safety) });
  };
  const fail = (err) => {
    const code = timedOut() || isTimeout(err) ? "reply_timeout" : "reply_upstream";
    onFinish(code);
    return sse("error", { error: code });
  };

  let buffer = ""; // raw content, think blocks included
  let used = -1; // length of visible text already split into sentences; -1 until the marker is known
  let health = false; // the model marked the reply
  let accepted = ""; // gated text so far, held-back sentence included
  const released = []; // gated sentences, in order (sent ones and the held one)
  let held = null;
  // Removes a marker from model text; any marker found sets health.
  const unmark = (text) => {
    const out = stripHealthMarker(text);
    health ||= out.health;
    return out.text;
  };
  // Decides the leading marker once. Returns false while the start may still become the marker.
  const markerKnown = (ready, final = false) => {
    if (used >= 0) return true;
    const lead = leadingHealthMarker(ready, final);
    if (!lead) return false;
    health ||= lead.health;
    used = lead.start;
    return true;
  };
  // Gates the new sentence together with everything before it, so the gate sees what /reply would.
  // Returns the violation (null when it passes and the sentence is accepted).
  const gate = (sentence) => {
    const v = gateViolation(join(accepted, sentence));
    if (v === null) {
      accepted = join(accepted, sentence);
      released.push(sentence);
    }
    return v;
  };

  // One repair call for a failing sentence. Returns { text, safety, code }.
  const repair = async (failing, rule) => {
    const fallback = { text: SAFE_FALLBACK_TEXT, safety: "replaced", code: "reply_replaced" };
    const ms = Math.min(REPAIR_TIMEOUT_MS, remaining());
    if (ms < MIN_REPAIR_MS) return fallback;
    let next;
    try {
      const raw = await callModel(repairMessages(messages, join(accepted, failing), rule, STREAM_REPAIR_TAIL), env, fetchFn, ms);
      next = dropRepeats(unmark(raw), released);
    } catch {
      return fallback;
    }
    if (!next) return fallback;
    const v = gateViolation(join(accepted, next));
    if (v === null) return { text: next, safety: "repaired", code: "reply_repaired" };
    if (v === "crisis") return { text: REFERRAL_TEXT, safety: "replaced", code: "reply_crisis" };
    return fallback;
  };

  // A failing sentence ends the stream. The held sentence passed the gate; it goes out only before a repaired
  // continuation (on "replaced" the client stops speech anyway).
  async function* gateFailed(failing, rule) {
    const out = rule === "crisis" ? { text: REFERRAL_TEXT, safety: "replaced", code: "reply_crisis" } : await repair(failing, rule);
    if (out.safety === "repaired" && held !== null) yield sse("sentence", { text: held });
    yield done(health ? withHealthLine(out.text) : out.text, out.safety, health, out.code);
  }

  // A second copy of the reply (reply.js cutRepeat): once the opening sentence comes back, nothing more is taken.
  let repeated = false;
  const cutCopy = (s) => {
    const opening = released[0];
    if (!opening || opening.length < MIN_OPENING) return s;
    const at = s.indexOf(opening);
    if (at < 0) return s;
    repeated = true;
    return s.slice(0, at).trim();
  };

  // Unmarks, gates and holds back the sentences. Returns the gate failure as [sentence, rule], or null.
  function* take(sentences) {
    for (const raw of sentences) {
      if (repeated) return null;
      const s = cutCopy(unmark(raw));
      if (!s) continue;
      const v = gate(s);
      if (v) return [s, v];
      if (held !== null) yield sse("sentence", { text: held });
      held = s;
    }
    return null;
  }

  try {
    const { url, model, headers } = replyEndpoint(env);
    const res = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "text/event-stream", ...headers },
      signal,
      body: requestBody(model, messages, true, env),
    });
    if (!res.ok || !res.body) throw new Error("upstream status");
    for await (const delta of upstreamDeltas(res.body)) {
      buffer += delta;
      const ready = visible(buffer);
      if (!markerKnown(ready)) continue;
      const { sentences, rest } = splitSentences(ready.slice(used));
      used = ready.length - rest.length;
      const failed = yield* take(sentences);
      if (failed) return yield* gateFailed(...failed);
    }
    if (timedOut()) throw new TimeoutError();
    markerKnown(visible(buffer), true);
    const failed = yield* take([stripThinking(visible(buffer).slice(used))]);
    if (failed) return yield* gateFailed(...failed);
    if (held === null) throw new Error("upstream empty");
    yield done(health ? withHealthLine(held) : held, "passed", health, null);
  } catch (err) {
    yield fail(err);
  }
}

export const SSE_HEADERS = { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store" };

// Returns { status, body, code, ignored } for a JSON answer (400, 503), or
// { status: 200, stream, ignored } where stream is a ReadableStream of SSE bytes.
// onFinish(code) is called once with a fixed code (null on success) when the stream ends.
export async function runReplyStream({
  plan, transcript, phone, env = {}, memoryStore, now = Date.now(), fetchFn = fetch,
  timeoutMs = STREAM_TIMEOUT_MS, onFinish = () => {}, spec = null,
}) {
  const prep = await prepareReply({ plan, transcript, phone, env, memoryStore, now, spec });
  const encoder = new TextEncoder();
  let finished = false;
  const finish = (code) => {
    if (!finished) {
      finished = true;
      onFinish(code);
    }
  };

  if (prep.early) {
    if (prep.early.status !== 200) return prep.early;
    // Crisis: the fixed referral as the only event, no model call.
    const { text, personality_id, safety, health, council_suggested } = prep.early.body;
    const bytes = encoder.encode(sse("done", { text, personality_id, safety, health, council_suggested }));
    finish(prep.early.code);
    return { status: 200, ignored: prep.early.ignored, stream: new Blob([bytes]).stream() };
  }

  if (env.REPLY_PROVIDER === META_PROVIDER) {
    return { status: 200, ignored: prep.ignored, stream: wholeReplyStream({ ...prep, transcript, env, fetchFn, timeoutMs: Math.min(timeoutMs, REPLY_TIMEOUT_MS) }, finish) };
  }

  const controller = new AbortController();
  const startedAt = Date.now();
  let expired = false;
  const timer = setTimeout(() => {
    expired = true;
    controller.abort();
  }, timeoutMs);
  const events = replyEvents({
    ...prep, transcript, env, fetchFn, signal: controller.signal, timedOut: () => expired, onFinish: finish,
    remaining: () => timeoutMs - (Date.now() - startedAt),
  });
  const stop = () => clearTimeout(timer);
  const stream = new ReadableStream({
    async pull(ctl) {
      const { value, done } = await events.next();
      if (done) {
        stop();
        ctl.close();
      } else {
        ctl.enqueue(encoder.encode(value));
      }
    },
    async cancel() {
      // Client went away: stop the upstream call. No event can be delivered now.
      stop();
      controller.abort();
      finish("reply_client_closed");
      await events.return();
    },
  });
  return { status: 200, ignored: prep.ignored, stream };
}

// One /reply call sent as the stream's last event: done with the /reply body, or error with its fixed code.
// A client that goes away does not stop the call; it ends at its own timeout.
function wholeReplyStream(args, finish) {
  let closed = false;
  return new ReadableStream({
    async pull(ctl) {
      const out = await answerReply(args).catch(() => ({ status: 502, body: { error: "reply_upstream" }, code: "reply_upstream" }));
      finish(out.code);
      if (closed) return;
      ctl.enqueue(new TextEncoder().encode(out.status === 200 ? sse("done", out.body) : sse("error", { error: out.body.error })));
      ctl.close();
    },
    cancel() {
      closed = true;
      finish("reply_client_closed");
    },
  });
}
