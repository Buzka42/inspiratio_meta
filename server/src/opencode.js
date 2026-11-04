// OpenCode Go client. OpenAI-compatible chat completions. Inject fetchFn for tests.
// The endpoint answers 400 MissingSessionID unless x-opencode-session is sent.
export const OPENCODE_URL = "https://opencode.ai/zen/v1/chat/completions";
export const SESSION_HEADER = "x-opencode-session";

export async function chatJson(messages, env, { fetchFn = fetch, model, sessionId } = {}) {
  if (typeof sessionId !== "string" || !sessionId) throw new Error("opencode session id required");
  const res = await fetchFn(env?.OPENCODE_BASE_URL || OPENCODE_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env?.OPENCODE_API_KEY}`,
      "Content-Type": "application/json",
      [SESSION_HEADER]: sessionId,
    },
    body: JSON.stringify({
      model,
      messages,
      temperature: 0.4,
      max_tokens: 2048,
      response_format: { type: "json_object" },
    }),
  });
  if (!res.ok) throw new Error(`opencode ${res.status}`);
  const data = await res.json();
  const content = data.choices?.[0]?.message?.content;
  if (!content) throw new Error("opencode returned no content");
  return content;
}
