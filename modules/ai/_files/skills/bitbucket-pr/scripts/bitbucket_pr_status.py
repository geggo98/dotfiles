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
"""Query Bitbucket Cloud build/pipeline status (Jenkins commit statuses) for a
pull request, commit, or branch.

Why this exists: `bb` has no command for this at all (checked v0.18.2,
installed here, and upstream v0.18.6). The closest thing, `bb pullrequest
merge-status`, reports the *merge task* state, not CI. `bb pipeline` queries
Bitbucket's own Pipelines API and is the wrong tool for a repo whose CI is
Jenkins, posting through the commit-statuses webhook: run against a real PR
carrying 7 Jenkins statuses, `bb pipeline list` printed "No pipelines found"
and exited 0 — the exact "a filter that cannot match reports the same as a
clean result" trap this repo's rules warn about.

Two REST endpoints carry the answer:
  GET /pullrequests/{id}/statuses   (PR target — mixes statuses of ALL commits
                                      ever pushed to the PR, not just the head)
  GET /commit/{sha}/statuses        (commit or branch target — {sha} accepts a
                                      short prefix, resolved server-side;
                                      measured: 7 and 12 char prefixes both 200)

Response shape, measured against a live PR with a completed Jenkins pipeline:
a FLAT list mixing exactly one *overall* entry (refname set, description is a
generic sentence, name carries a build number "... #N") with N *stage*
entries (refname null, description IS the stage name: "Checkout Code",
"Build", "Test", "Analysis", "Package", "Deployment").

Three measured traps this script exists to avoid:
  1. A PR object's source.commit.hash is TRUNCATED TO 12 CHARS; statuses carry
     the full 40-char hash. An `==` head-commit filter never matches on a
     perfectly healthy PR. Always compare by prefix.
  2. `key` is NOT a stable stage identifier — Jenkins mints a fresh random key
     per post (32-hex for the overall entry, 40-hex per stage), so a re-run's
     stages get entirely new keys. Dedup by (name, description), newest
     created_on wins — never by key.
  3. An empty result must never look like a clean/green build. Every fetched
     status is classified into exactly one bucket (overall / stage /
     unclassified), the counts are always printed, and an internal
     consistency check raises rather than silently dropping something.

Credentials reuse what `bb` already stores. The plumbing below
(SkillError / load_credentials / Bitbucket / _raise_for_status / split_repo)
is a deliberate sibling copy of bitbucket_pr_reviewers.py's — see that
script's docstring and SKILL.md §13 for why this is not factored into a
shared module: `uv run --script` locks and isolates per script, and a shared
module would get no lock of its own.

Exit codes:
  0 success | 1 bad args | 2 missing prereq/credentials
  3 API/auth/network failure | 4 pull request / commit / branch not found
  Only with --exit-code (defaulted on by --watch, override with
  --no-exit-code):
  10 red (FAILED or STOPPED, overall or any stage)
  11 still in progress, or --watch hit its --deadline
  12 no statuses at all on the target — "nothing" must never read as success.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import yaml

API_ROOT = "https://api.bitbucket.org/2.0"
API_HOST_PREFIX = "https://api.bitbucket.org/"

# A status is "in progress" iff its state is literally INPROGRESS; every other
# value (including one we don't recognise) counts as terminal. This keeps
# --watch from hanging forever on a CI that posts a state nobody anticipated.
RED_STATES = {"FAILED", "STOPPED"}
STATE_RANK = {"SUCCESSFUL": 0, "INPROGRESS": 1, "STOPPED": 2, "FAILED": 3}


class SkillError(Exception):
    """Carries a process exit code alongside the message."""

    def __init__(self, message: str, code: int):
        super().__init__(message)
        self.code = code


def log(msg: str) -> None:
    print(f"Info: {msg}", file=sys.stderr)


# --------------------------------------------------------------------------
# Credentials — sibling copy of bitbucket_pr_reviewers.py's plumbing; keep the
# two in sync (see module docstring above).
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


def _raise_for_status(resp: httpx.Response) -> None:
    if resp.is_success:
        return
    # A 404 for an unknown PR id comes back as plain text ("Not Found"), not
    # JSON — measured. A 404 for an unknown repo/workspace IS JSON with a
    # helpful message. Handle both.
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


def split_repo(value: str) -> tuple[str, str]:
    if value.count("/") != 1 or value.startswith("/") or value.endswith("/"):
        raise SkillError(f"--repo expects <workspace>/<slug> (got '{value}')", 1)
    ws, slug = value.split("/", 1)
    return ws, slug


# --------------------------------------------------------------------------
# Pagination — real on this endpoint (measured: pagelen=3 returns `next`).
# Hard error on truncation rather than silently dropping statuses: a cut-off
# page could easily be hiding the one FAILED stage.
# --------------------------------------------------------------------------


def fetch_all(bb: Bitbucket, path: str, max_pages: int) -> tuple[list[dict], int]:
    values: list[dict] = []
    page = bb.get_json(path, params={"pagelen": 100, "sort": "-created_on"})
    pages = 0
    while True:
        pages += 1
        values.extend(page.get("values") or [])
        nxt = page.get("next")
        if not nxt:
            return values, pages
        if not nxt.startswith(API_HOST_PREFIX):
            # The client carries Basic auth; never follow a redirect off-host.
            raise SkillError(f"pagination 'next' points off-host, refusing to follow with credentials: {nxt}", 3)
        if pages >= max_pages:
            raise SkillError(
                f"stopped after {max_pages} pages ({len(values)} statuses fetched) with more to come "
                f"(next={nxt}). A truncated list can hide a FAILED stage — raise --max-pages.",
                3,
            )
        page = bb.get_json(nxt)


# --------------------------------------------------------------------------
# Field extraction
# --------------------------------------------------------------------------

# matches:  "acme » example-service » feature-login-retry #42"  ->  "42"
_BUILD_IN_NAME = re.compile(r"#(?P<build>\d+)\s*$")
# matches:  ".../job/acme/job/example-service/job/feature-login-retry/42/display/redirect"
_BUILD_IN_URL = re.compile(r"/(?P<build>\d+)/(?:display/redirect/?)?$")


def _extract_build(status: dict) -> int | None:
    for text, pat in (
        (status.get("name") or "", _BUILD_IN_NAME),
        (status.get("url") or "", _BUILD_IN_URL),
    ):
        m = pat.search(text)
        if m:
            return int(m.group("build"))
    return None


def _commit_hash(status: dict) -> str | None:
    commit = status.get("commit")
    if isinstance(commit, dict):
        h = commit.get("hash")
        if h:
            return str(h)
    if isinstance(commit, str) and commit:
        return commit
    href = ((status.get("links") or {}).get("commit") or {}).get("href")
    if href:
        return href.rstrip("/").rsplit("/", 1)[-1]
    return None


# --------------------------------------------------------------------------
# Classification / dedup / rollup
# --------------------------------------------------------------------------


def classify(statuses: list[dict]) -> tuple[dict | None, list[dict], list[dict]]:
    """Split into (overall_or_None, stage_entries, unclassified_entries).

    refname is the discriminator, not key length or any other incidental
    field: the one overall entry per commit carries a branch refname, every
    per-stage entry has refname == null.
    """
    overall_candidates: list[dict] = []
    stages: list[dict] = []
    unclassified: list[dict] = []
    for s in statuses:
        if s.get("refname"):
            overall_candidates.append(s)
        elif s.get("description") is not None or s.get("name"):
            stages.append(s)
        else:
            unclassified.append(s)
    overall = None
    if overall_candidates:
        overall = max(overall_candidates, key=lambda s: s.get("created_on") or "")
        # Any other "overall-shaped" entries (rare: a re-run posting a second
        # rollup) are stage-adjacent noise, not proper stages — fold anything
        # but the newest into unclassified rather than inventing a bucket.
        unclassified.extend(c for c in overall_candidates if c is not overall)
    return overall, stages, unclassified


def dedup(entries: list[dict]) -> list[dict]:
    """Group by (name, description) — NOT by key, which Jenkins mints fresh
    per post and therefore never repeats across a re-run. Newest created_on
    wins; ties break on updated_on, then on the build number in the url."""
    best: dict[tuple[str, str], dict] = {}
    for s in entries:
        dkey = (s.get("name") or "", s.get("description") or "")
        prev = best.get(dkey)
        if prev is None:
            best[dkey] = s
            continue
        a, b = prev.get("created_on") or "", s.get("created_on") or ""
        if b > a:
            best[dkey] = s
        elif b == a:
            au, bu = prev.get("updated_on") or "", s.get("updated_on") or ""
            if bu > au:
                best[dkey] = s
            elif bu == au and (_extract_build(s) or -1) > (_extract_build(prev) or -1):
                best[dkey] = s
    return sorted(best.values(), key=lambda s: s.get("created_on") or "")


def rollup_state(overall: dict | None, stages: list[dict]) -> tuple[str | None, list[str]]:
    """Worst state across overall + stages, plus warnings when they disagree
    (Jenkins can post the rollup before every stage callback has landed)."""
    warnings: list[str] = []
    states = [s.get("state") for s in stages]
    if overall is not None:
        states.append(overall.get("state"))
    named = [s for s in states if s]
    if not named:
        return None, warnings
    unknown = sorted({s for s in named if s not in STATE_RANK})
    for u in unknown:
        warnings.append(f"unrecognised status state '{u}' — treated as terminal, ranked below FAILED/STOPPED")
    known = [s for s in named if s in STATE_RANK]
    worst = max(known, key=lambda s: STATE_RANK[s]) if known else "UNKNOWN"
    if overall is not None:
        ostate = overall.get("state")
        red_stage = next((s for s in stages if s.get("state") in RED_STATES), None)
        if red_stage is not None and ostate not in RED_STATES:
            warnings.append(
                f"overall reports {ostate} while stage '{red_stage.get('description')}' reports {red_stage.get('state')}"
            )
    return worst, warnings


def is_terminal(overall: dict | None, stages: list[dict], require_overall: bool) -> bool:
    if not stages and overall is None:
        return False  # nothing posted yet — keep waiting until the deadline
    if any(s.get("state") == "INPROGRESS" for s in stages):
        return False
    if overall is not None and overall.get("state") == "INPROGRESS":
        return False
    if require_overall and overall is None:
        return False
    return True


def compute_exit_code(overall: dict | None, stages: list[dict], deadline_hit: bool) -> int:
    if not stages and overall is None:
        return 12
    if deadline_hit:
        return 11
    if any(s.get("state") == "INPROGRESS" for s in stages) or (overall is not None and overall.get("state") == "INPROGRESS"):
        return 11
    worst, _ = rollup_state(overall, stages)
    return 10 if worst in RED_STATES else 0


# --------------------------------------------------------------------------
# Target resolution — PR / commit / branch all end up as a statuses path plus
# a pinned/head commit hash.
# --------------------------------------------------------------------------


@dataclass
class Target:
    kind: str  # "pr" | "commit" | "branch"
    statuses_path: str
    head_hash: str
    pr_info: dict | None = None


def resolve_target(bb: Bitbucket, ws: str, slug: str, args: argparse.Namespace) -> Target:
    if args.pr is not None:
        pr = bb.get_json(
            f"/repositories/{ws}/{slug}/pullrequests/{args.pr}",
            params={"fields": "id,title,state,source.commit.hash,source.branch.name,destination.branch.name"},
        )
        head = ((pr.get("source") or {}).get("commit") or {}).get("hash")
        if not head:
            raise SkillError(f"PR #{args.pr} has no source commit hash in the API response", 3)
        return Target(
            kind="pr",
            statuses_path=f"/repositories/{ws}/{slug}/pullrequests/{args.pr}/statuses",
            head_hash=head,
            pr_info={
                "id": pr.get("id"),
                "title": pr.get("title"),
                "state": pr.get("state"),
                "source_branch": ((pr.get("source") or {}).get("branch") or {}).get("name"),
                "destination_branch": ((pr.get("destination") or {}).get("branch") or {}).get("name"),
            },
        )
    if args.branch is not None:
        ref = bb.get_json(
            f"/repositories/{ws}/{slug}/refs/branches/{args.branch}",
            params={"fields": "name,target.hash"},
        )
        head = (ref.get("target") or {}).get("hash")
        if not head:
            raise SkillError(f"Branch '{args.branch}' has no target commit hash in the API response", 3)
        return Target(kind="branch", statuses_path=f"/repositories/{ws}/{slug}/commit/{head}/statuses", head_hash=head)
    # args.commit — the commit-statuses endpoint accepts a short prefix
    # server-side (measured: 7 and 12 char prefixes both resolved), so it is
    # passed through as given rather than resolved to the full hash first.
    return Target(
        kind="commit",
        statuses_path=f"/repositories/{ws}/{slug}/commit/{args.commit}/statuses",
        head_hash=args.commit,
    )


# --------------------------------------------------------------------------
# Snapshot — one fetch + classify + dedup pass
# --------------------------------------------------------------------------


@dataclass
class Snapshot:
    target: Target
    overall: dict | None
    stages: list[dict]
    unclassified: list[dict]
    counts: dict = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    rollup: str | None = None


def take_snapshot(bb: Bitbucket, ws: str, slug: str, args: argparse.Namespace) -> Snapshot:
    target = resolve_target(bb, ws, slug, args)
    fetched, pages = fetch_all(bb, target.statuses_path, args.max_pages)

    filter_to_head = target.kind == "pr" and not args.all_commits
    if filter_to_head:
        relevant = [s for s in fetched if (h := _commit_hash(s)) is not None and h.startswith(target.head_hash)]
        other_commits = len(fetched) - len(relevant)
        if fetched and not relevant:
            unresolved = sum(1 for s in fetched if _commit_hash(s) is None)
            if unresolved == len(fetched):
                raise SkillError(
                    f"could not extract a commit hash from any of {len(fetched)} statuses — "
                    "the head-commit filter would drop everything; re-run with --all-commits", 3,
                )
    else:
        relevant = fetched
        other_commits = 0

    overall, stages_raw, unclassified = classify(relevant)
    stages = stages_raw if args.history else dedup(stages_raw)
    rollup, warnings = rollup_state(overall, stages)

    counts = {
        "fetched": len(fetched),
        "relevant": len(relevant),
        "other_commits": other_commits,
        "overall": 1 if overall else 0,
        "stage_raw": len(stages_raw),
        "stage": len(stages),
        "unclassified": len(unclassified),
        "pages": pages,
    }
    if counts["fetched"] != counts["relevant"] + counts["other_commits"]:
        raise SkillError(f"internal consistency check failed (fetched vs relevant+other_commits): {counts}", 3)
    if counts["relevant"] != counts["overall"] + counts["stage_raw"] + counts["unclassified"]:
        raise SkillError(f"internal consistency check failed (relevant vs overall+stage+unclassified): {counts}", 3)

    return Snapshot(target, overall, stages, unclassified, counts, warnings, rollup)


# --------------------------------------------------------------------------
# Watch
# --------------------------------------------------------------------------


def run_watch(bb: Bitbucket, ws: str, slug: str, args: argparse.Namespace) -> tuple[Snapshot, bool]:
    deadline_at = time.monotonic() + args.deadline
    last_head: str | None = None
    snap: Snapshot | None = None
    stop_requested = False

    def handle_sigterm(signum: int, frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    old_handler = signal.signal(signal.SIGTERM, handle_sigterm)
    try:
        while True:
            snap = take_snapshot(bb, ws, slug, args)
            if last_head is not None and snap.target.head_hash != last_head:
                log(f"head moved {last_head[:12]} -> {snap.target.head_hash[:12]} — continuing to watch the new head")
            last_head = snap.target.head_hash
            stage_states = ", ".join(f"{s.get('description')}={s.get('state')}" for s in snap.stages) or "(none yet)"
            log(f"poll: overall={snap.overall.get('state') if snap.overall else 'none'}  stages: {stage_states}")

            if is_terminal(snap.overall, snap.stages, not args.no_require_overall):
                return snap, False
            if stop_requested:
                log("received SIGTERM — reporting the last snapshot")
                return snap, False
            remaining = deadline_at - time.monotonic()
            if remaining <= 0:
                return snap, True
            time.sleep(min(args.interval, remaining))
    finally:
        signal.signal(signal.SIGTERM, old_handler)


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


def render_table(snap: Snapshot, args: argparse.Namespace) -> str:
    t = snap.target
    lines: list[str] = []
    if t.kind == "pr":
        pr = t.pr_info or {}
        lines.append(f"PR #{pr.get('id')} {pr.get('state')}  {args.repo}  {pr.get('source_branch')} → {pr.get('destination_branch')}")
        lines.append(f"head {t.head_hash[:12]}")
    elif t.kind == "branch":
        lines.append(f"branch {args.branch}  {args.repo}")
        lines.append(f"head {t.head_hash[:12]}")
    else:
        lines.append(f"commit {t.head_hash}  {args.repo}")

    if snap.overall:
        build = _extract_build(snap.overall)
        build_part = f"  build #{build}" if build else ""
        lines.append(f"overall  {snap.overall.get('state')}{build_part}  {snap.overall.get('url', '')}")
    else:
        lines.append("overall  (no overall status posted)")

    lines.append("")
    if snap.stages:
        lines.append(f"{'STATE':<12} {'STAGE':<24} UPDATED")
        for s in snap.stages:
            stage_name = (s.get("description") or "")[:24]
            lines.append(f"{s.get('state',''):<12} {stage_name:<24} {s.get('updated_on','')}")
    else:
        lines.append("(no stage statuses)")

    lines.append("")
    c = snap.counts
    summary = f"{c['stage']} stage(s)"
    if not args.history and c["stage_raw"] != c["stage"]:
        summary += f" (deduped from {c['stage_raw']} raw)"
    summary += f" · {c['fetched']} status(es) fetched over {c['pages']} page(s)"
    if t.kind == "pr" and not args.all_commits:
        summary += f" · {c['relevant']} on head, {c['other_commits']} on other commits (--all-commits shows them)"
    if c["unclassified"]:
        summary += f" · {c['unclassified']} UNCLASSIFIED (see --raw)"
    lines.append(summary)
    for w in snap.warnings:
        lines.append(f"WARNING: {w}")
    if snap.rollup:
        lines.append(f"rollup: {snap.rollup}")
    return "\n".join(lines)


def render_json(snap: Snapshot, args: argparse.Namespace) -> str:
    t = snap.target
    obj = {
        "repo": args.repo,
        "target": {"kind": t.kind, "head_commit": t.head_hash, **({"pr": t.pr_info} if t.pr_info else {})},
        "overall": snap.overall,
        "stages": snap.stages,
        "unclassified": snap.unclassified,
        "counts": snap.counts,
        "rollup": snap.rollup,
        "warnings": snap.warnings,
    }
    return json.dumps(obj, indent=2)


def render_tsv(snap: Snapshot) -> str:
    rows = ["kind\tstate\tstage\tbuild\tcommit\tcreated_on\tupdated_on\turl"]

    def row(kind: str, s: dict) -> str:
        return "\t".join([
            kind,
            s.get("state") or "",
            s.get("description") or "",
            str(_extract_build(s) or ""),
            (_commit_hash(s) or "")[:12],
            s.get("created_on") or "",
            s.get("updated_on") or "",
            s.get("url") or "",
        ])

    if snap.overall:
        rows.append(row("overall", snap.overall))
    for s in snap.stages:
        rows.append(row("stage", s))
    return "\n".join(rows)


# --------------------------------------------------------------------------
# argparse / dispatch
# --------------------------------------------------------------------------

_DURATION_RE = re.compile(r"^(?P<num>\d+(?:\.\d+)?)(?P<unit>[smhd]?)$")


def _parse_duration(text: str) -> float:
    m = _DURATION_RE.match(text.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"invalid duration '{text}' (expected e.g. 15s, 15m, 1h, or a bare number of seconds)")
    mult = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group("unit")]
    return float(m.group("num")) * mult


def cmd_get(args: argparse.Namespace) -> int:
    ws, slug = split_repo(args.repo)
    if args.all_commits and args.pr is None:
        raise SkillError("--all-commits only applies to --pr", 1)
    if args.interval < 5:
        raise SkillError("--interval must be at least 5s", 1)
    if args.watch and args.deadline < args.interval:
        raise SkillError("--deadline must be at least --interval", 1)

    bb = Bitbucket(*load_credentials())

    if args.raw:
        target = resolve_target(bb, ws, slug, args)
        fetched, pages = fetch_all(bb, target.statuses_path, args.max_pages)
        print(json.dumps({
            "target": {"kind": target.kind, "head_commit": target.head_hash},
            "pages": pages,
            "values": fetched,
        }, indent=2))
        return 0

    if args.exit_code is None:
        args.exit_code = args.watch

    deadline_hit = False
    if args.watch:
        snap, deadline_hit = run_watch(bb, ws, slug, args)
    else:
        snap = take_snapshot(bb, ws, slug, args)

    if args.format == "json":
        print(render_json(snap, args))
    elif args.format == "tsv":
        print(render_tsv(snap))
    else:
        print(render_table(snap, args))

    if args.exit_code:
        return compute_exit_code(snap.overall, snap.stages, deadline_hit)
    return 0


def cmd_check_auth(args: argparse.Namespace) -> int:
    del args
    bb = Bitbucket(*load_credentials())
    me = bb.get_json("/user")
    print(json.dumps({
        "account_id": me.get("account_id"),
        "uuid": me.get("uuid"),
        "display_name": me.get("display_name"),
    }, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="bitbucket_pr_status.py",
        description="Query Bitbucket build/pipeline status (Jenkins commit statuses) for a PR, commit, or branch.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    g = sub.add_parser("get", help="Fetch and render build status")
    target = g.add_mutually_exclusive_group(required=True)
    target.add_argument("--pr", type=int, metavar="ID", help="Pull request id")
    target.add_argument("--commit", metavar="SHA", help="Commit hash or unambiguous prefix (>=7 chars)")
    target.add_argument("--branch", metavar="NAME", help="Branch name (resolved to its tip commit)")
    g.add_argument("--repo", required=True, metavar="WORKSPACE/SLUG")
    g.add_argument("--all-commits", action="store_true", help="Include statuses from commits other than the PR head (--pr only)")
    g.add_argument("--history", action="store_true", help="Skip dedup: show every raw status, including repeated stage posts from re-runs")
    g.add_argument("--format", choices=["table", "json", "tsv"], default="table")
    g.add_argument("--json", action="store_const", dest="format", const="json", help="Shortcut for --format json")
    g.add_argument("--raw", action="store_true", help="Dump the fetched statuses unfiltered/unclassified as JSON and exit")
    g.add_argument("--max-pages", type=int, default=20, help="Hard cap on pages followed (default 20 = up to 2000 statuses); refuses to truncate silently")
    g.add_argument("--watch", action="store_true", help="Poll until every stage is terminal (or --deadline)")
    g.add_argument("--interval", type=_parse_duration, default=15.0, metavar="DURATION", help="Poll interval while --watch (default 15s; min 5s)")
    g.add_argument("--deadline", type=_parse_duration, default=900.0, metavar="DURATION", help="--watch gives up after this long (default 15m)")
    g.add_argument("--no-require-overall", action="store_true", help="--watch: terminate once no stage is INPROGRESS, without waiting for an overall status")
    g.add_argument("--exit-code", dest="exit_code", action="store_true", default=None, help="Map the build result onto the exit code (10 red, 11 in-progress/deadline, 12 no statuses); default on with --watch")
    g.add_argument("--no-exit-code", dest="exit_code", action="store_false", help="Always exit 0 on a successful query, even under --watch")
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
