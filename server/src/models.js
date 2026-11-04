// Every model id the server uses, with the provider for each role. Edit model ids here only.
// TARGET before submission (owner decision 2026-10-24): every role on Nebius Token Factory.
// OpenCode Go rows are dev/test only. Env overrides (the `env` column) still win at runtime and
// are read where the call is made; the provider switch itself is REPLY_PROVIDER / MEMORY_PROVIDER.
// Providers: opencode_poc = OpenCode Go behind a PoC switch, opencode = OpenCode Go (council),
// nebius = Nebius Token Factory. No keys here.

// Daily talk is the reply role: /reply and /reply/stream share one endpoint.
export const MODELS = Object.freeze({
  // REPLY_PROVIDER=opencode_poc. Test deploys may set REPLY_LLM_MODEL (e.g. nemotron-3.5-lightning-free).
  reply: Object.freeze({ provider: "opencode_poc", model: "nemotron-3.5-lightning-free", env: "REPLY_LLM_MODEL" }),
  // REPLY_PROVIDER=openrouter_poc (test/PoC only, synthetic data). REPLY_LLM_MODEL still overrides.
  reply_openrouter: Object.freeze({ provider: "openrouter_poc", model: "nvidia/nemotron-3.5-lightning:free", env: "REPLY_LLM_MODEL" }),
  // REPLY_PROVIDER=nebius, the target. No default: REPLY_LLM_MODEL is required (nebius.js refuses without it).
  reply_nebius: Object.freeze({ provider: "nebius", model: null, env: "REPLY_LLM_MODEL" }),
  // REPLY_PROVIDER=meta, the Meta build (D3). No default: META_MODEL is required (providers/meta.js), never a
  // *-contributor id. Non-stream only; max_tokens floor 2000 (Muse hidden reasoning), no reasoning field.
  reply_meta: Object.freeze({ provider: "meta", model: null, env: "META_MODEL" }),
  // MEMORY_PROVIDER=poc_opencode_nebius: fact extraction on OpenCode Go, embeddings on Nebius.
  memory_llm: Object.freeze({ provider: "opencode_poc", model: "glm-5.3-flash-free", env: "MEMORY_LLM_MODEL" }),
  memory_embed: Object.freeze({ provider: "nebius", model: "Qwen/Qwen3-Embedding-8B", env: "MEMORY_EMBED_MODEL" }),
  // COUNCIL_TEST_PROVIDER=openrouter_poc (owner, 2026-10-25): council v2 and session summaries on free Nemotron
  // via OpenRouter while testing. Nebius is for the final build only.
  // One row per role. reasoning: the OpenRouter reasoning object sent with each call; json: the free endpoint
  // lists response_format (GET /api/v1/models, 2026-10-25), otherwise the reply parsers pull JSON from text.
  // fallback: tried once when the first model has no live endpoint (404), is rate limited per minute or upstream
  // (429, not the account's per-day cap) or answers 5xx.
  // Endpoint health, GET /api/v1/models/<id>/endpoints (2026-10-25): lightning and ultra up 100% over 30 min,
  // super-vl degraded, super-120b and nano-omni down (super-120b answered 404 live). Live: lightning answered a
  // summary in 0.98 s end to end; an ultra relay run hit the 12 s per-call limit, so ultra is the fallback only.
  council_test: Object.freeze({
    provider: "openrouter_poc", model: "nvidia/nemotron-3.5-lightning:free", env: "COUNCIL_TEST_MODEL",
    reasoning: Object.freeze({ effort: "none" }), json: false, fallback: "nvidia/nemotron-3-ultra-550b-a55b:free",
  }),
  council_test_expert: Object.freeze({ provider: "openrouter_poc", model: "nvidia/nemotron-3.5-lightning:free", env: "COUNCIL_TEST_EXPERT_MODEL", reasoning: Object.freeze({ effort: "none" }), json: false }),
  summary_test: Object.freeze({ provider: "openrouter_poc", model: "nvidia/nemotron-3.5-lightning:free", env: "COUNCIL_TEST_SUMMARY_MODEL", reasoning: Object.freeze({ effort: "none" }), json: false }),
  // Council v2 brain (owner, 2026-10-25; neutral naming D-E, 2026-10-29): the Meta Model API first when
  // META_API_KEY is set (the Meta build), Nebius otherwise. No model id in code: META_MODEL is required with
  // META_API_KEY. Never a *-contributor id: those train on prompts.
  council_primary: Object.freeze({ provider: "meta", model: null, env: "META_MODEL" }),
  // The council brain on Nebius. No default: COUNCIL_NEBIUS_MODEL is required.
  council_nebius: Object.freeze({ provider: "nebius", model: null, env: "COUNCIL_NEBIUS_MODEL" }),
});

// Council members on OpenCode Go (no env override). Ids verified against the OpenCode Go model
// list (2026-10-23). The Meta model is out: OpenCode Go only offers it as a contributor tier, which
// trains on prompts. mimo-v2.6-flash is a placeholder, picked only because it is non-Contributor.
// Legacy three-round council, a test provider: COUNCIL_PROVIDER=opencode and DATA_MODE=synthetic only.
export const COUNCIL_PROVIDER = "opencode";
// Council set (owner, 2026-10-25), from the OpenCode ZEN free list (zen/v1/models). Zero-retention, no training
// for deepseek and glm; nemotron uses NVIDIA trial terms (no personal data). The Meta model is not on Zen.
export const COUNCIL_MODELS = Object.freeze({
  deepseek: "deepseek-v4.1-flash-free",
  glm: "glm-5.3-flash-free",
  nemotron: "nemotron-3.5-super-vl-free",
});

// COUNCIL_PROVIDER=openrouter_poc (owner, 2026-10-25): free NVIDIA models on OpenRouter, test/PoC only,
// synthetic data only. Keyed by the same three persona ids (and styles) as COUNCIL_MODELS; unset COUNCIL_PROVIDER
// keeps OpenCode Zen.
export const OPENROUTER_COUNCIL_PROVIDER = "openrouter_poc";
export const OPENROUTER_MEMBERS = Object.freeze({
  deepseek: "nvidia/nemotron-3.5-lightning:free",
  glm: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
  nemotron: "nvidia/nemotron-3-ultra-550b-a55b:free",
});
