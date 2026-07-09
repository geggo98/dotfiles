#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "httpx>=0.27",
#   "pyyaml>=6.0",
# ]
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""Set Bitbucket Cloud pull-request reviewers via the REST API.

Why this exists: `bb pr create --reviewer` / `bb pr update --add-reviewer`
resolve reviewer values by enumerating the *entire* workspace member list on
the client side. On very large workspaces (e.g. `check24`, thousands of
members) that pagination never finishes — it hangs and gets HTTP 429 rate
limited — regardless of whether the reviewer is given as a name or a UUID.

The REST API has no such problem: it accepts reviewers by `account_id` (or
`uuid`) and validates them server-side without any enumeration. This script
does GET → merge → PUT against a single pull request, so the `bitbucket-pr`
skill can set reviewers even on workspaces where `bb`'s own flags hang.

Reviewers MUST be given as an Atlassian `account_id` (e.g.
`557058:0c8e...`) or a UUID (`{...}`). Plain display names/nicknames cannot
be resolved without the very enumeration we are avoiding, so they are
rejected with a helpful error.

Credentials reuse what `bb` already stores: either the env vars
BITBUCKET_USER / BITBUCKET_APP_PASSWORD, or the `user` / `password` of the
active profile in bb's `config-cli.yml`.

Exit codes match the rest of the skill:
  0 success | 1 bad args | 2 missing prereq/credentials
  3 API/auth/network failure | 4 pull request not found
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import httpx
import yaml

API_ROOT = "https://api.bitbucket.org/2.0"

# Fields we read and must re-send on PUT: Bitbucket's PUT drops any omitted
# field, so we preserve title/description/destination/close_source_branch and
# replace only the reviewers array.
_PR_FIELDS = (
    "title,description,close_source_branch,"
    "destination.branch.name,"
    "reviewers.uuid,reviewers.account_id,reviewers.display_name,"
    "author.uuid,author.account_id,author.display_name"
)


class SkillError(Exception):
    """Carries a process exit code alongside the message."""

    def __init__(self, message: str, code: int):
        super().__init__(message)
        self.code = code


def log(msg: str) -> None:
    print(f"Info: {msg}", file=sys.stderr)


# --------------------------------------------------------------------------
# Credentials
# --------------------------------------------------------------------------


def _config_paths() -> list[Path]:
    env = os.environ.get("BITBUCKET_CONFIG")
    paths = [Path(env)] if env else []
    home = Path.home()
    paths += [
        home / "Library/Application Support/bitbucket/config-cli.yml",
        home / ".config/bitbucket/config-cli.yml",
    ]
    return paths


def _pick_profile(profiles: list[dict], wanted: str | None) -> dict:
    if not profiles:
        raise SkillError("No profiles found in bb config-cli.yml", 2)
    if wanted:
        for p in profiles:
            if str(p.get("name", "")) == wanted:
                return p
        raise SkillError(f"Profile '{wanted}' not found in bb config-cli.yml", 2)
    for p in profiles:
        if p.get("default") is True:
            return p
    return profiles[0]


def load_credentials() -> tuple[str, str]:
    """(user, app_password) from env, else from bb's config-cli.yml."""
    user = os.environ.get("BITBUCKET_USER")
    pw = os.environ.get("BITBUCKET_APP_PASSWORD")
    if user and pw:
        return user, pw

    for path in _config_paths():
        if not path.is_file():
            continue
        try:
            data = yaml.safe_load(path.read_text()) or {}
        except yaml.YAMLError as exc:
            raise SkillError(f"Could not parse {path}: {exc}", 2)
        profiles = data.get("profiles") or []
        profile = _pick_profile(profiles, os.environ.get("BB_PROFILE"))
        cfg_user = profile.get("user")
        cfg_pw = profile.get("password")
        if cfg_user and cfg_pw:
            return str(cfg_user), str(cfg_pw)
        raise SkillError(
            f"Profile '{profile.get('name')}' in {path} has no user/password", 2
        )

    raise SkillError(
        "No Bitbucket credentials. Set BITBUCKET_USER + BITBUCKET_APP_PASSWORD, "
        "or configure a bb profile (bb profile create).",
        2,
    )


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


class Bitbucket:
    def __init__(self, user: str, password: str, timeout: float = 30.0):
        self._client = httpx.Client(
            auth=(user, password),
            base_url=API_ROOT,
            headers={"Accept": "application/json"},
            timeout=timeout,
        )

    def request(self, method: str, path: str, **kw: Any) -> httpx.Response:
        # Small retry for transient 429/5xx — these are single-object calls,
        # not the member enumeration, so a couple of tries is plenty.
        delay = 2.0
        resp = self._client.request(method, path, **kw)
        for _ in range(3):
            if resp.status_code not in (429, 502, 503, 504):
                break
            retry_after = resp.headers.get("Retry-After")
            wait = float(retry_after) if retry_after and retry_after.isdigit() else delay
            log(f"HTTP {resp.status_code} on {method} {path}; retrying in {wait:g}s")
            time.sleep(wait)
            delay *= 2
            resp = self._client.request(method, path, **kw)
        return resp

    def get_json(self, path: str, **kw: Any) -> Any:
        resp = self.request("GET", path, **kw)
        _raise_for_status(resp)
        return resp.json()

    def put_json(self, path: str, body: Any) -> Any:
        resp = self.request("PUT", path, json=body)
        _raise_for_status(resp)
        return resp.json()


def _raise_for_status(resp: httpx.Response) -> None:
    if resp.is_success:
        return
    try:
        detail = resp.json().get("error", {}).get("message", resp.text)
    except Exception:
        detail = resp.text
    if resp.status_code == 404:
        raise SkillError(f"Not found (HTTP 404): {detail}", 4)
    if resp.status_code in (401, 403):
        raise SkillError(
            f"Bitbucket auth failed (HTTP {resp.status_code}): {detail}. "
            "Check the bb profile's user/app-password.",
            3,
        )
    raise SkillError(f"Bitbucket API error (HTTP {resp.status_code}): {detail}", 3)


# --------------------------------------------------------------------------
# Reviewer identity
# --------------------------------------------------------------------------


def classify_reviewer(token: str) -> tuple[str, str]:
    """Map a reviewer token to a payload key ('account_id' | 'uuid', value).

    account_id looks like '557058:0c8e...'; uuid looks like '{...}' or a bare
    36-char hyphenated id. Plain names cannot be resolved without enumerating
    the workspace (the very hang we avoid), so they are rejected.
    """
    tok = token.strip()
    if not tok:
        raise SkillError("Empty reviewer value", 1)
    _hex = "0123456789abcdefABCDEF"
    # New-style account_id: '<realm>:<uuid>' (contains a colon).
    if ":" in tok:
        return "account_id", tok
    # Legacy account_id: 24 hex chars, no colon, no braces (pre-GDPR ids).
    if len(tok) == 24 and all(c in _hex for c in tok):
        return "account_id", tok
    bare = tok.strip("{}")
    hexparts = bare.split("-")
    is_uuid = (
        len(bare) == 36
        and len(hexparts) == 5
        and all(c in "0123456789abcdefABCDEF" for c in bare.replace("-", ""))
    )
    if is_uuid:
        return "uuid", "{" + bare + "}"
    raise SkillError(
        f"Reviewer '{token}' is not an account_id or uuid. Names cannot be "
        "resolved on large workspaces (that is the hang this bypasses). "
        "Pass an Atlassian account_id (e.g. 557058:...) or a uuid ({...}). "
        "Find them with: bb pr get <id> (reviewers/participants), or bb user me.",
        1,
    )


def _canon(reviewer: dict) -> str:
    """Canonical identity for set comparison (account_id preferred)."""
    if reviewer.get("account_id"):
        return "aid:" + str(reviewer["account_id"])
    if reviewer.get("uuid"):
        return "uid:" + str(reviewer["uuid"])
    return "?:" + json.dumps(reviewer, sort_keys=True)


def _matches(reviewer: dict, kind: str, value: str) -> bool:
    """True if a token (account_id OR uuid) identifies this reviewer.

    Reviewers read back from GET carry BOTH ids, so a token in either form
    matches the same person — this is what lets add/remove work regardless of
    which id form the caller used, without duplicating an existing reviewer.
    """
    if kind == "account_id":
        return str(reviewer.get("account_id") or "") == value
    return str(reviewer.get("uuid") or "") == value


# --------------------------------------------------------------------------
# set command
# --------------------------------------------------------------------------


def cmd_set(args: argparse.Namespace) -> int:
    ws, repo = split_repo(args.repo)
    adds = [classify_reviewer(t) for t in args.add]
    removes = [classify_reviewer(t) for t in args.remove]
    if not adds and not removes:
        raise SkillError("set requires at least one --add or --remove", 1)

    creds = load_credentials()
    bb = Bitbucket(*creds)
    base = f"/repositories/{ws}/{repo}/pullrequests/{args.pr}"
    pr = bb.get_json(base, params={"fields": _PR_FIELDS})

    current: list[dict] = list(pr.get("reviewers") or [])
    author = pr.get("author") or {}

    def is_author(kind: str, value: str) -> bool:
        if not value:
            return False
        field = "account_id" if kind == "account_id" else "uuid"
        return value == str(author.get(field) or "")

    def author_reviewer(r: dict) -> bool:
        return is_author("account_id", str(r.get("account_id") or "")) or \
            is_author("uuid", str(r.get("uuid") or ""))

    # Start from the current reviewers (default reviewers included), but never
    # carry the PR author — Bitbucket rejects the author as a reviewer, so
    # re-sending them in the PUT would 400 the whole update.
    desired: list[dict] = [r for r in current if not author_reviewer(r)]

    # Removes: drop any reviewer the token matches by EITHER id form.
    for kind, value in removes:
        desired = [r for r in desired if not _matches(r, kind, value)]

    # Adds: append only when the person is not already present (matched in
    # either id form) and is not the author.
    for kind, value in adds:
        if is_author(kind, value):
            log(f"Skipping {value}: the PR author cannot be a reviewer")
            continue
        if any(_matches(r, kind, value) for r in desired):
            continue
        desired.append({kind: value})

    reviewers_payload = [
        {"account_id": r["account_id"]} if r.get("account_id") else {"uuid": r["uuid"]}
        for r in desired
    ]

    body: dict[str, Any] = {
        "title": pr.get("title") or "",
        "description": pr.get("description") or "",
        "reviewers": reviewers_payload,
    }
    if "close_source_branch" in pr:
        body["close_source_branch"] = bool(pr.get("close_source_branch"))
    dest_name = (((pr.get("destination") or {}).get("branch")) or {}).get("name")
    if dest_name:
        body["destination"] = {"branch": {"name": dest_name}}

    if args.dry_run:
        print(json.dumps({"method": "PUT", "url": API_ROOT + base, "body": body}, indent=2))
        return 0

    # Idempotency: skip the PUT when the effective reviewer set is unchanged.
    before = {_canon(r) for r in current if not author_reviewer(r)}
    after = {_canon(r) for r in desired}
    if before == after:
        log("Reviewers already up to date; no change made")
        emit_reviewers(args, pr.get("title"), current)
        return 0

    log(f"Setting {len(reviewers_payload)} reviewer(s) on PR #{args.pr} via REST")
    updated = bb.put_json(base, body)
    emit_reviewers(args, updated.get("title"), updated.get("reviewers") or [])
    return 0


def cmd_get(args: argparse.Namespace) -> int:
    ws, repo = split_repo(args.repo)
    bb = Bitbucket(*load_credentials())
    base = f"/repositories/{ws}/{repo}/pullrequests/{args.pr}"
    pr = bb.get_json(base, params={"fields": _PR_FIELDS})
    emit_reviewers(args, pr.get("title"), pr.get("reviewers") or [])
    return 0


def cmd_check_auth(args: argparse.Namespace) -> int:
    del args  # signature parity with the other subcommand handlers
    bb = Bitbucket(*load_credentials())
    me = bb.get_json("/user")
    print(json.dumps({
        "account_id": me.get("account_id"),
        "uuid": me.get("uuid"),
        "display_name": me.get("display_name"),
    }, indent=2))
    return 0


def emit_reviewers(args: argparse.Namespace, title: str | None, reviewers: list[dict]) -> None:
    out = {
        "pr": int(args.pr),
        "title": title,
        "reviewers": [
            {
                "account_id": r.get("account_id"),
                "uuid": r.get("uuid"),
                "display_name": r.get("display_name"),
            }
            for r in reviewers
        ],
    }
    print(json.dumps(out, indent=2))


# --------------------------------------------------------------------------
# argparse
# --------------------------------------------------------------------------


def split_repo(value: str) -> tuple[str, str]:
    if value.count("/") != 1 or value.startswith("/") or value.endswith("/"):
        raise SkillError(f"--repo expects <workspace>/<slug> (got '{value}')", 1)
    ws, slug = value.split("/", 1)
    return ws, slug


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="bitbucket_pr_reviewers.py",
        description="Set Bitbucket PR reviewers via REST (bypasses bb's hanging --reviewer).",
    )
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("set", help="Add/remove reviewers on a PR")
    s.add_argument("--pr", required=True, help="Pull request id")
    s.add_argument("--repo", required=True, help="<workspace>/<slug>")
    s.add_argument("--add", action="append", default=[], metavar="ACCOUNT_ID|UUID",
                   help="Reviewer to add (repeatable)")
    s.add_argument("--remove", action="append", default=[], metavar="ACCOUNT_ID|UUID",
                   help="Reviewer to remove (repeatable)")
    s.add_argument("--dry-run", action="store_true",
                   help="Print the planned PUT request instead of sending it")
    s.add_argument("--json", action="store_true", help="(default) JSON output")
    s.set_defaults(func=cmd_set)

    g = sub.add_parser("get", help="Show a PR's current reviewers")
    g.add_argument("--pr", required=True, help="Pull request id")
    g.add_argument("--repo", required=True, help="<workspace>/<slug>")
    g.add_argument("--json", action="store_true", help="(default) JSON output")
    g.set_defaults(func=cmd_get)

    c = sub.add_parser("check-auth", help="Verify credentials (GET /user)")
    c.set_defaults(func=cmd_check_auth)

    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except SkillError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return exc.code
    except httpx.HTTPError as exc:
        print(f"Error: HTTP request failed: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
