"""Local long-term memory for the Illunis bot: SQLite + FTS5 in the profile home.

Stdlib only. One connection per store, guarded by a lock, so the provider's background
threads (sync_turn) and tool calls can share it. Kinds mirror the Illunis server
(`server/src/memory.js`) minus "fact": the bot never stores facts, only notes the user
asked for and hypotheses that expire.
"""

from __future__ import annotations

import re
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

KINDS = ("note", "hypothesis")
MAX_TEXT = 1000
MAX_SOURCE = 64
MAX_LIMIT = 50
HYPOTHESIS_DEFAULT_DAYS = 30
HYPOTHESIS_MAX_DAYS = 180
TURN_LOG_DAYS = 7
TURN_SNIPPET = 300
_DAY = 86400
_TOKEN_RE = re.compile(r"\w+", re.UNICODE)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS memories (
  rowid INTEGER PRIMARY KEY,
  id TEXT UNIQUE NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('note','hypothesis')),
  text TEXT NOT NULL,
  source TEXT NOT NULL,
  confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  created_at INTEGER NOT NULL,
  expires_at INTEGER
);
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  text, content='memories', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;
CREATE TABLE IF NOT EXISTS turn_log (
  rowid INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  user_text TEXT NOT NULL,
  assistant_text TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS used_approvals (
  action_id TEXT PRIMARY KEY,
  used_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
"""


class MemoryError_(ValueError):
    """Validation failure; message is safe to return to the model (never echoes text)."""


def iso(ts: Optional[int]) -> Optional[str]:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: Any) -> int:
    if not isinstance(value, str) or not value.strip():
        raise MemoryError_("expires_at must be an ISO 8601 date")
    try:
        dt = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError as exc:
        raise MemoryError_("expires_at must be an ISO 8601 date") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def fts_query(query: str) -> str:
    """User text -> safe FTS5 expression: quoted tokens joined by OR (no operators pass)."""
    tokens = [t for t in _TOKEN_RE.findall(query.lower()) if len(t) > 1][:16]
    return " OR ".join(f'"{t}"' for t in tokens)


class MemoryStore:
    def __init__(self, db_path: str | Path, *, clock=time.time):
        self._path = Path(db_path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._clock = clock
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(self._path), check_same_thread=False, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA secure_delete=ON")
            self._conn.executescript(_SCHEMA)
        try:
            self._path.chmod(0o600)
        except OSError:
            pass

    def now(self) -> int:
        return int(self._clock())

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # -- memories -----------------------------------------------------------

    def write(self, *, kind: str, text: str, source: str = "illunis", confidence: Any = None,
              expires_at: Any = None) -> dict:
        if kind not in KINDS:
            raise MemoryError_(f"kind must be one of {', '.join(KINDS)}")
        if not isinstance(text, str) or not text.strip():
            raise MemoryError_("text required")
        text = text.strip()
        if len(text) > MAX_TEXT:
            raise MemoryError_(f"text longer than {MAX_TEXT} characters")
        if not isinstance(source, str) or not source.strip() or len(source) > MAX_SOURCE:
            raise MemoryError_("source required (max 64 characters)")
        if confidence is None:
            confidence = 0.8 if kind == "note" else 0.5
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
            raise MemoryError_("confidence must be a number from 0 to 1")
        now = self.now()
        exp = parse_iso(expires_at) if expires_at is not None else None
        if kind == "hypothesis":
            exp = exp if exp is not None else now + HYPOTHESIS_DEFAULT_DAYS * _DAY
            exp = min(exp, now + HYPOTHESIS_MAX_DAYS * _DAY)
        if exp is not None and exp <= now:
            raise MemoryError_("expires_at must be in the future")
        item = {"id": uuid.uuid4().hex, "kind": kind, "text": text, "source": source.strip(),
                "confidence": float(confidence), "created_at": now, "expires_at": exp}
        with self._lock:
            self._conn.execute(
                "INSERT INTO memories(id, kind, text, source, confidence, created_at, expires_at) "
                "VALUES (:id, :kind, :text, :source, :confidence, :created_at, :expires_at)", item)
        return self._public(item)

    def recall(self, query: str = "", *, limit: int = 8, kind: Optional[str] = None) -> list[dict]:
        limit = max(1, min(int(limit or 8), MAX_LIMIT))
        if kind is not None and kind not in KINDS:
            raise MemoryError_(f"kind must be one of {', '.join(KINDS)}")
        now = self.now()
        live = "(m.expires_at IS NULL OR m.expires_at > ?)"
        kind_sql, kind_args = (" AND m.kind = ?", [kind]) if kind else ("", [])
        expr = fts_query(query or "")
        with self._lock:
            if expr:
                rows = self._conn.execute(
                    "SELECT m.* FROM memories_fts f JOIN memories m ON m.rowid = f.rowid "
                    f"WHERE memories_fts MATCH ? AND {live}{kind_sql} "
                    "ORDER BY bm25(memories_fts), m.created_at DESC LIMIT ?",
                    [expr, now, *kind_args, limit]).fetchall()
            elif (query or "").strip():
                rows = []  # only punctuation / single letters: nothing meaningful to match
            else:
                rows = self._conn.execute(
                    f"SELECT m.* FROM memories m WHERE {live}{kind_sql} "
                    "ORDER BY m.created_at DESC, m.rowid DESC LIMIT ?",
                    [now, *kind_args, limit]).fetchall()
        return [self._public(dict(r)) for r in rows]

    def forget(self, memory_id: str) -> bool:
        if not isinstance(memory_id, str) or not re.fullmatch(r"[0-9a-f]{32}", memory_id):
            raise MemoryError_("id must be a memory id from recall")
        with self._lock:
            cur = self._conn.execute("DELETE FROM memories WHERE id = ?", (memory_id,))
        return cur.rowcount > 0

    def purge_expired(self) -> int:
        now = self.now()
        with self._lock:
            n = self._conn.execute(
                "DELETE FROM memories WHERE expires_at IS NOT NULL AND expires_at <= ?", (now,)).rowcount
            n += self._conn.execute(
                "DELETE FROM turn_log WHERE created_at <= ?", (now - TURN_LOG_DAYS * _DAY,)).rowcount
            self._conn.execute("DELETE FROM used_approvals WHERE expires_at <= ?", (now - _DAY,))
        return n

    def count(self) -> int:
        with self._lock:
            return self._conn.execute("SELECT COUNT(*) FROM memories").fetchone()[0]

    # -- turn log (short retention, never recalled into prompts) ------------

    def log_turn(self, session_id: str, user_text: str, assistant_text: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO turn_log(session_id, user_text, assistant_text, created_at) VALUES (?,?,?,?)",
                (session_id or "", (user_text or "")[:TURN_SNIPPET], (assistant_text or "")[:TURN_SNIPPET],
                 self.now()))

    def turn_count(self) -> int:
        with self._lock:
            return self._conn.execute("SELECT COUNT(*) FROM turn_log").fetchone()[0]

    # -- approvals (single use) --------------------------------------------

    def claim_approval(self, action_id: str, expires_at: int) -> bool:
        """True the first time ``action_id`` is claimed; False on any reuse."""
        with self._lock:
            try:
                self._conn.execute("INSERT INTO used_approvals(action_id, used_at, expires_at) VALUES (?,?,?)",
                                   (action_id, self.now(), int(expires_at)))
            except sqlite3.IntegrityError:
                return False
        return True

    @staticmethod
    def _public(item: dict) -> dict:
        return {"id": item["id"], "kind": item["kind"], "text": item["text"], "source": item["source"],
                "confidence": item["confidence"], "created_at": iso(item["created_at"]),
                "expires_at": iso(item.get("expires_at"))}
