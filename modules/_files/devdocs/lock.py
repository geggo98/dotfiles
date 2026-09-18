"""Resolve every family in modules/_files/devdocs/families.nix to its newest
DevDocs slug, and every source in modules/_files/devdocs/sources.nix
(Maven-javadoc, the Gradle docs archive, Valkey commands) to its newest
release, prefetch each hash via `nix store prefetch-file`, and (re)write
modules/_files/devdocs/docs.lock.json (schema 2: `docs` + `sources`). Backs
`just devdocs-lock` (writes) and `just devdocs-list` (--report, read-only).

Stdlib-only, no PEP-723/uv header -- same reasoning as build-index.py and
devdocs-cli.py: nothing to lock, and this is a one-shot CLI script, not a
long-running service.

DevDocs resolution rule, matching modules/devdocs.nix's own (looser) check:
if docs.json lists a slug exactly equal to the family name, that wins
(`node`, `typescript`, `git`); otherwise the highest-versioned `<family>~*`,
compared NUMERICALLY on the dotted suffix (`python~3.14` must beat
`python~3.9` -- a string sort gets that backwards). docs.json has been
observed to carry DUPLICATE slugs (measured 2026-09-17: "bun" and "vitest"
each appeared twice, one entry stale enough that its own `links.home`
pointed at leafletjs.com) -- deduplicated by keeping the highest `mtime` per
slug before resolution ever runs.

`sources` resolution is per-kind (see resolve_maven/resolve_gradle/
resolve_redis_commit below) and is a STRICTLY BETTER pinning story than
DevDocs': Maven Central artifacts and the Gradle docs archive are immutable
once published, so unlike downloads.devdocs.io (which rebuilds a slug's
tarball in place at a fixed URL, tracked only by `mtime`) a stale `sources`
lock entry never stops fetching -- it is simply behind, not broken. Maven's
own `<release>`/`<latest>` in maven-metadata.xml are NOT trustworthy for
"the newest stable version": measured 2026-09-18, `spring-core` pointed at
`7.1.0-M1` and `groovy` at `6.0.0-RC-3` -- both milestone/RC builds, not
what `just devdocs-lock` should ever pin unasked. resolve_maven therefore
filters PRERELEASE_RE out of the full `<versions>` list itself.

Exit codes, matching infra/scripts/osv-audit.py's convention: 0 did-work-or-
nothing-to-do, 1 at least one declared family/source failed to resolve, 2
tool/network error.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

MANIFEST_URL = "https://devdocs.io/docs.json"
SCHEMA = 2
MAVEN_BASE = "https://repo1.maven.org/maven2"
GRADLE_VERSIONS_URL = "https://services.gradle.org/versions/current"
GITHUB_API = "https://api.github.com/repos"
PRERELEASE_RE = re.compile(
    r"(?i)(?:^|[.\-_])(alpha\d*|beta\d*|rc\d*|m\d+|snapshot|preview\d*|cr\d*|milestone\d*)(?:[.\-_]|$)"
)


def log(*args):
    print(*args, file=sys.stderr)


def fetch_manifest(manifest_path=None):
    if manifest_path:
        with open(manifest_path, encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(MANIFEST_URL, headers={"User-Agent": "Mozilla/5.0"})
    try:
        # https://devdocs.io/docs.json 302-redirects to a fingerprinted asset
        # URL; urllib follows redirects by default, unlike a bare fetchurl.
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except (urllib.error.URLError, OSError) as exc:
        log(f"error: could not fetch {MANIFEST_URL}: {exc}")
        sys.exit(2)


def dedup_by_slug(docs):
    """Keep the freshest (highest mtime) entry per slug. See module
    docstring: docs.json has shipped genuine duplicate-slug rows."""
    by_slug = {}
    for d in docs:
        prev = by_slug.get(d["slug"])
        if prev is None or d["mtime"] > prev["mtime"]:
            by_slug[d["slug"]] = d
    return by_slug


def version_key(slug, family):
    suffix = slug[len(family) + 1:] if slug != family and slug.startswith(family + "~") else ""
    return tuple(int(p) for p in re.findall(r"\d+", suffix))


def resolve_family(family, by_slug):
    if family in by_slug:
        return by_slug[family]
    candidates = [d for s, d in by_slug.items() if s == family or s.startswith(family + "~")]
    if not candidates:
        return None
    return max(candidates, key=lambda d: version_key(d["slug"], family))


def load_nix_json(path):
    """A plain-literal .nix file (a list or attrset, no `lib`/functions) --
    read via `nix eval --json` rather than parsing Nix syntax by hand. Used
    for both families.nix (a list) and sources.nix (an attrset)."""
    out = subprocess.run(
        ["nix", "eval", "--json", "--file", path],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


load_families = load_nix_json  # kept as a name: every existing call site says "families"


def sanitize_name(slug):
    return re.sub(r"[^0-9a-zA-Z+._?=-]", "-", slug)


def prefetch_file(url, name, unpack=False):
    """`nix store prefetch-file --json [--unpack] --name <name> <url>` ->
    the SRI hash, or None (logged) on failure. `unpack=True` is for a
    `sources` entry whose `hashMode` is "recursive" (a tarball meant for
    `pkgs.fetchzip`, e.g. a GitHub archive) -- it hashes the UNPACKED tree
    (a NAR hash), matching what fetchzip itself would compute, rather than
    the compressed bytes."""
    args = ["nix", "store", "prefetch-file", "--json"]
    if unpack:
        args.append("--unpack")
    args += ["--name", name, url]
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=300, check=True)
    except subprocess.CalledProcessError as exc:
        log(f"  prefetch failed for {url}: {exc.stderr.strip()}")
        return None
    except subprocess.TimeoutExpired:
        log(f"  prefetch timed out for {url}")
        return None
    return json.loads(out.stdout)["hash"]


def prefetch_hash(slug):
    url = f"https://downloads.devdocs.io/{slug}.tar.gz"
    name = f"devdocs-{sanitize_name(slug)}.tar.gz"
    return prefetch_file(url, name)


# --------------------------------------------------------------------------
# `sources` resolution: mavenJavadoc, javadocUrl (Gradle), redisCommands
# --------------------------------------------------------------------------

def http_get(url, headers=None, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def http_get_optional(url, headers=None, timeout=30):
    try:
        return http_get(url, headers, timeout)
    except (urllib.error.URLError, OSError):
        return None


def maven_versions(group_id, artifact_id):
    """Every version maven-metadata.xml lists for this coordinate -- NOT
    just <release>/<latest>, which are untrustworthy (see module docstring:
    measured pointing at milestone/RC builds for spring-core and groovy)."""
    gpath = group_id.replace(".", "/")
    url = f"{MAVEN_BASE}/{gpath}/{artifact_id}/maven-metadata.xml"
    data = http_get(url)
    root = ET.fromstring(data)
    return [v.text for v in root.findall("./versioning/versions/version") if v.text]


def maven_version_key(v):
    """Numeric sort key from the LEADING dotted-digit run: "4.1.1" ->
    (4,1,1); "1.0.0.RELEASE" -> (1,0,0) (the ".RELEASE" tail is ignored for
    ranking, harmless since it never competes against a differently-shaped
    stable version within one artifact's history)."""
    m = re.match(r"^(\d+(?:\.\d+)*)", v)
    return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)


def resolve_maven(src):
    """{version, url, filename} for the newest STABLE version matching
    src.get("track", "") as a prefix, or None if nothing qualifies."""
    versions = maven_versions(src["groupId"], src["artifactId"])
    track = src.get("track") or ""
    candidates = [v for v in versions if v.startswith(track) and not PRERELEASE_RE.search(v)]
    if not candidates:
        return None
    version = max(candidates, key=maven_version_key)
    classifier = src.get("classifier", "javadoc")
    extension = src.get("extension", "jar")
    gpath = src["groupId"].replace(".", "/")
    filename = f"{src['artifactId']}-{version}-{classifier}.{extension}"
    url = f"{MAVEN_BASE}/{gpath}/{src['artifactId']}/{version}/{filename}"
    return {"version": version, "url": url, "filename": filename}


def maven_sha1(jar_url):
    """The publisher's own .sha1 sidecar -- a cheap 40-byte staleness
    pre-check, mirroring DevDocs' `mtime` trick. Never used as the actual
    Nix hash (that always comes from `nix store prefetch-file`)."""
    data = http_get_optional(jar_url + ".sha1")
    return data.decode("ascii").strip().split()[0] if data else None


def resolve_gradle():
    """https://services.gradle.org/versions/current -> {"version": "9.7.1", ...}."""
    data = http_get(GRADLE_VERSIONS_URL)
    return json.loads(data)["version"]


def gradle_sha256(url):
    data = http_get_optional(url + ".sha256")
    return data.decode("ascii").strip().split()[0] if data else None


def resolve_redis_commit(repo, ref):
    """GitHub's own commit-date API -- {sha, iso committer date}."""
    data = http_get(f"{GITHUB_API}/{repo}/commits/{ref}", headers={"Accept": "application/vnd.github+json"})
    d = json.loads(data)
    return d["sha"], d["commit"]["committer"]["date"]


def load_lock(lock_path):
    if os.path.exists(lock_path):
        with open(lock_path, encoding="utf-8") as f:
            lock = json.load(f)
        lock.setdefault("docs", {})
        lock.setdefault("sources", {})
        return lock
    return {"schema": SCHEMA, "generated": "", "manifest_url": MANIFEST_URL, "docs": {}, "sources": {}}


def write_lock_atomic(lock_path, lock):
    # Same publish discipline as every other list-processing script in this
    # repo (AGENTS.md, "Any script that processes a list must be
    # resumable"): write to a temp name in the same directory, fsync, then
    # rename -- an interrupted run leaves a stray .tmp, never a truncated
    # lock file that the next `just build` would silently trust.
    d = os.path.dirname(os.path.abspath(lock_path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".docs.lock.json.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(lock, f, indent=1, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, lock_path)
    except BaseException:
        os.unlink(tmp)
        raise


def lock_one_source(name, src, existing):
    """Resolve+prefetch one modules/_files/devdocs/sources.nix entry.
    Returns (entry_dict, unchanged: bool) on success, or (None, False) on
    failure (logged). Mirrors cmd_lock's DevDocs loop but per-kind, since
    each kind resolves and stales-checks differently -- see module
    docstring's table."""
    kind = src["kind"]
    resolved_at = time.strftime("%Y-%m-%dT%H:%M:%S%z")

    if kind == "mavenJavadoc":
        resolved = resolve_maven(src)
        if resolved is None:
            log(f"  FAIL  {name}: no stable version of {src['groupId']}:{src['artifactId']} "
                f"matching track={src.get('track', '')!r} found")
            return None, False
        sha1 = maven_sha1(resolved["url"])
        if existing and existing.get("version") == resolved["version"] and existing.get("sha1") == sha1:
            return existing, True
        h = prefetch_file(resolved["url"], resolved["filename"])
        if h is None:
            return None, False
        entry = {
            "kind": kind, "slug": src.get("slug", name),
            "groupId": src["groupId"], "artifactId": src["artifactId"],
            "classifier": src.get("classifier", "javadoc"), "extension": src.get("extension", "jar"),
            "version": resolved["version"], "url": resolved["url"],
            "sha1": sha1, "hash": h, "hashMode": "flat",
            "license": src["license"], "resolvedAt": resolved_at,
        }
        return entry, False

    if kind == "javadocUrl":
        version = resolve_gradle()
        url = src["urlTemplate"].replace("@version@", version)
        subdir = src["subdirTemplate"].replace("@version@", version)
        upstream_sha256 = gradle_sha256(url)
        if existing and existing.get("version") == version and existing.get("upstreamSha256") == upstream_sha256:
            return existing, True
        h = prefetch_file(url, f"{name}-{version}-docs.zip")
        if h is None:
            return None, False
        entry = {
            "kind": kind, "slug": src.get("slug", name),
            "urlTemplate": src["urlTemplate"], "subdirTemplate": src["subdirTemplate"],
            "version": version, "url": url, "subdir": subdir,
            "upstreamSha256": upstream_sha256, "hash": h, "hashMode": "flat",
            "license": src["license"], "resolvedAt": resolved_at,
        }
        return entry, False

    if kind == "redisCommands":
        commit, commit_date = resolve_redis_commit(src["repo"], src.get("ref", "main"))
        if existing and existing.get("commit") == commit:
            return existing, True
        url = f"https://github.com/{src['repo']}/archive/{commit}.tar.gz"
        h = prefetch_file(url, f"{name}-{commit[:12]}.tar.gz", unpack=True)
        if h is None:
            return None, False
        entry = {
            "kind": kind, "slug": src.get("slug", name),
            "repo": src["repo"], "ref": src.get("ref", "main"),
            "commit": commit, "commitDate": commit_date, "url": url,
            "hash": h, "hashMode": "recursive",
            "license": src["license"], "resolvedAt": resolved_at,
        }
        return entry, False

    log(f"  FAIL  {name}: unknown source kind {kind!r}")
    return None, False


def cleanup_stale_temp(lock_path):
    d = os.path.dirname(os.path.abspath(lock_path)) or "."
    base = os.path.basename(lock_path)
    n = 0
    for f in os.listdir(d):
        if f.startswith(f".{base}.") and f.endswith(".tmp"):
            os.unlink(os.path.join(d, f))
            n += 1
    return n


SOURCE_KINDS = ("mavenJavadoc", "javadocUrl", "redisCommands")


def cmd_lock(families_path, sources_path, lock_path, only_names, prune, manifest_path, kind_filter):
    cleaned = cleanup_stale_temp(lock_path)
    families = load_families(families_path)
    sources = load_nix_json(sources_path)
    lock = load_lock(lock_path)

    do_devdocs = kind_filter in (None, "devdocs")
    do_sources = kind_filter is None or kind_filter in SOURCE_KINDS

    all_declared = list(families) + list(sources)
    if only_names:
        unknown = [n for n in only_names if n not in all_declared]
        if unknown:
            log(f"error: not declared in families.nix or sources.nix: {', '.join(unknown)}")
            sys.exit(2)

    relocked, unchanged, failed = [], [], []

    if do_devdocs:
        manifest = fetch_manifest(manifest_path)
        by_slug = dedup_by_slug(manifest)
        targets = [f for f in (only_names or families) if f in families]
        for family in targets:
            resolved = resolve_family(family, by_slug)
            if resolved is None:
                failed.append(family)
                log(f"  FAIL  {family}: no matching slug in {MANIFEST_URL}")
                continue
            existing = lock["docs"].get(family)
            if existing and existing.get("slug") == resolved["slug"] and existing.get("mtime") == resolved["mtime"]:
                unchanged.append(family)
                continue
            h = prefetch_hash(resolved["slug"])
            if h is None:
                failed.append(family)
                continue
            lock["docs"][family] = {
                "slug": resolved["slug"],
                "release": resolved.get("release", ""),
                "mtime": resolved["mtime"],
                "db_size": resolved.get("db_size"),
                "hash": h,
            }
            relocked.append(family)
            log(f"  OK    {family} -> {resolved['slug']} ({resolved.get('release') or '?'})")

    if do_sources:
        targets = [n for n in (only_names or sources) if n in sources]
        for name in targets:
            src = sources[name]
            if kind_filter and kind_filter in SOURCE_KINDS and src["kind"] != kind_filter:
                continue
            existing = lock["sources"].get(name)
            entry, was_unchanged = lock_one_source(name, src, existing)
            if entry is None:
                failed.append(name)
                continue
            lock["sources"][name] = entry
            if was_unchanged:
                unchanged.append(name)
            else:
                relocked.append(name)
                log(f"  OK    {name} -> {entry.get('version') or entry.get('commit', '')[:12]} "
                    f"({entry['kind']})")

    pruned = []
    if prune:
        for name in list(lock["docs"]):
            if name not in families:
                pruned.append(name)
                del lock["docs"][name]
        for name in list(lock["sources"]):
            if name not in sources:
                pruned.append(name)
                del lock["sources"][name]

    lock["schema"] = SCHEMA
    lock["manifest_url"] = MANIFEST_URL
    lock["generated"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    write_lock_atomic(lock_path, lock)

    parts = [f"{len(relocked)} relocked", f"{len(unchanged)} unchanged"]
    if pruned:
        parts.append(f"{len(pruned)} pruned")
    if failed:
        parts.append(f"{len(failed)} failed")
    if cleaned:
        parts.append(f"{cleaned} stale temp file(s) cleaned")
    tail = "nothing left to do" if not relocked and not pruned and not failed else ""
    log(f"{', '.join(parts)}{' -- ' + tail if tail else ''}")

    if failed:
        log(f"failed: {', '.join(failed)}")
        sys.exit(1)
    sys.exit(0)


def cmd_report(families_path, sources_path, lock_path, manifest_path):
    manifest = fetch_manifest(manifest_path)
    by_slug = dedup_by_slug(manifest)
    families = load_families(families_path)
    sources = load_nix_json(sources_path)
    lock = load_lock(lock_path)

    width = max((len(f) for f in list(families) + list(sources)), default=8)
    stale_upstream = []
    for family in families:
        resolved = resolve_family(family, by_slug)
        entry = lock["docs"].get(family)
        if resolved is None:
            print(f"{family:<{width}}  NOT FOUND upstream")
            continue
        locked_slug = entry["slug"] if entry else "(not locked)"
        locked_mtime = entry.get("mtime") if entry else None
        marker = ""
        if entry and (entry["slug"] != resolved["slug"] or locked_mtime != resolved["mtime"]):
            marker = "  <- upstream has moved, run `just devdocs-lock`"
            stale_upstream.append(family)
        print(f"{family:<{width}}  locked={locked_slug:<16} upstream={resolved['slug']:<16}"
              f" release={resolved.get('release') or '?'}{marker}")

    print()
    for name, src in sources.items():
        entry = lock["sources"].get(name)
        locked_version = (entry or {}).get("version") or (entry or {}).get("commit", "")[:12] or "(not locked)"
        try:
            if src["kind"] == "mavenJavadoc":
                resolved = resolve_maven(src)
                upstream = resolved["version"] if resolved else "NOT FOUND"
            elif src["kind"] == "javadocUrl":
                upstream = resolve_gradle()
            elif src["kind"] == "redisCommands":
                commit, _date = resolve_redis_commit(src["repo"], src.get("ref", "main"))
                upstream = commit[:12]
            else:
                upstream = "?"
        except (urllib.error.URLError, OSError, subprocess.SubprocessError) as exc:
            upstream = f"ERROR({exc})"
        marker = ""
        if entry and locked_version != upstream and not str(upstream).startswith(("NOT FOUND", "ERROR")):
            marker = "  <- upstream has moved, run `just devdocs-lock`"
            stale_upstream.append(name)
        print(f"{name:<{width}}  locked={locked_version:<16} upstream={upstream:<16} kind={src['kind']}{marker}")

    if stale_upstream:
        log(f"\n{len(stale_upstream)} famil{'y is' if len(stale_upstream)==1 else 'ies are'} "
            f"stale against upstream: {', '.join(stale_upstream)}")
        log("Note: downloads.devdocs.io serves only the CURRENT build for a slug, "
            "not a version history -- an old locked hash can stop fetching once "
            "upstream rebuilds. R2 (once a doc has been built and pushed there) "
            "is what makes a stale lock harmless in the meantime.")


def main():
    import argparse
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("families", nargs="*", help="limit to these family/source names (default: all declared)")
    p.add_argument("--report", action="store_true", help="read-only: what's installed/pinned/stale")
    p.add_argument("--prune", action="store_true", help="also drop lock entries no longer declared")
    p.add_argument(
        "--kind", choices=("devdocs",) + SOURCE_KINDS, default=None,
        help="restrict to one population: the DevDocs families, or one sources.nix kind "
             "(default: everything)",
    )
    p.add_argument(
        "--families-file",
        default=os.path.join(os.path.dirname(__file__), "families.nix"),
    )
    p.add_argument(
        "--sources-file",
        default=os.path.join(os.path.dirname(__file__), "sources.nix"),
    )
    p.add_argument(
        "--lock-file",
        default=os.path.join(os.path.dirname(__file__), "docs.lock.json"),
    )
    p.add_argument("--manifest-file", default=os.environ.get("DEVDOCS_MANIFEST"),
                    help="use a local docs.json instead of fetching (for tests)")
    args = p.parse_args()

    if args.report:
        cmd_report(args.families_file, args.sources_file, args.lock_file, args.manifest_file)
    else:
        cmd_lock(args.families_file, args.sources_file, args.lock_file, args.families,
                  args.prune, args.manifest_file, args.kind)


if __name__ == "__main__":
    main()
