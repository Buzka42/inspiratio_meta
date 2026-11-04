"""Reference validator for the Illunis <-> Hermes JSON contract (see ../../CONTRACT.md).

The Worker mirrors these rules in JS. Stdlib only, no I/O. ``validate_request`` and
``validate_reply`` return a list of problems; an empty list means valid.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
from datetime import datetime
from typing import Any

VERSION = 1
OPS = ("message", "memory_write", "memory_recall", "action_propose", "action_execute",
       "spec_propose", "spec_apply", "knowledge_add", "knowledge_remove")
ACTION_TYPES = ("message_bot",)
ERROR_CODES = ("bad_request", "not_allowed", "approval_invalid", "approval_expired", "unavailable", "internal")
EXECUTE_STATUS = ("done", "queued", "failed")
MEMORY_KINDS = ("note", "hypothesis")
SPEC_DOMAIN = "illunis-spec-v1"
SPEC_MD_MAX = 16000
CHANGE_MAX = 8192
MEMORY_MODES = ("off", "phone", "hermes")

_REQ_ID = re.compile(r"[A-Za-z0-9_-]{8,64}")
_MEM_ID = re.compile(r"[0-9a-f]{32}")
_HEX64 = re.compile(r"[0-9a-f]{64}")
_SRC_ID = re.compile(r"src_[0-9a-f]{16}")
_BANK = re.compile(r"[a-z][a-z0-9_]{0,31}")
_SPEC_HEAD = re.compile(r"# Illunis spec \(version (\d+)\)")
_TARGET = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}(/[A-Za-z0-9][A-Za-z0-9_-]{0,63})?")


def _str(v: Any, lo: int, hi: int) -> bool:
    return isinstance(v, str) and lo <= len(v.strip()) and len(v) <= hi


def _iso(v: Any) -> bool:
    if not isinstance(v, str):
        return False
    try:
        datetime.fromisoformat(v.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def _pos_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 1


def _json_size(v: Any) -> int:
    try:  # Same measure as JS JSON.stringify(v).length for ASCII content.
        return len(json.dumps(v, separators=(",", ":"), ensure_ascii=False))
    except (TypeError, ValueError):
        return CHANGE_MAX + 1


def _exact_keys(obj: dict, required: set, optional: set, where: str, out: list) -> None:
    keys = set(obj)
    for k in sorted(required - keys):
        out.append(f"{where}.{k} missing")
    for k in sorted(keys - required - optional):
        out.append(f"{where}.{k} not allowed")


def validate_action(action: Any, where: str = "action") -> list[str]:
    out: list[str] = []
    if not isinstance(action, dict):
        return [f"{where} must be an object"]
    _exact_keys(action, {"type", "target", "text"}, set(), where, out)
    if action.get("type") not in ACTION_TYPES:
        out.append(f"{where}.type must be one of {', '.join(ACTION_TYPES)}")
    if not (isinstance(action.get("target"), str) and _TARGET.fullmatch(action["target"])):
        out.append(f"{where}.target must be a bot handle")
    if not _str(action.get("text"), 1, 2000):
        out.append(f"{where}.text must be 1-2000 characters")
    return out


# Spec ops: shapes only. The Worker re-validates every change (server/src/spec/schema.js) and builds
# the diff and readback itself, so a bot's change is never trusted beyond its shape.
def _validate_change_shape(c: Any, where: str, out: list) -> None:
    if not isinstance(c, dict):
        out.append(f"{where} must be an object")
        return
    _exact_keys(c, {"base_version"}, {"spec_patch", "knowledge_add", "knowledge_remove"}, where, out)
    if not _pos_int(c.get("base_version")):
        out.append(f"{where}.base_version must be a positive integer")
    if "spec_patch" in c and not isinstance(c["spec_patch"], dict):
        out.append(f"{where}.spec_patch must be an object")
    if "knowledge_add" in c and not isinstance(c["knowledge_add"], dict):
        out.append(f"{where}.knowledge_add must be an object")
    if "knowledge_remove" in c and not (isinstance(c["knowledge_remove"], str) and _SRC_ID.fullmatch(c["knowledge_remove"])):
        out.append(f"{where}.knowledge_remove must be a source id")
    if _json_size(c) > CHANGE_MAX:
        out.append(f"{where} must be at most {CHANGE_MAX} characters")


def _validate_source(s: Any, where: str, out: list) -> None:
    if not isinstance(s, dict):
        out.append(f"{where} must be an object")
        return
    _exact_keys(s, {"title", "origin", "date", "text", "bank"}, set(), where, out)
    if not _str(s.get("title"), 1, 120):
        out.append(f"{where}.title must be 1-120 characters")
    if not _str(s.get("origin"), 1, 200):
        out.append(f"{where}.origin must be 1-200 characters")
    if not _iso(s.get("date")):
        out.append(f"{where}.date must be ISO 8601")
    if not _str(s.get("text"), 1, 3200):
        out.append(f"{where}.text must be 1-3200 characters")
    if not (isinstance(s.get("bank"), str) and _BANK.fullmatch(s["bank"])):
        out.append(f"{where}.bank must be an expert id")


def _validate_approval(approval: Any, out: list) -> None:
    if not isinstance(approval, dict):
        out.append("input.approval must be an object")
        return
    _exact_keys(approval, {"action_id", "expires_at", "sig"}, set(), "input.approval", out)
    if not (isinstance(approval.get("action_id"), str) and _REQ_ID.fullmatch(approval["action_id"])):
        out.append("input.approval.action_id invalid")
    exp = approval.get("expires_at")
    if isinstance(exp, bool) or not isinstance(exp, int):
        out.append("input.approval.expires_at must be unix seconds")
    if not (isinstance(approval.get("sig"), str) and _HEX64.fullmatch(approval["sig"])):
        out.append("input.approval.sig must be 64 hex characters")


def _validate_input(op: str, data: Any, out: list) -> None:
    if not isinstance(data, dict):
        out.append("input must be an object")
        return
    if op == "message":
        _exact_keys(data, {"text"}, {"context"}, "input", out)
        if not _str(data.get("text"), 1, 4000):
            out.append("input.text must be 1-4000 characters")
        if "context" in data and not _str(data["context"], 0, 4000):
            out.append("input.context must be at most 4000 characters")
    elif op == "memory_write":
        _exact_keys(data, {"kind", "text"}, {"confidence", "expires_at"}, "input", out)
        if data.get("kind") not in MEMORY_KINDS:
            out.append("input.kind must be note or hypothesis")
        if not _str(data.get("text"), 1, 1000):
            out.append("input.text must be 1-1000 characters")
        c = data.get("confidence", 0.5)
        if isinstance(c, bool) or not isinstance(c, (int, float)) or not 0 <= c <= 1:
            out.append("input.confidence must be 0..1")
        if "expires_at" in data and not _iso(data["expires_at"]):
            out.append("input.expires_at must be ISO 8601")
    elif op == "memory_recall":
        _exact_keys(data, {"query"}, {"limit"}, "input", out)
        if not _str(data.get("query"), 0, 500):
            out.append("input.query must be at most 500 characters")
        lim = data.get("limit", 8)
        if isinstance(lim, bool) or not isinstance(lim, int) or not 1 <= lim <= 50:
            out.append("input.limit must be 1..50")
    elif op == "action_propose":
        _exact_keys(data, {"request"}, set(), "input", out)
        if not _str(data.get("request"), 1, 2000):
            out.append("input.request must be 1-2000 characters")
    elif op == "action_execute":
        _exact_keys(data, {"action", "approval"}, set(), "input", out)
        out.extend("input." + p for p in validate_action(data.get("action")))
        _validate_approval(data.get("approval"), out)
    elif op == "spec_propose":
        _exact_keys(data, {"request", "base_version"}, {"spec_md"}, "input", out)
        if not _str(data.get("request"), 1, 2000):
            out.append("input.request must be 1-2000 characters")
        if not _pos_int(data.get("base_version")):
            out.append("input.base_version must be a positive integer")
        if "spec_md" in data and not _str(data["spec_md"], 0, SPEC_MD_MAX):
            out.append(f"input.spec_md must be at most {SPEC_MD_MAX} characters")
    elif op == "spec_apply":  # Worker only, after the phone approved.
        _exact_keys(data, {"version", "spec_md", "sig"}, set(), "input", out)
        if not _pos_int(data.get("version")):
            out.append("input.version must be a positive integer")
        if not _str(data.get("spec_md"), 1, SPEC_MD_MAX):
            out.append(f"input.spec_md must be 1-{SPEC_MD_MAX} characters")
        if not (isinstance(data.get("sig"), str) and _HEX64.fullmatch(data["sig"])):
            out.append("input.sig must be 64 hex characters")
    elif op == "knowledge_add":
        _exact_keys(data, {"request"}, set(), "input", out)
        if not _str(data.get("request"), 1, 4000):
            out.append("input.request must be 1-4000 characters")
    elif op == "knowledge_remove":
        _exact_keys(data, {"request", "sources"}, set(), "input", out)
        if not _str(data.get("request"), 1, 2000):
            out.append("input.request must be 1-2000 characters")
        sources = data.get("sources")
        if not isinstance(sources, list) or len(sources) > 50:
            out.append("input.sources must be a list of at most 50")
        else:
            for i, it in enumerate(sources):
                w = f"input.sources[{i}]"
                if not isinstance(it, dict):
                    out.append(f"{w} must be an object")
                    continue
                _exact_keys(it, {"id", "title"}, set(), w, out)
                if not (isinstance(it.get("id"), str) and _SRC_ID.fullmatch(it["id"])):
                    out.append(f"{w}.id must be a source id")
                if not _str(it.get("title"), 1, 120):
                    out.append(f"{w}.title must be 1-120 characters")


def validate_request(req: Any) -> list[str]:
    out: list[str] = []
    if not isinstance(req, dict):
        return ["request must be a JSON object"]
    _exact_keys(req, {"illunis", "op", "request_id", "input"}, set(), "request", out)
    if req.get("illunis") != VERSION:
        out.append("request.illunis must be 1")
    if req.get("op") not in OPS:
        out.append("request.op unknown")
        return out
    if not (isinstance(req.get("request_id"), str) and _REQ_ID.fullmatch(req["request_id"])):
        out.append("request.request_id invalid")
    _validate_input(req["op"], req.get("input"), out)
    return out


def _validate_result(op: str, res: Any, out: list) -> None:
    if not isinstance(res, dict):
        out.append("result must be an object")
        return
    if op == "message":
        _exact_keys(res, {"text"}, set(), "result", out)
        if not _str(res.get("text"), 1, 2000):
            out.append("result.text must be 1-2000 characters")
    elif op == "memory_write":
        _exact_keys(res, {"id"}, set(), "result", out)
        if not (isinstance(res.get("id"), str) and _MEM_ID.fullmatch(res["id"])):
            out.append("result.id must be a memory id")
    elif op == "memory_recall":
        _exact_keys(res, {"items"}, set(), "result", out)
        items = res.get("items")
        if not isinstance(items, list) or len(items) > 50:
            out.append("result.items must be a list of at most 50")
            return
        for i, it in enumerate(items):
            w = f"result.items[{i}]"
            if not isinstance(it, dict):
                out.append(f"{w} must be an object")
                continue
            _exact_keys(it, {"id", "kind", "text", "confidence", "created_at", "expires_at"}, {"source"}, w, out)
            if it.get("kind") not in MEMORY_KINDS:
                out.append(f"{w}.kind invalid")
            if not _str(it.get("text"), 1, 1000):
                out.append(f"{w}.text invalid")
            if it.get("expires_at") is not None and not _iso(it.get("expires_at")):
                out.append(f"{w}.expires_at invalid")
    elif op == "action_propose":
        _exact_keys(res, {"action", "readback"}, set(), "result", out)
        out.extend("result." + p for p in validate_action(res.get("action")))
        if not _str(res.get("readback"), 1, 300):
            out.append("result.readback must be 1-300 characters")
    elif op == "action_execute":
        _exact_keys(res, {"action_id", "status"}, {"detail"}, "result", out)
        if not (isinstance(res.get("action_id"), str) and _REQ_ID.fullmatch(res["action_id"])):
            out.append("result.action_id invalid")
        if res.get("status") not in EXECUTE_STATUS:
            out.append("result.status must be done, queued or failed")
        if "detail" in res and not _str(res["detail"], 0, 500):
            out.append("result.detail must be at most 500 characters")
    elif op == "spec_propose":
        _exact_keys(res, {"change"}, set(), "result", out)
        _validate_change_shape(res.get("change"), "result.change", out)
    elif op == "spec_apply":
        _exact_keys(res, {"version"}, set(), "result", out)
        if not _pos_int(res.get("version")):
            out.append("result.version must be a positive integer")
    elif op == "knowledge_add":
        _exact_keys(res, {"source"}, set(), "result", out)
        _validate_source(res.get("source"), "result.source", out)
    elif op == "knowledge_remove":
        _exact_keys(res, {"source_id"}, set(), "result", out)
        if not (isinstance(res.get("source_id"), str) and _SRC_ID.fullmatch(res["source_id"])):
            out.append("result.source_id must be a source id")


def validate_reply(reply: Any, *, op: str | None = None, request_id: str | None = None) -> list[str]:
    out: list[str] = []
    if not isinstance(reply, dict):
        return ["reply must be a JSON object"]
    ok = reply.get("ok")
    _exact_keys(reply, {"illunis", "op", "request_id", "ok"}, {"result", "error"}, "reply", out)
    if reply.get("illunis") != VERSION:
        out.append("reply.illunis must be 1")
    if reply.get("op") not in OPS:
        out.append("reply.op unknown")
        return out
    if op is not None and reply["op"] != op:
        out.append("reply.op does not match the request")
    if request_id is not None and reply.get("request_id") != request_id:
        out.append("reply.request_id does not match the request")
    if not isinstance(ok, bool):
        out.append("reply.ok must be a boolean")
        return out
    if ok:
        if "error" in reply:
            out.append("reply.error not allowed when ok is true")
        _validate_result(reply["op"], reply.get("result"), out)
    else:
        if "result" in reply:
            out.append("reply.result not allowed when ok is false")
        err = reply.get("error")
        if not isinstance(err, dict):
            out.append("reply.error must be an object")
        else:
            _exact_keys(err, {"code", "message"}, set(), "reply.error", out)
            if err.get("code") not in ERROR_CODES:
                out.append("reply.error.code unknown")
            if not _str(err.get("message"), 0, 300):
                out.append("reply.error.message must be at most 300 characters")
    return out


def parse_reply(text: str, **kw) -> tuple[dict | None, list[str]]:
    """Strict: the whole assistant text (trimmed) must be one JSON object. No fences, no prose."""
    try:
        data = json.loads((text or "").strip())
    except ValueError:
        return None, ["reply is not a single JSON object"]
    problems = validate_reply(data, **kw)
    return (data if not problems else None), problems


# ---- spec mirror (spec_apply) ----
# sig = hex(HMAC-SHA256(ILLUNIS_INBOX_SECRET, "illunis-spec-v1\n{version}\n{hex(SHA-256(spec_md))}"))

def spec_message(version: int, spec_md: str) -> bytes:
    digest = hashlib.sha256(spec_md.encode("utf-8")).hexdigest()
    return f"{SPEC_DOMAIN}\n{int(version)}\n{digest}".encode("utf-8")


def sign_spec(secret: str, version: int, spec_md: str) -> str:
    """Reference signer (the Worker signs after the phone's approval). Tests use it."""
    return hmac.new(secret.encode("utf-8"), spec_message(version, spec_md), hashlib.sha256).hexdigest()


def spec_version(spec_md: Any) -> int | None:
    """The version in SPEC.md's first line, or None."""
    if not isinstance(spec_md, str):
        return None
    m = _SPEC_HEAD.fullmatch(spec_md.split("\n", 1)[0].strip())
    return int(m.group(1)) if m else None


def verify_spec(secret: str, version: Any, spec_md: Any, sig: Any) -> int:
    """Check a spec_apply body. Returns the version or raises ValueError (messages name no values)."""
    if not secret or len(secret) < 32:
        raise ValueError("spec secret not configured")
    if not _pos_int(version) or not _str(spec_md, 1, SPEC_MD_MAX):
        raise ValueError("bad version or spec_md")
    sig = str(sig or "").lower()
    if not _HEX64.fullmatch(sig) or not hmac.compare_digest(sig, sign_spec(secret, version, spec_md)):
        raise ValueError("spec signature does not match")
    if spec_version(spec_md) != version:
        raise ValueError("spec_md version does not match")
    return version


def memory_mode(spec_md: Any) -> str | None:
    """memory.mode from the '## Memory' section, skipping fenced blocks (the user's guidelines)."""
    if not isinstance(spec_md, str):
        return None
    fenced, section = False, None
    for line in spec_md.splitlines():
        if line.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        if line.startswith("## "):
            section = line[3:].strip()
        elif section == "Memory":
            m = re.fullmatch(r"- mode: (\w+)", line.strip())
            if m:
                return m.group(1) if m.group(1) in MEMORY_MODES else None
    return None
