#!/usr/bin/env python3
"""Minimal stdlib JIRA REST v2 mock for the jira skill integration test.

No real JIRA account. Serves just enough of /rest/api/2 to exercise the client:
read commands, comment post/delete, description PUT (for the undo round-trip),
issue links (create/list/delete + the link-type table), and a *paginated*
/user/search that injects one HTTP 429 (to prove the client's retry/backoff) so
the cache test can show the second lookup hits SQLite, not the API.

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
        "JIRA-1": {
            "summary": "Test issue",
            "status": "To Do",
            "issuetype": "Task",
            "assignee": None,
            "labels": ["wip"],
            "updated": "2026-07-20T10:00:00.000+0000",
            "description": "ORIG DESC",
            "attachment": [],
        },
        # A second real issue, so links have somewhere to point.
        "JIRA-2": {
            "summary": "Link target",
            "status": "To Do",
            "issuetype": "Task",
            "assignee": None,
            "labels": [],
            "updated": "2026-07-20T10:00:00.000+0000",
            "description": "TARGET",
            "attachment": [],
        },
        # ~60 KB description: proves `get --format json` stays parseable (it must not be
        # routed through the spill guard) and that `description` does spill.
        "JIRA-99": {
            "summary": "Huge description",
            "status": "To Do",
            "issuetype": "Task",
            "assignee": None,
            "labels": [],
            "updated": "2026-07-20T10:00:00.000+0000",
            "description": "BIG " * 15000,
            "attachment": [],
        },
    },
    "links": {},
    "comments": {
        "JIRA-1": [
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
    "next_issue_id": 500,
    "next_link_id": 9000,
    "user_429_served": False,
}

TRANSITIONS = [
    {"id": "11", "name": "To Do", "to": {"id": "10083", "name": "To Do"}},
    {"id": "61", "name": "In Code Review", "to": {"id": "10084", "name": "In Code Review"}},
    {"id": "71", "name": "In QA", "to": {"id": "10091", "name": "In QA"}},
    {"id": "31", "name": "Done", "to": {"id": "10085", "name": "Done"}},
]

# The four types below are copied VERBATIM from the live site (2026-08-25), and
# the selection is deliberate — each one buys a test the others cannot:
#   Blocks   asymmetric, the everyday case
#   Relates  SYMMETRIC (outward == inward), so a phrase matches both directions
#   Depends / Used  a REAL collision: "Used by" is the outward of `Used` AND the
#                   inward of `Depends`, so the ambiguity test is genuine rather
#                   than an invented string nothing would ever produce.
LINK_TYPES = [
    {"id": "10000", "name": "Blocks", "outward": "blocks", "inward": "is blocked by"},
    {"id": "10003", "name": "Relates", "outward": "relates to", "inward": "relates to"},
    {"id": "10010", "name": "Depends", "outward": "Depends on", "inward": "Used by"},
    {"id": "10012", "name": "Used", "outward": "Used by", "inward": "Uses"},
]


def _link_side(key):
    """The nested issue stub Jira puts on each end of a link."""
    it = STATE["issue"].get(key)
    if not it:
        return {"key": key}
    return {"key": key, "fields": {"status": {"name": it["status"]}, "summary": it["summary"]}}


def _issue_links(key):
    """The `issuelinks` field as real Jira renders it, from KEY's point of view.

    Mirrors the shape measured on link 72461: on the link's *inwardIssue* the
    counterpart appears under `outwardIssue` (that end is the subject of
    type.outward), and on the *outwardIssue* it appears under `inwardIssue`.
    Getting this backwards would make the direction test cheerfully confirm the
    very bug it exists to catch, so it is asserted against the real site, not
    inferred from the field names."""
    out = []
    for lid, l in sorted(STATE["links"].items(), key=lambda kv: int(kv[0])):
        inw, outw = l["inwardIssue"]["key"], l["outwardIssue"]["key"]
        if key == inw:
            out.append({"id": lid, "type": l["type"], "outwardIssue": _link_side(outw)})
        elif key == outw:
            out.append({"id": lid, "type": l["type"], "inwardIssue": _link_side(inw)})
    return out


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


def _issue_fields(key, fields=None):
    """Honour the `fields=` query param like real Jira does.

    Returning everything unconditionally would make any "is field X requested?" test pass
    for the wrong reason — which is exactly the blind spot that let `get` ship without
    ever asking for `description`."""
    it = STATE["issue"][key]
    all_fields = {
        "summary": it["summary"],
        "status": {"name": it["status"]},
        "issuetype": {"name": it["issuetype"]},
        "assignee": it["assignee"],
        "labels": it["labels"],
        "updated": it["updated"],
        "description": it["description"],
        "attachment": it["attachment"],
        "issuelinks": _issue_links(key),
    }
    if not fields:
        return all_fields
    wanted = [f for part in fields for f in part.split(",") if f]
    return {k: v for k, v in all_fields.items() if k in wanted}


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
                {"key": k, "fields": _issue_fields(k, q.get("fields"))} for k in STATE["issue"]
            ]
            return self._send(200, {"issues": issues, "isLast": True, "nextPageToken": None})

        # Issue links. Kept above the /issue/... routes below: the regex there does
        # not match "/issueLink", but the paths are one character apart and the next
        # person to widen that regex should trip over this comment first.
        if path == "/rest/api/2/issueLinkType" and method == "GET":
            return self._send(200, {"issueLinkTypes": LINK_TYPES})

        if path == "/rest/api/2/issueLink" and method == "POST":
            b = body or {}
            name = (b.get("type") or {}).get("name")
            t = next((x for x in LINK_TYPES if x["name"] == name), None)
            if not t:
                return self._send(400, {"errorMessages": [f"no such link type: {name}"]})
            inw = (b.get("inwardIssue") or {}).get("key")
            outw = (b.get("outwardIssue") or {}).get("key")
            for k in (inw, outw):
                if k not in STATE["issue"]:
                    return self._send(404, {"errorMessages": [f"issue not found: {k}"]})
            with LOCK:
                STATE["next_link_id"] += 1
                lid = str(STATE["next_link_id"])
            # Real Jira answers 201 with an EMPTY body — the id is not returned.
            # That is precisely why the client has to read the link back.
            STATE["links"][lid] = {
                "id": lid,
                "type": t,
                "inwardIssue": {"key": inw},
                "outwardIssue": {"key": outw},
            }
            return self._send(201)

        lm = re.match(r"^/rest/api/2/issueLink/([0-9]+)$", path)
        if lm:
            lid = lm.group(1)
            l = STATE["links"].get(lid)
            if not l:
                return self._send(404, {"errorMessages": [f"no such link: {lid}"]})
            if method == "GET":
                return self._send(200, {
                    "id": lid,
                    "type": l["type"],
                    "inwardIssue": _link_side(l["inwardIssue"]["key"]),
                    "outwardIssue": _link_side(l["outwardIssue"]["key"]),
                })
            if method == "DELETE":
                del STATE["links"][lid]
                return self._send(204)

        # Bare POST /issue — create. Must come before the /issue/<KEY> regex below, which
        # does not match this path (which is why `create` was untestable until now).
        if path == "/rest/api/2/issue" and method == "POST":
            fields = (body or {}).get("fields") or {}
            with LOCK:
                STATE["next_issue_id"] += 1
                key = f"VUKFZIF-{STATE['next_issue_id']}"
            STATE["issue"][key] = {
                "summary": fields.get("summary", ""),
                "status": "To Do",
                "issuetype": (fields.get("issuetype") or {}).get("name", "Task"),
                "assignee": None,
                "labels": fields.get("labels") or [],
                "updated": "2026-07-20T12:00:00.000+0000",
                "description": fields.get("description"),
                "attachment": [],
            }
            return self._send(201, {"id": str(STATE["next_issue_id"]), "key": key})

        m = re.match(r"^/rest/api/2/issue/([A-Z]+-[0-9]+)(/.*)?$", path)
        if m:
            key, sub = m.group(1), (m.group(2) or "")
            if key not in STATE["issue"]:
                return self._send(404, {"errorMessages": ["issue not found"]})
            return self._issue(method, key, sub, body, q)

        return self._send(404, {"errorMessages": [f"unmapped {method} {path}"]})

    def _issue(self, method, key, sub, body, q):
        # /issue/<KEY>
        if sub == "":
            if method == "GET":
                return self._send(200, {"key": key, "fields": _issue_fields(key, q.get("fields"))})
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
