#!/usr/bin/env python3
"""Audit infra/pnpm-lock.yaml against OSV, and flag freshly published entries.

Why this exists next to GitHub's Dependabot alerts: on 04.08.2026 Dependabot showed
2 advisories for this lockfile while OSV returned 7 for the same tree, including the
two HIGH ones (ip-address GHSA-mwp4-54f8-5fhr, brace-expansion GHSA-rgw5-rvv9-x895).
All seven had been published the day before -- Dependabot simply had not caught up on
the transitive deps yet. An alert page you cannot date is an alert page you cannot
use to rule anything out, so this asks the source directly.

Two independent checks, because they fail differently:

  advisories  every locked name@version against OSV's querybatch endpoint. Catches
              known CVEs; blind to a compromise nobody has filed yet.
  freshness   the npm publish date of every locked version. Catches the opposite
              case -- during the Shai-Hulud npm worm (03./04.08.2026) the useful
              question was not "is anything flagged?" but "did anything published
              inside the attack window get into the tree at all?". The answer was
              no, and only the dates could show that.

Stdlib only, on purpose: an auditing tool that installs dependencies to run has a
supply chain of its own. No PEP-723 header, hence no sibling .lock to keep in sync.

Exit codes: 0 clean, 1 advisories found, 2 tool/network error.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

OSV_BATCH = "https://api.osv.dev/v1/querybatch"
OSV_VULN = "https://api.osv.dev/v1/vulns/"
REGISTRY = "https://registry.npmjs.org/"

# Lockfile keys look like `  name@version:`, `  '@scope/name@version':` or
# `  '@scope/name@version(peer@1.2.3)':`. The peer suffix is a pnpm resolution
# variant of the same tarball, so it is stripped before dedup.
KEY_RE = re.compile(r"^  '?([^\s:']+)'?:\s*$", re.M)
NAME_VER_RE = re.compile(r"^(@?[^@]+(?:/[^@]+)?)@([0-9].*)$")


def parse_lock(text: str) -> list[tuple[str, str]]:
    found = set()
    for key in KEY_RE.findall(text):
        m = NAME_VER_RE.match(re.sub(r"\(.*\)$", "", key))
        if m:
            found.add(m.groups())
    return sorted(found)


def _get_json(url: str, data: bytes | None = None, timeout: int = 60):
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def query_osv(pkgs: list[tuple[str, str]]) -> list[dict]:
    queries = [{"package": {"ecosystem": "npm", "name": n}, "version": v} for n, v in pkgs]
    results = _get_json(OSV_BATCH, json.dumps({"queries": queries}).encode())["results"]
    hits = []
    for (name, version), res in zip(pkgs, results):
        for vuln in res.get("vulns", []):
            hits.append({"package": name, "version": version, "id": vuln["id"]})
    # querybatch returns IDs only; the severity and the fixed version -- the two things
    # that decide whether to act -- need the detail endpoint.
    for hit in hits:
        try:
            d = _get_json(OSV_VULN + hit["id"], timeout=30)
        except urllib.error.URLError:
            continue
        hit["summary"] = d.get("summary", "")
        hit["aliases"] = d.get("aliases", [])
        hit["severity"] = (d.get("database_specific") or {}).get("severity", "UNKNOWN")
        fixed = []
        for aff in d.get("affected", []):
            if aff.get("package", {}).get("name") != hit["package"]:
                continue
            for rng in aff.get("ranges", []):
                fixed += [e["fixed"] for e in rng.get("events", []) if "fixed" in e]
        hit["fixed"] = fixed
    return hits


def publish_dates(pkgs: list[tuple[str, str]]) -> dict[tuple[str, str], str]:
    """Publish timestamp per locked version, via the full packument.

    The abbreviated packument (Accept: application/vnd.npm.install-v1+json) is a much
    smaller download but carries no per-version `time` map -- asking for it silently
    yields "unknown" for every entry, which reads exactly like "nothing is recent".
    """
    def fetch(name: str) -> tuple[str, dict]:
        url = REGISTRY + urllib.parse.quote(name, safe="@")
        try:
            return name, _get_json(url).get("time", {})
        except (urllib.error.URLError, ValueError, TimeoutError):
            return name, {}

    names = sorted({n for n, _ in pkgs})
    times: dict[str, dict] = {}
    with cf.ThreadPoolExecutor(16) as pool:
        for name, t in pool.map(fetch, names):
            times[name] = t
    return {(n, v): times.get(n, {}).get(v, "") for n, v in pkgs}


def render(pkgs, hits, dates, cooldown_days: int) -> str:
    cutoff = (datetime.now(timezone.utc) - timedelta(days=cooldown_days)).isoformat()
    fresh = sorted(((t, n, v) for (n, v), t in dates.items() if t and t >= cutoff), reverse=True)
    unknown = [f"{n}@{v}" for (n, v), t in dates.items() if not t]
    newest = max((t for t in dates.values() if t), default="")

    out = [f"{len(pkgs)} locked versions", ""]
    if hits:
        out.append(f"ADVISORIES: {len(hits)}")
        # Explicit order, not reverse-alphabetical: "MODERATE" > "HIGH" as a string,
        # which would bury exactly the findings worth reading first.
        rank = {"CRITICAL": 0, "HIGH": 1, "MODERATE": 2, "LOW": 3}
        for h in sorted(hits, key=lambda x: (rank.get(x.get("severity", ""), 9), x["package"])):
            alias = f" ({', '.join(h.get('aliases', []))})" if h.get("aliases") else ""
            fixed = ", ".join(h.get("fixed", [])) or "?"
            out.append(f"  [{h.get('severity','?'):8}] {h['package']}@{h['version']} -> fixed in {fixed}")
            out.append(f"             {h['id']}{alias}")
            if h.get("summary"):
                out.append(f"             {h['summary']}")
    else:
        out.append("ADVISORIES: none")
    out.append("")

    out.append(f"newest locked version published: {newest[:19] or 'unknown'}")
    if fresh:
        # Not an error: a legitimate release simply aged past the cooldown between the
        # last resolve and now. It is worth eyeballing during an active incident.
        out.append(f"published within the last {cooldown_days} d ({len(fresh)}):")
        out += [f"  {t[:19]}  {n}@{v}" for t, n, v in fresh]
    else:
        out.append(f"nothing published within the last {cooldown_days} d")
    if unknown:
        out.append(f"publish date unresolved ({len(unknown)}): {', '.join(sorted(unknown))}")
    return "\n".join(out) + "\n"


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("lockfile", nargs="?", default=str(here.parent / "pnpm-lock.yaml"),
                    help="pnpm-lock.yaml to audit; '-' reads stdin (default: ../pnpm-lock.yaml)")
    ap.add_argument("--format", choices=("text", "json"), default="text")
    ap.add_argument("--output", metavar="PATH", help="write the report to PATH ('-' = stdout)")
    ap.add_argument("--cooldown-days", type=int, default=3,
                    help="flag versions published within this many days (default: 3, "
                         "matching minimumReleaseAge in pnpm-workspace.yaml)")
    args = ap.parse_args()

    text = sys.stdin.read() if args.lockfile == "-" else Path(args.lockfile).read_text()
    pkgs = parse_lock(text)
    if not pkgs:
        print(f"no package entries found in {args.lockfile}", file=sys.stderr)
        return 2

    try:
        hits = query_osv(pkgs)
        dates = publish_dates(pkgs)
    except (urllib.error.URLError, ValueError, TimeoutError) as e:
        print(f"audit could not complete: {e}", file=sys.stderr)
        return 2

    if args.format == "json":
        report = json.dumps(
            {"locked": len(pkgs), "advisories": hits,
             "published": {f"{n}@{v}": t for (n, v), t in sorted(dates.items())}},
            indent=2, sort_keys=True) + "\n"
    else:
        report = render(pkgs, hits, dates, args.cooldown_days)

    if args.output and args.output != "-":
        Path(args.output).write_text(report)
        print(f"{args.output}\t{len(report.encode())}")
    else:
        sys.stdout.write(report)

    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
