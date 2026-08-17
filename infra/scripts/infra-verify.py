#!/usr/bin/env python3
"""Verify the recorded inventory of unprovisioned hosts against reality.

Why this exists: `infra/src/inventory.ts` records hosts Pulumi cannot manage --
the IONOS VPS lives in the Cloud Panel, which has no API for this tariff and no
Terraform/Pulumi provider (see that file's header for the evidence). So `pulumi
preview` reconciles nothing here: the constants could drift arbitrarily far from
the real machine and every Pulumi command would still report a clean stack. That
is precisely the failure mode this repo treats as unacceptable -- an inventory you
cannot falsify is documentation wearing an inventory's clothes.

What it checks, per host, over both address families:

  reachability  can we open an SSH connection at all
  identity      does the presented Ed25519 host key match the recorded one

The host key is the useful invariant. It changes if the machine is reinstalled,
if the address now points somewhere else, or if something is intercepting the
connection -- three failures, one comparison. The recorded keys double as
`known_hosts` material for pinning host keys instead of `accept-new`.

The inventory is read straight from the TypeScript source via Node's native type
stripping (Node >= 22.18), not from a build artefact or a duplicated JSON file, so
there is exactly one place these values live.

Stdlib only, matching osv-audit.py next door: no PEP-723 header, hence no sibling
.lock to keep in sync.

Exit codes: 0 all hosts verified, 1 a check failed, 2 tool error.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

# `ssh-keyscan <addr>` prints `<addr> <keytype> <base64>`; we compare the last two
# fields, since the address column differs between the v4 and v6 probe of one host.
# matches:  87.106.149.208 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
#           -> ("ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAA...")
KEY_TYPE = "ssh-ed25519"


def load_inventory(inventory_ts: Path) -> dict[str, dict]:
    """Import the TypeScript inventory through Node and hand back plain data."""
    if not inventory_ts.is_file():
        # Checked here so the common typo does not arrive as twenty lines of
        # ERR_MODULE_NOT_FOUND stack trace with the useful sentence at the top.
        raise RuntimeError(f"no such file: {inventory_ts}")
    node = shutil.which("node")
    if node is None:
        raise RuntimeError(
            "node not found on PATH -- run inside `nix develop` (the devenv shell "
            "provides Node 24, whose native type stripping reads inventory.ts directly)"
        )
    # The missing-export check belongs here rather than in Python: JSON.stringify
    # of a missing symbol yields the *string* "undefined", which would reach us as
    # non-empty output and fail later as an opaque JSON decode error.
    script = (
        f'const m = await import({json.dumps(inventory_ts.resolve().as_uri())});\n'
        "if (m.unmanagedHosts === undefined) {\n"
        '  console.error("module has no `unmanagedHosts` export");\n'
        "  process.exit(3);\n"
        "}\n"
        "console.log(JSON.stringify(m.unmanagedHosts));\n"
    )
    proc = subprocess.run(
        [node, "--input-type=module", "-e", script],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        # Node prints the diagnosis then a stack through its own internals, which
        # says nothing about this repo. Keep the lines that name the problem.
        blame = [
            line for line in proc.stderr.splitlines()
            if line.strip() and not line.lstrip().startswith("at ")
        ]
        raise RuntimeError(
            f"could not import {inventory_ts}:\n  "
            + "\n  ".join(blame[:6] or ["(no output from node)"])
        )
    return json.loads(proc.stdout)


def scan_host_key(address: str, timeout: int) -> str:
    """Return the host's Ed25519 key, or raise if it cannot be obtained.

    ssh-keyscan reports an unreachable host on stderr and can still exit 0, so an
    empty stdout is treated as failure regardless of the exit status. Anything
    else would let "host is gone" read exactly like "host is fine".
    """
    keyscan = shutil.which("ssh-keyscan")
    if keyscan is None:
        raise RuntimeError("ssh-keyscan not found on PATH")
    proc = subprocess.run(
        [keyscan, "-T", str(timeout), "-t", "ed25519", address],
        capture_output=True, text=True,
    )
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[1] == KEY_TYPE:
            return f"{fields[1]} {fields[2]}"
    detail = proc.stderr.strip().splitlines()
    raise RuntimeError(
        f"no {KEY_TYPE} host key from {address}"
        + (f" ({detail[-1]})" if detail else " (no response within %ds)" % timeout)
    )


def verify(name: str, host: dict, timeout: int) -> list[str]:
    """Check one host on every address it claims. Returns a list of failures."""
    failures: list[str] = []
    expected = host["sshHostKeyEd25519"]
    for family, address in (("IPv4", host.get("ipv4")), ("IPv6", host.get("ipv6"))):
        if not address:
            continue
        label = f"{name} {family} {address}"
        try:
            actual = scan_host_key(address, timeout)
        except RuntimeError as e:
            print(f"  FAIL  {label}: {e}")
            failures.append(label)
            continue
        if actual != expected:
            print(f"  FAIL  {label}: host key does not match the inventory")
            print(f"          recorded: {expected}")
            print(f"          presented: {actual}")
            failures.append(label)
        else:
            print(f"  ok    {label}: host key matches")
    return failures


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument(
        "--inventory", type=Path, default=here.parent / "src" / "inventory.ts",
        help="TypeScript inventory to verify (default: ../src/inventory.ts)",
    )
    ap.add_argument(
        "--timeout", type=int, default=8,
        help="seconds to wait for each ssh-keyscan (default: 8)",
    )
    ap.add_argument("--host", help="verify only this inventory key")
    args = ap.parse_args()

    try:
        hosts = load_inventory(args.inventory)
    except (RuntimeError, json.JSONDecodeError) as e:
        print(f"inventory could not be read: {e}", file=sys.stderr)
        return 2

    if args.host:
        if args.host not in hosts:
            print(
                f"no host {args.host!r} in the inventory "
                f"(have: {', '.join(sorted(hosts)) or 'none'})",
                file=sys.stderr,
            )
            return 2
        hosts = {args.host: hosts[args.host]}

    if not hosts:
        # An empty inventory is not a pass. Either the file lost its entries or the
        # import silently returned the wrong symbol; both deserve a non-zero exit.
        print("inventory contains no hosts -- nothing was verified", file=sys.stderr)
        return 2

    failures: list[str] = []
    for name, host in sorted(hosts.items()):
        print(f"{name} ({host.get('hostname', '?')}, {host.get('os', '?')})")
        failures += verify(name, host, args.timeout)

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s) -- {', '.join(failures)}")
        print(
            "If the machine really was reinstalled or renumbered, update "
            f"{args.inventory} rather than ignoring this."
        )
        return 1
    print(f"OK: {len(hosts)} host(s) match the inventory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
