# Illunis and Hermes contract (v1)

This contract sits between the Illunis Worker (`server/src/assistants/`) and the Hermes
`illunis` profile. The reference validators are in
`plugins/illunis_memory/contract.py` (JSON shapes) and `plugins/illunis_memory/signing.py`
(HMAC). The Worker mirrors both in JS, and the tests in `tests/` pin the behaviour.

## Transport

The Worker calls `${HERMES_BASE_URL}/p/illunis/v1/runs` (with SSE events) or
`/p/illunis/api/sessions/{id}/chat`. It sends these headers:

- `Authorization: Bearer <HERMES_API_KEY>`: the illunis profile's `API_SERVER_KEY`.
- `CF-Access-Client-Id` and `CF-Access-Client-Secret`: the Cloudflare Access service token.
- `Idempotency-Key`: a fresh random value for each logical request. Retries reuse it.

The user message of the run is one JSON request object, serialised compactly. The bot's
final assistant text must be one reply object. Hermes's built-in run `/approval` endpoint
is a different thing: it answers dangerous-command prompts, and those never occur here
because the API server has no terminal and `approvals.unattended_mode` is `deny`.
Approval of Illunis actions travels inside `action_execute` (below).

## Request

```json
{"illunis": 1, "op": "<op>", "request_id": "<8-64 of A-Za-z0-9_->", "input": { ... }}
```

Unknown keys are rejected at every level.

| op | input |
|---|---|
| `message` | `text` (1-4000), optional `context` (≤4000, the short-term summary) |
| `memory_write` | `kind` (`note` or `hypothesis`), `text` (1-1000), optional `confidence` (0..1) and `expires_at` (ISO 8601) |
| `memory_recall` | `query` (≤500, may be empty for the newest), optional `limit` (1..50, default 8) |
| `action_propose` | `request` (1-2000): what the user asked for, in plain words |
| `action_execute` | `action` (exactly as returned by propose) and `approval` `{action_id, expires_at, sig}` |
| `spec_propose` | `request` (1-2000, the user's words), `base_version` (int ≥1), optional `spec_md` (≤16000, the current SPEC.md) |
| `spec_apply` | **Worker only.** `version` (int ≥1), `spec_md` (1-16000), `sig` (64 hex). See "Spec mirror" |
| `knowledge_add` | `request` (1-4000): the source the user wants added, in their words |
| `knowledge_remove` | `request` (1-2000) and `sources`: up to 50 `{id, title}` (`id` is `src_` + 16 hex) |

## Reply

The reply is exactly one JSON object. It has no prose, no Markdown and no code fences.
Leading and trailing whitespace is allowed.

```json
{"illunis": 1, "op": "<same op>", "request_id": "<same id>", "ok": true, "result": { ... }}
{"illunis": 1, "op": "<same op>", "request_id": "<same id>", "ok": false,
 "error": {"code": "<code>", "message": "<≤300 chars>"}}
```

The error codes are `bad_request`, `not_allowed`, `approval_invalid`, `approval_expired`,
`unavailable` and `internal`.

| op | result |
|---|---|
| `message` | `text` (1-2000) |
| `memory_write` | `id` (32 hex characters) |
| `memory_recall` | `items`: up to 50 `{id, kind, text, confidence, created_at, expires_at, source?}` |
| `action_propose` | `action` and `readback` (1-300, one sentence the phone reads back aloud) |
| `action_execute` | `action_id`, `status` (`done`, `queued` or `failed`) and optional `detail` (≤500) |
| `spec_propose` | `change`: `{base_version, spec_patch?, knowledge_add?, knowledge_remove?}`, ≤8192 characters |
| `spec_apply` | `version`: the version now in SPEC.md |
| `knowledge_add` | `source`: `{title (1-120), origin (1-200), date (ISO 8601), text (1-3200), bank (expert id)}` |
| `knowledge_remove` | `source_id`: one id from the request's `sources` |

The only action type in v1 is `{"type": "message_bot", "target": "<bot handle or peer/agent>",
"text": "<1-2000>"}`. Signed data contains no floats.

The Worker treats any reply that fails validation as `upstream_error`. It never speaks raw
Hermes text.

## Approval flow

1. The phone sends the request. The Worker sends `action_propose`, and Hermes returns
   `action` and `readback`.
2. The Worker stores `{action_id, action, action_hash}` with a 60 s confirm window and
   returns `{action_id, readback}` to the phone.
3. The phone reads the readback aloud. Only an explicit yes calls
   `/assistant/action/confirm` with `{action_id, confirm_phrase_heard: true}`.
4. The Worker checks that the confirmation is single use and inside the window, then
   signs the approval:
   - `action_hash = hex(SHA-256(canonical_json(action)))`
   - `expires_at = now + 120` in unix seconds. Hermes refuses a lifetime over 180 s or one
     already in the past.
   - `sig = hex(HMAC-SHA256(ILLUNIS_INBOX_SECRET, "illunis-approval-v1\n" + action_id + "\n" + action_hash + "\n" + expires_at))`
5. The Worker sends `action_execute` with the same `action` and the approval. The bot
   calls `illunis_approval_verify`. The plugin recomputes the hash from the action it
   received, checks the signature and expiry, and records `action_id` as used. Only then
   does the bot call `message_agent`.

`canonical_json` sorts keys recursively, uses no whitespace, keeps UTF-8 as is and
allows no floats. In JS that is `JSON.stringify` over a copy with sorted keys.

## Spec changes

The spec ops are additive: the protocol stays `illunis: 1` and the five ops above are
unchanged. An older plugin rejects the new ops, so reinstall the profile.

- **Proposals are untrusted.** `spec_propose`, `knowledge_add` and `knowledge_remove` only
  propose. The contract checks shape only; the Worker forces `base_version` to its own,
  re-validates the change (`server/src/spec/schema.js` `validateChange`: refused keys,
  guardrails, enums, registry skills, crisis and gate checks on guidelines) and builds the
  diff and readback itself from fixed phrases. No bot text ever reaches the app.
- **The bot cannot approve.** The Worker creates the `change_id` (300 s, single use,
  `base_version` compare-and-set) and gives it only to the phone. Hermes never receives
  it. Only the phone's device token can call `/spec/apply`.
- **`spec_apply` is sent by the Worker only,** after the phone approved, and never
  requested by the bot. The bot passes `version`, `spec_md` and `sig` unchanged to
  `illunis_spec_write`, which writes `~/.hermes/profiles/illunis/SPEC.md` (mode 600)
  only when all of these hold, and refuses otherwise:
  - `sig = hex(HMAC-SHA256(ILLUNIS_INBOX_SECRET, "illunis-spec-v1\n" + version + "\n" + hex(SHA-256(spec_md))))`, compared in constant time;
  - the first line of `spec_md` is `# Illunis spec (version N)` with `N == version`;
  - `version` is greater than the mirror's current version (a replay is refused).
- **The bot can ask, in words only.** When the user asks the bot to change a setting, the
  bot calls `illunis_spec_request(text)`, which pushes an inbox item of kind
  `spec_request` whose `text` is the user's words (1-500 characters). The body has the
  usual six keys and nothing else, so a `change_id` or a change is refused (`bad_item`).
  The Worker withholds a `spec_request` when there is no saved spec. The phone proposes
  from the words (`POST /spec/propose {request}`), shows the card, and only the phone's
  Approve calls `/spec/apply`. The bot gets nothing back and never says it applied it.
- If Hermes is down or replies outside the contract, the Worker proposes with its own
  brain (`propose_settings` tool or prompt JSON) through the same validator, and the
  mirror stays `pending` or `off`. The Worker copy is the source of truth.
- `illunis_memory_write` refuses with `not_allowed` unless the mirror's `## Memory`
  section says `- mode: hermes`. Fenced blocks (the user's guidelines) are skipped when
  reading it.

Shared test vectors: `tests/spec_vectors.json` (pytest and `server/test/spec-propose.test.js`).

## Inbox push (Hermes to Worker)

The request is `POST ${ILLUNIS_WORKER_URL}/assistant/inbox`.

- The body is canonical JSON:
  `{"kind","nonce","source","text","ts","v"}`.
  - `kind` is one of `message`, `reminder`, `bot_reply`, `action_result`, `memory` or
    `spec_request`.
  - `text` is 1-2000 characters (1-500 for `spec_request`).
  - `ts` is unix seconds.
  - `nonce` is 32 hex characters.
  - `source` is `hermes:illunis`.
  - `v` is `1`.
- `X-Illunis-Timestamp` is the same `ts` as a decimal string.
- `X-Illunis-Signature` is `hex(HMAC-SHA256(ILLUNIS_INBOX_SECRET, raw body bytes))`.

The Worker must check these rules, in this order:

1. Read the raw body bytes and cap them at 8 KB. Compute the HMAC over those bytes, never
   over re-serialised JSON. Compare in constant time.
2. Parse the body. Header `ts` must equal body `ts`.
3. Reject when `|now - ts| > 300` seconds (the skew rule).
4. Reject a `nonce` already seen in the last 600 seconds (Durable Object
   `AssistantInbox`). The nonce store outlives the skew window, so a captured request
   cannot be replayed.
5. Validate `kind` and `text`, store the item for the owner's device, and return `202`.
   Error bodies never echo the text.

Known vector (pinned in `tests/test_signing.py::test_known_vector`): with the secret
`"k" * 32`, `ts = 1700000000` and a nonce of 32 zeros, the body is

```
{"kind":"message","nonce":"00000000000000000000000000000000","source":"hermes:illunis","text":"hi","ts":1700000000,"v":1}
```

and the signature is HMAC-SHA256 of those exact bytes.

## Secrets

| Name | Where it lives | Purpose |
|---|---|---|
| `API_SERVER_KEY` | `~/.hermes/profiles/illunis/.env` | Bearer for `/p/illunis/*` |
| `HERMES_API_KEY` | Worker secret | Same value as above |
| `ILLUNIS_INBOX_SECRET` | profile `.env` and Worker secret | Inbox, approval and spec-mirror HMAC |
| `ILLUNIS_WORKER_URL` | profile `.env` | Worker base URL (https) |
| `CF_ACCESS_CLIENT_ID` / `_SECRET` | Worker secrets | Cloudflare Access service token |

`setup_profile.sh` generates the first two values and pipes them straight into
`wrangler secret put`. They are never printed and never stored in the repo.
