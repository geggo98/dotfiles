#!/usr/bin/env python3
"""Minimal stdlib JIRA REST v2 mock for the jira skill integration test.

No real JIRA account. Serves just enough of /rest/api/2 to exercise the client:
read commands, comment post/delete, description PUT (for the undo round-trip),
and a *paginated* /user/search that injects one HTTP 429 (to prove the client's
retry/backoff) so the cache test can show the second lookup hits SQLite, not the API.

Usage: mock_server.py <PORTFILE> <REQLOG> <BODYLOG>
  PORTFILE  the chosen port is written here once bound
  REQLOG    one "<METHOD> <path?query>" line per request (grep-friendly)
  BODYLOG   one JSON object per request (method/path/query/body) for assertions
"""
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORTFILE, REQLOG, BODYLOG = sys.argv[1], sys.argv[2], sys.argv[3]

LOCK = threading.Lock()

STATE = {
    "issue": {
        "VUKFZIF-1": {
            "summary": "Test issue",
            "status": "To Do",
            "issuetype": "Task",
            "assignee": None,
            "labels": ["wip"],
            "updated": "2026-07-20T10:00:00.000+0000",
            "description": "ORIG DESC",
            "attachment": [],
            "issuelinks": [],
        }
    },
    "comments": {
        "VUKFZIF-1": [
            {
                "id": "1001",
                "body": "first comment",
                "author": {"displayName": "Tester"},
                "created": "2026-07-20T09:00:00.000+0000",
                "updated": "2026-07-20T09:00:00.000+0000",
            }
        ]
    },
    "next_comment_id": 2000,
    "user_429_served": False,
}

TRANSITIONS = [
    {"id": "11", "name": "To Do", "to": {"id": "10083", "name": "To Do"}},
    {"id": "61", "name": "In Code Review", "to": {"id": "10084", "name": "In Code Review"}},
    {"id": "71", "name": "In QA", "to": {"id": "10091", "name": "In QA"}},
    {"id": "31", "name": "Done", "to": {"id": "10085", "name": "Done"}},
]

# 60 users matching any query — forces two pages at the client's 50/page.
USERS = [
    {
        "accountId": f"acc{n}",
        "emailAddress": f"user{n}@example.com",
        "displayName": f"User {n}",
        "active": True,
    }
    for n in range(60)
]


def _issue_fields(key):
    it = STATE["issue"][key]
    return {
        "summary": it["summary"],
        "status": {"name": it["status"]},
        "issuetype": {"name": it["issuetype"]},
        "assignee": it["assignee"],
        "labels": it["labels"],
        "updated": it["updated"],
        "description": it["description"],
        "attachment": it["attachment"],
        "issuelinks": it["issuelinks"],
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence default stderr logging
        pass

    # -- helpers ----------------------------------------------------------
    def _record(self, body):
        with LOCK:
            with open(REQLOG, "a") as f:
                f.write(f"{self.command} {self.path}\n")
            with open(BODYLOG, "a") as f:
                u = urlparse(self.path)
                f.write(
                    json.dumps(
                        {
                            "method": self.command,
                            "path": u.path,
                            "query": parse_qs(u.query),
                            "body": body,
                        }
                    )
                    + "\n"
                )

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) if n else b""
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return raw.decode("utf-8", "replace")

    def _send(self, code, obj=None, headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if obj is None:
            self.end_headers()
            return
        data = json.dumps(obj).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # -- dispatch ---------------------------------------------------------
    def do_GET(self):
        self._route("GET", None)

    def do_POST(self):
        self._route("POST", self._read_body())

    def do_PUT(self):
        self._route("PUT", self._read_body())

    def do_DELETE(self):
        self._route("DELETE", None)

    def _route(self, method, body):
        self._record(body)
        u = urlparse(self.path)
        path = u.path
        q = parse_qs(u.query)

        if path == "/rest/api/2/myself":
            return self._send(200, {
                "accountId": "acc-self",
                "emailAddress": "test@example.com",
                "displayName": "Test Self",
                "active": True,
            })

        if path == "/rest/api/2/user/search":
            with LOCK:
                first = not STATE["user_429_served"]
                STATE["user_429_served"] = True
            if first:
                # Inject one throttle so the client's GET retry/backoff is exercised.
                return self._send(429, {"message": "rate limited"}, {"Retry-After": "0"})
            start = int((q.get("startAt", ["0"])[0]))
            mx = int((q.get("maxResults", ["50"])[0]))
            return self._send(200, USERS[start : start + mx])

        if path == "/rest/api/2/search/jql":
            issues = [
                {"key": k, "fields": _issue_fields(k)} for k in STATE["issue"]
            ]
            return self._send(200, {"issues": issues, "isLast": True, "nextPageToken": None})

        m = re.match(r"^/rest/api/2/issue/([A-Z]+-[0-9]+)(/.*)?$", path)
        if m:
            key, sub = m.group(1), (m.group(2) or "")
            if key not in STATE["issue"]:
                return self._send(404, {"errorMessages": ["issue not found"]})
            return self._issue(method, key, sub, body)

        return self._send(404, {"errorMessages": [f"unmapped {method} {path}"]})

    def _issue(self, method, key, sub, body):
        # /issue/<KEY>
        if sub == "":
            if method == "GET":
                return self._send(200, {"key": key, "fields": _issue_fields(key)})
            if method == "PUT":
                fields = (body or {}).get("fields") or {}
                if "description" in fields:
                    STATE["issue"][key]["description"] = fields["description"]
                if "labels" in fields:
                    STATE["issue"][key]["labels"] = fields["labels"]
                upd = (body or {}).get("update") or {}
                for op in upd.get("labels", []):
                    if "add" in op and op["add"] not in STATE["issue"][key]["labels"]:
                        STATE["issue"][key]["labels"].append(op["add"])
                    if "remove" in op and op["remove"] in STATE["issue"][key]["labels"]:
                        STATE["issue"][key]["labels"].remove(op["remove"])
                return self._send(204)

        # /issue/<KEY>/transitions
        if sub == "/transitions":
            if method == "GET":
                return self._send(200, {"transitions": TRANSITIONS})
            if method == "POST":
                tid = ((body or {}).get("transition") or {}).get("id")
                for t in TRANSITIONS:
                    if t["id"] == tid:
                        STATE["issue"][key]["status"] = t["to"]["name"]
                return self._send(204)

        # /issue/<KEY>/assignee
        if sub == "/assignee" and method == "PUT":
            acc = (body or {}).get("accountId")
            STATE["issue"][key]["assignee"] = {"accountId": acc, "displayName": acc} if acc else None
            return self._send(204)

        # /issue/<KEY>/comment  and  /issue/<KEY>/comment/<id>
        cm = re.match(r"^/comment(?:/([0-9]+))?$", sub)
        if cm:
            cid = cm.group(1)
            comments = STATE["comments"].setdefault(key, [])
            if cid is None and method == "GET":
                return self._send(200, {"comments": comments, "total": len(comments)})
            if cid is None and method == "POST":
                with LOCK:
                    STATE["next_comment_id"] += 1
                    nid = str(STATE["next_comment_id"])
                comments.append({"id": nid, "body": (body or {}).get("body", ""),
                                 "author": {"displayName": "Test Self"}, "created": "2026-07-20T11:00:00.000+0000"})
                return self._send(201, {"id": nid, "body": (body or {}).get("body", "")})
            if cid is not None:
                found = next((c for c in comments if c["id"] == cid), None)
                if method == "GET":
                    return self._send(200, found or {}) if found else self._send(404, {"errorMessages": ["no comment"]})
                if method == "PUT":
                    if not found:
                        return self._send(404, {"errorMessages": ["no comment"]})
                    found["body"] = (body or {}).get("body", "")
                    return self._send(200, found)
                if method == "DELETE":
                    STATE["comments"][key] = [c for c in comments if c["id"] != cid]
                    return self._send(204)

        return self._send(404, {"errorMessages": [f"unmapped issue sub {method} {sub}"]})


def main():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    with open(PORTFILE, "w") as f:
        f.write(str(port))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
