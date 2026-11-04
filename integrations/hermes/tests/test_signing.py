import hashlib
import hmac
import json

import pytest

from illunis_memory import signing

SECRET = "a" * 64
NOW = 1_790_000_000
ACTION = {"type": "message_bot", "target": "researcher", "text": "Ask about the Thursday plan"}


def test_inbox_signature_is_hmac_of_raw_body():
    body, headers = signing.build_inbox_request(SECRET, "reminder", "Stretch at 6", now=NOW, nonce="n" * 32)
    expected = hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
    assert headers["X-Illunis-Signature"] == expected
    assert headers["X-Illunis-Timestamp"] == str(NOW)
    parsed = json.loads(body)
    assert parsed == {"v": 1, "kind": "reminder", "text": "Stretch at 6", "ts": NOW, "nonce": "n" * 32,
                      "source": "hermes:illunis"}
    assert body == signing.canonical_json(parsed).encode()  # canonical: sorted keys, no spaces


def test_known_vector():
    # Fixed vector so the Worker's JS implementation can assert the same bytes and hex.
    body, headers = signing.build_inbox_request("k" * 32, "message", "hi", now=1700000000, nonce="0" * 32)
    assert body == (b'{"kind":"message","nonce":"00000000000000000000000000000000",'
                    b'"source":"hermes:illunis","text":"hi","ts":1700000000,"v":1}')
    assert headers["X-Illunis-Signature"] == hmac.new(b"k" * 32, body, hashlib.sha256).hexdigest()


def test_verify_round_trip_and_rejections():
    body, headers = signing.build_inbox_request(SECRET, "message", "zażółć", now=NOW)
    assert signing.verify_inbox_request(SECRET, body, headers, now=NOW + 299)["text"] == "zażółć"
    with pytest.raises(ValueError, match="skew"):
        signing.verify_inbox_request(SECRET, body, headers, now=NOW + 301)
    with pytest.raises(ValueError, match="skew"):
        signing.verify_inbox_request(SECRET, body, headers, now=NOW - 301)
    with pytest.raises(ValueError, match="signature"):
        signing.verify_inbox_request("b" * 64, body, headers, now=NOW)
    with pytest.raises(ValueError, match="signature"):
        signing.verify_inbox_request(SECRET, body.replace(b"message", b"reminder"), headers, now=NOW)
    with pytest.raises(ValueError, match="mismatch"):
        signing.verify_inbox_request(SECRET, body, {**headers, "X-Illunis-Timestamp": str(NOW + 1)}, now=NOW)


def test_short_secret_refused():
    with pytest.raises(ValueError):
        signing.build_inbox_request("short", "message", "x")


def test_canonical_json_rejects_floats():
    with pytest.raises(ValueError):
        signing.canonical_json({"a": 1.5})


def test_approval_round_trip():
    sig = signing.sign_approval(SECRET, "act_abcdef12", ACTION, NOW + 60)
    approval = {"action_id": "act_abcdef12", "expires_at": NOW + 60, "sig": sig}
    assert signing.verify_approval(SECRET, ACTION, approval, now=NOW) == "act_abcdef12"


@pytest.mark.parametrize("mutate,match", [
    (lambda a, p: ({**a, "text": "Something else"}, p), "does not match"),
    (lambda a, p: (a, {**p, "action_id": "act_other123"}), "does not match"),
    (lambda a, p: (a, {**p, "expires_at": p["expires_at"] + 1}), "does not match"),
    (lambda a, p: (a, {**p, "sig": "0" * 64}), "does not match"),
    (lambda a, p: (a, {**p, "action_id": "x"}), "action_id"),
    (lambda a, p: (a, {**p, "expires_at": "soon"}), "expires_at"),
])
def test_approval_tamper(mutate, match):
    sig = signing.sign_approval(SECRET, "act_abcdef12", ACTION, NOW + 60)
    action, approval = mutate(ACTION, {"action_id": "act_abcdef12", "expires_at": NOW + 60, "sig": sig})
    with pytest.raises(ValueError, match=match):
        signing.verify_approval(SECRET, action, approval, now=NOW)


def test_approval_expiry_and_ttl():
    sig = signing.sign_approval(SECRET, "act_abcdef12", ACTION, NOW)
    with pytest.raises(ValueError, match="expired"):
        signing.verify_approval(SECRET, ACTION, {"action_id": "act_abcdef12", "expires_at": NOW, "sig": sig},
                                now=NOW)
    far = NOW + signing.APPROVAL_MAX_TTL + 1
    sig = signing.sign_approval(SECRET, "act_abcdef12", ACTION, far)
    with pytest.raises(ValueError, match="too long"):
        signing.verify_approval(SECRET, ACTION, {"action_id": "act_abcdef12", "expires_at": far, "sig": sig},
                                now=NOW)


def test_approval_sig_differs_from_inbox_domain():
    msg = signing.approval_message("act_abcdef12", signing.action_hash(ACTION), NOW)
    assert msg.startswith(b"illunis-approval-v1\n")
