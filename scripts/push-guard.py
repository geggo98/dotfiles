#!/usr/bin/env python3
"""Pre-push guard: look for third-party PII and internal infrastructure in
whatever a `git push` would publish, and hand the findings to the user.

Runs as a Claude Code PreToolUse hook on Bash(git push*). It never decides on
its own: a clean scan stays silent, anything else returns permissionDecision
"ask" so a human clears it. That mirrors the repo rule -- a clearance given
once does not carry over, so every push gets looked at again.

Stdlib only, on purpose: a guard that installs dependencies to run has a supply
chain of its own (same reasoning as infra/scripts/osv-audit.py).

THE ONE THING THAT MUST NOT BREAK: `git diff | grep '^+'` returns NOTHING in
this repo. modules/git.nix sets diff.external to difftastic in
~/.config/git/config, so `git diff` emits a structural view with line numbers
instead of a unified diff, and every plus-line filter silently matches zero
lines -- no error, exit code 0. A scan built on it reports "clean" because it
structurally cannot find anything. Measured 2026-08-27 while preparing a real
push: 0 plus-lines where --no-ext-diff gave 789.

  Details: modules/ai/_files/rules/git-external-diff.md (shipped globally to
  ~/.claude/rules/), and the memory note
  ~/.claude/projects/<project>/memory/git-diff-difftastic-bricht-plus-grep.md

Hence --no-ext-diff below, and hence scan_is_vacuous(): if there are commits to
push but the scan saw no lines, that is reported as INCONCLUSIVE rather than
clean. "No hits" is only a result once you know the filter could have hit.

Exit codes: 0 = decision emitted on stdout (or nothing to do). 1 = the guard
itself failed, which is also surfaced as "ask" rather than swallowed.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

# Paths where addresses and host names are cleared for publication. The Pulumi
# tree IS the infrastructure definition -- names and addresses are its content,
# not a leak. Everything outside still gets flagged.
ADDRESS_CLEARED_PREFIXES = ("infra/",)

# Machine-generated files whose hex is upstream revisions, never secrets.
HEX_EXEMPT_SUFFIXES = ("flake.lock", "pnpm-lock.yaml", ".lock")

# Identifier-ish prefixes that are standards or public advisories, not tickets.
TICKET_PREFIX_ALLOW = {
    "PEP", "ISO", "RFC", "UTF", "SHA", "AES", "RSA", "CVE", "GHSA", "DIN",
    "ASD", "STE", "GR", "HTTP", "TLS", "IPV", "MD", "CRC", "ANSI", "ECMA",
    "POSIX", "NIST", "FIPS", "OWASP", "SPDX", "SLSA", "ABC", "XXX",
}

# The repository owner's own addresses, plus the tooling address. Third-party
# addresses are exactly what this guard exists to catch, so the list stays tiny
# and explicit rather than pattern-based.
# md5, sha-1, sha-256: content digests, quoted constantly in this repo. An
# Atlassian account id is 24 hex, so the useful range survives the exclusion.
DIGEST_LENGTHS = {32, 40, 64}

# RFC 5737 (IPv4) and RFC 3849 (IPv6) documentation ranges. Reserved, so an
# address here can never be real infrastructure.
DOC_IP_PREFIXES = ("192.0.2.", "198.51.100.", "203.0.113.", "2001:db8:", "2001:DB8:")

# Public resolvers: quoting them is not disclosure.
PUBLIC_IP_ALLOW = {
    "0.0.0.0", "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4",
    "9.9.9.9", "149.112.112.112", "255.255.255.255",
}

# RFC 2606 reserves these; an address there identifies no real person.
EXAMPLE_DOMAINS = ("@example.com", "@example.org", "@example.net", "@example.test")

EMAIL_ALLOW = {
    "stefan@schwetschke.de",
    "noreply@anthropic.com",
}


def rx(pattern: str) -> re.Pattern:
    return re.compile(pattern, re.VERBOSE)


# matches:  someone.else@example.org  ->  $+{addr}
EMAIL = rx(r""" (?P<addr> [A-Za-z0-9._%+-]+ @ [A-Za-z0-9.-]+ \. [A-Za-z]{2,} ) """)

# matches:  192.0.2.10   203.0.113.7        (four dotted octets, 0-255 each)
IPV4 = rx(r"""
    (?<! [\w.] )
    (?P<addr>
      (?: 25[0-5] | 2[0-4]\d | 1\d\d | [1-9]?\d ) (?: \. (?: 25[0-5] | 2[0-4]\d | 1\d\d | [1-9]?\d ) ){3}
    )
    (?! [\w.] )
""")

# Two shapes only, so a clock ("12:34:56") or a version cannot match:
# compressed with "::", or the full eight groups.
# matches:  2001:db8:1:2::1   2001:db8::   2001:db8:0:0:0:0:0:1
IPV6 = rx(r"""
    (?<! [\w:.] )
    (?P<addr>
        (?: [0-9a-fA-F]{1,4} : ){1,7} :  (?: [0-9a-fA-F]{1,4} (?: : [0-9a-fA-F]{1,4} ){0,6} )?
      | (?: [0-9a-fA-F]{1,4} : ){7} [0-9a-fA-F]{1,4}
      | :: (?: [0-9a-fA-F]{1,4} (?: : [0-9a-fA-F]{1,4} ){0,6} )?
    )
    (?! [\w:.] )
""")

# matches:  <host>.pub.<machine-domain>   <host>.tailnet.<machine-domain>
INTERNAL_HOST = rx(r""" (?P<host> [A-Za-z0-9_-]+ (?: \. [A-Za-z0-9_-]+ )* \. (?: 0xf1a5c0\.net | ts\.net ) ) """)

# matches:  8 hex, dash, 4, dash, 4, dash, 4, dash, 12 hex
UUID = rx(r"""
    (?<! [\w-] )
    (?P<id> [0-9a-fA-F]{8} - [0-9a-fA-F]{4} - [0-9a-fA-F]{4} - [0-9a-fA-F]{4} - [0-9a-fA-F]{12} )
    (?! [\w-] )
""")

# matches:  712020:9b1c...  (Atlassian account id: numeric realm, colon, uuid)
ATLASSIAN_ID = rx(r""" (?P<id> \d{6} : [0-9a-fA-F-]{30,40} ) """)

# matches:  <2-10 caps>-<2-6 digits>;  PEP-723 etc. filtered by TICKET_PREFIX_ALLOW
TICKET = rx(r"""
    (?<! [\w-] )
    (?P<key> (?P<prefix> [A-Z][A-Z0-9]{1,9} ) - (?P<num> \d{2,6} ) )
    (?! [\w-] )
""")

# matches a bare hex blob that is neither a nix hash nor an inline code span
HEXBLOB = rx(r""" (?<! [\w/-] ) (?P<id> [0-9a-f]{24,} ) (?! [\w-] ) """)


# --no-textconv is a SECURITY flag here, not a formatting one. .gitattributes
# maps *.enc.yaml to the `sopsdiffer` driver whose textconv is `sops -d`, so a
# plain `git diff` hands back DECRYPTED secrets. Measured 2026-08-27 on a real
# commit: 3 plaintext hits with textconv, 0 with --no-textconv. Without it this
# guard would read secrets and print them into its own findings output.
#
# --no-ext-diff is the difftastic fix described in the module docstring.
DIFF_FLAGS = ("--no-ext-diff", "--no-textconv", "--no-color", "-U0")


def git(*args: str) -> str:
    """Run git and return stdout. Never uses the external differ."""
    res = subprocess.run(
        ["git", "--no-pager", *args],
        capture_output=True, text=True, check=False,
    )
    if res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {res.stderr.strip()}")
    return res.stdout


def commits_to_push() -> tuple[list[str], str]:
    """Commits that exist locally and on no remote, plus a human description."""
    try:
        upstream = git("rev-parse", "--abbrev-ref", "@{u}").strip()
        rng = f"{upstream}..HEAD"
        return git("rev-list", rng).split(), rng
    except RuntimeError:
        pass
    # No upstream (new branch, or `git push origin main` without -u).
    out = git("rev-list", "HEAD", "--not", "--remotes")
    return out.split(), "HEAD --not --remotes"


def added_lines(commits: list[str]) -> list[tuple[str, int, str]]:
    """(path, lineno, text) for every added line across the pushed commits.

    --no-ext-diff is load-bearing; see the module docstring.
    """
    if not commits:
        return []
    base, tip = f"{commits[-1]}^", commits[0]
    try:
        diff = git("diff", *DIFF_FLAGS, base, tip)
    except RuntimeError:
        # Root commit has no parent; diff against the empty tree.
        empty = git("hash-object", "-t", "tree", "/dev/null").strip()
        diff = git("diff", *DIFF_FLAGS, empty, tip)

    out, path, lineno = [], "?", 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path, lineno = line[6:], 0
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            lineno = int(m.group(1)) if m else 0
        elif line.startswith("+") and not line.startswith("+++"):
            out.append((path, lineno, line[1:]))
            lineno += 1
    return out


def commit_messages(commits: list[str]) -> list[tuple[str, int, str]]:
    """Commit messages are published too, so they are scanned like content."""
    out = []
    for sha in commits:
        body = git("show", "-s", "--format=%B", sha)
        for i, line in enumerate(body.splitlines(), 1):
            out.append((f"(commit message {sha[:9]})", i, line))
    return out


def address_cleared(path: str) -> bool:
    return path.startswith(ADDRESS_CLEARED_PREFIXES)


def scan(rows: list[tuple[str, int, str]]) -> list[dict]:
    findings = []

    def add(path, lineno, kind, value, text):
        findings.append({
            "kind": kind, "file": path, "line": lineno,
            "value": value, "context": text.strip()[:160],
        })

    for path, lineno, text in rows:
        if "/nix/store/" in text:
            text_for_hex = re.sub(r"/nix/store/\S+", " ", text)
        else:
            text_for_hex = text

        for m in EMAIL.finditer(text):
            addr = m.group("addr").lower()
            if addr.endswith(EXAMPLE_DOMAINS):
                continue
            if addr not in EMAIL_ALLOW:
                add(path, lineno, "email address of a third party", m.group("addr"), text)

        for m in ATLASSIAN_ID.finditer(text):
            add(path, lineno, "Atlassian-style account id", m.group("id"), text)

        if not path.endswith(HEX_EXEMPT_SUFFIXES):
            for m in UUID.finditer(text):
                add(path, lineno, "UUID / account-id shape", m.group("id"), text)

        if not address_cleared(path):
            for m in IPV4.finditer(text):
                a = m.group("addr")
                # Version numbers and netmask-free zeros are not addresses.
                if (a.startswith(("0.", "127.")) or a.endswith(".0.0")
                        or a in PUBLIC_IP_ALLOW or a.startswith(DOC_IP_PREFIXES)):
                    continue
                add(path, lineno, "IP address outside infra/", a, text)
            for m in IPV6.finditer(text):
                a = m.group("addr")
                # "::" is the unspecified address and "::1" the loopback --
                # neither names infrastructure, and both occur in code.
                if a in ("::", "::1") or a.startswith(DOC_IP_PREFIXES):
                    continue
                add(path, lineno, "IPv6 address outside infra/", m.group("addr"), text)
            for m in INTERNAL_HOST.finditer(text):
                add(path, lineno, "internal host name outside infra/", m.group("host"), text)

        for m in TICKET.finditer(text):
            if m.group("prefix") not in TICKET_PREFIX_ALLOW:
                add(path, lineno, "ticket-key shape", m.group("key"), text)

        if not path.endswith(HEX_EXEMPT_SUFFIXES):
            for m in HEXBLOB.finditer(text_for_hex):
                if len(m.group("id")) in DIGEST_LENGTHS:
                    continue
                add(path, lineno, "long hex identifier", m.group("id"), text)

    return findings


def render(findings: list[dict], rng: str, n_commits: int, n_rows: int) -> str:
    by_kind: dict[str, list[dict]] = {}
    for f in findings:
        by_kind.setdefault(f["kind"], []).append(f)

    lines = [
        "Pre-push check found content that needs your explicit clearance.",
        "",
        f"Scanned {n_commits} commit(s) ({rng}) — {n_rows} added lines "
        f"plus their commit messages.",
        "",
        "This repository is PUBLIC. A clearance given once does not carry over, "
        "so each of these needs a decision now:",
        "",
    ]
    for kind, items in sorted(by_kind.items()):
        lines.append(f"{kind} — {len(items)}x")
        for f in items[:6]:
            lines.append(f"    {f['file']}:{f['line']}  {f['value']}")
            lines.append(f"        {f['context']}")
        if len(items) > 6:
            lines.append(f"    … and {len(items) - 6} more")
        lines.append("")
    lines += [
        "IP addresses and host names under infra/ are already cleared and are "
        "not reported.",
        "Everything above is either third-party personal data or internal "
        "infrastructure until you say otherwise.",
    ]
    return "\n".join(lines)


def decide(reason: str) -> None:
    json.dump({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }, sys.stdout)
    sys.stdout.write("\n")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # not our business

    cmd = (payload.get("tool_input") or {}).get("command", "")
    if not re.search(r"\bgit\b[^|;&]*\bpush\b", cmd):
        return 0
    if "--dry-run" in cmd:
        return 0  # a dry run publishes nothing

    root = os.environ.get("CLAUDE_PROJECT_DIR")
    if root and os.path.isdir(root):
        os.chdir(root)

    try:
        commits, rng = commits_to_push()
        rows = added_lines(commits) + commit_messages(commits)
    except Exception as exc:
        decide(
            "The pre-push PII/infrastructure guard could not run, so nothing "
            f"has been checked: {exc}\n\n"
            "Do not treat this as a clean result. Scan manually with "
            "`git diff --no-ext-diff origin/main..HEAD` before publishing."
        )
        return 0

    if not commits:
        return 0

    # A filter that structurally cannot match reports the same thing as a clean
    # result. Say so instead of saying "clean".
    if not rows:
        decide(
            f"The pre-push guard saw {len(commits)} commit(s) to push but read "
            "0 lines from them, so it cannot have found anything. This is the "
            "difftastic failure mode described in "
            "modules/ai/_files/rules/git-external-diff.md. Check the guard "
            "before trusting this push."
        )
        return 0

    findings = scan(rows)
    if findings:
        decide(render(findings, rng, len(commits), len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
