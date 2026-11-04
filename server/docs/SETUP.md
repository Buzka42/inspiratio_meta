# Server setup

Cloudflare Worker, plain JavaScript. Run tests with `npm test`.

## Environment variables (names only, never commit values)

Secrets (`wrangler secret put <NAME>`):
- `META_API_KEY`: Meta Model API key (dev.meta.ai), the main council provider.
- `NEBIUS_API_KEY`: Nebius Token Factory key (reply provider, council, log parse, embeddings).
- `TAVILY_API_KEY`: Tavily search key, expert web search and food checks in `/log/parse`. Refused
  under `DATA_MODE=owner_real`.
- `OPENCODE_API_KEY`: OpenCode key, legacy test council and PoCs only, `DATA_MODE=synthetic` only. Not used on the
  Nebius deploy; delete it last (see Nebius deploy).
- `MEMORY_KEY`: Graphiti server key.
- `DEVICE_TOKEN_SECRET`: HMAC secret for device tokens, at least 32 characters.
- `REPLY_LLM_KEY`: optional bearer key for the self-hosted reply endpoint.
- `HERMES_API_KEY`: the Hermes `illunis` profile's `API_SERVER_KEY` (piped in by `integrations/hermes/setup_profile.sh`).
- `ILLUNIS_INBOX_SECRET`: shared with the profile; signs inbox pushes and action approvals (at least 32 characters).
- `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`: the Cloudflare Access service token in front of the tunnel.

Plain vars:
- `DATA_MODE`: `owner_real` (default when unset) or `synthetic`. `owner_real` refuses contributor models and the
  free OpenCode/OpenRouter providers on the council, reply and memory paths. Any other value is refused.
- `COUNCIL_NEBIUS_MODEL`: council model id on Nebius, required for the council fallback (no default). Copy the exact
  id from the Nebius model list; the code never names a model.
- `META_MODEL`: Meta model id, required when `META_API_KEY` is set (the literal default is removed).
  `*-contributor` ids are always refused.
- `META_BASE_URL`: optional, only `https://api.meta.ai/v1...` is accepted.
- `BASETEN_API_KEY` (secret): Baseten Model API key; turns on the Baseten brain (Muse Spark Open) in `callBrain`.
- `BASETEN_MODEL`: optional, default `meta-models/muse-spark-open`. `*-contributor` ids are refused.
- `BASETEN_BASE_URL`: optional, only `https://inference.baseten.co/v1...` is accepted.
- `COUNCIL_PROVIDER`: unset or `""` = council v2; `opencode` / `openrouter_poc` = legacy test council (synthetic only).
  `v2` is also accepted; the old `muse` value is removed.
- `QUOTA_SESSION_SUMMARIES_PER_DAY`: per-device daily limit on `/session/summary` (default 10).
- `OPENCODE_BASE_URL`: optional override of the OpenCode Go endpoint.
- `MEMORY_SERVER_URL`: Graphiti server on the owner's VPS.
- `MEMORY_LLM_BASE_URL`: self-hosted OpenAI-compatible LLM used by Graphiti.
- `MEMORY_EMBED_BASE_URL`: self-hosted OpenAI-compatible embedder used by Graphiti.
- `REPLY_LLM_BASE_URL`: self-hosted OpenAI-compatible base URL for `/reply` (for example ending in `/v1`).
- `REPLY_LLM_MODEL`: model name served by that endpoint (or the Nebius reply model when `REPLY_PROVIDER=nebius`).
- `REPLY_PROVIDER`: `nebius` selects Nebius for `/reply` and the stream; unset keeps the self-hosted endpoint.
- `LOG_LLM_MODEL`: optional model for `/log/parse`; falls back to `REPLY_LLM_MODEL`.
- `KNOWLEDGE_EMBED_PROVIDER`: `nebius` embeds expert knowledge with Nebius; unset uses Workers AI `@cf/baai/bge-m3`;
  any other value is refused.
- `KNOWLEDGE_EMBED_MODEL`: Nebius embedding model id, `Qwen/Qwen3-Embedding-8B`. Requested at
  `dimensions: 1024`, so the Vectorize index stays at 1024.
- `KNOWLEDGE_INGEST_DEVICE_ID`: the one device allowed to call `POST /knowledge/*`. Set only during ingest, then unset
 . Unset answers 503.
- `TOKEN_TTL_DAYS`: device token lifetime in days, read when a token is issued (default 90).
- `QUOTA_REPLIES_PER_DAY`: per-device daily limit on `/reply` (default 200).
- `QUOTA_TURNS_PER_DAY`: per-device daily limit on `/turn` (default 200).
- `QUOTA_COUNCIL_PER_DAY`: per-device daily limit shared by `/council` and `/analysis/21d`, plus one hit per
  `/digest` that runs the council (default 5).
- `QUOTA_DIGESTS_PER_DAY`: per-device daily limit shared by `/digest` and `/digest/voice` (default 20).
- `HERMES_BASE_URL`: `https://<tunnel host>`, host only (no path, port or query; http is refused).
- `HERMES_SESSION_ID`: id of the profile's "Bot Chat" session (`hermes -p illunis sessions list`).
- `ASSISTANT_OWNER_DEVICE_ID`: the one device linked to the assistant (hackathon single-owner link).
- `QUOTA_ASSISTANT_PER_DAY`: per-device daily limit shared by every `/assistant/*` route that calls Hermes (default 300).
- `QUOTA_INBOX_POLLS_PER_DAY`: per-device daily limit on `GET /assistant/inbox` (default 2000).

Bindings (in `wrangler.jsonc`): `QUOTA_DO` (QuotaCounter, migration `v1`) and `ASSISTANT_DO`
(AssistantInbox, migration `v2`), plus `AI` and `KNOWLEDGE` for the council.

## Device auth

Every route except `GET /health` needs `Authorization: Bearer <deviceId>.<iat>.<exp>.<hmac>`.
`iat` and `exp` are Unix seconds and `hmac` is base64url HMAC-SHA256 of
`<deviceId>.<iat>.<exp>` keyed by `DEVICE_TOKEN_SECRET`, so the expiry cannot be
edited. Lifetime is `TOKEN_TTL_DAYS` (default 90), set where the token is issued.
Comparison is constant time. All answers below are 401:

- no bearer token: `{ "error": "unauthorized" }`
- bad format, wrong signature, old two-part token, unset or short secret, or
  `iat` more than 60 seconds in the future: `code: "token_invalid"`
- past `exp`: `code: "token_expired"` (only after the signature checks)
- device on the revocation list: `code: "device_revoked"`

Script pair in `src/auth.js`: `issueDeviceToken(deviceId, env)` (env holds
`DEVICE_TOKEN_SECRET`, optional `TOKEN_TTL_DAYS`; prints nothing) and
`revokeDevice(deviceId, revocations)`. The revocation list (`RevocationList`)
sits on the get/put backing in `src/quota-store.js`. The Worker's default is in
memory per isolate, so a revocation is lost on restart until a persistent
backing is wired; rotating the secret still revokes every token. The Worker
needs the `nodejs_compat` flag (set in `wrangler.jsonc`) for `node:crypto`.

## Quotas

Counted per device per UTC day, before the body is read, so bad requests count.
Over the limit answers 429 with `retry_after` (seconds to the next UTC day) and a
`Retry-After` header. Counters go through the `QuotaStore` interface
(`src/quota-store.js`, keys `quota:<day>:<device>:<bucket>`). The default
With the `QUOTA_DO` binding (set in `wrangler.jsonc`) the Worker counts in a
Durable Object, `QuotaCounter` in `src/worker.js` (the Worker entry): one object
per device id, one storage record `{ day, counts }`, replaced on a new UTC day.
Hits are serialised inside the object, so counts are exact across isolates and
restarts. If the object cannot be reached the route answers 503
`quota_unavailable` (fail closed). Without the binding (local dev, tests) the
fallback `InMemoryQuotaStore` resets when the isolate restarts and is not shared
across isolates, so it is a soft limit only. The first deploy applies migration
`v1` (`new_sqlite_classes: ["QuotaCounter"]`); never edit or remove an applied
migration, add a new tag instead.

## Logs and deploy check

Logs carry route names, device ids and fixed codes only, never tokens,
transcripts, payloads or error messages. Before deploying, run
`node scripts/check-deploy.mjs`: it fails on key- or token-shaped strings under
`server/` and on secret-looking `vars` in `wrangler.jsonc`. With `--smoke <base_url>` it calls a deployed Worker
instead (see Nebius deploy).

## Endpoints

- `GET /health`
- `POST /router` with `transcript`
- `POST /memory/write` with `text`, `kind`, `source`, optional `confidence`, `expires_at`
- `POST /memory/recall` with optional `query`, `limit`
- `POST /council` (v2) with `question`, optional `purpose` (`chat` | `digest` | `analysis`), optional
  `context` (`short_term_summary`, `signals`). Answer `{synthesis, experts_consulted, sources:[{id,title,url,kind}],
  medical, providers, consults, limits_hit, advise_only}`. Legacy test council: `personas`, `run_id`.
- `POST /analysis/21d` with `checkins` (`[{at, mood?, energy?, sleep?, note?}]`), `start` (YYYY-MM-DD), optional `tz`,
  optional `signals` (21 daily snapshots), optional `comment: false`. Stateless; nothing is stored.
- `POST /session/summary` with `turns` (`[{role: "user" | "assistant", text}]`). Answer `{summary, topics, safety, provider}`.
- `POST /turn` with `transcript`, optional `context`
- `POST /reply` with `plan` (`personality_id`, optional `skill_id`, optional `crisis`) and `transcript`
- `POST /digest` with `personality_id`, `findings`, optional `skill_pack_id`, optional `context.short_term_summary`,
  optional `council: false`. Adds `council` (v2 view) and `council_code` when a council provider is configured.
- `POST /knowledge/ingest` and `POST /knowledge/stats`: device token and
  `deviceId == KNOWLEDGE_INGEST_DEVICE_ID`. Not metered. See Nebius deploy.
- `POST /digest/voice` with `personality_id`, `findings`, optional `skill_pack_id`

## OpenCode Go

Default endpoint: `https://opencode.ai/inference/go/openai/v1/chat/completions`.
Every request sends `x-opencode-session`, set once per council run to
`illunis-council-<run_id>`. Without `run_id`, a random id is generated per run.
Council models: `deepseek-v4.1-flash`, `glm-5.3-flash`, `mimo-v2.6-flash`
(the third is a placeholder). Any model with "contributor" in its id, or any
model not on that list, is refused with 400 before a network call.

## Memory refusal

With no memory vars set, an in-memory store is used (development only).
Once any memory var is set, all four of `MEMORY_SERVER_URL`, `MEMORY_KEY`,
`MEMORY_LLM_BASE_URL` and `MEMORY_EMBED_BASE_URL` are required. A missing one,
or an LLM or embedder URL pointing at a known third-party API, makes
`/memory/write` and `/memory/recall` answer 503 `not_configured` with a
`detail` naming the variable and reason (never its value). The Graphiti adapter
is still a stub, so a full config also answers 503.

Run the Graphiti server with its LLM and embedder set to the same self-hosted
URLs. Its compose file must not ship default credentials or unpinned images.

## Reply generation

`POST /reply` sends health content only to `REPLY_LLM_BASE_URL` (path
`/chat/completions` is appended), with temperature 0.4, `max_tokens` 1024 and a
20 second timeout. There is no third-party fallback. The client is not trusted
for prompt text: the system message is rebuilt on the server from
`plan.personality_id` and `plan.skill_id` (content files), plus a memory block
from the server's own memory store, recalled for the transcript, in which
observations are labelled tentative. The user message is the transcript.

- A client-sent `plan.system_prompt` or `plan.memories` is dropped. The log gets
  only `reply_input_ignored <device> client_system_prompt_ignored` (or
  `client_memories_ignored`), never the text.
- Unknown `personality_id` or `skill_id`: 400 `bad_request`, no model call.
- Health replies: the model decides (owner, 2026-10-29). The base prompt tells it
  to begin a reply with `[[HEALTH]]` when the answer gives health guidance whose
  wrong use could cause harm (a medicine, a dose, a diagnosis, a symptom that may
  need care, a treatment change, a practice for a person with a condition, a
  serious or new symptom), and not for general wellbeing talk. The server strips
  the marker (also from the first streamed sentence; it never reaches the client)
  and then the answer ends with the "not medical advice" line, once, and carries
  `health: true`. The line is added after the safety gate, so a replaced answer
  keeps it too. Without the marker there is no line, whatever words appear. The
  council uses the relay's JSON `medical` flag the same way. Keyword matching
  (`touchesHealth`) remains only for the digests and the assistant inbox route.
  The fixed crisis referral is sent as is.

- Crisis plan, or crisis wording in the transcript: fixed referral, no model call.
- `REPLY_LLM_BASE_URL` or `REPLY_LLM_MODEL` unset, invalid, not http(s), or a
  third-party host (OpenAI, Anthropic, OpenCode, OpenRouter, any Meta or Google
  domain): 503 `reply_not_configured`, no outbound call. `detail` names the
  variable, never its value.
- Model output failing the safety gate: see Gate repair above.
- Answer: `{text, personality_id, safety: "passed" | "repaired" | "replaced", health, council_suggested}`
 . `council_suggested` is true only for a passed or repaired reply whose transcript triggers the
  council offer (the rule in `src/council-trigger.js`, copied from the client).
- Gate repair: a reply that breaks a gate rule (for example "you must" or a diagnosis claim) gets
  one repair call that names the rule. A repaired reply answers `safety: "repaired"`. A second failure answers the fixed
  `SAFE_FALLBACK_TEXT` with `safety: "replaced"`. Crisis wording always gets the referral with `safety: "replaced"`.
  Log codes: `reply_repaired`, `reply_replaced`, `reply_crisis`.
- `/reply/stream`: a failing sentence is never sent. One repair call continues the reply; its text
  arrives in the `done` event as `{text, personality_id, safety, health, council_suggested}`, and the client appends it.
- Upstream error or empty answer: 502 `reply_upstream`. Timeout: 504 `reply_timeout`.

Auth and the `reply` quota bucket apply. Logs carry the device id and a fixed
code only, never the transcript, prompt or reply.

## Council v2

`src/council/relay.js`: one relay model with a `consult(expert_id, question)` tool over the registry in
`src/council/experts.js` (4 wellbeing experts). Bounds: 8 consults, 3 per expert, 45 s. Experts answer
in JSON (`points[{text, source_ids}]`, `caveats`, `confidence`, `search_query`); a point citing an id that was not
retrieved for that consult is dropped. Only the relay's synthesis reaches the user,
after `gateText`; a medical expert or `medical: true` appends the not-medical-advice line and the clinician path.
Crisis text gets the referral before any call. Provider: `src/council/provider.js` (`callBrain`) tries Meta,
then Baseten (`BASETEN_API_KEY`), then Nebius (`COUNCIL_NEBIUS_MODEL`) on not configured, 5xx, 429, timeout,
network or region refusal (451/403), and records the provider. The /council answer's `providers` field lists it.

Web search and gate repair:
- Web search: `searchWeb` in `src/council/web.js` picks Meta Responses `web_search` when Meta is configured, else
  Tavily (`TAVILY_API_KEY`), else nothing. Tavily is refused under `DATA_MODE=owner_real`. Web results are cited as
  `kind: "web"` sources with ids `web:<n>.<i>`.
- A thin bank (fewer than 2 distinct sources from retrieval) triggers one search before the expert call.
- Gate repair on the synthesis: `gate: "passed" | "repaired" | "replaced"`; `limits_hit` may include `gate_repaired`
  or `gate_replaced`. Repair runs only when at least 2000 ms of the 25 s budget remain.
- Uncited expert points are dropped for every expert (`filterPoints` in `src/council/relay.js`), wellbeing included.

Knowledge banks: bindings `AI` and `KNOWLEDGE` in `wrangler.jsonc`. Create the index once with
`wrangler vectorize create illunis-knowledge --dimensions=1024 --metric=cosine`. Each expert is one Vectorize
namespace. Ingest goes through the Worker, `POST /knowledge/ingest` and `POST /knowledge/stats`,
gated by `KNOWLEDGE_INGEST_DEVICE_ID` (503 when unset, 403 for another device). Use `scripts/ingest-knowledge.mjs`
with `ILLUNIS_SERVER_URL` and `ILLUNIS_DEVICE_TOKEN`; the old direct Cloudflare API route is retired. See Nebius deploy.

### Expert flags

The registry in `experts.js` never changes; `activeExperts(env)` picks who the relay may consult. The consult
tool's `expert_id` enum and the relay roster list only active experts, and a consult for an inactive id gets
`{error: "expert_inactive"}` with no retrieval or model call.
- `COUNCIL_MEDICAL`: `on` turns the 9 medical experts on. Default (unset or any other value): off.
- `COUNCIL_COACHING`: `off` drops `diet` and `training` (Meta demo). Default: on (Nebius demo keeps them).

## Log parse

`POST /log/parse` (`src/logs/parse.js`, validator `src/logs/schemas.js`). Request
`{kind: "food"|"activity"|"strength"|"run"|"cardio", text, prefs?: {effort: "none"|"rir"|"rpe"}, date?: "yyyy-mm-dd"}`.
Crisis text returns 200 `{ok: false, code: "crisis", crisis: true, text: <referral>}` before any check or call.
The model call is Nebius chat completions in JSON mode: `NEBIUS_API_KEY`, model `LOG_LLM_MODEL` (else
`REPLY_LLM_MODEL`; no default), `NEBIUS_BASE_URL` rules as for `/reply`; `DATA_MODE` refusals apply (503).
Success: 200 `{ok: true, schema: "illunis.log/1", kind, date, source: "typed", entry}` (`date` is the request's,
else the server's UTC day).

Food check: for `kind: "food"` with at least one item that has `kcal`, and Tavily allowed, up to
3 items are checked in parallel (8 s each). The query is "<name> calories per 100 g" for g or ml, else "<name> calories
per <unit or 'serving'>". The number is taken from the first result that states kcal, and it must appear in that
result's text. A match (`|user - found| <= max(25, 0.15 * found)`) answers 200 `{ok: true, ..., check: [{item_index,
status: "match" | "unverified", source_url?, source_title?}]}`. A mismatch answers 200 `{ok: false, code:
"needs_choice", pending: {schema, kind, date, source, entry}, needs_choice: [{item_index, field: "kcal", user_value,
found_value, source_url, source_title}]}`; `ok: false` keeps old clients from saving it. No Tavily key or a Tavily
error gives the unchanged success with no `check` or `unverified`. Nothing is changed silently. Log codes:
`food_checked`, `food_unverified`, `food_needs_choice`. A rejected model answer is 422 `{ok: false, code}` with a fixed code: `bad_json`,
`not_object`, `bad_field`, `out_of_range`, `empty_entry`, `number_not_in_text`. Every number in the entry must
appear in the user's text (`src/analysis/numbers.js`); effort is removed unless `prefs.effort` names its scale.
Totals, pace and averages are computed on the phone. The route shares the `reply` quota bucket; logs carry the
device id and the fixed code only.

## Assistant bridge (Hermes)

Code in `src/assistants/` (`contract.js`, `hermes.js`, `store.js`, `routes.js`), contract in
`integrations/hermes/CONTRACT.md`. The Worker calls
`${HERMES_BASE_URL}/p/illunis/api/sessions/${HERMES_SESSION_ID}/chat` with `{message: <request JSON>}`,
`Authorization: Bearer`, the two `CF-Access-Client-*` headers and an `Idempotency-Key`, a 45 s timeout and
redirects not followed. It never sends `system_message` or `instructions`. The bot's reply must be exactly one
contract object for the same op and request id, or the route answers 502 `assistant_unavailable` with a fixed
code (`hermes_contract`, `hermes_access`, `hermes_status_5xx`, ...); a timeout is 504 `assistant_timeout`; a bot
refusal is 422 `assistant_refused` with the contract error code only. Bot text is never logged.
The owner's Hermes is the owner's own host, so it is allowed under `DATA_MODE=owner_real`.

Device routes need a device token and `deviceId == ASSISTANT_OWNER_DEVICE_ID` (otherwise 403
`assistant_not_linked`):

- `POST /assistant/message` with `text` (1-4000), optional `context` (at most 4000). Answer `{text, safety, health}`;
  the text passes `gateText`, crisis input gets the referral with no Hermes call.
- `POST /assistant/memory/write` with `kind` (`note` | `hypothesis`), `text`, optional `confidence`, `expires_at`. Answer `{id}`.
- `POST /assistant/memory/recall` with optional `query`, `limit` (1-50). Answer `{items}` (data, not for direct speech).
- `POST /assistant/action/propose` with `request`. Answer `{action_id, readback, expires_in: 60}`. The readback is
  built by the Worker from the action ("I will message <target>: <text>"), not taken from the bot, so the spoken
  sentence is what gets signed. A readback failing the gate, or crisis wording, is 422 `action_refused`.
- `POST /assistant/action/confirm` with exactly `{action_id, confirm_phrase_heard: true}`. Single use within 60 s
  (404 `action_unknown`, 410 `action_expired`). The Worker then signs the approval (expires in 120 s, HMAC with
  `ILLUNIS_INBOX_SECRET` per CONTRACT.md) and sends `action_execute`. Answer `{action_id, status, detail?}`.
  Hermes's own `/approval` endpoint is never used.
- `GET /assistant/inbox?limit=N` (1-20). Answer `{items:[{id, kind, text, ts}], more}` in arrival order; the
  read acknowledges them (they are removed). Text passes `gateText`.

`POST /assistant/inbox` (from Hermes, no device token): raw body at most 8 KB, `X-Illunis-Signature` HMAC over the
raw bytes (constant-time compare), `X-Illunis-Timestamp` equal to body `ts`, skew at most 300 s, nonce refused for
600 s, then `kind`/`text` checked. 202 `{accepted, id}`; 401 bad signature, 400 with a fixed `code`, 409 replay,
413 too large, 507 `inbox_full` (200 items). Error bodies never echo the text. Missing `ILLUNIS_INBOX_SECRET`,
`ASSISTANT_OWNER_DEVICE_ID` or the `ASSISTANT_DO` binding answers 503 naming the variable.

The `AssistantInbox` Durable Object (one per device id) holds the inbox, the nonce log and pending actions.
Hackathon scope is a single owner link: every push lands in the owner device's object. Multi-user pairing (a
per-device link record created by a pairing flow, holding each user's Hermes URL and keys) is future work for
the VPS brain design (`docs/DESIGN.md (section 2.2)`).

## Nebius deploy

Run every command from `server/`, where `wrangler.jsonc` lives.

Secrets (`npx wrangler secret put <NAME>`; values never go in files or in chat):
- `NEBIUS_API_KEY`
- `TAVILY_API_KEY`
- `DEVICE_TOKEN_SECRET` (already set on the dev Worker)

Plain vars (names and values only):

| Var | Value |
|---|---|
| `REPLY_PROVIDER` | `nebius` |
| `REPLY_LLM_MODEL` | the reply model id, copied from the Nebius list |
| `COUNCIL_NEBIUS_MODEL` | the council model id; it must support tool calling (checked at the first council run) |
| `LOG_LLM_MODEL` | optional; falls back to `REPLY_LLM_MODEL` |
| `KNOWLEDGE_EMBED_PROVIDER` | `nebius` |
| `KNOWLEDGE_EMBED_MODEL` | `Qwen/Qwen3-Embedding-8B` |
| `KNOWLEDGE_INGEST_DEVICE_ID` | the owner device id, during ingest only |
| `DATA_MODE` | `owner_any` on the dev Worker; `synthetic` for the final demo |
| `QUOTA_COUNCIL_PER_DAY` | `5` |
| `COUNCIL_MEDICAL` | unset |
| `COUNCIL_COACHING` | unset |

Must be unset on the Nebius deploy: `META_API_KEY`, `COUNCIL_TEST_PROVIDER`, `COUNCIL_PROVIDER`, every `OPENCODE_*`
and `OPENROUTER_*` variable. The release config never sets the OpenCode or OpenRouter provider switches; their code
paths stay behind the switches for tests.

[UNVERIFIED: whether the dev Worker takes plain vars from the Cloudflare dashboard or from a `vars` block in
`wrangler.jsonc`. That file has no `vars` block today, and check-deploy fails on secret-looking names there.]

Deploy:

```
cd server
npm test
node scripts/check-deploy.mjs
npx wrangler deploy
```

Secret deletion comes last (D-B), after the final smoke run passes:

```
npx wrangler secret delete OPENCODE_API_KEY
npx wrangler secret delete OPENROUTER_API_KEY
```

[UNVERIFIED: the `secret delete` subcommand on the installed wrangler version; check with `npx wrangler secret --help`.]

Ingest. The vector index stays at 1024 dimensions; Qwen3 embeddings are requested at
`dimensions: 1024` (checked live 2026-10-29), so no index is recreated.

1. Set `KNOWLEDGE_INGEST_DEVICE_ID` to the owner device id, then deploy.
2. Read the owner token without echoing it, then ingest the four wellbeing banks:

   ```
   read -rs ILLUNIS_DEVICE_TOKEN && export ILLUNIS_DEVICE_TOKEN
   ILLUNIS_SERVER_URL=https://<host> node scripts/ingest-knowledge.mjs --only diet,training,breath_stress,sleep_lifestyle --verify
   ```

   Expected counts: diet 8, training 7, breath_stress 8, sleep_lifestyle 7. `--verify` polls `/knowledge/stats` up to
   3 times, 10 s apart, because Vectorize upserts are eventually consistent.
3. Unset `KNOWLEDGE_INGEST_DEVICE_ID` and deploy again. Without the variable the ingest route answers 503.

Smoke test (contract C10). Run it against the dev Worker and again after the synthetic redeploy:

```
ILLUNIS_DEVICE_TOKEN=<token> node scripts/check-deploy.mjs --smoke https://<host>
```

It makes six calls: `GET /health`; `/reply` with a plain line (`safety` passed or repaired, `council_suggested` a
boolean); `/reply` with a big question (`council_suggested` true); `/council` (at least one source, providers
`["nebius"]`); `/log/parse` with a matching food line (`check` present); `/log/parse` with a mismatching line
(`code` `needs_choice`). The token is read from `ILLUNIS_DEVICE_TOKEN` only and is sent only in the `Authorization`
header. Each check prints one line with its route, status and fixed fields; no response text, transcript or token is
printed. Any failed check exits 1. Plain `http://localhost` is allowed for local dev; any other `http` is refused.
