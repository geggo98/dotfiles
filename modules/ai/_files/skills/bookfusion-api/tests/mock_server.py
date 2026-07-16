#!/usr/bin/env python3
"""Minimal stdlib mock of the BookFusion API for integration tests.

Usage: mock_server.py <portfile> <reqlog> [<bodylog>]
  <portfile>: the chosen ephemeral port is written here once the server is listening.
  <reqlog>:   one line appended per request: "<epoch_ms> <METHOD> <PATH> ua=<UA> xtoken=<X-Token>".
              This format is LOAD-BEARING for the test suite (test 4 awk's the epoch_ms; many greps
              match METHOD/PATH). Do NOT change it — put anything richer in <bodylog>.
  <bodylog>:  one JSON object appended per request: {method,path,ct,xtoken,body,parts}. Lets tests assert
              the OUTGOING request body/headers/multipart part names. Defaults to "<reqlog>.body".

This mock doubles as executable documentation of the REAL BookFusion API: the responses below are annotated
with `# REAL BEHAVIOR:` notes captured from live traffic (the 129-book library this skill was built against).
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "test-token-123"
# REAL BEHAVIOR: POST /api/v3/auth.json issues a token ONLY for valid credentials; bad creds -> 401.
VALID_EMAIL = "test@example.com"
VALID_PASSWORD = "hunter2"

BOOKS = [{"id": 111, "title": "Kubernetes Up & Running", "number": 111},
         {"id": 222, "title": "Programming Rust", "number": 222}]

# REAL BEHAVIOR: a Book carries read_url (NOT `url`), formats[], cover.{blurhash,width,height} and
# permissions.return — none of which were in the original reverse-engineered schema (now added to openapi.yaml).
CANNED_BOOK = {
    "id": 111, "number": 111, "title": "Canned Book", "summary": "preserved on omit",
    "language": "en", "read_url": "https://reader.bookfusion.com/books/111?type=epub",
    "authors": [{"name": "Old Author"}], "tags": ["old"], "bookshelves": [], "series": [], "categories": [],
    "cover": {"url": "https://x/c.jpg", "blurhash": "L6Pj0^", "width": 400, "height": 600},
    "formats": [{"name": "EPUB", "download_size": 123, "content_type": "application/epub+zip"}],
    "permissions": {"update_metadata": True, "send_to_kindle": True, "export": True, "return": False},
}

REQLOG = sys.argv[2] if len(sys.argv) > 2 else "/dev/null"
BODYLOG = sys.argv[3] if len(sys.argv) > 3 else (REQLOG + ".body" if REQLOG != "/dev/null" else "/dev/null")


def parse_multipart(body, ctype):
    """Return (payload_obj, parts) for a multipart/form-data body (stdlib only).
    parts = {name: {"filename":.., "size":..}}; payload_obj = json.loads of the `payload` part."""
    m = re.search(r"boundary=([^;]+)", ctype or "")
    if not m:
        return None, {}
    delim = ("--" + m.group(1)).encode()
    parts, payload = {}, None
    for chunk in body.split(delim):
        if not chunk or chunk in (b"--\r\n", b"--", b"\r\n") or b"\r\n\r\n" not in chunk:
            continue
        head, data = chunk.split(b"\r\n\r\n", 1)
        if data.endswith(b"\r\n"):
            data = data[:-2]
        head_s = head.decode("utf-8", "replace")
        nm = re.search(r'name="([^"]+)"', head_s)
        if not nm:
            continue
        fn = re.search(r'filename="([^"]+)"', head_s)
        name = nm.group(1)
        parts[name] = {"filename": fn.group(1) if fn else None, "size": len(data)}
        if name == "payload":
            try:
                payload = json.loads(data)
            except Exception:
                payload = None
    return payload, parts


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence default stderr access logging
        pass

    def _log(self):
        # LOAD-BEARING format — keep byte-identical (see module docstring).
        with open(REQLOG, "a") as f:
            f.write("%d %s %s ua=%s xtoken=%s\n" % (
                int(time.time() * 1000), self.command, self.path,
                self.headers.get("User-Agent", "-"), self.headers.get("X-Token", "-")))

    def _read(self):
        """Read the body, append {method,path,ct,xtoken,body,parts} to BODYLOG, return (parsed_or_raw, parts)."""
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else b""
        ct = self.headers.get("Content-Type", "")
        parts = {}
        if ct.startswith("multipart/form-data"):
            parsed, parts = parse_multipart(body, ct)
        elif body:
            try:
                parsed = json.loads(body)
            except Exception:
                parsed = body.decode("utf-8", "replace")
        else:
            parsed = None
        rec = {"method": self.command, "path": self.path, "ct": ct,
               "xtoken": self.headers.get("X-Token", "-"), "body": parsed, "parts": parts}
        with open(BODYLOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
        return parsed, parts

    def _send(self, code, obj=None, ctype="application/json", raw=None):
        payload = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(code)
        if payload:
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def _needs_token(self):
        if self.headers.get("X-Token") != TOKEN:
            self._send(401, {"error": "unauthorized"})
            return True
        return False

    def do_POST(self):
        self._log()
        parsed, parts = self._read()
        p = self.path
        if p == "/api/v3/auth.json":
            d = parsed if isinstance(parsed, dict) else {}
            if d.get("email") == VALID_EMAIL and d.get("password") == VALID_PASSWORD:
                return self._send(200, {"token": TOKEN, "type": "password"})
            return self._send(401, {"error": "invalid credentials"})
        if p == "/api/user/books/search":
            if self._needs_token():
                return
            return self._send(200, BOOKS)
        if p == "/api/user/tts":
            if self._needs_token():
                return
            # REAL BEHAVIOR: getTtsCredentials returns token + preview_token + a signed streaming url
            # (all credential material). The client must never print any of these to the context.
            return self._send(200, {"token": "tts-token-xyz", "preview_token": "tts-preview-abc",
                                    "url": "https://tts.example/stream?sig=secret-signed",
                                    "expires_at": "2030-01-01T00:00:00Z"})
        if p == "/api/user/highlights":
            if self._needs_token():
                return
            # REAL BEHAVIOR: createHighlight is multipart; the optional quote-image part is named
            # "binary" (NOT "file"). The BODYLOG `parts` records which name the client actually sent.
            return self._send(200, {"id": 555, "quote_text": (parsed or {}).get("quote_text", "")})
        if p == "/api/user/highlights/export":
            if self._needs_token():
                return
            # REAL BEHAVIOR: an export can be binary (application/octet-stream, e.g. a PDF). The client
            # must write it byte-exact (no UTF-8 round-trip). These bytes include non-UTF-8 sequences.
            return self._send(200, ctype="application/octet-stream", raw=b"\x00\x01\x02BOOKFUSION\xff\xfe\r\n")
        if p == "/api/user/series":
            if self._needs_token():
                return
            d = parsed if isinstance(parsed, dict) else {}
            # REAL BEHAVIOR: series index is stored numerically and echoes back as a float-string.
            return self._send(200, {"id": 900, "title": d.get("title", "S"), "index": "1.0",
                                    "creation_token": d.get("creation_token")})
        if p == "/api/user/bookshelves":
            if self._needs_token():
                return
            d = parsed if isinstance(parsed, dict) else {}
            return self._send(200, {"id": 96027, "name": d.get("name", "Work"), "smart": False})
        # Fallback: echo the received JSON body so tests can assert coerced types reached the wire.
        return self._send(200, {"received": parsed})

    def do_GET(self):
        self._log()
        if self._needs_token():
            return
        m = re.match(r"^/api/user/books/(\d+)/reading_position$", self.path)
        if m:
            # REAL BEHAVIOR: a book with no saved reading position returns 404 (not an empty 200).
            if m.group(1) == "999":
                return self._send(404, {"error": "not found"})
            return self._send(200, {"chapter_index": 0, "percentage": 0})
        return self._send(200, {"id": 1, "email": "test@example.com"})

    def do_DELETE(self):
        self._log()
        self._read()
        return self._send(204)

    def do_PATCH(self):
        self._log()
        parsed, parts = self._read()
        m = re.match(r"^/api/user/books/(\d+)$", self.path)
        if m:
            if self._needs_token():
                return
            # REAL BEHAVIOR: updateUserBook is multipart; the 'payload' JSON is MERGED onto the book —
            # omitted fields are preserved, and each SENT array field (tags/bookshelf_ids/authors/series)
            # REPLACES the whole set. series[].index round-trips as a float-string ("202401" -> "202401.0").
            book = dict(CANNED_BOOK)
            payload = parsed if isinstance(parsed, dict) else {}
            for k, v in payload.items():
                if k == "authors":
                    book["authors"] = [{"name": a} for a in v]
                elif k == "bookshelf_ids":
                    book["bookshelves"] = [{"id": i, "name": "S%s" % i} for i in v]
                elif k == "series":
                    book["series"] = [{"id": s.get("id"), "index": "%s.0" % s.get("index")} for s in v]
                else:
                    book[k] = v
            return self._send(200, book)
        return self._send(200, {"ok": True})


def main():
    portfile = sys.argv[1]
    httpd = HTTPServer(("127.0.0.1", 0), H)  # port 0 => OS picks an ephemeral port
    with open(portfile, "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
