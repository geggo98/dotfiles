#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "httpx>=0.27",
# ]
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""JIRA Cloud ticket control via the REST API v2.

Fills the gaps the Atlassian MCP leaves open — most importantly ARBITRARY status
transitions (the MCP cannot reach every workflow status), plus a predictable v2
wiki-markup comment/description body (the MCP mangles Markdown), assignee changes,
issue creation and attachment upload/embed. Talks to Jira REST v2 directly with
httpx; works from ANY directory (no git, no `bb`).

Three operation tiers, gated by global flags (see main()):
  * read      — no flag (whoami/get/status/transitions/comments/user/users/search/
                links/attachments/download/undo --list)
  * write     — require --write (transition/comment/comment-edit/assign/create/
                attach/describe/label/link/watch/unwatch/undo)
  * dangerous — require --dangerous, which implies --write (comment-rm/attach-rm)

Two local SQLite stores back the extra capabilities:
  * user cache  (throwaway, $JIRA_CACHE_DIR) — paginated /user[/assignable]/search
                results, so resolving assignees on a huge user directory does not
                re-enumerate and get rate-limited (HTTP 429).
  * undo journal (durable, $JIRA_STATE_DIR) — every op that OVERWRITES or DELETES
                data snapshots the prior value first, so `undo` can restore it.

Credentials (env wins; else read from $SOPS_SECRETS_DIR files):
  JIRA_URL        | jira_url            (default https://c24-kfz.atlassian.net)
  JIRA_USERNAME   | jira_username
  JIRA_API_TOKEN  <- ATLASSIAN_API_TOKEN | jira_api_token -> atlassian_c24_bitbucket_api_token
Auth is HTTP Basic ("$JIRA_USERNAME:$JIRA_API_TOKEN") against the Jira site. httpx
puts it in a header, so the token never reaches the process argv.

Exit codes: 0 success, 1 bad args / gating refusal, 2 missing prereq/credentials,
            3 API/auth/network, 4 issue/resource not found.
"""
from __future__ import annotations

import json
import mimetypes
import os
import re
import sqlite3
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import httpx

# --------------------------------------------------------------------------
# Constants & tiny helpers
# --------------------------------------------------------------------------

READ, WRITE, DANGEROUS = "read", "write", "dangerous"

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
NC = "\033[0m"

KEY_RE = re.compile(r"^[A-Z][A-Z0-9]+-[0-9]+$")
IMG_EXT = {"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tif", "tiff", "ico", "heic"}

# Known assignee aliases (accountId). Keep in sync with references/workflow.md.
ASSIGNEE_ALIAS = {
    "marco": "712020:7130493d-95c6-473d-94d3-eaf7f51ce9a7",
}


def log_error(msg: str) -> None:
    print(f"{RED}Error: {msg}{NC}", file=sys.stderr)


def log_info(msg: str) -> None:
    print(f"{YELLOW}Info: {msg}{NC}", file=sys.stderr)


# Human status lines go to STDERR so stdout carries ONLY the machine result
# (id/key/json/tsv) — e.g. CID=$(jira.sh --write comment KEY -) captures just the id.
def log_success(msg: str) -> None:
    print(f"{GREEN}{msg}{NC}", file=sys.stderr)


class SkillError(Exception):
    """Carries a process exit code alongside the message."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


def require_key(key: str | None, cmd: str) -> str:
    # Validate the key shape before it is interpolated into REST URL paths/queries
    # — a stray ?, &, / or .. could otherwise alter which request is sent. Returns
    # the validated key (narrowed to str) so callers can reuse it type-safely.
    if not key:
        raise SkillError(f"{cmd} requires an issue key (e.g. VUKFZIF-1234)", 1)
    if not KEY_RE.match(key):
        raise SkillError(
            f"{cmd}: invalid issue key '{key}' — expected upper-case PROJECT-NUMBER "
            f"(e.g. VUKFZIF-1234)",
            1,
        )
    return key


def validate_format(fmt: str, *allowed: str) -> None:
    if fmt not in allowed:
        raise SkillError(f"Invalid --format '{fmt}' (expected: {', '.join(allowed)})", 1)


def _read_stdin() -> str:
    if sys.stdin.isatty():
        raise SkillError(
            "This command expects content on stdin (e.g. printf '%s' \"text\" | ... -)", 1
        )
    content = sys.stdin.read()
    if not content:
        raise SkillError("Received empty content on stdin", 1)
    return content


def human_bytes(n: int) -> str:
    units = ["B", "KiB", "MiB", "GiB"]
    f = float(n)
    i = 0
    while f >= 1024 and i < 3:
        f /= 1024
        i += 1
    return f"{int(f)} {units[i]}" if i == 0 else f"{f:.1f} {units[i]}"


def buffer_output(text: str, label: str, ext: str) -> None:
    """Print text; if it exceeds $JIRA_OUTPUT_MAX_BYTES, spill to a tempfile and
    print a short header + preview instead (keeps big results out of context)."""
    max_bytes = int(os.environ.get("JIRA_OUTPUT_MAX_BYTES", "32768"))
    data = text if text.endswith("\n") else text + "\n"
    raw = data.encode()
    if len(raw) <= max_bytes:
        sys.stdout.write(data)
        return
    fd, path = tempfile.mkstemp(prefix=f"jira-{label}.", suffix=f".{ext}")
    with os.fdopen(fd, "wb") as fh:
        fh.write(raw)
    lines = data.count("\n")
    preview = 20
    print(
        f"--- {label} truncated: {human_bytes(len(raw))} ({len(raw)} bytes, {lines} lines); "
        f"max {human_bytes(max_bytes)} ---"
    )
    print(f"full output written to: {path}")
    print(f"preview (first {preview} lines):")
    sys.stdout.write("\n".join(data.split("\n")[:preview]) + "\n")
    print("--- end preview ---")


def wiki_ref_for(path: str) -> str:
    """Jira v2 wiki-markup reference for an ALREADY-uploaded attachment: images
    render inline (!name!), everything else becomes a file link ([^name])."""
    base = Path(path).name
    ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
    return f"!{base}!" if ext in IMG_EXT else f"[^{base}]"


def _validate_upload_file(f: str) -> None:
    p = Path(f)
    if not p.exists():
        raise SkillError(f"attachment not found: {f}", 1)
    if p.is_dir():
        raise SkillError(f"attachment is a directory (not supported): {f}", 1)
    if not p.is_file():
        raise SkillError(f"attachment is not a regular file: {f}", 1)
    if not os.access(p, os.R_OK):
        raise SkillError(f"attachment not readable: {f}", 1)
    if p.stat().st_size == 0:
        raise SkillError(f"attachment is empty: {f}", 1)


# --------------------------------------------------------------------------
# Credentials
# --------------------------------------------------------------------------


def _secrets_dir() -> Path:
    d = os.environ.get("SOPS_SECRETS_DIR")
    if d:
        return Path(d)
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "sops-nix" / "secrets"


def _resolve(env_names: list[str], files: list[str], default: str | None = None) -> str | None:
    for e in env_names:
        v = os.environ.get(e)
        if v:
            return v
    d = _secrets_dir()
    for f in files:
        p = d / f
        if p.is_file():
            try:
                v = p.read_text().strip()
            except OSError:
                continue
            if v:
                return v
    return default


# --------------------------------------------------------------------------
# HTTP client
# --------------------------------------------------------------------------


class JiraClient:
    def __init__(self, base_url: str, username: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.api = f"{self.base_url}/rest/api/2"
        # BasicAuth goes in a header, never the argv. follow_redirects lets
        # attachment `content` URLs 302 to the (pre-signed) media host.
        self._client = httpx.Client(
            auth=httpx.BasicAuth(username, token),
            headers={"Accept": "application/json"},
            timeout=60.0,
            follow_redirects=True,
        )

    def _url(self, path: str) -> str:
        return path if path.startswith("http") else f"{self.api}{path}"

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict | None = None,
        json_body: Any = None,
        raw: bool = False,
    ) -> Any:
        url = self._url(path)
        attempts = 0
        while True:
            resp = self._client.request(method, url, params=params, json=json_body)
            # Retry only idempotent reads on transient throttling/5xx. A retried
            # POST/PUT/DELETE could double-apply if the first attempt committed.
            if method == "GET" and resp.status_code in (429, 502, 503, 504) and attempts < 4:
                attempts += 1
                ra = resp.headers.get("Retry-After", "")
                try:
                    wait = float(ra)
                except ValueError:
                    wait = min(2**attempts, 10)
                log_info(f"HTTP {resp.status_code} on {method} {path}; retrying in {wait:g}s")
                time.sleep(wait)
                continue
            break
        if resp.is_success:
            if raw:
                return resp.content
            if resp.status_code == 204 or not resp.content:
                return None
            try:
                return resp.json()
            except ValueError:
                return {"message": resp.text}
        self._raise(method, path, resp)

    def _raise(self, method: str, path: str, resp: httpx.Response) -> None:
        try:
            d = resp.json()
            msg = d.get("errorMessages") or d.get("errors") or d.get("message") or resp.text
            if isinstance(msg, (list, dict)):
                msg = "; ".join(f"{k}: {v}" for k, v in msg.items()) if isinstance(msg, dict) else "; ".join(map(str, msg))
        except ValueError:
            msg = resp.text
        code = resp.status_code
        if code in (401, 403):
            raise SkillError(
                f"Jira auth failed (HTTP {code}) on {method} {path}: {msg}. "
                "Run 'whoami' to verify the account behind the token.",
                3,
            )
        if code == 404:
            raise SkillError(f"Jira resource not found (HTTP 404): {method} {path}", 4)
        if code == 413:
            raise SkillError(f"Attachment too large (HTTP 413) on {method} {path}", 3)
        raise SkillError(f"Jira request failed (HTTP {code}) on {method} {path}: {msg}", 3)

    def get(self, path: str, params: dict | None = None, raw: bool = False) -> Any:
        return self._request("GET", path, params=params, raw=raw)

    def post(self, path: str, body: Any = None) -> Any:
        return self._request("POST", path, json_body=body)

    def put(self, path: str, body: Any = None) -> Any:
        return self._request("PUT", path, json_body=body)

    def delete(self, path: str, params: dict | None = None) -> Any:
        return self._request("DELETE", path, params=params)

    def _upload(self, key: str, files: list[tuple[str, tuple[str, bytes, str]]]) -> Any:
        url = self._url(f"/issue/{key}/attachments")
        to = float(os.environ.get("JIRA_UPLOAD_MAX_TIME", "300"))
        resp = self._client.post(
            url, files=files, headers={"X-Atlassian-Token": "no-check"}, timeout=to
        )
        if resp.is_success:
            try:
                return resp.json()
            except ValueError:
                return []
        self._raise("POST", f"/issue/{key}/attachments", resp)

    def upload(self, key: str, paths: list[str]) -> Any:
        files = []
        for p in paths:
            data = Path(p).read_bytes()
            mime = mimetypes.guess_type(p)[0] or "application/octet-stream"
            files.append(("file", (Path(p).name, data, mime)))
        return self._upload(key, files)

    def upload_bytes(self, key: str, filename: str, data: bytes) -> Any:
        mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        return self._upload(key, [("file", (filename, data, mime))])


# --------------------------------------------------------------------------
# User directory — paginated search + local SQLite cache
# --------------------------------------------------------------------------


class UserDirectory:
    """Cache-backed, paginated wrapper over /user/search and /user/assignable/search.

    On a large directory (e.g. check24, thousands of members) resolving an
    assignee by repeatedly enumerating the API gets rate-limited (HTTP 429).
    Results are cached in SQLite with a TTL so a repeated lookup skips the API.
    """

    def __init__(self, client: JiraClient):
        self.client = client
        self.ttl = int(os.environ.get("JIRA_USER_CACHE_TTL", "86400"))
        self.cap = int(os.environ.get("JIRA_USER_SEARCH_CAP", "1000"))
        d = os.environ.get("JIRA_CACHE_DIR")
        base = Path(d) if d else Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "jira-skill"
        base.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(base / "users.sqlite3"))
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS users("
            "account_id TEXT PRIMARY KEY, email TEXT, display_name TEXT, active INTEGER, updated_at INTEGER)"
        )
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS searches("
            "scope TEXT, query TEXT, account_ids TEXT, updated_at INTEGER, PRIMARY KEY(scope, query))"
        )
        self.db.commit()

    def _now(self) -> int:
        return int(time.time())

    def _cached_ids(self, scope: str, query: str) -> list[str] | None:
        row = self.db.execute(
            "SELECT account_ids, updated_at FROM searches WHERE scope=? AND query=?",
            (scope, query.lower()),
        ).fetchone()
        if not row:
            return None
        ids, ts = row
        if self._now() - ts > self.ttl:
            return None
        return json.loads(ids)

    def _cached_user(self, aid: str) -> dict:
        row = self.db.execute(
            "SELECT account_id, email, display_name, active FROM users WHERE account_id=?",
            (aid,),
        ).fetchone()
        if not row:
            return {"accountId": aid}
        return {
            "accountId": row[0],
            "emailAddress": row[1],
            "displayName": row[2],
            "active": bool(row[3]),
        }

    def _store(self, scope: str, query: str, users: list[dict]) -> None:
        now = self._now()
        for u in users:
            self.db.execute(
                "INSERT OR REPLACE INTO users VALUES(?,?,?,?,?)",
                (
                    u.get("accountId"),
                    u.get("emailAddress"),
                    u.get("displayName"),
                    1 if u.get("active") else 0,
                    now,
                ),
            )
        self.db.execute(
            "INSERT OR REPLACE INTO searches VALUES(?,?,?,?)",
            (scope, query.lower(), json.dumps([u.get("accountId") for u in users]), now),
        )
        self.db.commit()

    def _fetch(self, endpoint: str, params: dict) -> list[dict]:
        out: dict[str, dict] = {}
        start = 0
        page = 50
        while True:
            p = dict(params, startAt=start, maxResults=page)
            batch = self.client.get(endpoint, params=p)
            if not isinstance(batch, list):
                batch = []
            for u in batch:
                out[u.get("accountId")] = u
            if len(batch) < page or len(out) >= self.cap:
                if len(out) >= self.cap and len(batch) == page:
                    log_info(
                        f"user search hit cap {self.cap}; results truncated "
                        "(raise $JIRA_USER_SEARCH_CAP if you need more)."
                    )
                break
            start += page
        return list(out.values())

    def search(self, query: str, refresh: bool = False) -> list[dict]:
        scope = "global"
        if not refresh:
            ids = self._cached_ids(scope, query)
            if ids is not None:
                return [self._cached_user(a) for a in ids]
        users = self._fetch("/user/search", {"query": query})
        self._store(scope, query, users)
        return users

    def search_assignable(
        self, query: str, project: str | None = None, issue: str | None = None, refresh: bool = False
    ) -> list[dict]:
        scope = f"assignable:{project or ''}:{issue or ''}"
        if not refresh:
            ids = self._cached_ids(scope, query)
            if ids is not None:
                return [self._cached_user(a) for a in ids]
        params: dict[str, str] = {"query": query}
        if issue:
            params["issueKey"] = issue
        elif project:
            params["project"] = project
        users = self._fetch("/user/assignable/search", params)
        self._store(scope, query, users)
        return users

    def resolve_assignee(self, target: str) -> tuple[str, str]:
        """Resolve an email/name to a single (accountId, displayName), or refuse.

        /user/search is a fuzzy substring match over displayName AND email and
        includes inactive users — never blindly take the first hit.
        """
        users = self.search(target)
        if not users:
            raise SkillError(f"No Jira user found for '{target}'.", 4)
        if len(users) == 1:
            return users[0]["accountId"], users[0].get("displayName") or ""
        exact = [
            u
            for u in users
            if (u.get("emailAddress") or "").lower() == target.lower() and u.get("active")
        ]
        if len(exact) == 1:
            return exact[0]["accountId"], exact[0].get("displayName") or ""
        lines = [f"'{target}' matched {len(users)} users; cannot resolve unambiguously. Candidates:"]
        for u in users:
            lines.append(
                f"  - {u.get('accountId')}  {u.get('displayName')}  "
                f"<{u.get('emailAddress') or '?'}>  active={u.get('active')}"
            )
        lines.append("Re-run with the exact accountId.")
        raise SkillError("\n".join(lines), 1)


# --------------------------------------------------------------------------
# Undo journal — snapshot overwritten/deleted data in durable SQLite
# --------------------------------------------------------------------------


class UndoJournal:
    def __init__(self):
        d = os.environ.get("JIRA_STATE_DIR")
        base = Path(d) if d else Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state")) / "jira-skill"
        base.mkdir(parents=True, exist_ok=True)
        self.dir = base
        self.blobs = base / "blobs"
        self.blobs.mkdir(exist_ok=True)
        self.db = sqlite3.connect(str(base / "undo.sqlite3"))
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS undo_log("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, issue_key TEXT, op TEXT, "
            "ref TEXT, prior_json TEXT, blob_path TEXT, undone INTEGER DEFAULT 0)"
        )
        self.db.commit()

    def record(self, issue_key: str, op: str, ref: str | None, prior: Any, blob_path: str | None = None) -> int:
        cur = self.db.execute(
            "INSERT INTO undo_log(ts, issue_key, op, ref, prior_json, blob_path) VALUES(?,?,?,?,?,?)",
            (int(time.time()), issue_key, op, ref, json.dumps(prior), blob_path),
        )
        self.db.commit()
        return int(cur.lastrowid or 0)

    def save_blob(self, name: str, data: bytes) -> str:
        stamp = int(time.time())
        p = self.blobs / f"{stamp}-{name}"
        i = 0
        while p.exists():
            i += 1
            p = self.blobs / f"{stamp}-{i}-{name}"
        p.write_bytes(data)
        return str(p)

    def list(self, issue: str | None = None, limit: int = 20) -> list[tuple]:
        q = "SELECT id, ts, issue_key, op, ref, undone FROM undo_log"
        args: list[Any] = []
        if issue:
            q += " WHERE issue_key=?"
            args.append(issue)
        q += " ORDER BY id DESC LIMIT ?"
        args.append(limit)
        return self.db.execute(q, args).fetchall()

    def latest(self, issue: str | None = None, entry_id: int | None = None) -> tuple | None:
        q = "SELECT id, ts, issue_key, op, ref, prior_json, blob_path FROM undo_log WHERE undone=0"
        args: list[Any] = []
        if entry_id:
            q += " AND id=?"
            args.append(entry_id)
        if issue:
            q += " AND issue_key=?"
            args.append(issue)
        q += " ORDER BY id DESC LIMIT 1"
        return self.db.execute(q, args).fetchone()

    def mark_undone(self, eid: int) -> None:
        self.db.execute("UPDATE undo_log SET undone=1 WHERE id=?", (eid,))
        self.db.commit()


# --------------------------------------------------------------------------
# Context (lazy credential resolution + client)
# --------------------------------------------------------------------------


class Ctx:
    def __init__(self, want_write: bool, want_dangerous: bool):
        self.want_write = want_write
        self.want_dangerous = want_dangerous
        self._client: JiraClient | None = None

    @property
    def client(self) -> JiraClient:
        if self._client is None:
            url = _resolve(["JIRA_URL"], ["jira_url"], "https://c24-kfz.atlassian.net")
            user = _resolve(["JIRA_USERNAME"], ["jira_username"])
            token = _resolve(
                ["JIRA_API_TOKEN", "ATLASSIAN_API_TOKEN"],
                ["jira_api_token", "atlassian_c24_bitbucket_api_token"],
            )
            if not user or not token:
                missing = []
                if not user:
                    missing.append("JIRA_USERNAME (or file jira_username)")
                if not token:
                    missing.append(
                        "JIRA_API_TOKEN / ATLASSIAN_API_TOKEN "
                        "(or file jira_api_token / atlassian_c24_bitbucket_api_token)"
                    )
                raise SkillError(
                    "Missing Jira credentials:\n  - "
                    + "\n  - ".join(missing)
                    + f"\nSet them in the environment, or place sops-nix files in: {_secrets_dir()}",
                    2,
                )
            url = (url or "https://c24-kfz.atlassian.net").rstrip("/")
            if not (url.startswith("http://") or url.startswith("https://")):
                url = "https://" + url
            self._client = JiraClient(url, user, token)
        return self._client


# --------------------------------------------------------------------------
# Shared body / attachment helpers (comment / describe / comment-edit)
# --------------------------------------------------------------------------


def _resolve_body(
    file: str | None, text: str | None, have_text: bool, use_stdin: bool, implicit_pipe: bool, what: str
) -> str:
    if use_stdin and (have_text or file):
        raise SkillError("'-' (stdin) cannot be combined with inline text or --file.", 1)
    if have_text and file:
        raise SkillError("Provide either inline text or --file, not both.", 1)
    if file:
        p = Path(file)
        if not p.is_file() or not os.access(p, os.R_OK):
            raise SkillError(f"{what} --file not readable: {file}", 1)
        return p.read_text()
    if have_text:
        return text or ""
    if use_stdin:
        return _read_stdin()
    if implicit_pipe and not sys.stdin.isatty():
        return sys.stdin.read()
    return ""


def _do_attach_embed(client: JiraClient, key: str, attach: list[str], embed: list[str]) -> None:
    """Validate then upload --attach + --embed files BEFORE the body is written,
    so a failed upload never leaves a dead !name! / [^name] reference behind."""
    files = list(attach) + list(embed)
    if not files:
        return
    for f in files:
        _validate_upload_file(f)
    client.upload(key, files)
    log_success(f"{key}: uploaded {len(files)} attachment(s).")


def _append_embed(body: str, embed: list[str]) -> str:
    for f in embed:
        ref = wiki_ref_for(f)
        body = (body + "\n\n" + ref) if body else ref
    return body


def _find_attachment(client: JiraClient, key: str, ref: str) -> dict:
    data = client.get(f"/issue/{key}?fields=attachment")
    atts = (data.get("fields") or {}).get("attachment") or []
    match = None
    for a in atts:
        if str(a.get("id")) == str(ref) or a.get("filename") == ref:
            match = a  # last match wins (same filename may appear more than once)
    if not match:
        raise SkillError(f"No attachment '{ref}' on {key}.", 4)
    return match


def _resolve_account(ctx: Ctx, who: str) -> str:
    if who == "@me":
        return ctx.client.get("/myself")["accountId"]
    if ":" in who or re.match(r"^[0-9a-f]{24}$", who):
        return who
    acc, _ = UserDirectory(ctx.client).resolve_assignee(who)
    return acc


def _current_status(client: JiraClient, key: str) -> str:
    return client.get(f"/issue/{key}?fields=status")["fields"]["status"]["name"]


def _print_users(users: list[dict], fmt: str) -> None:
    if fmt == "tsv":
        out = "\n".join(
            f"{u.get('accountId')}\t{u.get('emailAddress') or '-'}\t{u.get('displayName')}\t{str(bool(u.get('active'))).lower()}"
            for u in users
        )
        print(out)
    else:
        print(
            json.dumps(
                [
                    {
                        "accountId": u.get("accountId"),
                        "emailAddress": u.get("emailAddress"),
                        "displayName": u.get("displayName"),
                        "active": bool(u.get("active")),
                    }
                    for u in users
                ],
                indent=2,
                ensure_ascii=False,
            )
        )


# --------------------------------------------------------------------------
# Read commands
# --------------------------------------------------------------------------


def _parse_format_key(args: list[str], cmd: str, *allowed: str) -> tuple[str, str | None]:
    fmt = allowed[0]
    key = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--format":
            if i + 1 >= len(args):
                raise SkillError(f"--format requires {'|'.join(allowed)}", 1)
            fmt = args[i + 1]
            i += 2
        elif a.startswith("--"):
            raise SkillError(f"Unknown {cmd} flag: '{a}'", 1)
        else:
            key = a
            i += 1
    return fmt, key


def cmd_whoami(ctx: Ctx, args: list[str]) -> None:
    fmt, extra = _parse_format_key(args, "whoami", "json", "tsv")
    if extra:
        raise SkillError(f"whoami takes no positional arguments (got '{extra}')", 1)
    validate_format(fmt, "json", "tsv")
    me = ctx.client.get("/myself")
    if fmt == "tsv":
        print(f"{me.get('accountId')}\t{me.get('emailAddress')}\t{me.get('displayName')}")
    else:
        print(
            json.dumps(
                {k: me.get(k) for k in ("accountId", "emailAddress", "displayName", "active")},
                indent=2,
                ensure_ascii=False,
            )
        )


def cmd_get(ctx: Ctx, args: list[str]) -> None:
    fmt, key = _parse_format_key(args, "get", "json", "tsv")
    key = require_key(key, "get")
    validate_format(fmt, "json", "tsv")
    d = ctx.client.get(f"/issue/{key}?fields=summary,status,assignee,issuetype,labels,updated")
    f = d["fields"]
    out = {
        "key": d.get("key"),
        "summary": f.get("summary"),
        "status": (f.get("status") or {}).get("name"),
        "type": (f.get("issuetype") or {}).get("name"),
        "assignee": (f.get("assignee") or {}).get("displayName"),
        "labels": f.get("labels") or [],
        "updated": f.get("updated"),
    }
    if fmt == "tsv":
        print(f"{out['key']}\t{out['status']}\t{out['type']}\t{out['assignee'] or '-'}\t{out['summary']}")
    else:
        print(json.dumps(out, indent=2, ensure_ascii=False))


def cmd_status(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    key = require_key(key, "status")
    print(_current_status(ctx.client, key))


def cmd_transitions(ctx: Ctx, args: list[str]) -> None:
    fmt, key = _parse_format_key(args, "transitions", "json", "tsv")
    key = require_key(key, "transitions")
    validate_format(fmt, "json", "tsv")
    tb = ctx.client.get(f"/issue/{key}/transitions")
    rows = [{"id": t["id"], "name": t["name"], "to": t["to"]["name"], "toId": t["to"]["id"]} for t in tb.get("transitions", [])]
    if fmt == "tsv":
        print("\n".join(f"{r['id']}\t{r['to']}\t{r['name']}" for r in rows))
    else:
        print(json.dumps(rows, indent=2, ensure_ascii=False))


def cmd_comments(ctx: Ctx, args: list[str]) -> None:
    fmt = "text"
    maxr = 50
    key = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--format":
            fmt = args[i + 1]
            i += 2
        elif a == "--max":
            maxr = int(args[i + 1])
            i += 2
        elif a.startswith("--"):
            raise SkillError(f"Unknown comments flag: '{a}'", 1)
        else:
            key = a
            i += 1
    key = require_key(key, "comments")
    validate_format(fmt, "text", "json")
    data = ctx.client.get(f"/issue/{key}/comment", params={"orderBy": "-created", "maxResults": maxr})
    comments = data.get("comments", [])
    if fmt == "json":
        out = json.dumps(
            [
                {
                    "id": c.get("id"),
                    "author": (c.get("author") or {}).get("displayName"),
                    "created": c.get("created"),
                    "updated": c.get("updated"),
                    "body": c.get("body"),
                }
                for c in comments
            ],
            indent=2,
            ensure_ascii=False,
        )
        buffer_output(out + "\n", f"comments-{key}", "json")
    else:
        parts = [
            f"── comment {c.get('id')} — {(c.get('author') or {}).get('displayName')} @ {c.get('created')} ──\n{c.get('body')}\n"
            for c in comments
        ]
        buffer_output(("\n".join(parts) + "\n") if parts else "", f"comments-{key}", "txt")
    total = data.get("total", len(comments))
    if isinstance(total, int) and total > len(comments):
        log_info(
            f"Showing newest {len(comments)} of {total} comments — raise --max before "
            "trusting a negative idempotency check."
        )


def cmd_user(ctx: Ctx, args: list[str]) -> None:
    fmt = "json"
    refresh = False
    query = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--format":
            fmt = args[i + 1]
            i += 2
        elif a == "--refresh":
            refresh = True
            i += 1
        elif a.startswith("--"):
            raise SkillError(f"Unknown user flag: '{a}'", 1)
        else:
            query = a
            i += 1
    if not query:
        raise SkillError("user requires a search query (email / name)", 1)
    validate_format(fmt, "json", "tsv")
    _print_users(UserDirectory(ctx.client).search(query, refresh=refresh), fmt)


def cmd_users(ctx: Ctx, args: list[str]) -> None:
    fmt = "json"
    refresh = False
    project = None
    issue = None
    query = ""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--format":
            fmt = args[i + 1]
            i += 2
        elif a == "--refresh":
            refresh = True
            i += 1
        elif a == "--project":
            project = args[i + 1]
            i += 2
        elif a == "--issue":
            issue = args[i + 1]
            i += 2
        elif a.startswith("--"):
            raise SkillError(f"Unknown users flag: '{a}'", 1)
        else:
            query = a
            i += 1
    if not project and not issue:
        raise SkillError("users requires --project KEY or --issue KEY (assignable search)", 1)
    validate_format(fmt, "json", "tsv")
    _print_users(
        UserDirectory(ctx.client).search_assignable(query, project=project, issue=issue, refresh=refresh),
        fmt,
    )


def cmd_search(ctx: Ctx, args: list[str]) -> None:
    fmt = "tsv"
    maxr = 50
    jql_parts = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--format":
            fmt = args[i + 1]
            i += 2
        elif a == "--max":
            maxr = int(args[i + 1])
            i += 2
        elif a.startswith("--"):
            raise SkillError(f"Unknown search flag: '{a}'", 1)
        else:
            jql_parts.append(a)
            i += 1
    jql = " ".join(jql_parts)
    if not jql:
        raise SkillError("search requires a JQL query", 1)
    validate_format(fmt, "tsv", "json")
    issues: list[dict] = []
    token = None
    while len(issues) < maxr:
        params: dict[str, Any] = {
            "jql": jql,
            "maxResults": min(50, maxr - len(issues)),
            "fields": "summary,status,issuetype,assignee,updated",
        }
        if token:
            params["nextPageToken"] = token
        # Atlassian removed the legacy /search (HTTP 410). /search/jql is token-paginated
        # (nextPageToken + isLast) and returns no total.
        data = ctx.client.get("/search/jql", params=params)
        batch = data.get("issues", [])
        issues.extend(batch)
        token = data.get("nextPageToken")
        if data.get("isLast") or not token or not batch:
            break
    issues = issues[:maxr]
    if fmt == "json":
        out = json.dumps(
            [
                {
                    "key": it.get("key"),
                    "status": (it["fields"].get("status") or {}).get("name"),
                    "type": (it["fields"].get("issuetype") or {}).get("name"),
                    "assignee": (it["fields"].get("assignee") or {}).get("displayName"),
                    "summary": it["fields"].get("summary"),
                }
                for it in issues
            ],
            indent=2,
            ensure_ascii=False,
        )
        buffer_output(out + "\n", "search", "json")
    else:
        lines = [
            f"{it.get('key')}\t{(it['fields'].get('status') or {}).get('name')}\t{(it['fields'].get('assignee') or {}).get('displayName') or '-'}\t{it['fields'].get('summary')}"
            for it in issues
        ]
        buffer_output(("\n".join(lines) + "\n") if lines else "", "search", "txt")


def cmd_links(ctx: Ctx, args: list[str]) -> None:
    fmt, key = _parse_format_key(args, "links", "tsv", "json")
    key = require_key(key, "links")
    validate_format(fmt, "tsv", "json")
    data = ctx.client.get(f"/issue/{key}?fields=issuelinks")
    rows = []
    for l in (data["fields"].get("issuelinks") or []):
        t = l.get("type", {})
        if l.get("outwardIssue"):
            other, rel = l["outwardIssue"], t.get("outward")
        else:
            other, rel = l.get("inwardIssue", {}), t.get("inward")
        of = other.get("fields", {}) or {}
        rows.append(
            {
                "relation": rel,
                "key": other.get("key"),
                "status": (of.get("status") or {}).get("name"),
                "summary": of.get("summary"),
            }
        )
    if fmt == "json":
        buffer_output(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", f"links-{key}", "json")
    else:
        lines = [f"{r['relation']}\t{r['key']}\t{r['status'] or '-'}\t{r['summary'] or ''}" for r in rows]
        buffer_output(("\n".join(lines) + "\n") if lines else "", f"links-{key}", "txt")


def cmd_attachments(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    key = require_key(key, "attachments")
    data = ctx.client.get(f"/issue/{key}?fields=attachment")
    for a in (data["fields"].get("attachment") or []):
        print(f"{a.get('id')}\t{a.get('filename')}\t{a.get('size')}\t{a.get('mimeType')}\t{a.get('content')}")


def cmd_download(ctx: Ctx, args: list[str]) -> None:
    key = None
    ref = None
    out = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--output":
            out = args[i + 1]
            i += 2
        elif a.startswith("--"):
            raise SkillError(f"Unknown download flag: '{a}'", 1)
        else:
            if key is None:
                key = a
            elif ref is None:
                ref = a
            i += 1
    key = require_key(key, "download")
    if not ref:
        raise SkillError("download requires <KEY> <attachment-id|filename>", 1)
    att = _find_attachment(ctx.client, key, ref)
    data = ctx.client.get(att["content"], raw=True)
    dest = Path(out) if out else Path(att.get("filename", "attachment"))
    dest.write_bytes(data)
    print(f"{dest}\t{len(data)}")
    log_success(f"{key}: downloaded attachment {att['id']} → {dest} ({len(data)} bytes).")


# --------------------------------------------------------------------------
# Write commands
# --------------------------------------------------------------------------


def _transition_core(client: JiraClient, key: str, target: str, journal: bool) -> None:
    tb = client.get(f"/issue/{key}/transitions")
    trans = tb.get("transitions", [])
    current = _current_status(client, key)
    tid = None
    goal = None
    if target.isdigit():
        for t in trans:
            if str(t["id"]) == target:
                tid, goal = str(t["id"]), t["to"]["name"]
                break
    else:
        for t in trans:
            if t["to"]["name"].lower() == target.lower():
                tid, goal = str(t["id"]), t["to"]["name"]
                break
    effective_goal = goal or target
    if current.lower() == effective_goal.lower():
        log_success(f"{key} is already in status '{current}' — nothing to do.")
        return
    if not tid:
        valid = ", ".join(sorted({t["to"]["name"] for t in trans}))
        detail = (
            f"Transition id '{target}' is not available from status '{current}'."
            if target.isdigit()
            else f"No transition to status '{target}' from '{current}'."
        )
        raise SkillError(f"{detail}\nValid target statuses from here: {valid}", 1)
    if journal:
        UndoJournal().record(key, "transition", current, {"status": current})
    client.post(f"/issue/{key}/transitions", {"transition": {"id": tid}})
    now = _current_status(client, key)
    log_success(f"{key}: '{current}' → '{now}' (transition {tid}).")
    if goal and now.lower() != goal.lower():
        log_info(
            f"Resulting status '{now}' differs from requested '{goal}' "
            "(a workflow post-function may have moved it)."
        )


def cmd_transition(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    target = args[1] if len(args) > 1 else None
    key = require_key(key, "transition")
    if not target:
        raise SkillError("transition requires a target status name or transition id", 1)
    _transition_core(ctx.client, key, target, journal=True)


def cmd_comment(ctx: Ctx, args: list[str]) -> None:
    key = None
    file = None
    text = None
    use_stdin = False
    have_text = False
    attach: list[str] = []
    embed: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--file":
            file = args[i + 1]
            i += 2
        elif a == "--attach":
            attach.append(args[i + 1])
            i += 2
        elif a == "--embed":
            embed.append(args[i + 1])
            i += 2
        elif a == "-":
            use_stdin = True
            i += 1
        elif a.startswith("--"):
            raise SkillError(f"Unknown comment flag: '{a}'", 1)
        else:
            if key is None:
                key = a
            else:
                text, have_text = a, True
            i += 1
    key = require_key(key, "comment")
    body = _resolve_body(file, text, have_text, use_stdin, implicit_pipe=True, what="comment")
    if not body and not embed:
        raise SkillError(
            "Refusing to post an empty comment. Provide text / --file / stdin, or at least "
            "one --embed (use 'attach' to upload a file without commenting).",
            1,
        )
    client = ctx.client
    _do_attach_embed(client, key, attach, embed)
    body = _append_embed(body, embed)
    resp = client.post(f"/issue/{key}/comment", {"body": body})
    cid = resp.get("id")
    log_success(f"{key}: comment {cid} posted.")
    print(cid)


def cmd_comment_edit(ctx: Ctx, args: list[str]) -> None:
    key = None
    cid = None
    file = None
    text = None
    use_stdin = False
    have_text = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--file":
            file = args[i + 1]
            i += 2
        elif a == "-":
            use_stdin = True
            i += 1
        elif a.startswith("--"):
            raise SkillError(f"Unknown comment-edit flag: '{a}'", 1)
        else:
            if key is None:
                key = a
            elif cid is None:
                cid = a
            else:
                text, have_text = a, True
            i += 1
    key = require_key(key, "comment-edit")
    if not cid or not cid.isdigit():
        raise SkillError("comment-edit requires a numeric comment id", 1)
    body = _resolve_body(file, text, have_text, use_stdin, implicit_pipe=False, what="comment-edit")
    if not body:
        raise SkillError("comment-edit requires a new body (text / --file / stdin).", 1)
    client = ctx.client
    prior = client.get(f"/issue/{key}/comment/{cid}").get("body", "")
    UndoJournal().record(key, "comment-edit", cid, {"body": prior})
    client.put(f"/issue/{key}/comment/{cid}", {"body": body})
    log_success(f"{key}: comment {cid} updated (undo available).")


def cmd_assign(ctx: Ctx, args: list[str]) -> None:
    key = None
    target = None
    for a in args:
        if a == "--unassign":
            target = "--unassign"
        elif a.startswith("--"):
            raise SkillError(f"Unknown assign flag: '{a}'", 1)
        elif key is None:
            key = a
        elif target is None:
            target = a
    key = require_key(key, "assign")
    if not target:
        raise SkillError("assign requires <email | accountId | @me | alias | --unassign>", 1)
    client = ctx.client
    prior = (client.get(f"/issue/{key}?fields=assignee")["fields"].get("assignee")) or {}
    UndoJournal().record(key, "assign", None, {"accountId": prior.get("accountId")})
    if target == "--unassign":
        client.put(f"/issue/{key}/assignee", {"accountId": None})
        log_success(f"{key}: assignee cleared (undo available).")
        return
    if target in ASSIGNEE_ALIAS:
        acc, who = ASSIGNEE_ALIAS[target], f"alias '{target}'"
    elif target == "@me":
        me = client.get("/myself")
        acc, who = me["accountId"], me.get("displayName") or "@me"
    elif "@" in target:
        acc, who = UserDirectory(client).resolve_assignee(target)
    else:
        acc, who = target, "accountId"
    client.put(f"/issue/{key}/assignee", {"accountId": acc})
    log_success(f"{key}: assigned to {who or acc} ({acc}) (undo available).")


def cmd_create(ctx: Ctx, args: list[str]) -> None:
    typ = "Task"
    summary = None
    project = os.environ.get("JIRA_PROJECT_KEY", "VUKFZIF")
    desc = None
    desc_file = None
    desc_stdin = False
    labels: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--type":
            typ = args[i + 1]
            i += 2
        elif a == "--summary":
            summary = args[i + 1]
            i += 2
        elif a == "--project":
            project = args[i + 1]
            i += 2
        elif a == "--label":
            labels.append(args[i + 1])
            i += 2
        elif a == "--description":
            desc = args[i + 1]
            i += 2
        elif a == "--description-file":
            desc_file = args[i + 1]
            i += 2
        elif a == "-":
            desc_stdin = True
            i += 1
        else:
            raise SkillError(f"Unknown/unexpected create argument: '{a}'", 1)
    if not summary:
        raise SkillError("create requires --summary", 1)
    if desc_file:
        p = Path(desc_file)
        if not p.is_file() or not os.access(p, os.R_OK):
            raise SkillError(f"--description-file not readable: {desc_file}", 1)
        desc = p.read_text()
    elif desc_stdin:
        desc = _read_stdin()
    fields: dict[str, Any] = {"project": {"key": project}, "issuetype": {"name": typ}, "summary": summary}
    if desc:
        fields["description"] = desc
    if labels:
        fields["labels"] = labels
    resp = ctx.client.post("/issue", {"fields": fields})
    key = resp.get("key")
    log_success(f"Created {key} ({typ}) in {project}.")
    print(key)


def cmd_attach(ctx: Ctx, args: list[str]) -> None:
    key = None
    files: list[str] = []
    for a in args:
        if a.startswith("--"):
            raise SkillError(f"Unknown attach flag: '{a}'", 1)
        if key is None:
            key = a
        else:
            files.append(a)
    key = require_key(key, "attach")
    if not files:
        raise SkillError("attach requires at least one file path", 1)
    for f in files:
        _validate_upload_file(f)
    resp = ctx.client.upload(key, files)
    for a in resp:
        print(f"{a.get('id')}\t{a.get('filename')}\t{a.get('size')}")
    log_success(f"{key}: uploaded {len(resp)} attachment(s).")


def cmd_describe(ctx: Ctx, args: list[str]) -> None:
    key = None
    file = None
    text = None
    use_stdin = False
    have_text = False
    attach: list[str] = []
    embed: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--file":
            file = args[i + 1]
            i += 2
        elif a == "--attach":
            attach.append(args[i + 1])
            i += 2
        elif a == "--embed":
            embed.append(args[i + 1])
            i += 2
        elif a == "-":
            use_stdin = True
            i += 1
        elif a.startswith("--"):
            raise SkillError(f"Unknown describe flag: '{a}'", 1)
        else:
            if key is None:
                key = a
            else:
                text, have_text = a, True
            i += 1
    key = require_key(key, "describe")
    body = _resolve_body(file, text, have_text, use_stdin, implicit_pipe=False, what="describe")
    if not body and not embed:
        raise SkillError(
            "Refusing to set an empty description. Provide text / --file / stdin, or at least "
            "one --embed (use 'attach' to upload a file without changing the description).",
            1,
        )
    client = ctx.client
    # Snapshot the prior description BEFORE anything mutates, so undo can restore it.
    prior = client.get(f"/issue/{key}?fields=description")["fields"].get("description")
    UndoJournal().record(key, "describe", None, {"description": prior})
    _do_attach_embed(client, key, attach, embed)
    body = _append_embed(body, embed)
    client.put(f"/issue/{key}", {"fields": {"description": body}})
    log_success(f"{key}: description updated (undo available).")


def cmd_label(ctx: Ctx, args: list[str]) -> None:
    key = None
    add: list[str] = []
    rem: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--add":
            add.append(args[i + 1])
            i += 2
        elif a == "--remove":
            rem.append(args[i + 1])
            i += 2
        elif a.startswith("--"):
            raise SkillError(f"Unknown label flag: '{a}'", 1)
        else:
            if key is not None:
                raise SkillError(f"Unexpected label argument: '{a}'", 1)
            key = a
            i += 1
    key = require_key(key, "label")
    if not add and not rem:
        raise SkillError("label requires at least one --add or --remove", 1)
    client = ctx.client
    prior = client.get(f"/issue/{key}?fields=labels")["fields"].get("labels") or []
    UndoJournal().record(key, "label", None, {"labels": prior})
    update = {"labels": [{"add": l} for l in add] + [{"remove": l} for l in rem]}
    client.put(f"/issue/{key}", {"update": update})
    log_success(f"{key}: labels updated (+{len(add)}/-{len(rem)}) (undo available).")


def cmd_link(ctx: Ctx, args: list[str]) -> None:
    pos = [a for a in args if not a.startswith("--")]
    if [a for a in args if a.startswith("--")]:
        raise SkillError(f"Unknown link flag: '{[a for a in args if a.startswith('--')][0]}'", 1)
    if len(pos) != 3:
        raise SkillError('link requires <KEY> <type> <other-KEY> (e.g. link A "Blocks" B)', 1)
    key, ltype, other = pos
    key = require_key(key, "link")
    other = require_key(other, "link")
    ctx.client.post(
        "/issueLink",
        {"type": {"name": ltype}, "outwardIssue": {"key": key}, "inwardIssue": {"key": other}},
    )
    log_success(f"Linked {key} —{ltype}→ {other}.")


def cmd_watch(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    who = args[1] if len(args) > 1 else "@me"
    key = require_key(key, "watch")
    acc = _resolve_account(ctx, who)
    # Body is the accountId as a bare JSON string, per the watchers API.
    ctx.client.post(f"/issue/{key}/watchers", acc)
    log_success(f"{key}: added watcher {acc}.")


def cmd_unwatch(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    who = args[1] if len(args) > 1 else "@me"
    key = require_key(key, "unwatch")
    acc = _resolve_account(ctx, who)
    ctx.client.delete(f"/issue/{key}/watchers", params={"accountId": acc})
    log_success(f"{key}: removed watcher {acc}.")


# --------------------------------------------------------------------------
# Dangerous commands (irreversible deletes — snapshot for undo first)
# --------------------------------------------------------------------------


def cmd_comment_rm(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    cid = args[1] if len(args) > 1 else None
    key = require_key(key, "comment-rm")
    if not cid or not cid.isdigit():
        raise SkillError("comment-rm requires a numeric comment id", 1)
    client = ctx.client
    c = client.get(f"/issue/{key}/comment/{cid}")
    UndoJournal().record(
        key,
        "comment-rm",
        cid,
        {"body": c.get("body", ""), "author": (c.get("author") or {}).get("displayName"), "created": c.get("created")},
    )
    client.delete(f"/issue/{key}/comment/{cid}")
    log_success(f"{key}: comment {cid} deleted (undo available — restores as a new comment).")


def cmd_attach_rm(ctx: Ctx, args: list[str]) -> None:
    key = args[0] if args else None
    ref = args[1] if len(args) > 1 else None
    key = require_key(key, "attach-rm")
    if not ref:
        raise SkillError("attach-rm requires <KEY> <attachment-id>", 1)
    client = ctx.client
    att = _find_attachment(client, key, ref)
    # Download the bytes BEFORE deleting so undo can re-upload them.
    data = client.get(att["content"], raw=True)
    j = UndoJournal()
    blob = j.save_blob(att.get("filename", "attachment"), data)
    j.record(key, "attach-rm", str(att["id"]), {"filename": att.get("filename"), "size": att.get("size")}, blob)
    client.delete(f"/attachment/{att['id']}")
    log_success(f"{key}: attachment {att['id']} ('{att.get('filename')}') deleted (undo available).")


# --------------------------------------------------------------------------
# Undo (read: --list; write: apply)
# --------------------------------------------------------------------------


def _apply_undo(client: JiraClient, row: tuple) -> str:
    _, _, key, op, ref, prior_json, blob = row
    prior = json.loads(prior_json)
    if op == "describe":
        client.put(f"/issue/{key}", {"fields": {"description": prior.get("description")}})
        return f"{key}: description restored."
    if op == "comment-edit":
        client.put(f"/issue/{key}/comment/{ref}", {"body": prior.get("body")})
        return f"{key}: comment {ref} body restored."
    if op == "assign":
        acc = prior.get("accountId")
        client.put(f"/issue/{key}/assignee", {"accountId": acc})
        return f"{key}: assignee restored to {acc or '(unassigned)'}."
    if op == "transition":
        _transition_core(client, key, prior.get("status"), journal=False)
        return f"{key}: status restored to '{prior.get('status')}'."
    if op == "label":
        client.put(f"/issue/{key}", {"fields": {"labels": prior.get("labels", [])}})
        return f"{key}: labels restored."
    if op == "comment-rm":
        resp = client.post(f"/issue/{key}/comment", {"body": prior.get("body", "")})
        return (
            f"{key}: deleted comment re-created as {resp.get('id')} "
            f"(original id {ref}; author/timestamps cannot be restored)."
        )
    if op == "attach-rm":
        if not blob or not Path(blob).exists():
            raise SkillError(f"backup bytes missing for attachment {ref}; cannot restore.", 1)
        resp = client.upload_bytes(key, prior.get("filename", f"restored-{ref}"), Path(blob).read_bytes())
        nid = resp[0].get("id") if resp else "?"
        return f"{key}: attachment '{prior.get('filename')}' re-uploaded as {nid} (original id {ref})."
    raise SkillError(f"Don't know how to undo op '{op}'.", 1)


def cmd_undo(ctx: Ctx, args: list[str]) -> None:
    do_list = False
    issue = None
    entry_id = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--list":
            do_list = True
            i += 1
        elif a == "--issue":
            issue = args[i + 1]
            i += 2
        elif a == "--id":
            entry_id = int(args[i + 1])
            i += 2
        else:
            raise SkillError(f"Unknown undo flag: '{a}'", 1)
    j = UndoJournal()
    if do_list:
        rows = j.list(issue)
        if not rows:
            print("(no undo entries)")
            return
        for (eid, ts, key, op, ref, undone) in rows:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))
            print(f"{eid}\t{when}\t{key}\t{op}\t{ref or '-'}\t{'undone' if undone else 'active'}")
        return
    # Applying an undo mutates the ticket → it is a WRITE and needs --write.
    if not ctx.want_write:
        raise SkillError("Refusing to apply undo (a write) without --write.", 1)
    row = j.latest(issue, entry_id)
    if not row:
        raise SkillError("No undoable entry found (try 'undo --list').", 4)
    msg = _apply_undo(ctx.client, row)
    j.mark_undone(row[0])
    log_success(msg)


# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

COMMANDS: dict[str, tuple[Any, str]] = {
    # read
    "whoami": (cmd_whoami, READ),
    "get": (cmd_get, READ),
    "status": (cmd_status, READ),
    "transitions": (cmd_transitions, READ),
    "comments": (cmd_comments, READ),
    "user": (cmd_user, READ),
    "users": (cmd_users, READ),
    "search": (cmd_search, READ),
    "links": (cmd_links, READ),
    "attachments": (cmd_attachments, READ),
    "download": (cmd_download, READ),
    "undo": (cmd_undo, READ),  # apply path enforces --write internally
    # write
    "transition": (cmd_transition, WRITE),
    "comment": (cmd_comment, WRITE),
    "comment-edit": (cmd_comment_edit, WRITE),
    "assign": (cmd_assign, WRITE),
    "create": (cmd_create, WRITE),
    "attach": (cmd_attach, WRITE),
    "describe": (cmd_describe, WRITE),
    "label": (cmd_label, WRITE),
    "link": (cmd_link, WRITE),
    "watch": (cmd_watch, WRITE),
    "unwatch": (cmd_unwatch, WRITE),
    # dangerous
    "comment-rm": (cmd_comment_rm, DANGEROUS),
    "attach-rm": (cmd_attach_rm, DANGEROUS),
}

USAGE = """\
JIRA Cloud ticket control via REST API v2 — read / write / dangerous tiers.

USAGE: jira.sh [--write] [--dangerous] <command> [args...]

GATING (global flags, accepted anywhere; '--' marks the rest literal):
  read commands need no flag. write commands require --write. dangerous
  (destructive) commands require --dangerous, which implies --write.

READ:
  whoami            [--format json|tsv]        Account behind the token (verify auth).
  get      <KEY>    [--format json|tsv]        Summary, status, type, assignee, labels.
  status   <KEY>                               Print the current status name only.
  transitions <KEY> [--format json|tsv]        Available transitions (id, target, name).
  comments <KEY>    [--format text|json] [--max n]   Recent comments (newest first).
  user     <query>  [--format json|tsv] [--refresh]  Resolve accountId (cache-backed).
  users    <query>  --project KEY | --issue KEY [--format json|tsv] [--refresh]
                                               Assignable-user search (paged + cached).
  search   <JQL>    [--format tsv|json] [--max n]    JQL issue search.
  links    <KEY>    [--format tsv|json]        List issue links.
  attachments <KEY>                            List attachments (id/name/size/mime/url).
  download <KEY> <att-id|filename> [--output P]   Download an attachment.
  undo     --list [--issue KEY]                List undoable journal entries.

WRITE (need --write):
  transition <KEY> <status-name|id>            Move to ANY status (name match, idempotent).
  comment    <KEY> [text | --file P | -] [--attach F]... [--embed F]...   Add a comment.
  comment-edit <KEY> <id> [text | --file P | -]   Replace a comment body.
  assign     <KEY> <email|accountId|@me|alias|--unassign>   Set/clear the assignee.
  create     --summary S [--type T] [--project K] [--label L]... [--description X | -]
  attach     <KEY> <file>...                   Upload attachment(s).
  describe   <KEY> [text | --file P | -] [--attach F]... [--embed F]...   Set/replace description.
  label      <KEY> [--add L]... [--remove L]...   Add/remove labels.
  link       <KEY> <type> <other-KEY>          Link two issues (e.g. "Blocks").
  watch / unwatch <KEY> [accountId|@me]        Add/remove a watcher.
  undo       [--issue KEY] [--id N]            Apply the inverse of the last (or chosen) entry.

DANGEROUS (need --dangerous):
  comment-rm <KEY> <comment-id>                Delete a comment (snapshot kept for undo).
  attach-rm  <KEY> <attachment-id>             Delete an attachment (bytes kept for undo).

CREDENTIALS (env wins; else $SOPS_SECRETS_DIR files):
  JIRA_URL | jira_url ;  JIRA_USERNAME | jira_username
  JIRA_API_TOKEN <- ATLASSIAN_API_TOKEN | jira_api_token -> atlassian_c24_bitbucket_api_token

ENVIRONMENT:
  JIRA_PROJECT_KEY        default project for create   (default: VUKFZIF)
  JIRA_OUTPUT_MAX_BYTES   spill output > N bytes to a tempfile (default: 32768)
  JIRA_UPLOAD_MAX_TIME    upload timeout in seconds     (default: 300)
  JIRA_USER_CACHE_TTL     user-cache TTL in seconds     (default: 86400)
  JIRA_USER_SEARCH_CAP    max users fetched per search  (default: 1000)
  JIRA_CACHE_DIR          user cache dir  (default: $XDG_CACHE_HOME/jira-skill)
  JIRA_STATE_DIR          undo journal dir (default: $XDG_STATE_HOME/jira-skill)

EXIT CODES: 0 ok, 1 bad args / gating refusal, 2 missing prereq/creds,
            3 API/auth/network, 4 not found, 124 timeout (killed by gtimeout).
"""


def main() -> None:
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        sys.exit(0)

    want_write = False
    want_dangerous = False
    rest: list[str] = []
    literal = False
    for tok in argv:
        if literal:
            rest.append(tok)
            continue
        if tok == "--":
            literal = True
            continue
        if tok == "--write":
            want_write = True
            continue
        if tok == "--dangerous":
            want_dangerous = True
            continue
        rest.append(tok)
    if want_dangerous:
        want_write = True

    if not rest:
        log_error("Missing command")
        print(USAGE, file=sys.stderr)
        sys.exit(1)
    command, cargs = rest[0], rest[1:]
    if command not in COMMANDS:
        log_error(f"Unknown command: '{command}'")
        print(USAGE, file=sys.stderr)
        sys.exit(1)

    func, tier = COMMANDS[command]
    if tier == DANGEROUS and not want_dangerous:
        log_error(f"Refusing to run '{command}': a DANGEROUS (destructive) command requires --dangerous.")
        sys.exit(1)
    if tier == WRITE and not want_write:
        log_error(f"Refusing to run '{command}': a WRITE command requires --write (or --dangerous).")
        sys.exit(1)

    ctx = Ctx(want_write, want_dangerous)
    try:
        func(ctx, cargs)
    except SkillError as e:
        log_error(str(e))
        sys.exit(e.code)
    except httpx.HTTPError as e:
        log_error(f"HTTP error: {e}")
        sys.exit(3)
    except (IndexError, ValueError) as e:
        log_error(f"Bad arguments for '{command}': {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
