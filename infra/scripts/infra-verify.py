#!/usr/bin/env python3
"""Verify the recorded machine inventory against reality.

Why this exists: `infra/src/inventory.ts` records machines Pulumi cannot manage --
the IONOS VPS lives in the Cloud Panel, which has no API for this tariff and no
Terraform/Pulumi provider (see that file's header for the evidence). So `pulumi
preview` reconciles nothing here: the constants could drift arbitrarily far from
the real machine and every Pulumi command would still report a clean stack. That
is precisely the failure mode this repo treats as unacceptable -- an inventory you
cannot falsify is documentation wearing an inventory's clothes.

What it checks, per machine:

  identity      does the Ed25519 host key presented at each recorded address match
  reachability  can we open a connection at all -- silence is never a pass
  naming        does <name>.<realm>.0xf1a5c0.net resolve to the recorded address
  rebind        do site realms still resolve *through the LAN's own resolver*

The last one is the reason this grew past host keys. A site realm publishes RFC 1918
addresses, and the FRITZ!Box strips those out of public DNS answers unless the domain
is listed under DNS-Rebind-Schutz. That exception is unmanaged state: it survives no
factory reset, and losing it breaks name resolution for exactly the devices that have
no Tailscale -- while every device that *does* have Tailscale keeps working, because
MagicDNS never consults the FRITZ!Box. Without this check the failure is invisible from
the machine you would run the check on.

The control for that test is our own `pub` record: it is published in the same zone and
holds a public address, so a resolver that answers it but not the site realm is
filtering rather than unreachable.

Location matters, and the script does not pretend otherwise: a site realm is reachable
from that LAN or over the WireGuard tunnel, not from a hotel. An unreachable address is
reported as a failure with that hint attached; narrow the run with `--host` when that is
expected.

The inventory is read straight from the TypeScript source via Node's native type
stripping (Node >= 22.18), not from a build artefact or a duplicated JSON file, so
there is exactly one place these values live.

Stdlib only, matching osv-audit.py next door: no PEP-723 header, hence no sibling
.lock to keep in sync.

Exit codes: 0 everything verified, 1 a check failed, 2 tool error.
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

# Measured on 2026-08-18 and worth recording, because the opposite is the obvious guess:
# Tailscale SSH answers :22 in userspace and identifies itself as `SSH-2.0-Tailscale`,
# but it presents the *host's own* Ed25519 key -- byte-identical to what OpenSSH offers
# on the public address and over WireGuard. So scanning the tailnet address is a
# meaningful check rather than a guaranteed mismatch, and it additionally proves
# tailscaled is up.
REALM_NOTES = {
    "tailnet": "needs Tailscale up on this machine",
}


def load_inventory(inventory_ts: Path) -> dict:
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
    #
    # Importing the module also runs its naming assertions, so a name that violates
    # the scheme fails here too, with the message that file raises.
    script = (
        f"const m = await import({json.dumps(inventory_ts.resolve().as_uri())});\n"
        'const want = ["machines", "machineZone", "sites"];\n'
        "const missing = want.filter((s) => m[s] === undefined);\n"
        "if (missing.length) {\n"
        '  console.error("module is missing exports: " + missing.join(", "));\n'
        "  process.exit(3);\n"
        "}\n"
        "console.log(JSON.stringify("
        "{ machines: m.machines, zone: m.machineZone, sites: m.sites }));\n"
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


def dig(name: str, rrtype: str, timeout: int, server: str | None = None) -> list[str]:
    """Resolve one name, returning the answer values (empty list for no answer).

    `+short` is used rather than parsing a full response because the only thing this
    needs is the value; a CNAME in the chain would print as an extra line, which the
    address filter in the caller discards.
    """
    dig_bin = shutil.which("dig")
    if dig_bin is None:
        raise RuntimeError("dig not found on PATH")
    cmd = [dig_bin, "+short", f"+time={timeout}", "+tries=1"]
    if server:
        cmd.append(f"@{server}")
    cmd += [name, rrtype]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def verify_host_keys(name: str, machine: dict, timeout: int) -> list[str]:
    """Check the presented host key at every recorded address."""
    expected = (machine.get("ssh") or {}).get("hostKeyEd25519")
    if not expected:
        return []
    failures: list[str] = []
    for realm, endpoint in sorted(machine.get("addresses", {}).items()):
        for family, address in (("IPv4", endpoint.get("v4")), ("IPv6", endpoint.get("v6"))):
            if not address:
                continue
            label = f"{name} {realm} {family} {address}"
            try:
                actual = scan_host_key(address, timeout)
            except RuntimeError as e:
                hint = REALM_NOTES.get(realm, "reachable from that network only")
                print(f"  FAIL  {label}: {e} [{hint}]")
                failures.append(label)
                continue
            if actual != expected:
                print(f"  FAIL  {label}: host key does not match the inventory")
                print(f"          recorded:  {expected}")
                print(f"          presented: {actual}")
                failures.append(label)
            else:
                print(f"  ok    {label}: host key matches")
    return failures


def verify_dns(name: str, machine: dict, zone: str, sites: dict, timeout: int) -> list[str]:
    """Check that every recorded address is published under the scheme's name."""
    failures: list[str] = []
    for realm, endpoint in sorted(machine.get("addresses", {}).items()):
        fqdn = f"{name}.{realm}.{zone}"
        for rrtype, key in (("A", "v4"), ("AAAA", "v6")):
            expected = endpoint.get(key)
            if not expected:
                continue
            label = f"{name} {realm} {rrtype}"
            got = dig(fqdn, rrtype, timeout)
            if expected in got:
                print(f"  ok    {label}: {fqdn} -> {expected}")
            elif not got:
                print(f"  FAIL  {label}: {fqdn} does not resolve (expected {expected})")
                failures.append(label)
            else:
                print(f"  FAIL  {label}: {fqdn} -> {', '.join(got)}, expected {expected}")
                failures.append(label)

        # The rebind check. Only site realms have a LAN resolver, and only they publish
        # private addresses, so this is exactly the pairing that can be filtered away.
        resolver = (sites.get(realm) or {}).get("resolver")
        expected4 = endpoint.get("v4")
        if not resolver or not expected4:
            continue
        label = f"{name} {realm} via {resolver}"
        if not dig(zone, "SOA", timeout, server=resolver):
            # Control query failed: the resolver itself is not answering, so we are not
            # on that LAN. Say so rather than reporting either a pass or a failure.
            print(f"  --    {label}: resolver did not answer -- not on that network, check skipped")
            continue
        got = dig(fqdn, "A", timeout, server=resolver)
        if expected4 in got:
            print(f"  ok    {label}: rebind exception in place")
        else:
            print(f"  FAIL  {label}: resolver answers for the zone but not for {fqdn}")
            print("          This is DNS rebind protection eating the private address.")
            print("          FRITZ!Box -> Heimnetz -> Netzwerk -> Netzwerkeinstellungen")
            print(f"          -> DNS-Rebind-Schutz -> Hostname-Ausnahmen: {zone}")
            failures.append(label)
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
        help="seconds to wait for each probe (default: 8)",
    )
    ap.add_argument("--host", help="verify only this machine")
    ap.add_argument(
        "--skip-dns", action="store_true",
        help="host keys only; skip the name and rebind checks",
    )
    args = ap.parse_args()

    try:
        data = load_inventory(args.inventory)
    except (RuntimeError, json.JSONDecodeError) as e:
        print(f"inventory could not be read: {e}", file=sys.stderr)
        return 2

    machines: dict = data["machines"]
    zone: str = data["zone"]
    sites: dict = data["sites"]

    if args.host:
        if args.host not in machines:
            print(
                f"no machine {args.host!r} in the inventory "
                f"(have: {', '.join(sorted(machines)) or 'none'})",
                file=sys.stderr,
            )
            return 2
        machines = {args.host: machines[args.host]}

    if not machines:
        # An empty inventory is not a pass. Either the file lost its entries or the
        # import silently returned the wrong symbol; both deserve a non-zero exit.
        print("inventory contains no machines -- nothing was verified", file=sys.stderr)
        return 2

    failures: list[str] = []
    checked = 0
    for name, machine in sorted(machines.items()):
        addresses = machine.get("addresses", {})
        if not addresses:
            # Deliberate, not missing: workstations and not-yet-built hosts have no
            # stable address to check. Printed so the inventory's shape stays visible.
            print(f"{name} ({machine.get('role', '?')}, {machine.get('managed', '?')}) -- no addresses recorded")
            continue
        print(f"{name} ({machine.get('role', '?')}, {machine.get('os', machine.get('managed', '?'))})")
        checked += 1
        failures += verify_host_keys(name, machine, args.timeout)
        if not args.skip_dns:
            try:
                failures += verify_dns(name, machine, zone, sites, args.timeout)
            except RuntimeError as e:
                print(f"DNS checks could not run: {e}", file=sys.stderr)
                return 2

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s) -- {', '.join(failures)}")
        print(
            "If the machine really was reinstalled or renumbered, update "
            f"{args.inventory} rather than ignoring this."
        )
        return 1
    print(f"OK: {checked} machine(s) match the inventory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
