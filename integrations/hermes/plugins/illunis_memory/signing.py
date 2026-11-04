"""HMAC helpers shared with the Illunis Worker. Stdlib only.

Inbox push (Hermes -> Worker):
  body      = canonical JSON {"v":1,"kind","text","ts","nonce","source"}
  headers   X-Illunis-Timestamp: <ts, unix seconds>
            X-Illunis-Signature: hex(HMAC-SHA256(ILLUNIS_INBOX_SECRET, raw body bytes))
  The Worker verifies over the raw bytes it received, checks header ts == body ts,
  |now - ts| <= MAX_SKEW_SECONDS, and rejects a reused nonce inside that window.

Approval (Worker -> Hermes, inside action_execute):
  action_hash = hex(SHA-256(canonical JSON of the action object))
  sig         = hex(HMAC-SHA256(secret, "illunis-approval-v1\\n{action_id}\\n{action_hash}\\n{expires_at}"))
  The domain prefix keeps an approval signature from ever validating as an inbox body.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import time
from typing import Any, Optional

MAX_SKEW_SECONDS = 300
APPROVAL_MAX_TTL = 180
APPROVAL_DOMAIN = "illunis-approval-v1"
_HEX64 = re.compile(r"[0-9a-f]{64}")
_ACTION_ID = re.compile(r"[A-Za-z0-9_-]{8,64}")


def canonical_json(value: Any) -> str:
    """Sorted keys, no whitespace, UTF-8 kept. Matches JS JSON.stringify over a key-sorted
    copy for strings, integers, booleans, null, arrays and objects (no floats in signed data)."""
    _reject_floats(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _reject_floats(value: Any) -> None:
    if isinstance(value, float):
        raise ValueError("floats are not allowed in signed data")
    if isinstance(value, dict):
        for k, v in value.items():
            if not isinstance(k, str):
                raise ValueError("object keys must be strings")
            _reject_floats(v)
    elif isinstance(value, list):
        for v in value:
            _reject_floats(v)


def hmac_hex(secret: str, message: bytes) -> str:
    return hmac.new(secret.encode("utf-8"), message, hashlib.sha256).hexdigest()


def build_inbox_request(secret: str, kind: str, text: str, *, now: Optional[int] = None,
                        nonce: Optional[str] = None, source: str = "hermes:illunis") -> tuple[bytes, dict]:
    """Return (raw body bytes, headers) for POST /assistant/inbox."""
    if not secret or len(secret) < 32:
        raise ValueError("ILLUNIS_INBOX_SECRET missing or too short")
    ts = int(time.time() if now is None else now)
    body = canonical_json({"v": 1, "kind": kind, "text": text, "ts": ts,
                           "nonce": nonce or secrets.token_hex(16), "source": source}).encode("utf-8")
    headers = {"Content-Type": "application/json", "X-Illunis-Timestamp": str(ts),
               "X-Illunis-Signature": hmac_hex(secret, body)}
    return body, headers


def verify_inbox_request(secret: str, raw_body: bytes, headers: dict, *, now: Optional[int] = None) -> dict:
    """Reference verifier (the Worker implements the same rule in JS). Returns the parsed body
    or raises ValueError. Nonce replay tracking is the caller's job (Durable Object)."""
    sig = str(headers.get("X-Illunis-Signature", "")).lower()
    if not _HEX64.fullmatch(sig) or not hmac.compare_digest(sig, hmac_hex(secret, raw_body)):
        raise ValueError("bad signature")
    try:
        body = json.loads(raw_body.decode("utf-8"))
        ts = int(headers.get("X-Illunis-Timestamp", ""))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError("bad body or timestamp") from exc
    if not isinstance(body, dict) or body.get("ts") != ts:
        raise ValueError("timestamp mismatch")
    current = int(time.time() if now is None else now)
    if abs(current - ts) > MAX_SKEW_SECONDS:
        raise ValueError("timestamp outside allowed skew")
    return body


def action_hash(action: dict) -> str:
    return hashlib.sha256(canonical_json(action).encode("utf-8")).hexdigest()


def approval_message(action_id: str, a_hash: str, expires_at: int) -> bytes:
    return f"{APPROVAL_DOMAIN}\n{action_id}\n{a_hash}\n{int(expires_at)}".encode("utf-8")


def sign_approval(secret: str, action_id: str, action: dict, expires_at: int) -> str:
    """Reference signer (the Worker signs after the user's spoken yes). Tests use it."""
    return hmac_hex(secret, approval_message(action_id, action_hash(action), expires_at))


def verify_approval(secret: str, action: dict, approval: dict, *, now: Optional[int] = None) -> str:
    """Check an approval against the exact action. Returns action_id or raises ValueError.
    Single-use is enforced by the caller (MemoryStore.claim_approval)."""
    if not secret:
        raise ValueError("approval secret not configured")
    if not isinstance(action, dict) or not isinstance(approval, dict):
        raise ValueError("action and approval must be objects")
    action_id = approval.get("action_id")
    expires_at = approval.get("expires_at")
    sig = str(approval.get("sig", "")).lower()
    if not isinstance(action_id, str) or not _ACTION_ID.fullmatch(action_id):
        raise ValueError("bad action_id")
    if isinstance(expires_at, bool) or not isinstance(expires_at, int):
        raise ValueError("bad expires_at")
    current = int(time.time() if now is None else now)
    if expires_at <= current:
        raise ValueError("approval expired")
    if expires_at > current + APPROVAL_MAX_TTL:
        raise ValueError("approval lifetime too long")
    expected = hmac_hex(secret, approval_message(action_id, action_hash(action), expires_at))
    if not _HEX64.fullmatch(sig) or not hmac.compare_digest(sig, expected):
        raise ValueError("approval signature does not match this action")
    return action_id
