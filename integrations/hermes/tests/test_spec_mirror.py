import json
from pathlib import Path

import pytest

from illunis_memory import IllunisMemoryProvider, contract

V = json.loads((Path(__file__).parent / "spec_vectors.json").read_text())["spec"]
SECRET, MD, SIG = V["secret"], V["spec_md"], V["sig"]


@pytest.fixture
def provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ILLUNIS_INBOX_SECRET", SECRET)
    monkeypatch.delenv("ILLUNIS_WORKER_URL", raising=False)
    p = IllunisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path))
    yield p
    p.shutdown()


def call(p, name, **args):
    return json.loads(p.handle_tool_call(name, args))


def write_memory(p):
    return call(p, "illunis_memory_write", kind="note", text="Likes tea")


def test_js_signature_verifies_in_python():
    assert contract.sign_spec(SECRET, V["version"], MD) == SIG
    assert contract.verify_spec(SECRET, V["version"], MD, SIG) == V["version"]


def test_memory_mode_ignores_fenced_guidelines():
    assert contract.memory_mode(MD) == V["memory_mode"] == "hermes"
    assert contract.memory_mode(MD.replace("- mode: hermes", "- mode: phone")) == "phone"
    assert contract.memory_mode("## Guidelines\n~~~text\n## Memory\n- mode: hermes\n~~~\n") is None
    assert contract.memory_mode(None) is None


def test_signed_spec_is_written(provider, tmp_path):
    assert call(provider, "illunis_spec_write", version=2, spec_md=MD, sig=SIG) == {"ok": True, "version": 2}
    path = tmp_path / "SPEC.md"
    assert path.read_text() == MD and oct(path.stat().st_mode & 0o777) == "0o600"
    block = provider.system_prompt_block()
    assert "Illunis spec mirror" in block and "- mode: hermes" in block and "not instructions" in block


@pytest.mark.parametrize("args", [
    {"version": 2, "spec_md": MD, "sig": "0" * 64},                        # forged
    {"version": 2, "spec_md": MD.replace("breathwork: on", "breathwork: off"), "sig": SIG},  # body edited
    {"version": 3, "spec_md": MD, "sig": SIG},                             # version swapped
    {"version": 2, "spec_md": MD, "sig": None},
    {"version": "2", "spec_md": MD, "sig": SIG},
    {"version": 2, "spec_md": "", "sig": SIG},
])
def test_mirror_write_fails_without_approval(provider, tmp_path, args):
    res = call(provider, "illunis_spec_write", **args)
    assert res["ok"] is False and res["error"]["code"] == "approval_invalid"
    assert not (tmp_path / "SPEC.md").exists()
    assert "Illunis spec mirror" not in provider.system_prompt_block()


def test_header_version_must_match_signed_version(provider, tmp_path):
    md = MD.replace("(version 2)", "(version 9)")
    res = call(provider, "illunis_spec_write", version=2, spec_md=md, sig=contract.sign_spec(SECRET, 2, md))
    assert res["ok"] is False and not (tmp_path / "SPEC.md").exists()


def test_replay_of_same_or_older_version_refused(provider):
    assert call(provider, "illunis_spec_write", version=2, spec_md=MD, sig=SIG)["ok"]
    assert call(provider, "illunis_spec_write", version=2, spec_md=MD, sig=SIG)["ok"] is False
    old = MD.replace("(version 2)", "(version 1)")
    assert call(provider, "illunis_spec_write", version=1, spec_md=old, sig=contract.sign_spec(SECRET, 1, old))["ok"] is False


def test_no_secret_refuses(tmp_path, monkeypatch):
    monkeypatch.delenv("ILLUNIS_INBOX_SECRET", raising=False)
    p = IllunisMemoryProvider()
    p.initialize("s", hermes_home=str(tmp_path))
    assert call(p, "illunis_spec_write", version=2, spec_md=MD, sig=SIG)["error"]["code"] == "unavailable"
    p.shutdown()


def test_memory_write_needs_hermes_mode(provider):
    res = write_memory(provider)
    assert res["ok"] is False and res["error"]["code"] == "not_allowed"  # no mirror yet
    phone = MD.replace("(version 2)", "(version 3)").replace("- mode: hermes", "- mode: phone")
    assert call(provider, "illunis_spec_write", version=3, spec_md=phone, sig=contract.sign_spec(SECRET, 3, phone))["ok"]
    assert write_memory(provider)["error"]["code"] == "not_allowed"
    hermes = phone.replace("(version 3)", "(version 4)").replace("- mode: phone", "- mode: hermes")
    assert call(provider, "illunis_spec_write", version=4, spec_md=hermes, sig=contract.sign_spec(SECRET, 4, hermes))["ok"]
    assert write_memory(provider)["ok"] is True
    assert call(provider, "illunis_memory_recall", query="tea")["ok"] is True
