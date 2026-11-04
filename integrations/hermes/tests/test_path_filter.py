import http.client
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "proxy"))
import path_filter  # noqa: E402


@pytest.mark.parametrize("method,target", [
    ("GET", "/p/illunis/health"),
    ("POST", "/p/illunis/v1/runs"),
    ("GET", "/p/illunis/v1/runs/run_1/events"),
    ("POST", "/p/illunis/api/sessions/local-abc123/chat"),
    ("POST", "/p/illunis/api/sessions/s1/chat/stream"),
])
def test_allowed(method, target):
    assert path_filter.allowed(method, target)


@pytest.mark.parametrize("method,target", [
    ("GET", "/v1/models"),
    ("GET", "/health"),
    ("GET", "/api/jobs"),
    ("GET", "/p/hermes/v1/models"),
    ("POST", "/p/illunis/v1/chat/completions"),
    ("POST", "/p/illunis/api/sessions/../chat"),
    ("GET", "/p/illunis/health?x=1"),
    ("DELETE", "/p/illunis/v1/runs/r1"),
    ("GET", "/p/illunis/health/"),
])
def test_denied(method, target):
    assert not path_filter.allowed(method, target)


class Upstream(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        Upstream.seen.append((self.path, self.headers.get("Authorization"), self.rfile.read(n)))
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST


def serve(handler):
    s = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


def test_forwards_allowed_and_blocks_rest():
    up = serve(Upstream)
    path_filter.Handler.upstream = up.server_address
    px = serve(path_filter.Handler)
    try:
        c = http.client.HTTPConnection(*px.server_address)
        c.request("POST", "/p/illunis/api/sessions/s1/chat", body=b'{"message":"x"}',
                  headers={"Authorization": "Bearer t", "Content-Type": "application/json"})
        r = c.getresponse()
        assert r.status == 200 and r.read() == b'{"ok":true}'
        assert Upstream.seen[-1] == ("/p/illunis/api/sessions/s1/chat", "Bearer t", b'{"message":"x"}')
        n = len(Upstream.seen)
        for m, p in [("GET", "/v1/models"), ("POST", "/api/jobs"), ("GET", "/p/default/health")]:
            c = http.client.HTTPConnection(*px.server_address)
            c.request(m, p)
            assert c.getresponse().status == 404
        assert len(Upstream.seen) == n  # nothing denied reached upstream
        c = http.client.HTTPConnection(*px.server_address)
        c.request("POST", "/p/illunis/v1/runs", body=b"x" * (path_filter.MAX_BODY + 1))
        assert c.getresponse().status == 413
    finally:
        px.shutdown()
        up.shutdown()
