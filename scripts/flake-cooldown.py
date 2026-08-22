#!/usr/bin/env python3
"""Update mutable flake inputs to the newest commit that is at least N days old.

WHY THIS EXISTS. `nix flake update` always jumps an input to the CURRENT head of its
branch. There is no "give me last week's head", so every update adopts code that is
minutes old — which is precisely the window a supply-chain attack lives in.

Measured on 2026-08-22 in this repo: a plain `just update` moved six inputs to a HEAD
committed that same day (home-manager 0.2 days old, worktrunk 0.1, llm-agents 0.3,
determinate 0.6, devenv 0.5, nix-homebrew 0.8) while the ChainDrop/Shai-Hulud npm
campaign was live and still classified active by CSA advisory AD-2026-009. Nothing in
the repo said a word about it.

WHY A COOLDOWN AND NOT A SCANNER. The poisoned ChainDrop tarballs carried VALID npm
provenance and SLSA L3 attestations, signed by GitHub Actions through Sigstore — every
cryptographic check passed, because the source was trojanized before the build ran. A
vulnerability scanner returns "clean" for exactly as long as it matters. Age is the one
signal an attacker cannot forge: a malicious release is usually pulled within hours to
days, so simply refusing to be the first consumer converts most of these incidents into
a non-event. modules/supply-chain-hardening.nix already applies this reasoning to npm,
pnpm, bun and uv; this closes the same gap one level up, at the flake inputs.

WHAT IT DOES NOT DO. A cooldown on the flake INPUT bounds the age of everything inside
it from below -- a llm-agents.nix rev from 14 days ago cannot pin an npm version
published yesterday -- but it says nothing about whether that older code is malicious.
It is a soak, not a verdict. It also cannot help against an attack nobody notices for
longer than the threshold. Pair it with an advisory check, do not substitute it.

AND THE DATE IS ATTACKER-SETTABLE. State this plainly rather than discover it later:
the committer date this tool sorts by is chosen by whoever makes the commit. Measured
2026-08-22 -- `GIT_COMMITTER_DATE=2019-01-01 git commit` produces an input that this
tool reports as 2790 days old. Anyone who controls the upstream repository can therefore
walk straight through the bar.

That is not a reason to drop the cooldown, but it does define what it is FOR. It defends
against the common shape of these incidents -- a compromised account publishes, the
release is live for hours, someone notices, it gets pulled -- because refusing to be an
early consumer removes you from the blast radius. It does NOT defend against a patient
attacker who has already taken over the repo and forges timestamps. Nothing here does.
The same caveat applies one level down: registry.npmjs.org's `time` map and GitHub's
`published_at` are both supplied by the party being audited.

MECHANISM. `nix flake lock --override-input <name> github:<o>/<r>/<rev>` writes the
explicit rev into flake.lock while leaving flake.nix untouched: the `original` entry
stays plain branch-tracking, only `locked` carries the older rev. Verified here on
2026-08-22 against Determinate Nix 3.21.9 / Nix 2.34.8.

    original: {"owner": "NotAShelf", "repo": "nvf", "type": "github"}
    locked:   {... "rev": "b05fadedb5e8510ed5dd07fce5364f36fc359dac" ...}

The consequence, and it is the reason this must be wired into `just update`: because
`original` stays branch-tracking, a BARE `nix flake update` silently discards the
cooldown and goes back to HEAD. `just update` is the only update path that honours it,
exactly as `just switch` is the only supported apply path.

INPUT CLASSIFICATION, which is subtler than it looks. A GitHub input's `ref` may be
either a branch or a tag, and the two need opposite treatment:

    ref is a BRANCH   nixpkgs (nixos-26.05), nixpkgs-unstable (nixos-unstable),
                      home-manager (release-26.05), darwin (nix-darwin-26.05)
                      -> mutable, `nix flake update` moves it, needs a cooldown
    ref is a TAG      yt-dlp-src (2026.07.04), brew-src (6.0.17),
                      agent-browser-src (v0.33.0)
                      -> immutable, `nix flake update` does NOT move it, skip
    no ref at all     devenv, nvf, sops-nix, worktrunk, ...
                      -> tracks the default branch, needs a cooldown

Guessing from the string does not work (`6.0.17` and `release-26.05` are both plausible
either way), so each `ref` is resolved against the GitHub branches endpoint.

Stdlib only, deliberately, for the same reason infra/scripts/osv-audit.py is: a tool
whose job is to keep untrusted code out has no business installing any to run. `gh` is
consulted for an API token if it happens to be authenticated, purely to lift the rate
limit from 60 to 5000 requests/hour; everything works without it.

Exit codes: 0 nothing to do / all cooled, 1 action needed or refused, 2 tool error.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

GITHUB_API = "https://api.github.com"
UA = "flake-cooldown (nix-darwin config)"

# Categories, kept distinct on purpose. CLAUDE.md: "Classify every item as SUCCESS,
# SKIP, ERROR or CLEANUP, and never collapse two of them. A skip is not a failure."
COOLED = "cooled"      # moved to an older-but-fresh-enough rev  (SUCCESS)
CURRENT = "current"    # already at the right rev, nothing to do (SUCCESS)
CHANNEL = "channel"    # Hydra-gated channel head — see below    (SUCCESS)
IMMUTABLE = "immutable"  # tag/rev pin — flake update cannot move it   (SKIP)
FROZEN = "frozen"      # explicitly excluded by the caller        (SKIP)
UNSUPPORTED = "unsupported"  # not a github input                 (SKIP)
FAILED = "failed"      # lookup or lock error                     (ERROR)

# A nixpkgs CHANNEL branch (nixos-26.05, nixos-unstable, …) must never get a commit
# cooldown, and this is not a preference — it produces a worse revision.
#
# The channel branch is fast-forwarded to a revision only after Hydra has built and
# tested it; its HEAD is the published channel. The commits *between* two heads are
# ordinary merges that were never published as a channel, so they are neither
# Hydra-validated nor covered by cache.nixos.org's channel-based retention. Picking one
# trades "2 days old and fully cached" for "5 days old, never validated, rebuild the
# world".
#
# Measured 2026-08-22: channels.nixos.org/nixos-26.05/git-revision returned
# 5880666fd9eb563038431edb35c2d0aa595884e6 — byte-identical to the branch head that a
# plain `nix flake update` had just locked, while a 5-day cooldown would have selected
# the intermediate commit 5c11f83f0.
#
# So the soak already exists here; it is just spelled "Hydra" instead of "days". Anything
# resolvable through channels.nixos.org is therefore reported as CHANNEL and left at its
# published head.
CHANNEL_STATUS_URL = "https://channels.nixos.org/{ref}/git-revision"


class ToolError(Exception):
    """Unrecoverable: network down, gh broken, nix missing. Exit 2, not 1."""


def http_json(url: str, token: str | None) -> tuple[int, object]:
    """GET url, return (status, parsed-json). 404 is a normal answer here, not an error."""
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": UA,
        **({"Authorization": f"Bearer {token}"} if token else {}),
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (403, 429):
            remaining = e.headers.get("x-ratelimit-remaining")
            if remaining == "0":
                raise ToolError(
                    "GitHub API rate limit exhausted. Authenticate with `gh auth login` "
                    "to raise it from 60 to 5000 requests/hour."
                ) from e
        if e.code == 404:
            return 404, None
        raise ToolError(f"GitHub API {e.code} for {url}: {e.reason}") from e
    except urllib.error.URLError as e:
        raise ToolError(f"cannot reach {url}: {e.reason}") from e


def gh_token() -> str | None:
    """Best-effort token. Absent is fine — it only costs rate limit, never correctness."""
    if not shutil.which("gh"):
        return None
    try:
        out = subprocess.run(["gh", "auth", "token"], capture_output=True,
                             text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    tok = out.stdout.strip()
    return tok if out.returncode == 0 and tok else None


def flake_metadata(flake: str) -> dict:
    try:
        out = subprocess.run(["nix", "flake", "metadata", "--json", flake],
                             capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        raise ToolError(f"cannot run `nix flake metadata`: {e}") from e
    if out.returncode != 0:
        raise ToolError(f"`nix flake metadata` failed:\n{out.stderr.strip()}")
    return json.loads(out.stdout)


def root_inputs(meta: dict) -> dict[str, dict]:
    """Map root input name -> its lock node. Ignores transitive inputs on purpose:
    pinning a parent re-resolves its children from that parent's own lock, so they
    inherit the parent's age instead of racing ahead to their own branch heads."""
    nodes = meta["locks"]["nodes"]
    out = {}
    for name, ref in nodes["root"]["inputs"].items():
        key = ref if isinstance(ref, str) else ref[-1]
        out[name] = nodes[key]
    return out


def is_branch(owner: str, repo: str, ref: str, token: str | None) -> bool:
    status, _ = http_json(f"{GITHUB_API}/repos/{owner}/{repo}/branches/{ref}", token)
    return status == 200


def default_branch(owner: str, repo: str, token: str | None) -> str:
    status, body = http_json(f"{GITHUB_API}/repos/{owner}/{repo}", token)
    if status != 200 or not isinstance(body, dict):
        raise ToolError(f"cannot read default branch of {owner}/{repo}")
    return body["default_branch"]


def newest_commit_before(owner: str, repo: str, branch: str, cutoff: datetime,
                         token: str | None) -> tuple[str, datetime] | None:
    """Newest commit on `branch` with committer date <= cutoff.

    GitHub's `until` filter does exactly this server-side, so it is one request per
    input rather than a paginated walk. Committer date is the same clock flake.lock
    records as `lastModified` for a github input, so the two are directly comparable.
    """
    url = (f"{GITHUB_API}/repos/{owner}/{repo}/commits"
           f"?sha={urllib.parse.quote(branch)}"
           f"&until={cutoff.strftime('%Y-%m-%dT%H:%M:%SZ')}&per_page=1")
    status, body = http_json(url, token)
    if status != 200 or not body:
        return None
    c = body[0]
    when = datetime.strptime(c["commit"]["committer"]["date"],
                             "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return c["sha"], when


def published_channel_head(ref: str) -> str | None:
    """The revision channels.nixos.org currently publishes for `ref`, or None if `ref`
    is not a channel. Plain text body, one 40-char sha. Never raises: a channel lookup
    that cannot be made is answered "not a channel", which only costs a cooldown."""
    req = urllib.request.Request(CHANNEL_STATUS_URL.format(ref=urllib.parse.quote(ref)),
                                 headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            rev = r.read().decode().strip()
    except (urllib.error.URLError, OSError, UnicodeDecodeError):
        return None
    return rev if re.fullmatch(r"[0-9a-f]{40}", rev) else None


# FlakeHub inputs are tarball URLs carrying a semver RANGE, e.g.
#   https://flakehub.com/f/DeterminateSystems/determinate/3
# which re-resolves to the newest matching release on every lock. For `determinate` that
# is the root nix-daemon, so a floating range there defeats every cooldown the repo has:
# measured 2026-08-22, a plain `just update` moved it 3.21.8 -> 3.22.2, published 0.7
# days earlier. One request to the releases endpoint returns version, published_at and
# yanked_at for all of them, so this is cheap to do properly.
FLAKEHUB_URL_RE = re.compile(
    r"^https://(?:api\.)?flakehub\.com/f/(?P<org>[^/]+)/(?P<project>[^/]+)/(?P<range>[^/?#]+?)(?:\.tar\.gz)?/?$")
FLAKEHUB_RELEASES = "https://api.flakehub.com/f/{org}/{project}/releases"


def flakehub_release_before(org: str, project: str, semver_range: str,
                            cutoff: datetime) -> tuple[str, datetime] | None:
    """Newest non-yanked release matching `semver_range` published at or before cutoff.

    Only a bare major ("3") or a full version is understood, which covers every
    FlakeHub input this repo has. A range this cannot parse returns None rather than
    guessing — an unresolved input is reported, never silently left floating.
    """
    req = urllib.request.Request(FLAKEHUB_RELEASES.format(org=org, project=project),
                                 headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            releases = json.load(r)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        raise ToolError(f"cannot list FlakeHub releases for {org}/{project}: {e}") from e

    if not re.fullmatch(r"\d+(\.\d+){0,2}", semver_range):
        return None
    prefix = semver_range + "."

    best: tuple[str, datetime] | None = None
    for rel in releases:
        ver = rel.get("version") or ""
        if not (ver == semver_range or ver.startswith(prefix)):
            continue
        if rel.get("yanked_at"):
            continue
        raw = rel.get("published_at")
        if not raw:
            continue
        # published_at carries fractional seconds and a trailing Z.
        when = datetime.strptime(raw[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        if when > cutoff:
            continue
        if best is None or when > best[1]:
            best = (ver, when)
    return best


def age_days(ts: datetime, now: datetime) -> float:
    return (now - ts).total_seconds() / 86400.0


def parse_days_for(values: list[str]) -> dict[str, int]:
    """--days-for name=N, repeatable. N=0 means "no cooldown, take branch head"."""
    out: dict[str, int] = {}
    for v in values:
        m = re.fullmatch(r"(?P<name>[A-Za-z0-9._-]+)=(?P<days>\d+)", v)
        if not m:
            raise SystemExit(f"error: --days-for expects NAME=DAYS, got {v!r}")
        out[m["name"]] = int(m["days"])
    return out


def main() -> int:
    p = argparse.ArgumentParser(
        description="Update mutable flake inputs to the newest commit at least N days old.",
        epilog="Exit codes: 0 clean, 1 action needed or refused, 2 tool error.")
    p.add_argument("--days", type=int, default=5,
                   help="cooldown in days (default: 5)")
    p.add_argument("--days-for", action="append", default=[], metavar="NAME=DAYS",
                   help="per-input override; 0 disables the cooldown for that input")
    p.add_argument("--freeze", action="append", default=[], metavar="NAME",
                   help="do not touch this input at all (repeatable)")
    p.add_argument("--only", action="append", default=[], metavar="NAME",
                   help="restrict to these inputs (repeatable)")
    p.add_argument("--flake", default=".", help="flake to operate on (default: .)")
    p.add_argument("--dry-run", action="store_true",
                   help="resolve and report, but do not touch flake.lock")
    args = p.parse_args()

    now = datetime.now(timezone.utc)
    per_input = parse_days_for(args.days_for)
    frozen = set(args.freeze)
    only = set(args.only)

    token = gh_token()
    meta = flake_metadata(args.flake)
    inputs = root_inputs(meta)

    results: list[tuple[str, str, str]] = []   # (category, name, detail)
    overrides: list[tuple[str, str]] = []      # (name, flakeref)

    for name in sorted(inputs):
        node = inputs[name]
        original = node.get("original", {})
        locked = node.get("locked", {})

        if only and name not in only:
            continue
        if name in frozen:
            cur = locked.get("lastModified")
            when = (datetime.fromtimestamp(cur, timezone.utc) if cur else None)
            detail = f"held at {locked.get('rev','?')[:9]}"
            if when:
                detail += f" ({when:%Y-%m-%d}, {age_days(when, now):.1f}d)"
            results.append((FROZEN, name, detail))
            continue

        days = per_input.get(name, args.days)
        cutoff = now - timedelta(days=days)

        if original.get("type") == "tarball":
            m = FLAKEHUB_URL_RE.match(original.get("url", ""))
            if not m:
                results.append((UNSUPPORTED, name,
                                "tarball URL, not FlakeHub — resolve by hand"))
                continue
            try:
                pick = flakehub_release_before(m["org"], m["project"], m["range"], cutoff)
            except ToolError as e:
                results.append((FAILED, name, str(e)))
                continue
            if not pick:
                results.append((FAILED, name,
                                f"no {m['project']} release in range {m['range']} "
                                f"older than {days}d"))
                continue
            ver, when = pick
            # The locked URL embeds the resolved version: .../determinate/3.22.2/<uuid>/…
            cur = re.search(r"/f/pinned/[^/]+/[^/]+/(?P<v>[^/]+)/", locked.get("url", ""))
            cur_ver = cur["v"] if cur else "?"
            if cur_ver == ver:
                results.append((CURRENT, name,
                                f"{ver} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d)"))
            else:
                results.append((COOLED, name,
                                f"{cur_ver} → {ver} ({when:%Y-%m-%d}, "
                                f"{age_days(when, now):.1f}d, {days}d bar)"))
                overrides.append(
                    (name, f"https://flakehub.com/f/{m['org']}/{m['project']}/={ver}"))
            continue

        if original.get("type") != "github":
            results.append((UNSUPPORTED, name,
                            f"type={original.get('type')} — resolve by hand"))
            continue

        owner, repo = original["owner"], original["repo"]

        if original.get("rev"):
            results.append((IMMUTABLE, name, f"rev pin {original['rev'][:9]}"))
            continue

        ref = original.get("ref")
        try:
            if ref:
                if not is_branch(owner, repo, ref, token):
                    results.append((IMMUTABLE, name, f"tag pin {ref}"))
                    continue
                branch = ref
            else:
                branch = default_branch(owner, repo, token)
        except ToolError as e:
            results.append((FAILED, name, str(e)))
            continue

        # Channel branches: no cooldown, take the published head. Gated on the repo
        # actually being nixpkgs so a third-party branch that happens to be named
        # after a channel cannot be mistaken for one.
        if owner.lower() == "nixos" and repo == "nixpkgs":
            head = published_channel_head(branch)
            if head:
                cur_rev = locked.get("rev", "")
                cur_ts = locked.get("lastModified")
                shown = (f"{datetime.fromtimestamp(cur_ts, timezone.utc):%Y-%m-%d}, "
                         f"{age_days(datetime.fromtimestamp(cur_ts, timezone.utc), now):.1f}d"
                         if cur_ts else "?")
                if cur_rev == head:
                    results.append((CHANNEL, name,
                                    f"{branch} head {head[:9]} ({shown}) — Hydra-gated"))
                else:
                    results.append((CHANNEL, name,
                                    f"{cur_rev[:9] or '(none)'} → {branch} head "
                                    f"{head[:9]} — Hydra-gated, no cooldown"))
                    overrides.append((name, f"github:{owner}/{repo}/{head}"))
                continue

        try:
            found = newest_commit_before(owner, repo, branch, cutoff, token)
        except ToolError as e:
            results.append((FAILED, name, str(e)))
            continue

        if not found:
            results.append((FAILED, name,
                            f"no commit on {branch} older than {days}d"))
            continue

        rev, when = found
        age = age_days(when, now)
        cur_rev = locked.get("rev", "")

        if cur_rev == rev:
            results.append((CURRENT, name,
                            f"{branch} @ {rev[:9]} ({when:%Y-%m-%d}, {age:.1f}d)"))
            continue

        cur_ts = locked.get("lastModified")
        cur_age = (age_days(datetime.fromtimestamp(cur_ts, timezone.utc), now)
                   if cur_ts else None)
        direction = "→" if cur_age is None or cur_age > age else "↓"
        detail = (f"{cur_rev[:9] or '(none)'}"
                  f"{f' ({cur_age:.1f}d)' if cur_age is not None else ''} "
                  f"{direction} {rev[:9]} ({when:%Y-%m-%d}, {age:.1f}d, {days}d bar)")
        results.append((COOLED, name, detail))
        overrides.append((name, f"github:{owner}/{repo}/{rev}"))

    # ---- report -----------------------------------------------------------------
    order = [COOLED, CHANNEL, CURRENT, IMMUTABLE, FROZEN, UNSUPPORTED, FAILED]
    label = {COOLED: "TO UPDATE (cooled)", CHANNEL: "channel — Hydra-gated, no cooldown",
             CURRENT: "already current",
             IMMUTABLE: "skipped — immutable pin", FROZEN: "skipped — frozen",
             UNSUPPORTED: "skipped — not a github input", FAILED: "ERROR"}
    width = max((len(n) for _, n, _ in results), default=10)
    for cat in order:
        rows = [(n, d) for c, n, d in results if c == cat]
        if not rows:
            continue
        print(f"\n{label[cat]} ({len(rows)}):")
        for n, d in rows:
            print(f"  {n:<{width}}  {d}")

    counts = {c: sum(1 for x, _, _ in results if x == c) for c in order}
    print(f"\nsummary: {counts[COOLED]} cooled, {counts[CHANNEL]} channel, "
          f"{counts[CURRENT]} current, "
          f"{counts[IMMUTABLE] + counts[FROZEN] + counts[UNSUPPORTED]} skipped, "
          f"{counts[FAILED]} errors  (cooldown {args.days}d"
          + (f", overrides {per_input}" if per_input else "") + ")")

    if counts[FAILED]:
        print("\nrefusing to write flake.lock while an input could not be resolved.",
              file=sys.stderr)
        return 1

    if not overrides:
        print("nothing to do — every mutable input already sits at or behind the bar.")
        return 0

    # One invocation, so the lock is written once and stays internally consistent.
    # A separate `nix flake lock` per input would re-resolve the others in between.
    cmd = ["nix", "flake", "lock", args.flake]
    for n, r in overrides:
        cmd += ["--override-input", n, r]

    if args.dry_run:
        print("\n--dry-run: flake.lock untouched. Would run:")
        print("  " + " ".join(cmd))
        return 0

    print(f"\nlocking {len(overrides)} input(s)…")
    try:
        out = subprocess.run(cmd, text=True, timeout=1800)
    except (OSError, subprocess.SubprocessError) as e:
        raise ToolError(f"`nix flake lock` failed to run: {e}") from e
    if out.returncode != 0:
        print("`nix flake lock` failed — flake.lock may be partially written.",
              file=sys.stderr)
        return 1
    print("done.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
