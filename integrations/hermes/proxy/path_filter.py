#!/usr/bin/env python3
"""Path-filter proxy between a Cloudflare quick tunnel and the local Hermes API server.

A quick tunnel (`cloudflared tunnel --url ...`) cannot filter paths and has no Access in front, so
point it at this proxy instead of Hermes. Only the routes the Illunis Worker needs on the `illunis`
profile are forwarded to 127.0.0.1:8642; everything else (the default profile's API, other profiles,
jobs, dashboards) gets 404 here and never reaches Hermes. Stdlib only. Logs method, path class and
status, never headers or bodies.

  python3 path_filter.py [--listen 127.0.0.1:8643] [--upstream 127.0.0.1:8642]
"""
import argparse
import http.client
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Same allowlist as RUNBOOK.md section 3 (named-tunnel ingress rule).
ALLOWED = re.compile(
    r"^/p/illunis/(health|v1/health|v1/runs(/[A-Za-z0-9_-]+(/(events|stop))?)?"
    r"|api/sessions/[A-Za-z0-9_-]+/chat(/stream)?)$"
)
METHODS = {"GET", "POST"}
MAX_BODY = 64 * 1024
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "host", "content-length"}
TIMEOUT_S = 120


def allowed(method, target):
    path = target.split("?", 1)[0]
    return method in METHODS and "?" not in target and bool(ALLOWED.match(path))


class Handler(BaseHTTPRequestHandler):
    upstream = ("127.0.0.1", 8642)
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet default logger: it prints full request lines
        pass

    def _deny(self, status=404):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        sys.stderr.write(f"deny {self.command} {status}\n")

    def _forward(self):
        if not allowed(self.command, self.path):
            return self._deny()
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY or self.headers.get("Transfer-Encoding"):
            return self._deny(413)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        conn = http.client.HTTPConnection(*self.upstream, timeout=TIMEOUT_S)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            res = conn.getresponse()
            self.send_response(res.status)
            for k, v in res.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()
            # Stream in chunks so SSE (/events, /chat/stream) passes through as it arrives.
            while chunk := res.read1(8192):
                self.wfile.write(chunk)
                self.wfile.flush()
            sys.stderr.write(f"pass {self.command} {res.status}\n")
        except (OSError, http.client.HTTPException):
            self._deny(502)
        finally:
            conn.close()
            self.close_connection = True

    do_GET = _forward
    do_POST = _forward

    def _other(self):
        self._deny(405)

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _other


def hostport(value):
    host, _, port = value.rpartition(":")
    return host, int(port)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--listen", default="127.0.0.1:8643")
    ap.add_argument("--upstream", default="127.0.0.1:8642")
    args = ap.parse_args(argv)
    Handler.upstream = hostport(args.upstream)
    server = ThreadingHTTPServer(hostport(args.listen), Handler)
    sys.stderr.write(f"path filter on {args.listen} -> {args.upstream}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
