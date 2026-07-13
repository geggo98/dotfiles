#!/usr/bin/env python3
"""Minimal stdlib mock of the BookFusion API for integration tests.

Usage: mock_server.py <portfile> <reqlog>
  <portfile>: the chosen ephemeral port is written here once the server is listening.
  <reqlog>:   one line appended per request: "<epoch_ms> <METHOD> <PATH> ua=<UA> xtoken=<X-Token>".

Behaviour:
  POST /api/v3/auth.json      -> 200 {"token":"test-token-123"} if email+password present, else 401.
  POST /api/user/books/search -> 200 canned book array, but only if X-Token == test-token-123 (else 401).
  DELETE /api/user/books/{id} -> 204 (no body).
  any other POST              -> 200 {"received": <parsed request body>}  (lets tests assert coerced types).
  anything else               -> 200 {"ok": true} / echo.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "test-token-123"
BOOKS = [{"id": 111, "title": "Kubernetes Up & Running", "number": 111},
         {"id": 222, "title": "Programming Rust", "number": 222}]
REQLOG = sys.argv[2] if len(sys.argv) > 2 else "/dev/null"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence default stderr logging
        pass

    def _log(self):
        with open(REQLOG, "a") as f:
            f.write("%d %s %s ua=%s xtoken=%s\n" % (
                int(time.time() * 1000), self.command, self.path,
                self.headers.get("User-Agent", "-"), self.headers.get("X-Token", "-")))

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, code, obj=None):
        payload = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        if payload:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_POST(self):
        self._log()
        body = self._body()
        if self.path == "/api/v3/auth.json":
            try:
                d = json.loads(body or b"{}")
            except Exception:
                d = {}
            if d.get("email") and d.get("password"):
                return self._send(200, {"token": TOKEN, "type": "password"})
            return self._send(401, {"error": "invalid credentials"})
        if self.path == "/api/user/books/search":
            if self.headers.get("X-Token") != TOKEN:
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, BOOKS)
        # Fallback: echo the received JSON body so tests can assert coerced types reached the wire.
        try:
            parsed = json.loads(body or b"{}")
        except Exception:
            parsed = None
        return self._send(200, {"received": parsed})

    def do_GET(self):
        self._log()
        if self.headers.get("X-Token") != TOKEN:
            return self._send(401, {"error": "unauthorized"})
        return self._send(200, {"id": 1, "email": "test@example.com"})

    def do_DELETE(self):
        self._log()
        return self._send(204)

    def do_PATCH(self):
        self._log()
        self._body()
        return self._send(200, {"ok": True})


def main():
    portfile = sys.argv[1]
    httpd = HTTPServer(("127.0.0.1", 0), H)
    with open(portfile, "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
