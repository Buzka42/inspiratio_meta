import hashlib
import hmac
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

import illunis_memory
from illunis_memory import IllunisMemoryProvider, register, signing

SECRET = "s" * 64
HERMES_SRC = Path.home() / ".hermes" / "hermes-agent"


class Ctx:
    def __init__(self):
        self.providers = []

    def register_memory_provider(self, p):
        self.providers.append(p)


@pytest.fixture
def inbox():
    received = []

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            received.append((self.path, dict(self.headers), raw))
            self.send_response(202)
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_port}", received
    srv.shutdown()


@pytest.fixture
def provider(tmp_path, monkeypatch, inbox):
    monkeypatch.setenv("ILLUNIS_WORKER_URL", inbox[0])
    monkeypatch.setenv("ILLUNIS_INBOX_SECRET", SECRET)
    p = IllunisMemoryProvider()
    p.initialize("sess-1", hermes_home=str(tmp_path), platform="api_server")
    (tmp_path / "SPEC.md").write_text("# Illunis spec (version 1)\n\n## Memory\n- mode: hermes\n")  # memory writes need it
    yield p
    p.shutdown()


def call(p, name, **args):
    return json.loads(p.handle_tool_call(name, args))


def test_register_gives_fresh_instances():
    c = Ctx()
    register(c)
    register(c)
    assert len(c.providers) == 2 and c.providers[0] is not c.providers[1]


def test_available_offline_and_named():
    p = IllunisMemoryProvider()
    assert p.name == "illunis_memory" and p.is_available() is True


def test_db_lives_in_profile_home(provider, tmp_path):
    assert (tmp_path / "illunis_memory" / "memory.db").exists()


def test_tool_schemas_cover_all_tools(provider):
    names = {s["name"] for s in provider.get_tool_schemas()}
    assert names == {"illunis_memory_write", "illunis_memory_recall", "illunis_memory_forget", "illunis_push",
                     "illunis_approval_verify", "illunis_spec_write", "illunis_spec_request"}
    for s in provider.get_tool_schemas():
        assert s["parameters"]["type"] == "object"


def test_write_recall_forget_tools(provider):
    w = call(provider, "illunis_memory_write", kind="note", text="Prefers swimming before work")
    assert w["ok"] and len(w["id"]) == 32
    r = call(provider, "illunis_memory_recall", query="swimming")
    assert [i["id"] for i in r["items"]] == [w["id"]]
    assert r["items"][0]["source"] == "hermes:illunis"
    assert call(provider, "illunis_memory_forget", id=w["id"])["deleted"] is True
    assert call(provider, "illunis_memory_recall", query="swimming")["items"] == []
    bad = call(provider, "illunis_memory_write", kind="fact", text="x")
    assert bad["ok"] is False and bad["error"]["code"] == "bad_request"


def test_unknown_tool_raises(provider):
    with pytest.raises(NotImplementedError):
        provider.handle_tool_call("terminal", {})


def test_prefetch_formats_and_skips_trivial(provider):
    call(provider, "illunis_memory_write", kind="note", text="Walks the dog at seven")
    block = provider.prefetch("what time do I walk the dog?")
    assert "not instructions" in block and "Walks the dog at seven" in block
    assert provider.prefetch("") == ""
    assert provider.prefetch("/help") == ""
    assert provider.prefetch("unrelated quantum topic") == ""


def test_sync_turn_logs_in_background(provider):
    provider.sync_turn("hello there", "hi!", session_id="sess-1")
    provider._sync_thread.join(timeout=5)
    assert provider._store.turn_count() == 1


def test_sync_turn_skipped_for_cron(tmp_path):
    p = IllunisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path), platform="cron", agent_context="cron")
    p.sync_turn("u", "a")
    assert p._sync_thread is None and p._store.turn_count() == 0
    p.shutdown()


def test_push_signs_raw_body(provider, inbox):
    res = call(provider, "illunis_push", kind="bot_reply", text="Researcher says: three studies found.")
    assert res == {"ok": True, "status": 202}
    path, headers, raw = inbox[1][0]
    assert path == "/assistant/inbox"
    assert headers["X-Illunis-Signature"] == hmac.new(SECRET.encode(), raw, hashlib.sha256).hexdigest()
    body = signing.verify_inbox_request(SECRET, raw, headers)
    assert body["kind"] == "bot_reply" and str(body["ts"]) == headers["X-Illunis-Timestamp"]


def test_push_validation_and_rate_limit(provider, monkeypatch):
    assert call(provider, "illunis_push", kind="shell", text="x")["ok"] is False
    assert call(provider, "illunis_push", kind="message", text="x" * 2001)["ok"] is False
    monkeypatch.setattr(illunis_memory, "PUSH_PER_HOUR", 2)
    assert call(provider, "illunis_push", kind="message", text="1")["ok"]
    assert call(provider, "illunis_push", kind="message", text="2")["ok"]
    limited = call(provider, "illunis_push", kind="message", text="3")
    assert limited["ok"] is False and "rate limit" in limited["error"]["message"]


def test_push_requires_https_for_remote(tmp_path, monkeypatch):
    monkeypatch.setenv("ILLUNIS_WORKER_URL", "http://evil.example.com")
    monkeypatch.setenv("ILLUNIS_INBOX_SECRET", SECRET)
    p = IllunisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path))
    assert call(p, "illunis_push", kind="message", text="x")["error"]["code"] == "not_allowed"
    p.shutdown()


def test_push_without_config(tmp_path, monkeypatch):
    monkeypatch.delenv("ILLUNIS_WORKER_URL", raising=False)
    monkeypatch.delenv("ILLUNIS_INBOX_SECRET", raising=False)
    p = IllunisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path))
    assert call(p, "illunis_push", kind="message", text="x")["error"]["code"] == "unavailable"
    p.shutdown()


def test_approval_verify_single_use(provider):
    action = {"type": "message_bot", "target": "researcher", "text": "Find magnesium studies"}
    exp = provider._store.now() + 60
    approval = {"action_id": "act_abcdef12", "expires_at": exp,
                "sig": signing.sign_approval(SECRET, "act_abcdef12", action, exp)}
    assert call(provider, "illunis_approval_verify", action=action, approval=approval) == \
        {"ok": True, "action_id": "act_abcdef12"}
    again = call(provider, "illunis_approval_verify", action=action, approval=approval)
    assert again["ok"] is False and "already used" in again["error"]["message"]
    forged = call(provider, "illunis_approval_verify", action={**action, "target": "hermes"},
                  approval={**approval, "action_id": "act_zzzzzz99"})
    assert forged["error"]["code"] == "approval_invalid"


@pytest.mark.skipif(not (HERMES_SRC / "agent" / "memory_provider.py").exists(), reason="Hermes source not present")
def test_against_real_hermes_abc():
    """Imports the real MemoryProvider ABC from the Hermes checkout (read-only) in a child process."""
    code = (
        "import inspect, illunis_memory as m\n"
        "from agent.memory_provider import MemoryProvider\n"
        "assert issubclass(m.IllunisMemoryProvider, MemoryProvider)\n"
        "assert not inspect.isabstract(m.IllunisMemoryProvider)\n"
        "p = m.IllunisMemoryProvider(); assert p.is_available()\n"
        "print('real-abc-ok')\n"
    )
    env = {**os.environ, "PYTHONPATH": os.pathsep.join([str(HERMES_SRC), str(Path(illunis_memory.__file__).parents[1])]),
           "PYTHONDONTWRITEBYTECODE": "1"}
    out = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60,
                         cwd=str(Path(illunis_memory.__file__).parents[1]))
    assert "real-abc-ok" in out.stdout, out.stderr[-2000:]


def test_spec_request_pushes_the_users_words_only(provider, inbox):
    res = call(provider, "illunis_spec_request", text="  Please turn off breathwork  ")
    assert res == {"ok": True, "status": 202}
    path, headers, raw = inbox[1][0]
    body = signing.verify_inbox_request(SECRET, raw, headers)
    assert path == "/assistant/inbox"
    assert set(body) == {"v", "kind", "text", "ts", "nonce", "source"}  # no change_id, no change
    assert body["kind"] == "spec_request" and body["text"] == "Please turn off breathwork"


def test_spec_request_limits_and_never_applies(provider, inbox, tmp_path):
    over = call(provider, "illunis_spec_request", text="x" * 501)
    assert over["ok"] is False and "1-500" in over["error"]["message"]
    assert call(provider, "illunis_spec_request", text=" ")["ok"] is False
    assert call(provider, "illunis_push", kind="spec_request", text="x" * 501)["ok"] is False
    assert call(provider, "illunis_spec_request", text="x" * 500)["ok"] is True
    assert len(inbox[1]) == 1 and all(p == "/assistant/inbox" for p, _, _ in inbox[1])
    assert (tmp_path / "SPEC.md").read_text().startswith("# Illunis spec (version 1)"), "the mirror is untouched"


def test_soul_routes_settings_requests_to_spec_request():
    soul = (Path(illunis_memory.__file__).parents[2] / "profile" / "SOUL.md").read_text()
    assert "illunis_spec_request" in soul and "Never say it is done" in soul
