#!/usr/bin/env python3
"""Supply-chain gate for this flake: adopt nothing that is suspiciously new, and
nothing that upstream has since withdrawn.

Two commands over one set of rules, because a policy that is checked by a different
tool than the one that applies it drifts apart:

    update   resolve every mutable flake input to the newest revision that clears the
             cooldown, and write those revisions into flake.lock   (`just update`)
    audit    report-only, across all four layers below                (`just audit`)

WHY THIS EXISTS. `nix flake update` always jumps every input to the CURRENT head of its
branch. There is no "give me last week's head", so every update adopts code that is
minutes old — precisely the window a supply-chain attack lives in.

Measured 2026-08-22 in this repo: a plain `just update` moved six inputs to a HEAD
committed that same day (home-manager 0.2 days old, worktrunk 0.1, llm-agents 0.3,
determinate 0.6, devenv 0.5, nix-homebrew 0.8) while the ChainDrop/Shai-Hulud npm
campaign was live and still classified active by CSA advisory AD-2026-009. Nothing in
the repo said a word about it.

WHY A COOLDOWN AND NOT A SCANNER. The poisoned ChainDrop tarballs carried VALID npm
provenance and SLSA L3 attestations, signed by GitHub Actions through Sigstore — every
cryptographic check passed, because the source was trojanized before the build ran. A
vulnerability scanner returns "clean" for exactly as long as it matters. Age is the one
signal an attacker cannot forge cheaply: a malicious release is usually pulled within
hours to days, so declining to be the first consumer converts most of these incidents
into a non-event. modules/supply-chain-hardening.nix already applies this to npm, pnpm,
bun and uv; this closes the same gap one level up.

THE SECOND RULE, WHICH A COOLDOWN ALONE MISSES: still there?
A withdrawn artifact is the strongest signal available, because it is emitted by the
ecosystem *after* someone found the problem. Age cannot express it — a malicious
version that was pulled yesterday is still "old enough" tomorrow. So every layer here
checks presence as well as age:

    layer 1  FlakeHub `yanked_at`; a git rev that no longer resolves
    layer 2  npm `unpublished` / a version missing from the registry's `time` map;
             a GitHub release that 404s, or has become a draft or pre-release
    layer 3  a VS Code extension that 404s, is deprecated, or whose chosen version has
             been removed from `allVersions` while the extension itself survives

That is not hypothetical: on the first real run, layer 1 rejected determinate 3.22.0 —
comfortably old enough at 15 days, and yanked on 2026-08-17.

FOUR LAYERS.
    1 flake inputs      github branches, github tags, FlakeHub semver ranges
    2 tracked packages  a hand-kept list dated against npm or GitHub releases; a
                        flake input's age bounds its contents only from below,
                        and loosely
    3 VS Code extensions  Open VSX / MS Marketplace, cooldown + still-exists
    4 hand-bumped pins  version strings no tool moves (a Nix module, a script header):
                        read from the file that carries them, compared with upstream

MECHANISM (layer 1). `nix flake lock --override-input <name> github:<o>/<r>/<rev>`
writes the explicit rev into flake.lock while leaving flake.nix untouched: `original`
stays plain branch-tracking, only `locked` carries the older rev. Verified 2026-08-22
against Determinate Nix 3.21.9 / Nix 2.34.8.

    original: {"owner": "NotAShelf", "repo": "nvf", "type": "github"}
    locked:   {... "rev": "b05fadedb5e8510ed5dd07fce5364f36fc359dac" ...}

The consequence, and the reason this must be wired into `just update`: because
`original` stays branch-tracking, a BARE `nix flake update` silently discards the
cooldown and goes back to HEAD. `just update` is the only update path that honours it,
exactly as `just switch` is the only supported apply path.

INPUT CLASSIFICATION, subtler than it looks. A GitHub input's `ref` may be a branch or
a tag, and the two need opposite treatment:

    ref is a BRANCH   nixpkgs (nixos-26.05), nixpkgs-unstable (nixos-unstable),
                      home-manager (release-26.05), darwin (nix-darwin-26.05)
                      -> mutable, `nix flake update` moves it, needs a cooldown
    ref is a TAG      yt-dlp-src (2026.07.04), brew-src (6.0.17),
                      agent-browser-src (v0.33.2)
                      -> immutable, `nix flake update` does NOT move it, skip
    no ref at all     devenv, nvf, sops-nix, worktrunk, ...
                      -> tracks the default branch, needs a cooldown

Guessing from the string does not work (`6.0.17` and `release-26.05` are both plausible
either way), so each `ref` is resolved against the GitHub branches endpoint.

AND THE DATE IS ATTACKER-SETTABLE. State this plainly rather than discover it later:
the committer date this tool sorts by is chosen by whoever makes the commit. Measured
2026-08-22 -- `GIT_COMMITTER_DATE=2019-01-01 git commit` produces an input that this
tool reports as 2790 days old. Anyone who controls the upstream repository can walk
straight through the bar, and the same holds one level down: registry.npmjs.org's
`time` map and the marketplaces' timestamps are supplied by the party being audited.

That is not a reason to drop the cooldown, but it defines what it is FOR. It defends
against the common shape of these incidents -- a compromised account publishes, the
release is live for hours, someone notices, it gets pulled -- because refusing to be an
early consumer removes you from the blast radius. It does NOT defend against a patient
attacker who already owns the repo. Nothing here does.

Stdlib only, deliberately, for the same reason infra/scripts/osv-audit.py is: a tool
whose job is to keep untrusted code out has no business installing any to run. `gh` is
consulted for an API token if it happens to be authenticated, purely to lift the rate
limit from 60 to 5000 requests/hour; everything works without it.

Exit codes: 0 nothing to do / all clear, 1 action needed or findings, 2 tool error.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

GITHUB_API = "https://api.github.com"
NPM_REGISTRY = "https://registry.npmjs.org"
OPENVSX_API = "https://open-vsx.org/api"
VSMARKETPLACE_QUERY = ("https://marketplace.visualstudio.com/_apis/public/gallery/"
                       "extensionquery")
UA = "supply-chain (nix-darwin config)"
MANIFEST = Path(__file__).with_suffix(".toml")

# Categories, kept distinct on purpose. docs/scripting.md: "Classify every item as SUCCESS,
# SKIP, ERROR or CLEANUP, and never collapse two of them. A skip is not a failure."
COOLED = "cooled"        # moved to an older-but-fresh-enough rev       (SUCCESS)
CURRENT = "current"      # already at the right rev, nothing to do      (SUCCESS)
HELD_NEWER = "held_newer"  # bar's pick is OLDER than the lock — see below (SKIP)
CHANNEL = "channel"      # Hydra-gated channel head — see below         (SUCCESS)
OK = "ok"                # audit: clears the bar and still exists       (SUCCESS)
TOO_NEW = "too_new"      # audit: younger than the bar                  (FINDING)
WITHDRAWN = "withdrawn"  # yanked / unpublished / 404 / deprecated      (FINDING)
PIN_BEHIND = "pin_behind"  # audit: hard-pinned, upstream has a newer   (FINDING)
                            # release — review before bumping the pin
PIN_HELD = "pin_held"    # audit: newer release exists, held on purpose  (SKIP)
IMMUTABLE ="immutable"  # tag/rev pin — flake update cannot move it    (SKIP)
FROZEN = "frozen"        # explicitly excluded by the manifest          (SKIP)
UNSUPPORTED = "unsupported"  # not a datable input type                 (SKIP)
FAILED = "failed"        # lookup or lock error                         (ERROR)

FINDING_CATEGORIES = {TOO_NEW, WITHDRAWN, PIN_BEHIND}

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
# So the soak already exists here; it is just spelled "Hydra" instead of "days".
CHANNEL_STATUS_URL = "https://channels.nixos.org/{ref}/git-revision"

# FlakeHub inputs are tarball URLs carrying a semver RANGE, e.g.
#   https://flakehub.com/f/DeterminateSystems/determinate/3
# which re-resolves to the newest matching release on every lock. For `determinate` that
# is the root nix-daemon, so a floating range there defeats every cooldown the repo has:
# measured 2026-08-22, a plain `just update` moved it 3.21.8 -> 3.22.2, published 0.7
# days earlier. One request to the releases endpoint returns version, published_at and
# yanked_at for all of them, so this is cheap to do properly.
FLAKEHUB_URL_RE = re.compile(
    r"^https://(?:api\.)?flakehub\.com/f/(?P<org>[^/]+)/(?P<project>[^/]+)/"
    r"(?P<range>[^/?#]+?)(?:\.tar\.gz)?/?$")
FLAKEHUB_RELEASES = "https://api.flakehub.com/f/{org}/{project}/releases"


class ToolError(Exception):
    """Unrecoverable: network down, gh broken, nix missing. Exit 2, not 1."""


# --------------------------------------------------------------------------- helpers

def http_json(url: str, token: str | None = None, *, data: bytes | None = None,
              headers: dict[str, str] | None = None) -> tuple[int, object]:
    """GET/POST url, return (status, parsed-json). 404 is a normal answer here — an
    extension that no longer exists is the single most useful thing this tool can
    learn, so it must not be raised as an error."""
    hdrs = {"Accept": "application/json", "User-Agent": UA}
    if token:
        hdrs["Authorization"] = f"Bearer {token}"
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (403, 429) and e.headers.get("x-ratelimit-remaining") == "0":
            raise ToolError(
                "GitHub API rate limit exhausted. Authenticate with `gh auth login` "
                "to raise it from 60 to 5000 requests/hour.") from e
        if e.code in (404, 410):
            return e.code, None
        raise ToolError(f"HTTP {e.code} for {url}: {e.reason}") from e
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        raise ToolError(f"cannot reach {url}: {e}") from e


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


def load_manifest() -> dict:
    try:
        with open(MANIFEST, "rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        raise ToolError(f"manifest not found: {MANIFEST}")
    except tomllib.TOMLDecodeError as e:
        raise ToolError(f"manifest {MANIFEST} is not valid TOML: {e}")


def flake_metadata(flake: str) -> dict:
    try:
        out = subprocess.run(["nix", "flake", "metadata", "--json", flake],
                             capture_output=True, text=True, timeout=600)
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


def age_days(ts: datetime, now: datetime) -> float:
    return (now - ts).total_seconds() / 86400.0


def iso(raw: str) -> datetime:
    """Parse the several ISO-8601 flavours these APIs emit, all UTC.
    npm:      2026-08-17T21:11:43.123Z      FlakeHub: …T19:50:30.197310Z
    GitHub:   2026-08-17T10:56:16Z          OpenVSX:  …T00:42:25.994032Z
    """
    return datetime.strptime(raw[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


# ------------------------------------------------------------------- layer 1: inputs

def published_channel_head(ref: str) -> str | None:
    """The revision channels.nixos.org currently publishes for `ref`, or None if `ref`
    is not a channel. Never raises: a channel lookup that cannot be made is answered
    "not a channel", which only costs a cooldown."""
    req = urllib.request.Request(CHANNEL_STATUS_URL.format(ref=urllib.parse.quote(ref)),
                                 headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            rev = r.read().decode().strip()
    except (urllib.error.URLError, OSError, UnicodeDecodeError):
        return None
    return rev if re.fullmatch(r"[0-9a-f]{40}", rev) else None


def is_branch(owner: str, repo: str, ref: str, token: str | None) -> bool:
    status, _ = http_json(f"{GITHUB_API}/repos/{owner}/{repo}/branches/"
                          f"{urllib.parse.quote(ref)}", token)
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
    return c["sha"], iso(c["commit"]["committer"]["date"])


def flakehub_release_table(org: str, project: str) -> dict[str, tuple[datetime, bool]]:
    """{version: (published_at, is_yanked)} for every release of org/project.

    One request for the whole table, so the pick and the age of the currently locked
    version come from the same fetch and cannot disagree.
    """
    status, releases = http_json(FLAKEHUB_RELEASES.format(org=org, project=project))
    if status != 200 or not isinstance(releases, list):
        raise ToolError(f"cannot list FlakeHub releases for {org}/{project}")
    table: dict[str, tuple[datetime, bool]] = {}
    for rel in releases:
        ver, raw = rel.get("version"), rel.get("published_at")
        if ver and raw:
            table[ver] = (iso(raw), bool(rel.get("yanked_at")))
    return table


def flakehub_pick(table: dict[str, tuple[datetime, bool]], semver_range: str,
                  cutoff: datetime) -> tuple[str, datetime, int] | None:
    """Newest non-yanked release matching `semver_range` published at or before cutoff.
    Returns (version, published_at, n_skipped_yanked).

    Only a bare major ("3") or a full version is understood, which covers every
    FlakeHub input this repo has. A range this cannot parse returns None rather than
    guessing — an unresolved input is reported, never silently left floating.
    """
    if not re.fullmatch(r"\d+(\.\d+){0,2}", semver_range):
        return None
    prefix = semver_range + "."
    best: tuple[str, datetime, int] | None = None
    yanked = 0
    for ver, (when, is_yanked) in table.items():
        if not (ver == semver_range or ver.startswith(prefix)):
            continue
        if when > cutoff:
            continue
        if is_yanked:
            yanked += 1
            continue
        if best is None or when > best[1]:
            best = (ver, when, 0)
    return (best[0], best[1], yanked) if best else None


# ----------------------------------------------------------------- layer 2: packages

def flake_ref_for_eval(flake: str) -> str:
    """`builtins.getFlake` refuses a relative path, so "." — the default and the only
    thing `just audit` ever passes — has to become an absolute flake ref first."""
    if "://" in flake or flake.startswith("github:"):
        return flake
    return "git+file://" + str(Path(flake).resolve())


def eval_package_version(flake: str, input_name: str, attr: str) -> str | None:
    """Version of <input>.packages.<currentSystem>.<attr>, by pure evaluation."""
    expr = (f'let f = builtins.getFlake "{flake_ref_for_eval(flake)}"; '
            f'in f.inputs."{input_name}".packages.${{builtins.currentSystem}}.'
            f'"{attr}".version')
    try:
        out = subprocess.run(["nix", "eval", "--impure", "--raw", "--expr", expr],
                             capture_output=True, text=True, timeout=900)
    except (OSError, subprocess.SubprocessError) as e:
        raise ToolError(f"cannot run `nix eval` for {input_name}.{attr}: {e}") from e
    return out.stdout.strip() if out.returncode == 0 else None


def npm_version_status(pkg: str, version: str) -> tuple[datetime | None, str | None]:
    """(published_at, problem). problem is a string when the version is gone or the
    package has been unpublished — the "still there?" half of the policy."""
    status, body = http_json(f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='@')}")
    if status in (404, 410) or not isinstance(body, dict):
        return None, f"npm package {pkg} no longer resolves (HTTP {status})"
    times = body.get("time", {})
    if "unpublished" in times:
        return None, f"npm package {pkg} has been UNPUBLISHED"
    raw = times.get(version)
    if not raw:
        return None, (f"version {version} is absent from the npm registry — withdrawn, "
                      f"or never published under this name")
    return iso(raw), None


def github_release_status(repo: str, version: str, token: str | None
                          ) -> tuple[datetime | None, str | None]:
    """(published_at, problem) for the GitHub release tagged exactly `version`.

    For packages that never touch a registry — antigravity-cli is a tarball off
    Google Cloud Storage — the vendor's GitHub releases are the only dated, listed
    record of what was published. The tag is the bare version string: no `v`
    guessing, because a wrong guess would report a real release as withdrawn.

    Same caveat as npm's `time` map: `published_at` is set by the party being
    audited, so this dates the release, it does not vouch for it.
    """
    status, rel = http_json(f"{GITHUB_API}/repos/{repo}/releases/tags/"
                            f"{urllib.parse.quote(version)}", token)
    if status in (404, 410) or not isinstance(rel, dict):
        # GitHub answers 404 alike for a missing release, a deleted repository and
        # one turned private. One extra request, on the failure path only, keeps
        # the diagnostic from sending someone to look for a tag in a repository
        # that is not there.
        repo_status, _ = http_json(f"{GITHUB_API}/repos/{repo}", token)
        if repo_status in (404, 410):
            return None, (f"repository github.com/{repo} no longer resolves "
                          f"(HTTP {repo_status}) — deleted, renamed without redirect, "
                          f"or private")
        return None, (f"no release under tag {version} on github.com/{repo} — "
                      f"withdrawn, or never published under this name")
    if rel.get("draft"):
        return None, f"release {version} on github.com/{repo} is a DRAFT"
    if rel.get("prerelease"):
        return None, f"release {version} on github.com/{repo} is flagged pre-release"
    raw = rel.get("published_at")
    if not raw:
        return None, f"release {version} on github.com/{repo} carries no published_at"
    return iso(raw), None


# --------------------------------------------------------------- layer 3: extensions

def openvsx_pick(namespace: str, name: str, cutoff: datetime
                 ) -> tuple[str, datetime, list[str]]:
    """Newest Open VSX version of namespace.name that is <= cutoff AND still listed.

    Raises ToolError with a precise reason when the extension itself is gone; that is
    the evil-twin signal and must never be softened into "no suitable version".
    """
    status, meta = http_json(f"{OPENVSX_API}/{namespace}/{name}")
    if status in (404, 410) or not isinstance(meta, dict):
        raise ToolError(f"extension {namespace}.{name} does NOT exist on Open VSX "
                        f"(HTTP {status}) — withdrawn, renamed, or never published")
    notes: list[str] = []
    if meta.get("deprecated"):
        raise ToolError(f"extension {namespace}.{name} is marked DEPRECATED upstream")
    if meta.get("verified") is False:
        notes.append("namespace NOT verified")

    # `allVersions` is ordered newest-first, but its first entries are ALIASES, not
    # versions: measured 2026-08-22, rust-lang.rust-analyzer yields
    #   ['latest', 'pre-release', '0.4.3022', '0.4.3021', …]
    # Both aliases resolve to a real manifest, so a naive walk happily "finds" one and
    # would return the literal string "latest" as the version to pin — a floating
    # pointer, i.e. precisely the thing this tool exists to prevent. Keep only keys that
    # begin with a digit.
    listed = [v for v in (meta.get("allVersions") or {}) if v[:1].isdigit()]
    if not listed:
        raise ToolError(f"extension {namespace}.{name} lists no concrete versions "
                        f"(only aliases) — treat as withdrawn")

    # Walk newest-first and stop at the first version that is old enough. Only versions
    # still present in allVersions are considered, so a version withdrawn after
    # publication is skipped even though its date would qualify.
    #
    # The walk is capped because Open VSX costs one request per version and some
    # extensions ship nightlies — rust-analyzer lists 102 versions here, of 1535 total.
    # The cap is REPORTED rather than silent: a bounded search that says "no suitable
    # version" without saying how far it looked is indistinguishable from a real
    # absence, and this tool's whole job is to tell those two apart.
    cap = 40
    inspected = 0
    prerelease = 0
    unfetchable = 0
    oldest_seen: datetime | None = None
    for ver in listed[:cap]:
        inspected += 1
        status, v = http_json(f"{OPENVSX_API}/{namespace}/{name}/"
                              f"{urllib.parse.quote(ver)}")
        if status != 200 or not isinstance(v, dict):
            unfetchable += 1
            continue
        raw = v.get("timestamp")
        if not raw:
            continue
        when = iso(raw)
        if oldest_seen is None or when < oldest_seen:
            oldest_seen = when
        if when > cutoff:
            continue
        if v.get("preRelease"):
            prerelease += 1
            continue
        if v.get("downloadable") is False:
            notes.append(f"{ver}: skipped, not downloadable")
            continue
        if prerelease:
            notes.append(f"{prerelease} pre-release version(s) skipped")
        if unfetchable:
            notes.append(f"{unfetchable} listed but unfetchable — treated as withdrawn")
        return ver, when, notes

    where = (f"inspected {inspected} of {len(listed)} listed versions"
             + (f" (capped at {cap})" if len(listed) > cap else ""))
    oldest = f", walked back to {oldest_seen:%Y-%m-%d}" if oldest_seen else ""
    raise ToolError(
        f"no Open VSX version of {namespace}.{name} is both old enough and still "
        f"listed — {where}{oldest}; {prerelease} were pre-releases, {unfetchable} "
        f"were unfetchable. If this extension ships nightlies, the stable channel may "
        f"sit beyond the cap.")


def vsmarketplace_extension(namespace: str, name: str) -> dict:
    """The raw gallery record for namespace.name (every version, with properties and
    statistics). Raises ToolError when the extension itself is gone (rule 1)."""
    # flags = IncludeVersions(1) | IncludeFiles(2) | IncludeCategoryAndTags(16)
    #       | IncludeVersionProperties(32) | IncludeAssetUri(128) | IncludeStatistics(256)
    #
    # NOT IncludeLatestVersionOnly(512), which is what this asked for until 2026-08-26
    # (flags=947) — and that made the walk below dead code: the response carried exactly
    # one version, so any extension whose newest release sat inside the cooldown was
    # reported TOO NEW even when a qualifying older version existed. Found the day
    # [[extensions]] was first populated; ms-azuretools.vscode-containers failed on its
    # 2.5.0 (1 day old) while 2.4.5 from 2026-05-29 was right there. Measured after the
    # fix: 14 versions returned for that extension, 1488 for eamodio.gitlens — the whole
    # list arrives in ONE request, unlike Open VSX which costs one request per version
    # and is therefore capped at 40.
    payload = json.dumps({
        "filters": [{"criteria": [{"filterType": 7, "value": f"{namespace}.{name}"}],
                     "pageSize": 1, "pageNumber": 1}],
        "flags": 435,
    }).encode()
    status, body = http_json(
        VSMARKETPLACE_QUERY, data=payload,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json;api-version=7.2-preview.1"})
    if status != 200 or not isinstance(body, dict):
        raise ToolError(f"marketplace query failed for {namespace}.{name}")
    results = (body.get("results") or [{}])[0].get("extensions") or []
    if not results:
        raise ToolError(f"extension {namespace}.{name} does NOT exist on the VS Code "
                        f"Marketplace — withdrawn, renamed, or never published")
    return results[0]


def vsmarketplace_versions(namespace: str, name: str) -> tuple[dict[str, datetime], list[str]]:
    """All non-prerelease, deduped {version: lastUpdated} for namespace.name on the MS
    Marketplace. Caller decides what to do with the set — vsmarketplace_pick walks it
    newest-first for the cooldown bar; check_extension's `pin` path looks up one entry
    directly. Raises ToolError only when the extension itself is gone (rule 1)."""
    ext = vsmarketplace_extension(namespace, name)
    notes: list[str] = []
    if not (ext.get("publisher") or {}).get("isDomainVerified"):
        notes.append("publisher domain NOT verified")

    # Rule 4 says non-prerelease, and openvsx_pick has always honoured it via the
    # `preRelease` field. The marketplace states it as a version PROPERTY instead, which
    # is why IncludeVersionProperties(32) is in the flags above. Without this filter the
    # nightly channel wins outright for anything that ships one: measured 2026-08-26,
    # 1141 of eamodio.gitlens's 1488 listed versions are pre-releases, and the newest
    # release build (18.3.0) sits far below them.
    prerelease = 0
    seen: dict[str, datetime] = {}
    for v in ext.get("versions") or []:
        ver, raw = v.get("version"), v.get("lastUpdated")
        if not (ver and raw) or ver in seen:
            continue
        if any(prop.get("key") == "Microsoft.VisualStudio.Code.PreRelease"
               for prop in (v.get("properties") or [])):
            prerelease += 1
            continue
        seen[ver] = iso(raw)
    if prerelease:
        notes.append(f"{prerelease} pre-release version(s) skipped")
    return seen, notes


def vsmarketplace_pick(namespace: str, name: str, cutoff: datetime
                       ) -> tuple[str, datetime, list[str]]:
    """Same policy against the MS Marketplace gallery API: newest release version that
    clears the cooldown."""
    seen, notes = vsmarketplace_versions(namespace, name)
    for ver, when in sorted(seen.items(), key=lambda kv: kv[1], reverse=True):
        if when <= cutoff:
            return ver, when, notes
    raise ToolError(f"no Marketplace version of {namespace}.{name} is old enough "
                    f"(newest {len(seen)} release versions are all inside the cooldown)")


def check_extension(ext_id: str, registry: str, cutoff: datetime, now: datetime,
                    pin: str | None = None) -> tuple[str, str, str]:
    """-> (category, ext_id, detail).

    Without `pin` (the common case): resolve the newest version that clears the cooldown
    and is still listed — the openvsx_pick / vsmarketplace_pick walk.

    With `pin` (lucax88x.codeacejumper, see modules/vscode.nix): the version is fixed
    elsewhere by a Nix hash pin, so this asks a different question about that ONE fixed
    version — still listed (rules 1/3), still old enough (rule 2: a hand-bumped pin gets
    no exemption from the cooldown), and not itself behind a newer non-prerelease release
    upstream. That last case is new — PIN_BEHIND — and it is the point of pinning: a
    newer release must be reviewed and adopted by a human editing both the hash and the
    `pin` field, never absorbed silently the way the cooldown walk absorbs one.
    """
    if "." not in ext_id:
        return FAILED, ext_id, "id must be <namespace>.<name>"
    namespace, name = ext_id.split(".", 1)

    if pin is not None:
        if registry != "vscode-marketplace":
            return FAILED, ext_id, (
                f'pin = "{pin}" is only implemented for registry = "vscode-marketplace" '
                f'(got "{registry}") — no extension has needed an Open VSX hard pin yet')
        try:
            seen, notes = vsmarketplace_versions(namespace, name)
        except ToolError as e:
            return WITHDRAWN, ext_id, str(e)
        if pin not in seen:
            return WITHDRAWN, ext_id, (f"pinned {pin} is no longer listed on the "
                                       f"Marketplace — withdrawn or renamed")
        when = seen[pin]
        if when > cutoff:
            return TOO_NEW, ext_id, (
                f"pinned {pin} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d) is younger "
                f"than the {(now - cutoff).days}d bar")
        newer = {v: w for v, w in seen.items() if w > when}
        if newer:
            latest_ver, latest_when = max(newer.items(), key=lambda kv: kv[1])
            return PIN_BEHIND, ext_id, (
                f"pinned {pin} ({when:%Y-%m-%d}) — upstream has {latest_ver} "
                f"({latest_when:%Y-%m-%d}, {age_days(latest_when, now):.1f}d); review "
                f"before bumping the pin")
        detail = (f"pinned {pin} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d) is the "
                  f"newest release and still listed")
        if notes:
            detail += "  [" + "; ".join(notes) + "]"
        return OK, ext_id, detail

    pick = openvsx_pick if registry == "open-vsx" else vsmarketplace_pick
    try:
        ver, when, notes = pick(namespace, name, cutoff)
    except ToolError as e:
        msg = str(e)
        cat = WITHDRAWN if ("does NOT exist" in msg or "DEPRECATED" in msg) else TOO_NEW
        return cat, ext_id, msg
    detail = f"{ver} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d) via {registry}"
    if notes:
        detail += "  [" + "; ".join(notes) + "]"
    return OK, ext_id, detail


# ------------------------------------------------------ layer 4: hand-bumped pins

class PinWithdrawn(Exception):
    """The pinned version is gone from its registry — a finding, not a tool error."""


def pin_current_version(root: Path, pin: dict) -> str:
    """The version the repo ACTUALLY pins, read out of the file that carries it.

    Never copied into the manifest: a second copy of the fact is a copy that drifts,
    and an audit comparing upstream against a stale copy reports "current" for a pin
    that was bumped or reverted by hand. A pattern that stops matching is FAILED,
    not skipped — a filter that cannot match reads the same as a clean result.
    """
    rel, pattern = pin.get("file"), pin.get("match")
    if not rel or not pattern:
        raise ToolError("manifest entry needs `file` and `match`")
    try:
        text = (root / rel).read_text()
    except OSError as e:
        raise ToolError(f"cannot read {rel}: {e}") from e
    try:
        m = re.search(pattern, text, re.M)
    except re.error as e:
        raise ToolError(f"`match` is not a valid regex: {e}") from e
    if not m or not m.groupdict().get("v"):
        raise ToolError(f"`match` found no version in {rel} — pattern drift? "
                        f"(it needs a named group `v`)")
    return m.group("v")


def pin_releases(pin: dict, token: str | None
                 ) -> tuple[dict[str, tuple[datetime, bool]], bool]:
    """-> ({version: (published_at, is_prerelease)}, listing_is_complete).

    `complete` decides what a missing version means. npm and PyPI list every version
    ever published, so absence is a withdrawal. The GitHub list is a window of the
    newest 100 releases, so absence there proves nothing and is asked again by tag.
    """
    src = pin.get("source")
    rels: dict[str, tuple[datetime, bool]] = {}
    if src == "github":
        repo, prefix = pin["repo"], pin.get("tag_prefix", "")
        status, data = http_json(f"{GITHUB_API}/repos/{repo}/releases?per_page=100", token)
        if status != 200 or not isinstance(data, list):
            raise ToolError(f"cannot list releases of github.com/{repo} (HTTP {status})")
        for r in data:
            tag = r.get("tag_name") or ""
            if r.get("draft") or not r.get("published_at") or not tag.startswith(prefix):
                continue
            rels[tag[len(prefix):]] = (iso(r["published_at"]), bool(r.get("prerelease")))
        return rels, False
    if src == "npm":
        pkg = pin["package"]
        status, body = http_json(f"{NPM_REGISTRY}/{urllib.parse.quote(pkg, safe='@')}")
        if status in (404, 410) or not isinstance(body, dict):
            raise PinWithdrawn(f"npm package {pkg} no longer resolves (HTTP {status})")
        times = body.get("time", {})
        if "unpublished" in times:
            raise PinWithdrawn(f"npm package {pkg} has been UNPUBLISHED")
        for v, raw in times.items():
            if v not in ("created", "modified"):
                rels[v] = (iso(raw), "-" in v)
        return rels, True
    if src == "pypi":
        pkg = pin["package"]
        status, body = http_json(f"https://pypi.org/pypi/{pkg}/json")
        if status in (404, 410) or not isinstance(body, dict):
            raise PinWithdrawn(f"PyPI project {pkg} no longer resolves (HTTP {status})")
        for v, files in body.get("releases", {}).items():
            live = [f for f in files if not f.get("yanked")]
            if live:   # a release with no live file is yanked or empty: not a candidate
                rels[v] = (min(iso(f["upload_time_iso_8601"]) for f in live),
                           re.search(r"[A-Za-z]", v) is not None)
        return rels, True
    raise ToolError(f"unknown source {src!r} (expected github, npm or pypi)")


def check_pin(pin: dict, root: Path, manifest: dict, now: datetime,
              token: str | None) -> tuple[str, str, str]:
    """-> (category, name, detail) for one hand-bumped version pin.

    The question is the one layer 2 cannot ask: not "is what the input ships old
    enough" but "has upstream moved past what a human pinned, and has that newer
    release cleared the bar". A pin never moves by itself, so a pin that is behind is
    silent unless something reports it — that is this layer.

    `hold = "<reason>"` marks a pin whose newer release exists but cannot be adopted
    for a real technical reason (a toolchain too old, a lockstep coupling). It is
    still reported, as a SKIP, so the reason stays in front of whoever reads the
    audit, but it does not make the run red every week.
    """
    name = pin.get("name", "?")
    try:
        cur = pin_current_version(root, pin)
        rels, complete = pin_releases(pin, token)
    except PinWithdrawn as e:
        return WITHDRAWN, name, str(e)
    except ToolError as e:
        return FAILED, name, str(e)

    bar = pin.get("bar", "packages")
    days = manifest["cooldown"][bar] if isinstance(bar, str) else bar
    cutoff = now - timedelta(days=days)
    prefix, allow_pre = pin.get("prefix", ""), pin.get("prereleases", False)

    if cur not in rels:
        if complete:
            return WITHDRAWN, name, (f"{cur} is no longer published — withdrawn, or "
                                     f"never published under this name")
        # The GitHub window is only the newest 100; ask for exactly this tag.
        repo, tag = pin["repo"], pin.get("tag_prefix", "") + cur
        status, rel = http_json(f"{GITHUB_API}/repos/{repo}/releases/tags/"
                                f"{urllib.parse.quote(tag)}", token)
        if status in (404, 410) or not isinstance(rel, dict) or not rel.get("published_at"):
            return WITHDRAWN, name, (f"no release under tag {tag} on github.com/{repo} — "
                                     f"withdrawn, or never published under this name")
        rels[cur] = (iso(rel["published_at"]), bool(rel.get("prerelease")))
    when = rels[cur][0]

    if when > cutoff:
        return TOO_NEW, name, (f"pinned {cur} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d) "
                               f"is younger than the {days}d bar")

    newer = {v: w for v, (w, pre) in rels.items()
             if w > when and v != cur and v.startswith(prefix) and (allow_pre or not pre)}
    cleared = {v: w for v, w in newer.items() if w <= cutoff}
    waiting = sorted(((v, w) for v, w in newer.items() if w > cutoff), key=lambda x: x[1])

    if cleared:
        v, w = max(cleared.items(), key=lambda kv: kv[1])
        detail = (f"{cur} -> {v} ({w:%Y-%m-%d}, {age_days(w, now):.1f}d, {days}d bar)")
        if pin.get("hold"):
            return PIN_HELD, name, f"{detail}; held: {pin['hold']}"
        if pin.get("note"):
            detail += f"; {pin['note']}"
        return PIN_BEHIND, name, detail

    detail = (f"{cur} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d) is the newest "
              f"release past the {days}d bar")
    if waiting:
        detail += "; newer but inside the bar: " + ", ".join(
            f"{v} ({age_days(w, now):.1f}d)" for v, w in waiting[-3:])
    return CURRENT, name, detail


# ---------------------------------------------------------------------------- render

LABEL = {
    COOLED: "TO UPDATE (cooled)",
    CHANNEL: "channel — Hydra-gated, no cooldown",
    CURRENT: "already current",
    HELD_NEWER: "held — locked rev is newer than the bar's pick",
    OK: "ok — old enough and still published",
    TOO_NEW: "TOO NEW — inside the cooldown",
    WITHDRAWN: "WITHDRAWN UPSTREAM",
    PIN_BEHIND: "PINNED — upstream published a newer version; review before bumping",
    PIN_HELD: "held — a newer release exists but is deliberately not adopted",
    IMMUTABLE: "skipped — immutable pin",
    FROZEN: "skipped — frozen",
    UNSUPPORTED: "skipped — cannot be dated",
    FAILED: "ERROR",
}
ORDER = [WITHDRAWN, PIN_BEHIND, TOO_NEW, COOLED, CHANNEL, OK, CURRENT, HELD_NEWER,
         PIN_HELD, IMMUTABLE, FROZEN, UNSUPPORTED, FAILED]


def render(title: str, results: list[tuple[str, str, str]]) -> dict[str, int]:
    if not results:
        return {}
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")
    width = max(len(n) for _, n, _ in results)
    for cat in ORDER:
        rows = [(n, d) for c, n, d in results if c == cat]
        if not rows:
            continue
        print(f"\n{LABEL[cat]} ({len(rows)}):")
        for n, d in rows:
            print(f"  {n:<{width}}  {d}")
    return {c: sum(1 for x, _, _ in results if x == c) for c in ORDER}


# ------------------------------------------------------------------------------ main

def resolve_inputs(args, manifest, now, token, *, for_update: bool
                   ) -> tuple[list[tuple[str, str, str]], list[tuple[str, str]]]:
    cooldown = manifest.get("cooldown", {})
    days_default = args.days if args.days is not None else cooldown.get("inputs", 5)
    # An explicit --days on the command line is a deliberate override of the whole
    # policy, so it beats the per-input table too; otherwise the table wins.
    per_input = {} if args.days is not None else dict(cooldown.get("per_input", {}))
    frozen = set(manifest.get("freeze", {}).get("inputs", [])) | set(args.freeze)
    only = set(args.only)

    meta = flake_metadata(args.flake)
    inputs = root_inputs(meta)
    results: list[tuple[str, str, str]] = []
    overrides: list[tuple[str, str]] = []

    for name in sorted(inputs):
        node = inputs[name]
        original, locked = node.get("original", {}), node.get("locked", {})

        if only and name not in only:
            continue
        if name in frozen and not only:
            ts = locked.get("lastModified")
            when = datetime.fromtimestamp(ts, timezone.utc) if ts else None
            d = f"held at {(locked.get('rev') or '?')[:9]}"
            if when:
                d += f" ({when:%Y-%m-%d}, {age_days(when, now):.1f}d)"
            results.append((FROZEN, name, d))
            continue

        days = per_input.get(name, days_default)
        cutoff = now - timedelta(days=days)

        if original.get("type") == "tarball":
            m = FLAKEHUB_URL_RE.match(original.get("url", ""))
            if not m:
                results.append((UNSUPPORTED, name,
                                "tarball URL, not FlakeHub — resolve by hand"))
                continue
            try:
                table = flakehub_release_table(m["org"], m["project"])
            except ToolError as e:
                results.append((FAILED, name, str(e)))
                continue
            pick = flakehub_pick(table, m["range"], cutoff)
            if not pick:
                results.append((FAILED, name, f"no {m['project']} release in range "
                                              f"{m['range']} older than {days}d"))
                continue
            ver, when, yanked = pick
            cur = re.search(r"/f/pinned/[^/]+/[^/]+/(?P<v>[^/]+)/", locked.get("url", ""))
            cur_ver = cur["v"] if cur else "?"
            extra = f", {yanked} yanked skipped" if yanked else ""

            if not for_update:
                # Same rule as the github path: judge what is LOCKED. A yanked locked
                # version is the strongest finding available here — the ecosystem
                # withdrew it after the fact, which no date could have told us.
                cur_when, cur_yanked = table.get(cur_ver, (None, False))
                if cur_yanked:
                    results.append((WITHDRAWN, name,
                                    f"locked {cur_ver} has been YANKED upstream"))
                elif cur_when is None:
                    results.append((WITHDRAWN, name,
                                    f"locked {cur_ver} is no longer listed on FlakeHub"))
                elif age_days(cur_when, now) < days:
                    results.append((TOO_NEW, name,
                                    f"locked {cur_ver} is {age_days(cur_when, now):.1f}d "
                                    f"old — inside the {days}d bar"))
                else:
                    note = "" if cur_ver == ver else f"; {ver} available"
                    results.append((OK, name,
                                    f"locked {cur_ver} ({age_days(cur_when, now):.1f}d, "
                                    f"{days}d bar{extra}){note}"))
                continue

            if cur_ver == ver:
                results.append((CURRENT, name,
                                f"{ver} ({when:%Y-%m-%d}, {age_days(when, now):.1f}d"
                                f"{extra})"))
            else:
                results.append((COOLED, name,
                                f"{cur_ver} → {ver} ({when:%Y-%m-%d}, "
                                f"{age_days(when, now):.1f}d, {days}d bar{extra})"))
                overrides.append((name,
                                  f"https://flakehub.com/f/{m['org']}/{m['project']}/={ver}"))
            continue

        if original.get("type") != "github":
            results.append((UNSUPPORTED, name,
                            f"type={original.get('type')} — no date in flake.lock"))
            continue

        owner, repo = original["owner"], original["repo"]
        if original.get("rev"):
            results.append((IMMUTABLE, name, f"rev pin {original['rev'][:9]}"))
            continue

        ref = original.get("ref")
        try:
            if ref:
                if not is_branch(owner, repo, ref, token):
                    ts = locked.get("lastModified")
                    when = datetime.fromtimestamp(ts, timezone.utc) if ts else None
                    d = f"tag pin {ref}"
                    if when:
                        d += f" ({when:%Y-%m-%d}, {age_days(when, now):.1f}d)"
                    results.append((IMMUTABLE, name, d))
                    continue
                branch = ref
            else:
                branch = default_branch(owner, repo, token)
        except ToolError as e:
            results.append((FAILED, name, str(e)))
            continue

        # Channel branches: no cooldown, take the published head. Gated on the repo
        # actually being nixpkgs so a third-party branch that happens to be named after
        # a channel cannot be mistaken for one.
        if owner.lower() == "nixos" and repo == "nixpkgs":
            head = published_channel_head(branch)
            if head:
                cur_rev = locked.get("rev", "")
                ts = locked.get("lastModified")
                shown = (f"{datetime.fromtimestamp(ts, timezone.utc):%Y-%m-%d}, "
                         f"{age_days(datetime.fromtimestamp(ts, timezone.utc), now):.1f}d"
                         if ts else "?")
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
            results.append((FAILED, name, f"no commit on {branch} older than {days}d"))
            continue

        rev, when = found
        age = age_days(when, now)
        cur_rev = locked.get("rev", "")
        if cur_rev == rev:
            results.append((CURRENT if for_update else OK, name,
                            f"{branch} @ {rev[:9]} ({when:%Y-%m-%d}, {age:.1f}d)"))
            continue

        ts = locked.get("lastModified")
        cur_age = age_days(datetime.fromtimestamp(ts, timezone.utc), now) if ts else None

        # AUDIT judges the age of what is LOCKED, not whether a different revision was
        # picked. Those are separate facts and conflating them cries wolf: an input can
        # be perfectly safe and merely outdated (devenv at 5.9 d against a 5 d bar, with
        # a newer qualifying rev available) — that is not a finding, and reporting it as
        # one trains people to ignore the tool.
        if not for_update:
            if cur_age is None:
                results.append((FAILED, name, "locked entry carries no lastModified"))
            elif cur_age < days:
                results.append((TOO_NEW, name,
                                f"locked {cur_rev[:9]} is {cur_age:.1f}d old — inside "
                                f"the {days}d bar"))
            else:
                results.append((OK, name,
                                f"locked {cur_rev[:9]} ({cur_age:.1f}d, {days}d bar); "
                                f"newer qualifying rev {rev[:9]} available"))
            continue

        arrow = "→" if cur_age is None or cur_age > age else "↓"
        detail = (f"{cur_rev[:9] or '(none)'}"
                  f"{f' ({cur_age:.1f}d)' if cur_age is not None else ''} "
                  f"{arrow} {rev[:9]} ({when:%Y-%m-%d}, {age:.1f}d, {days}d bar)")

        # An UPDATE must not regress. If the bar's pick is older than what is already
        # locked, moving there would undo a revision that has been built, cached and
        # possibly deployed — and it happens routinely and harmlessly whenever the bar
        # is raised (e.g. nixpkgs-llm-agents 5 -> 14 days), because the currently locked
        # rev simply has not aged past the new bar yet. Waiting fixes it; rolling back
        # does not. Reported, never silent, and `--allow-rollback` forces it for the
        # case that actually wants it: a lock polluted by a bare `nix flake update`.
        if (for_update and cur_age is not None and age > cur_age
                and not getattr(args, "allow_rollback", False)):
            results.append((HELD_NEWER, name,
                            f"{cur_rev[:9]} ({cur_age:.1f}d) is NEWER than the {days}d "
                            f"bar's pick {rev[:9]} ({age:.1f}d) — not rolled back; it "
                            f"clears the bar on its own in "
                            f"{max(0.0, days - cur_age):.1f}d"))
            continue

        results.append((COOLED if for_update else TOO_NEW, name, detail))
        overrides.append((name, f"github:{owner}/{repo}/{rev}"))

    return results, overrides


def cmd_update(args, manifest, now, token) -> int:
    results, overrides = resolve_inputs(args, manifest, now, token, for_update=True)
    counts = render("layer 1 — flake inputs", results)

    print(f"\nsummary: {counts.get(COOLED,0)} cooled, {counts.get(CHANNEL,0)} channel, "
          f"{counts.get(CURRENT,0)} current, "
          f"{counts.get(IMMUTABLE,0)+counts.get(FROZEN,0)+counts.get(UNSUPPORTED,0)+counts.get(HELD_NEWER,0)} "
          f"skipped, {counts.get(FAILED,0)} errors")

    if counts.get(FAILED):
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
        print("\n--dry-run: flake.lock untouched. Would run:\n  " + " ".join(cmd))
        return 0

    print(f"\nlocking {len(overrides)} input(s)…")
    try:
        out = subprocess.run(cmd, text=True, timeout=3600)
    except (OSError, subprocess.SubprocessError) as e:
        raise ToolError(f"`nix flake lock` failed to run: {e}") from e
    if out.returncode != 0:
        print("`nix flake lock` failed — flake.lock may be partially written.",
              file=sys.stderr)
        return 1
    print("done.")
    return 0


def cmd_audit(args, manifest, now, token) -> int:
    findings = 0
    errors = 0

    if not args.extensions_only and not args.pins_only:
        results, _ = resolve_inputs(args, manifest, now, token, for_update=False)
        c = render("layer 1 — flake inputs", results)
        findings += sum(c.get(k, 0) for k in FINDING_CATEGORIES)
        errors += c.get(FAILED, 0)

    if not args.inputs_only and not args.extensions_only and not args.pins_only:
        pkg_days = manifest.get("cooldown", {}).get("packages", 14)
        cutoff = now - timedelta(days=pkg_days)
        rows: list[tuple[str, str, str]] = []
        for p in manifest.get("packages", []):
            name = p.get("name", "?")
            try:
                ver = eval_package_version(args.flake, p["input"], p["attr"])
            except ToolError as e:
                rows.append((FAILED, name, str(e)))
                continue
            if not ver:
                rows.append((FAILED, name,
                             f"{p['input']}.{p['attr']} did not evaluate — renamed or "
                             f"removed upstream"))
                continue
            # Exactly one registry per entry, named explicitly. Neither is a
            # manifest bug; BOTH is the subtler one — an if/elif would date it
            # against whichever key comes first and never consult the other, so a
            # withdrawn release on the ignored side would read as `ok`. Either
            # shape surfaces as FAILED, not as a package that quietly stops being
            # audited.
            named = [k for k in ("npm", "github") if k in p]
            if len(named) != 1:
                rows.append((FAILED, name, f"{ver}: manifest entry must name exactly "
                                           f"one of `npm` or `github` to date it "
                                           f"against (found: {', '.join(named) or 'neither'})"))
                continue
            try:
                if named == ["npm"]:
                    source = f"npm {p['npm']}"
                    when, problem = npm_version_status(p["npm"], ver)
                else:
                    source = f"github {p['github']}"
                    when, problem = github_release_status(p["github"], ver, token)
            except ToolError as e:
                rows.append((FAILED, name, f"{ver}: {e}"))
                continue
            if problem:
                rows.append((WITHDRAWN, name, f"{ver}: {problem}"))
                continue
            age = age_days(when, now)
            cat = OK if when <= cutoff else TOO_NEW
            rows.append((cat, name, f"{ver} ({when:%Y-%m-%d}, {age:.1f}d, "
                                    f"{pkg_days}d bar) via {source}"))
        c = render("layer 2 — tracked packages (dated against their registry)", rows)
        findings += sum(c.get(k, 0) for k in FINDING_CATEGORIES)
        errors += c.get(FAILED, 0)

    if not args.inputs_only and not args.pins_only:
        ext_days = manifest.get("cooldown", {}).get("extensions", 14)
        cutoff = now - timedelta(days=ext_days)
        declared = list(manifest.get("extensions", []))
        cli = [{"id": e, "registry": args.registry} for e in args.extension]
        todo = cli or declared
        if not todo:
            print(f"\n{'=' * 78}\nlayer 3 — VS Code extensions\n{'=' * 78}\n"
                  f"\nnone declared. scripts/supply-chain.toml [[extensions]] is "
                  f"deliberately empty until\nthe default-extension set is actually "
                  f"wired into a module; the machinery is\nimplemented and testable "
                  f"with `just audit-extensions <id>…`.")
        else:
            rows = [check_extension(e["id"], e.get("registry", "open-vsx"),
                                    cutoff, now, pin=e.get("pin")) for e in todo]
            c = render("layer 3 — VS Code extensions "
                       f"({ext_days}d bar, must still be published)", rows)
            findings += sum(c.get(k, 0) for k in FINDING_CATEGORIES)
            errors += c.get(FAILED, 0)

    if not args.inputs_only and not args.extensions_only:
        root = MANIFEST.parent.parent
        rows = [check_pin(p, root, manifest, now, token) for p in manifest.get("pins", [])]
        c = render("layer 4 — hand-bumped version pins (still behind upstream?)", rows)
        findings += sum(c.get(k, 0) for k in FINDING_CATEGORIES)
        errors += c.get(FAILED, 0)

    print(f"\n{'=' * 78}")
    if errors:
        print(f"{errors} error(s) — could not complete the audit.")
        return 2
    if findings:
        print(f"{findings} finding(s): something is inside its cooldown or has been "
              f"withdrawn upstream.")
        return 1
    print("clean — everything clears its cooldown and is still published upstream.")
    return 0


# ------------------------------------------------- extension-pick: a cooled install plan
#
# `code --install-extension id@ver` honours ONE version. Everything the extension pulls
# in with it — an extension pack's members, `extensionDependencies` — arrives in the
# NEWEST version, cooldown or no. Measured 2026-11-05: installing ms-python.python@2026.10.0
# brought ms-python.vscode-python-envs 1.42.0 along, one day old and never reviewed, and
# installing ms-python.vscode-pylance@2026.4.1 pulled ms-python.python in its latest
# version too (a dependency of a dependency). A member that is ALREADY installed is never
# upgraded by a later install, so the whole closure has to be resolved here and installed
# leaves-first, each member pinned. That is what this command computes.

EXT_PACK = "Microsoft.VisualStudio.Code.ExtensionPack"
EXT_DEPS = "Microsoft.VisualStudio.Code.ExtensionDependencies"
EXT_PRERELEASE = "Microsoft.VisualStudio.Code.PreRelease"
EXT_SHA256 = "Microsoft.VisualStudio.Services.VsixSha256"


def _members(props: dict[str, str]) -> list[str]:
    """Pack members and hard dependencies, de-duplicated, in declared order."""
    out: list[str] = []
    for key in (EXT_DEPS, EXT_PACK):
        for part in (props.get(key) or "").split(","):
            part = part.strip()
            if part and part.lower() not in (o.lower() for o in out):
                out.append(part)
    return out


def extension_closure(ext_id: str, cutoff: datetime, now: datetime,
                      done: dict[str, dict], stack: tuple[str, ...] = (),
                      platform: str = "darwin-arm64") -> None:
    """Resolve ext_id and everything it pulls in into `done`, leaves first.

    `done` is an insertion-ordered {lowercased id: entry}; an entry is inserted only
    after all its members, so iterating `done` yields a valid install order. A member
    that cannot be cooled (too new, withdrawn) raises ToolError naming the member: the
    parent cannot be installed without it.
    """
    key = ext_id.lower()
    if key in done:
        return
    if key in stack:           # pack that lists its own parent
        return
    if "." not in ext_id:
        raise ToolError(f"id must be <namespace>.<name>: {ext_id!r}")
    namespace, name = ext_id.split(".", 1)
    ext = vsmarketplace_extension(namespace, name)
    # One version appears once per target platform (darwin-arm64, linux-x64, … or none
    # for a universal build). Group them, then walk the versions newest-first and take
    # the first STABLE one that clears the bar AND has a build for this platform.
    by_version: dict[str, list[dict]] = {}
    for v in ext.get("versions") or []:
        if v.get("version") and v.get("lastUpdated"):
            by_version.setdefault(v["version"], []).append(v)
    chosen = None
    wrong_platform = 0
    for ver, entries in sorted(by_version.items(),
                               key=lambda kv: kv[1][0]["lastUpdated"], reverse=True):
        props0 = {p.get("key"): p.get("value") for p in (entries[0].get("properties") or [])}
        if EXT_PRERELEASE in props0:
            # The key's mere presence marks a pre-release in the gallery, exactly as
            # vsmarketplace_versions reads it.
            continue
        if iso(entries[0]["lastUpdated"]) > cutoff:
            continue
        build = (next((e for e in entries if e.get("targetPlatform") == platform), None)
                 or next((e for e in entries
                          if e.get("targetPlatform") in (None, "", "universal")), None))
        if build is None:
            wrong_platform += 1
            continue
        props = {p.get("key"): p.get("value") for p in (build.get("properties") or [])}
        chosen = (ver, iso(build["lastUpdated"]), props, build)
        break
    if chosen is None:
        why = (f"; {wrong_platform} cooled version(s) have no {platform} build"
               if wrong_platform else "")
        raise ToolError(f"no stable Marketplace version of {ext_id} is old enough "
                        f"({len(by_version)} versions seen{why})")
    ver, when, props, build = chosen
    members = _members(props)
    for m in members:
        try:
            extension_closure(m, cutoff, now, done, stack + (key,), platform)
        except ToolError as e:
            raise ToolError(f"{ext_id} needs {m}: {e}") from e
    stats = {s.get("statisticName"): s.get("value") for s in (ext.get("statistics") or [])}
    done[key] = {
        "id": f"{ext.get('publisher', {}).get('publisherName', namespace)}.{ext.get('extensionName', name)}",
        "version": ver,
        "published": when.isoformat(),
        "ageDays": round(age_days(when, now), 1),
        "sha256": props.get(EXT_SHA256),
        "targetPlatform": build.get("targetPlatform") or "universal",
        "vsixUrl": f"{build['assetUri']}/Microsoft.VisualStudio.Services.VSIXPackage",
        "domainVerified": bool((ext.get("publisher") or {}).get("isDomainVerified")),
        "installs": int(stats.get("install") or 0),
        "needs": members,
    }


def cmd_extension_pick(args, manifest, now) -> int:
    """Cooled install plan for each id, as JSON on stdout.

    Output: {"cooldownDays": N, "results": [{"id", "ok": true, "plan": [entry, …]} |
    {"id", "ok": false, "detail": "…"}]}. `plan` is leaves-first and ALREADY includes the
    requested extension as its last element (unless an earlier id in this call brought
    it in as a member; plans are per id, so a shared member appears in each). Exit 0 when
    every id resolved, 1 when any could not (too new, withdrawn, member blocked).
    """
    days = manifest.get("cooldown", {}).get("extensions", 14)
    cutoff = now - timedelta(days=days)
    results = []
    for ext_id in args.ids:
        done: dict[str, dict] = {}
        try:
            extension_closure(ext_id, cutoff, now, done, platform=args.platform)
            results.append({"id": ext_id, "ok": True, "plan": list(done.values())})
        except ToolError as e:
            results.append({"id": ext_id, "ok": False, "detail": str(e)})
    print(json.dumps({"cooldownDays": days, "results": results}, indent=2))
    return 0 if all(r["ok"] for r in results) else 1


# ------------------------------------------------------- tag pins: pick a cooled release

def cmd_release(args, manifest, now, token) -> int:
    """Newest GitHub release of OWNER/REPO that clears the layer-1 cooldown.

    Tag-pinned inputs are classified IMMUTABLE by layer 1 and skipped, which is
    right — `nix flake update` never moves them. But the recipe that DOES move
    them by hand had no bar at all: `just brew-bump` took releases/latest.
    Measured 2026-09-01, that would have pinned Homebrew 6.0.21 twelve hours
    after publication, in a repo whose whole update path exists to avoid being
    the first consumer of anything.

    The tag on stdout, everything else on stderr, so the caller can use $(...).
    """
    owner, _, repo = args.repo.partition("/")
    if not owner or not repo:
        raise ToolError(f"expected OWNER/REPO, got {args.repo!r}")

    bar = args.days if args.days is not None else manifest["cooldown"]["inputs"]
    cutoff = now - timedelta(days=bar)

    status, data = http_json(
        f"https://api.github.com/repos/{owner}/{repo}/releases?per_page={args.limit}",
        token)
    if status != 200 or not isinstance(data, list):
        raise ToolError(f"cannot list releases for {owner}/{repo} (HTTP {status})")

    # Drafts have no tag anyone can fetch; prereleases are not what a pin wants.
    # A release with no published_at cannot be dated, so it cannot clear a bar.
    usable = [(iso(r["published_at"]), r["tag_name"]) for r in data
              if r.get("published_at") and r.get("tag_name")
              and not r.get("draft") and not r.get("prerelease")]
    usable.sort(reverse=True)

    if not usable:
        raise ToolError(f"{owner}/{repo}: no dated, published release among the "
                        f"newest {args.limit}")

    for published, tag in usable:
        if published <= cutoff:
            print(f"{owner}/{repo}: {tag} ({published:%Y-%m-%d}, "
                  f"{age_days(published, now):.1f}d, {bar}d bar)", file=sys.stderr)
            print(tag)
            return 0
        # Say what was declined and why. A silent skip reads as "not published yet".
        print(f"  skipped {tag} ({published:%Y-%m-%d}, "
              f"{age_days(published, now):.1f}d — inside the {bar}d bar)",
              file=sys.stderr)

    # Bounded search: name the bound, or an exhausted window is indistinguishable
    # from a repo that genuinely has nothing old enough.
    raise ToolError(f"{owner}/{repo}: none of the newest {len(usable)} releases "
                    f"(of {args.limit} requested) clears the {bar}d bar; oldest "
                    f"inspected is {usable[-1][1]} at "
                    f"{age_days(usable[-1][0], now):.1f}d")


def main() -> int:
    p = argparse.ArgumentParser(
        description="Cooldown + withdrawal gate for this flake's dependencies.",
        epilog="Exit codes: 0 clean, 1 findings / action needed, 2 tool error.")
    p.add_argument("--flake", default=".", help="flake to operate on (default: .)")
    p.add_argument("--days", type=int, default=None,
                   help="override the layer-1 cooldown from the manifest")
    p.add_argument("--freeze", action="append", default=[], metavar="NAME",
                   help="additionally leave this input untouched (repeatable)")
    p.add_argument("--only", action="append", default=[], metavar="NAME",
                   help="restrict layer 1 to these inputs (repeatable)")
    sub = p.add_subparsers(dest="command", required=True)

    up = sub.add_parser("update", help="apply the cooldown and write flake.lock")
    up.add_argument("--dry-run", action="store_true",
                    help="resolve and report, but do not touch flake.lock")
    up.add_argument("--allow-rollback", action="store_true",
                    help="also move inputs BACKWARDS when the locked rev is newer than "
                         "the bar allows (default: report and leave alone)")

    au = sub.add_parser("audit", help="report-only across all four layers")
    au.add_argument("--inputs-only", action="store_true",
                    help="layer 1 only (no npm, GitHub-release or marketplace lookups)")
    au.add_argument("--extensions-only", action="store_true",
                    help="layer 3 only")
    au.add_argument("--pins-only", action="store_true",
                    help="layer 4 only: hand-bumped version pins behind upstream")
    au.add_argument("--extension", action="append", default=[], metavar="ID",
                    help="check this <namespace>.<name> instead of the manifest list")
    au.add_argument("--registry", default="open-vsx",
                    choices=["open-vsx", "vscode-marketplace"],
                    help="registry for --extension (default: open-vsx)")

    ep = sub.add_parser("extension-pick",
                        help="cooled install plan (JSON) for VS Code extensions, "
                             "including pack members and dependencies, leaves first")
    ep.add_argument("ids", nargs="+", metavar="ID", help="<publisher>.<name>")
    ep.add_argument("--platform", default="darwin-arm64",
                    help="target platform of the builds to pick (default: darwin-arm64)")

    rel = sub.add_parser("release",
                         help="newest GitHub release of OWNER/REPO that clears the "
                              "layer-1 cooldown; prints the tag on stdout")
    rel.add_argument("repo", metavar="OWNER/REPO",
                     help="e.g. Homebrew/brew")
    rel.add_argument("--limit", type=int, default=30, metavar="N",
                     help="how many recent releases to inspect (default: 30)")

    args = p.parse_args()
    now = datetime.now(timezone.utc)
    manifest = load_manifest()
    token = gh_token()

    if args.command == "update":
        return cmd_update(args, manifest, now, token)
    if args.command == "release":
        return cmd_release(args, manifest, now, token)
    if args.command == "extension-pick":
        return cmd_extension_pick(args, manifest, now)
    return cmd_audit(args, manifest, now, token)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
