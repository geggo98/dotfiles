#!/usr/bin/env python3
"""Supply-chain gate for this flake: adopt nothing that is suspiciously new, and
nothing that upstream has since withdrawn.

Two commands over one set of rules, because a policy that is checked by a different
tool than the one that applies it drifts apart:

    update   resolve every mutable flake input to the newest revision that clears the
             cooldown, and write those revisions into flake.lock   (`just update`)
    audit    report-only, across all three layers below               (`just audit`)

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
    layer 2  npm `unpublished` / a version missing from the registry's `time` map
    layer 3  a VS Code extension that 404s, is deprecated, or whose chosen version has
             been removed from `allVersions` while the extension itself survives

That is not hypothetical: on the first real run, layer 1 rejected determinate 3.22.0 —
comfortably old enough at 15 days, and yanked on 2026-08-17.

THREE LAYERS.
    1 flake inputs      github branches, github tags, FlakeHub semver ranges
    2 tracked packages  a hand-kept list dated against npm; a flake input's age bounds
                        its contents only from below, and loosely
    3 VS Code extensions  Open VSX / MS Marketplace, cooldown + still-exists

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

# Categories, kept distinct on purpose. CLAUDE.md: "Classify every item as SUCCESS,
# SKIP, ERROR or CLEANUP, and never collapse two of them. A skip is not a failure."
COOLED = "cooled"        # moved to an older-but-fresh-enough rev       (SUCCESS)
CURRENT = "current"      # already at the right rev, nothing to do      (SUCCESS)
HELD_NEWER = "held_newer"  # bar's pick is OLDER than the lock — see below (SKIP)
CHANNEL = "channel"      # Hydra-gated channel head — see below         (SUCCESS)
OK = "ok"                # audit: clears the bar and still exists       (SUCCESS)
TOO_NEW = "too_new"      # audit: younger than the bar                  (FINDING)
WITHDRAWN = "withdrawn"  # yanked / unpublished / 404 / deprecated      (FINDING)
IMMUTABLE = "immutable"  # tag/rev pin — flake update cannot move it    (SKIP)
FROZEN = "frozen"        # explicitly excluded by the manifest          (SKIP)
UNSUPPORTED = "unsupported"  # not a datable input type                 (SKIP)
FAILED = "failed"        # lookup or lock error                         (ERROR)

FINDING_CATEGORIES = {TOO_NEW, WITHDRAWN}

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


def vsmarketplace_pick(namespace: str, name: str, cutoff: datetime
                       ) -> tuple[str, datetime, list[str]]:
    """Same policy against the MS Marketplace gallery API. Versions repeat per
    targetPlatform, so they are deduped, and pre-releases are skipped as on Open VSX."""
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
    ext = results[0]
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
    for ver, when in sorted(seen.items(), key=lambda kv: kv[1], reverse=True):
        if when <= cutoff:
            return ver, when, notes
    raise ToolError(f"no Marketplace version of {namespace}.{name} is old enough "
                    f"(newest {len(seen)} release versions are all inside the cooldown)")


def check_extension(ext_id: str, registry: str, cutoff: datetime, now: datetime
                    ) -> tuple[str, str, str]:
    """-> (category, ext_id, detail)."""
    if "." not in ext_id:
        return FAILED, ext_id, "id must be <namespace>.<name>"
    namespace, name = ext_id.split(".", 1)
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


# ---------------------------------------------------------------------------- render

LABEL = {
    COOLED: "TO UPDATE (cooled)",
    CHANNEL: "channel — Hydra-gated, no cooldown",
    CURRENT: "already current",
    HELD_NEWER: "held — locked rev is newer than the bar's pick",
    OK: "ok — old enough and still published",
    TOO_NEW: "TOO NEW — inside the cooldown",
    WITHDRAWN: "WITHDRAWN UPSTREAM",
    IMMUTABLE: "skipped — immutable pin",
    FROZEN: "skipped — frozen",
    UNSUPPORTED: "skipped — cannot be dated",
    FAILED: "ERROR",
}
ORDER = [WITHDRAWN, TOO_NEW, COOLED, CHANNEL, OK, CURRENT, HELD_NEWER,
         IMMUTABLE, FROZEN, UNSUPPORTED, FAILED]


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

    if not args.extensions_only:
        results, _ = resolve_inputs(args, manifest, now, token, for_update=False)
        c = render("layer 1 — flake inputs", results)
        findings += sum(c.get(k, 0) for k in FINDING_CATEGORIES)
        errors += c.get(FAILED, 0)

    if not args.inputs_only and not args.extensions_only:
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
            try:
                when, problem = npm_version_status(p["npm"], ver)
            except ToolError as e:
                rows.append((FAILED, name, f"{ver}: {e}"))
                continue
            if problem:
                rows.append((WITHDRAWN, name, f"{ver}: {problem}"))
                continue
            age = age_days(when, now)
            cat = OK if when <= cutoff else TOO_NEW
            rows.append((cat, name, f"{ver} ({when:%Y-%m-%d}, {age:.1f}d, "
                                    f"{pkg_days}d bar) via npm {p['npm']}"))
        c = render("layer 2 — tracked packages (dated against npm)", rows)
        findings += sum(c.get(k, 0) for k in FINDING_CATEGORIES)
        errors += c.get(FAILED, 0)

    if not args.inputs_only:
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
                                    cutoff, now) for e in todo]
            c = render("layer 3 — VS Code extensions "
                       f"({ext_days}d bar, must still be published)", rows)
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

    au = sub.add_parser("audit", help="report-only across all three layers")
    au.add_argument("--inputs-only", action="store_true",
                    help="layer 1 only (no npm or marketplace lookups)")
    au.add_argument("--extensions-only", action="store_true",
                    help="layer 3 only")
    au.add_argument("--extension", action="append", default=[], metavar="ID",
                    help="check this <namespace>.<name> instead of the manifest list")
    au.add_argument("--registry", default="open-vsx",
                    choices=["open-vsx", "vscode-marketplace"],
                    help="registry for --extension (default: open-vsx)")

    args = p.parse_args()
    now = datetime.now(timezone.utc)
    manifest = load_manifest()
    token = gh_token()

    if args.command == "update":
        return cmd_update(args, manifest, now, token)
    return cmd_audit(args, manifest, now, token)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
