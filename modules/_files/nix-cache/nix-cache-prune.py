#!/usr/bin/env python3
"""Remove a category of store paths from the R2 binary cache, safely.

WHY THIS EXISTS. `nix-cache-push` only ever adds. Until 02.09.2026 there was no
way to take anything out, and that turned out to matter: the post-build-hook had
been publishing per-project devenv outputs — `devenv-files` is a script carrying
the checkout's ABSOLUTE PATH, and `devenv-processes-<name>` puts the project's
own process names into a world-readable narinfo. The hook now filters them
(modules/nix-cache.nix), but the filter cannot retract what is already there.

DRY RUN BY DEFAULT. `--apply` is the only way to delete anything, and it is a
one-way door: R2 has no versioning on this bucket.

THREE SAFETY PROPERTIES, each of which cost a measurement:

1. REFERENTIAL COMPLETENESS. A binary cache must be closed under references, so
   deleting X while some surviving narinfo still lists X in its References would
   leave that survivor unusable. This script therefore deletes the transitive
   UPWARD closure of the selection, and refuses to start if that closure would
   still leave a dangling reference. On the devenv set this pulled in 53 further
   objects (`tasks.json`, `nix-darwin-env`, `process-compose.yaml`) — all of them
   devenv outputs too, just without the prefix.

2. SHARED NARs. Two store paths with identical contents share one `nar/<hash>`
   object. A NAR is only deleted once no surviving narinfo points at it.

3. THE EDGE CACHE IS NOT A DISASTER, but know what it does. `infra/src/index.ts`
   caches 200s for 30 days, so a deleted narinfo keeps being served for up to a
   month while its NAR is already gone. Measured 03.09.2026 against a local
   file:// cache built to reproduce exactly that state: with a second substituter
   configured, Nix prints
       warning: file 'nar/….nar.xz' does not exist in binary cache
   and copies from the next substituter — it does NOT abort. With no other
   source it reports "no substituter that can build it", at which point Nix
   builds the path locally, which for a devenv output is what happens anyway.
   So the stale window degrades to a warning plus a rebuild, not to a broken
   system. Purging the Cloudflare cache closes it immediately, but needs an API
   token with Zone.Cache Purge that is not on these machines.

RESUMABLE, per the rule in AGENTS.md: the state is the bucket itself. An
interrupted run leaves some objects deleted and some not; re-running asks the
bucket again and continues. Nothing is written down that could go missing
exactly when the run died badly.

Outcomes are counted separately and never collapsed:
  DELETED  the object was there and is now gone
  SKIP     already absent (a re-run, or someone else got there first)
  ERROR    the delete failed; the object is still there, re-run to retry
  KEPT     deliberately not touched (a NAR a survivor still needs)

Exit codes: 0 did work or nothing to do, 1 some deletes failed, 2 refused to
start because a safety check did not hold.
"""
import argparse
import collections
import concurrent.futures as futures
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

BUCKET = os.environ.get("NIX_CACHE_BUCKET", "nix-cache")
PUBLIC = os.environ.get("NIX_CACHE_PUBLIC_URL", "https://nix-cache.pub.schwetschke.dev")

# Cloudflare answers the default Python-urllib user agent with 403. Measured: the
# same URL is 200 from curl and 200 from urllib with a curl UA. Without this every
# fetch fails — and a script that folded those failures into "not found" would
# report a clean "nothing to prune" and be believed. Hence errors are counted and
# reported separately, and a non-empty error count aborts before any delete.
UA = {"User-Agent": "curl/8.7.1"}

# The category this script was written for. Same rule as the hook's filter in
# modules/nix-cache.nix, minus the devenv package itself, and minus
# devenv-nixpkgs-patched — that one is upstream devenv's nixpkgs checkout and
# carries no project detail, so there is nothing to retract.
DEVENV_KEEP = re.compile(r"^devenv$|^devenv-\d|^devenv-wrapped-|^devenv-nixpkgs-patched")
CATEGORIES = {
    "devenv": lambda name: name.startswith("devenv-") and not DEVENV_KEEP.match(name),
}


def aws(*args, capture=True):
    cmd = ["aws", *args]
    r = subprocess.run(cmd, capture_output=capture, text=True)
    return r.returncode, (r.stdout if capture else ""), (r.stderr if capture else "")


def list_keys():
    rc, out, err = aws("s3api", "list-objects-v2", "--bucket", BUCKET,
                       "--output", "json", "--query", "Contents[].Key")
    if rc != 0:
        sys.exit(f"nix-cache-prune: listing {BUCKET} failed: {err.strip()[:400]}")
    return json.loads(out) or []


def fetch_narinfo(key):
    try:
        with urllib.request.urlopen(
                urllib.request.Request(f"{PUBLIC}/{key}", headers=UA), timeout=30) as r:
            body = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return {"key": key, "error": f"HTTP {e.code}"}
    except Exception as e:
        return {"key": key, "error": type(e).__name__}
    rec = {"key": key}
    for line in body.splitlines():
        k, _, v = line.partition(": ")
        if k == "StorePath":
            rec["storePath"] = v
            rec["name"] = v.split("-", 1)[1] if "-" in v else v
        elif k == "URL":
            rec["url"] = v
        elif k == "References":
            rec["refs"] = v.split()
    return rec


def index(keys, jobs):
    narinfos = [k for k in keys if k.endswith(".narinfo")]
    recs = []
    with futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        for i, rec in enumerate(ex.map(fetch_narinfo, narinfos), 1):
            recs.append(rec)
            if i % 2000 == 0:
                print(f"  indexed {i}/{len(narinfos)}", file=sys.stderr, flush=True)
    return recs


def upward_closure(seed, recs):
    """Everything that (transitively) references the seed, plus the seed."""
    rev = collections.defaultdict(set)
    for r in recs:
        for ref in r.get("refs", []):
            full = ref if ref.startswith("/nix/store/") else f"/nix/store/{ref}"
            if full != r["storePath"]:
                rev[full].add(r["storePath"])
    closure, stack = set(seed), list(seed)
    while stack:
        p = stack.pop()
        for up in rev.get(p, ()):
            if up not in closure:
                closure.add(up)
                stack.append(up)
    return closure


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("category", choices=sorted(CATEGORIES),
                    help="which category of store paths to remove")
    ap.add_argument("--apply", action="store_true",
                    help="actually delete; without it this is a dry run")
    ap.add_argument("--jobs", type=int, default=16)
    args = ap.parse_args()
    match = CATEGORIES[args.category]

    print(f"listing {BUCKET} …", file=sys.stderr)
    keys = list_keys()
    present = set(keys)
    print(f"  {len(keys)} objects", file=sys.stderr)

    print("indexing narinfos …", file=sys.stderr)
    recs = index(keys, args.jobs)
    bad = [r for r in recs if "error" in r]
    ok = [r for r in recs if "storePath" in r]
    print(f"  {len(ok)} readable, {len(bad)} unreadable", file=sys.stderr)
    if bad:
        # Refuse rather than guess. An unreadable narinfo could be a member of the
        # category, could be referenced by one, and could name a NAR that must be
        # kept. Deleting around an unknown is how a cache loses referential
        # completeness quietly.
        kinds = collections.Counter(r["error"] for r in bad)
        print(f"nix-cache-prune: refusing — {len(bad)} narinfo(s) could not be read "
              f"({dict(kinds)}). Re-run; if it persists, investigate before pruning.",
              file=sys.stderr)
        for r in bad[:5]:
            print(f"  {r['key']}: {r['error']}", file=sys.stderr)
        return 2

    by_path = {r["storePath"]: r for r in ok}
    seed = {r["storePath"] for r in ok if match(r["name"])}
    doomed = upward_closure(seed, ok)
    survivors = [r for r in ok if r["storePath"] not in doomed]

    dangling = [(r["name"], ref) for r in survivors for ref in r.get("refs", [])
                if (ref if ref.startswith("/nix/store/") else f"/nix/store/{ref}") in doomed]
    if dangling:
        print(f"nix-cache-prune: refusing — {len(dangling)} surviving reference(s) would "
              "dangle. This is a bug in the closure computation, not a config choice.",
              file=sys.stderr)
        return 2

    keep_nars = {r["url"] for r in survivors if "url" in r}
    del_narinfos = sorted(f"{p.split('/')[-1].split('-')[0]}.narinfo" for p in doomed)
    del_nars = sorted({by_path[p]["url"] for p in doomed if "url" in by_path[p]} - keep_nars)
    shared = len({by_path[p]["url"] for p in doomed if "url" in by_path[p]} & keep_nars)

    kinds = collections.Counter(
        re.sub(r"^([A-Za-z+._]+(?:-[A-Za-z]+)*).*", r"\1", by_path[p]["name"]) for p in doomed)
    print(f"\ncategory '{args.category}': {len(seed)} matched, "
          f"{len(doomed)} after upward closure ({len(doomed) - len(seed)} referrers)")
    for k, n in sorted(kinds.items()):
        print(f"  {k:34} {n:5}")
    print(f"\nwould delete: {len(del_narinfos)} narinfo(s), {len(del_nars)} NAR(s)")
    if shared:
        print(f"KEPT: {shared} NAR(s) still referenced by surviving paths")

    if not args.apply:
        print("\ndry run — nothing deleted. Re-run with --apply to do it.")
        return 0

    deleted = skipped = errors = 0
    def rm(key):
        if key not in present:
            return "SKIP", key, ""
        rc, _, err = aws("s3api", "delete-object", "--bucket", BUCKET, "--key", key)
        return ("DELETED" if rc == 0 else "ERROR"), key, err.strip()[:200]

    # narinfos FIRST: while a narinfo is gone but its NAR is not, the cache is
    # merely missing a path. The reverse order would advertise a NAR that is not
    # there, which is the state worth avoiding even for the seconds it would last.
    with futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for state, key, err in ex.map(rm, del_narinfos + del_nars):
            if state == "DELETED":
                deleted += 1
            elif state == "SKIP":
                skipped += 1
            else:
                errors += 1
                print(f"  ERROR {key}: {err}", file=sys.stderr)

    print(f"\n{deleted} deleted, {skipped} already gone, {errors} errors, {shared} kept "
          f"(still referenced)")
    if errors:
        print("re-run to retry the failures — the bucket is the state, nothing to reset.")
    print("NOTE: narinfo 200s stay in Cloudflare's edge cache for up to 30 days "
          "(infra/src/index.ts). Nix warns and falls back; it does not break.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
