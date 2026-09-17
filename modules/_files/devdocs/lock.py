"""Resolve every family in modules/_files/devdocs/families.nix to its newest
DevDocs slug, prefetch the tarball hash via `nix store prefetch-file`, and
(re)write modules/_files/devdocs/docs.lock.json. Backs `just devdocs-lock`
(writes) and `just devdocs-list` (--report, read-only).

Stdlib-only, no PEP-723/uv header -- same reasoning as build-index.py and
devdocs-cli.py: nothing to lock, and this is a one-shot CLI script, not a
long-running service.

Resolution rule, matching modules/devdocs.nix's own (looser) check: if
docs.json lists a slug exactly equal to the family name, that wins (`node`,
`typescript`, `git`); otherwise the highest-versioned `<family>~*`, compared
NUMERICALLY on the dotted suffix (`python~3.14` must beat `python~3.9` --
a string sort gets that backwards). docs.json has been observed to carry
DUPLICATE slugs (measured 2026-09-17: "bun" and "vitest" each appeared
twice, one entry stale enough that its own `links.home` pointed at
leafletjs.com) -- deduplicated by keeping the highest `mtime` per slug
before resolution ever runs.

Exit codes, matching infra/scripts/osv-audit.py's convention: 0 did-work-or-
nothing-to-do, 1 at least one declared family failed to resolve, 2 tool/
network error.
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

MANIFEST_URL = "https://devdocs.io/docs.json"
SCHEMA = 1


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


def load_families(families_path):
    """families.nix is a plain Nix list -- read via `nix eval --json`
    rather than parsing Nix syntax by hand."""
    out = subprocess.run(
        ["nix", "eval", "--json", "--file", families_path],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def sanitize_name(slug):
    return re.sub(r"[^0-9a-zA-Z+._?=-]", "-", slug)


def prefetch_hash(slug):
    url = f"https://downloads.devdocs.io/{slug}.tar.gz"
    name = f"devdocs-{sanitize_name(slug)}.tar.gz"
    try:
        out = subprocess.run(
            ["nix", "store", "prefetch-file", "--json", "--name", name, url],
            capture_output=True, text=True, timeout=300, check=True,
        )
    except subprocess.CalledProcessError as exc:
        log(f"  prefetch failed for {slug}: {exc.stderr.strip()}")
        return None
    except subprocess.TimeoutExpired:
        log(f"  prefetch timed out for {slug}")
        return None
    return json.loads(out.stdout)["hash"]


def load_lock(lock_path):
    if os.path.exists(lock_path):
        with open(lock_path, encoding="utf-8") as f:
            return json.load(f)
    return {"schema": SCHEMA, "generated": "", "manifest_url": MANIFEST_URL, "docs": {}}


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


def cleanup_stale_temp(lock_path):
    d = os.path.dirname(os.path.abspath(lock_path)) or "."
    base = os.path.basename(lock_path)
    n = 0
    for f in os.listdir(d):
        if f.startswith(f".{base}.") and f.endswith(".tmp"):
            os.unlink(os.path.join(d, f))
            n += 1
    return n


def cmd_lock(families_path, lock_path, only_families, prune, manifest_path):
    cleaned = cleanup_stale_temp(lock_path)
    manifest = fetch_manifest(manifest_path)
    by_slug = dedup_by_slug(manifest)
    families = load_families(families_path)
    lock = load_lock(lock_path)

    targets = only_families if only_families else families
    unknown_targets = [f for f in targets if f not in families]
    if unknown_targets:
        log(f"error: not declared in families.nix: {', '.join(unknown_targets)}")
        sys.exit(2)

    relocked, unchanged, failed = [], [], []
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

    pruned = []
    if prune:
        for name in list(lock["docs"]):
            if name not in families:
                pruned.append(name)
                del lock["docs"][name]

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


def cmd_report(families_path, lock_path, manifest_path):
    manifest = fetch_manifest(manifest_path)
    by_slug = dedup_by_slug(manifest)
    families = load_families(families_path)
    lock = load_lock(lock_path)

    width = max((len(f) for f in families), default=8)
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
    p.add_argument("families", nargs="*", help="limit to these families (default: all declared)")
    p.add_argument("--report", action="store_true", help="read-only: what's installed/pinned/stale")
    p.add_argument("--prune", action="store_true", help="also drop lock entries no longer declared")
    p.add_argument(
        "--families-file",
        default=os.path.join(os.path.dirname(__file__), "families.nix"),
    )
    p.add_argument(
        "--lock-file",
        default=os.path.join(os.path.dirname(__file__), "docs.lock.json"),
    )
    p.add_argument("--manifest-file", default=os.environ.get("DEVDOCS_MANIFEST"),
                    help="use a local docs.json instead of fetching (for tests)")
    args = p.parse_args()

    if args.report:
        cmd_report(args.families_file, args.lock_file, args.manifest_file)
    else:
        cmd_lock(args.families_file, args.lock_file, args.families, args.prune, args.manifest_file)


if __name__ == "__main__":
    main()
