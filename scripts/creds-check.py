#!/usr/bin/env python3
"""Ask every long-lived credential on this machine whether it still authenticates.

WHY THIS EXISTS. `just audit` asks "is anything suspiciously NEW, or has upstream
WITHDRAWN it?". This asks the opposite and much duller question: "does the thing I
already trust still work?" Neither answers the other, so they stay separate commands.

Measured 2026-08-24, which is why it now exists: the Atlassian token in
`atlassian_c24_bitbucket_api_token` had expired on 2026-08-07 and nothing said so.
Classic Atlassian API tokens (`ATATT3...`) are opaque -- there is no expiry to read
out of the string -- so the first symptom was Jira answering **HTTP 404** on a
perfectly real ticket, because Jira hides issue existence from unauthenticated
callers. That reads as "the ticket does not exist" and sends you after the wrong
problem entirely. A credential that fails silently and then lies about why is worth
one deliberate probe.

Secrets are read from files, never from the environment (see the note in
modules/shells.nix). Nothing here prints a token: only the account it resolves to.

Exit codes match infra/scripts/osv-audit.py, so a caller can tell the three cases
apart without parsing stdout:
    0  every credential present authenticated (or there was nothing to check)
    1  at least one credential no longer authenticates
    2  the tool itself could not run (network, missing interpreter, bad config)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from base64 import b64encode
from dataclasses import dataclass
from pathlib import Path

TIMEOUT = 20

# Four outcomes, never collapsed into two. A credential that is simply absent on
# this host is a SKIP, not a failure -- the personal Mac has no work tokens and
# must not report red for it. (AGENTS.md, "Any script that processes a list".)
OK, SKIP, ERROR = "ok", "skip", "error"

COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def paint(s: str, code: str) -> str:
    return f"\033[{code}m{s}\033[0m" if COLOR else s


def secrets_dir() -> Path:
    d = os.environ.get("SOPS_SECRETS_DIR")
    if d:
        return Path(d)
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "sops-nix" / "secrets"


def read_secret(name: str) -> str | None:
    """Read one sops-nix secret file. Absent or empty is None, never an exception."""
    p = secrets_dir() / name
    try:
        v = p.read_text().strip()
    except OSError:
        return None
    return v or None


@dataclass
class Result:
    label: str
    status: str
    detail: str


def http_identity(url: str, user: str | None, token: str, field: str | None,
                  auth: str) -> Result | str:
    """GET url and return the identity string, or a Result describing the failure.

    The two Atlassian products here do NOT share an auth scheme, and guessing
    wrong looks exactly like a dead credential:
      basic  -- Jira Cloud, email + classic API token
      bearer -- the self-hosted Confluence Data Center instance, personal
                access token. Sending this one as Basic returns 401, which
                reads as "token rejected" when the token is in fact fine."""
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if auth == "bearer":
        req.add_header("Authorization", f"Bearer {token}")
    else:
        req.add_header("Authorization",
                       "Basic " + b64encode(f"{user}:{token}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        # 401/403 is the credential's answer and therefore a real finding.
        # Anything else is the tool failing to get an answer at all.
        if e.code in (401, 403):
            return Result("", ERROR, f"HTTP {e.code} — token rejected")
        if e.code == 404:
            return Result("", ERROR, f"HTTP 404 — endpoint or site wrong (a bad token also 404s here)")
        raise
    if not field:
        return "authenticated"
    try:
        return str(json.loads(body).get(field) or "authenticated")
    except (ValueError, AttributeError):
        return "authenticated"


def check_atlassian(label: str, url_file: str, user_file: str | None, token_file: str,
                    path: str, field: str | None, auth: str = "basic") -> Result:
    url, token = read_secret(url_file), read_secret(token_file)
    user = read_secret(user_file) if user_file else None
    needed = [(url_file, url), (token_file, token)]
    if user_file:
        needed.append((user_file, user))
    missing = [n for n, v in needed if not v]
    if missing:
        return Result(label, SKIP, "not configured here (" + ", ".join(missing) + ")")
    try:
        # rstrip matters: confluence_url carries a trailing slash, and the
        # resulting '//rest/api/...' is a 404 that looks like a wrong endpoint.
        out = http_identity(url.rstrip("/") + path, user, token, field, auth)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise SystemExit(f"creds-check: cannot reach {url}: {e}") from e
    if isinstance(out, Result):
        return Result(label, out.status, out.detail)
    return Result(label, OK, out)


def check_bb() -> Result:
    """The Bitbucket CLI keeps its own profile; ask it rather than duplicating it."""
    label = "bb (config-cli.yml)"
    if not shutil.which("bb"):
        return Result(label, SKIP, "bb not installed")
    try:
        p = subprocess.run(["bb", "profile", "list"], capture_output=True,
                           text=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return Result(label, ERROR, f"bb failed: {e}")
    if p.returncode != 0:
        return Result(label, ERROR, (p.stderr or p.stdout).strip().splitlines()[:1][0]
                      if (p.stderr or p.stdout).strip() else f"exit {p.returncode}")
    names = [ln.strip() for ln in p.stdout.splitlines() if ln.strip()]
    return Result(label, OK, f"{len(names)} profile(s) configured")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Check whether the long-lived credentials on this host still authenticate.")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    results = [
        check_atlassian("jira_api_token", "jira_url", "jira_username", "jira_api_token",
                        "/rest/api/2/myself", "displayName"),
        check_atlassian("confluence_personal_token", "confluence_url", None,
                        "confluence_personal_token", "/rest/api/user/current",
                        "displayName", auth="bearer"),
        check_bb(),
    ]

    if args.json:
        print(json.dumps([r.__dict__ for r in results], indent=2))
    else:
        width = max(len(r.label) for r in results)
        for r in results:
            tag = {OK: paint("ok   ", "32"), SKIP: paint("skip ", "33"),
                   ERROR: paint("ERROR", "31")}[r.status]
            print(f"  {r.label:<{width}}  {tag}  {r.detail}")

    n_ok = sum(r.status == OK for r in results)
    n_skip = sum(r.status == SKIP for r in results)
    n_err = sum(r.status == ERROR for r in results)
    # Self-describing summary: all three counts every run, so "2 ok" can never be
    # mistaken for "everything is fine" when one entry was silently skipped.
    print(f"\n{n_ok} ok, {n_skip} skipped (not configured here), {n_err} failing", end="")
    print(" — nothing to do." if n_err == 0 else " — re-issue the failing credential(s).")
    return 1 if n_err else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            sys.exit(2)
        raise
