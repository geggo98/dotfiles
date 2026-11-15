#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
#
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""Sample JMX attributes of a JVM over Jolokia into JSONL or CSV (a time series).

usage: jmx-sample.py --url URL (--read MBEAN ATTRIBUTE [--read ...] | --preset jvm)
                     [--interval S] [--count N] [--format jsonl|csv] [--out FILE]
                     [--timeout S] [--insecure-http]

Read-only: the script only sends Jolokia `read` requests (never `exec`, `write`, `search`).
Use it for a series of values over HTTP. For a single value over RMI use jmx.sh.

Credentials (never as arguments, never in the URL):
  JOLOKIA_USER and JOLOKIA_PASSWORD, or JOLOKIA_USER and JOLOKIA_PASSWORD_CMD (stdout is the password).
  When both are set, JOLOKIA_PASSWORD wins and the command does not run.

Values are written as the JVM reports them: ProcessCpuLoad is negative when the JVM cannot measure it.
Timestamps are UTC with millisecond resolution.

Safety rules enforced here:
  * A bulk `read` answers HTTP 200 even when single items fail (policy 403, unknown MBean 404).
    Every item is checked; one failed item stops the run with exit 1 and names the MBean/attribute.
  * `user:pass@host` in the URL is refused.
  * HTTP Basic over plain http:// to a non-loopback host is refused unless --insecure-http is given.
  * Redirects are never followed (the Authorization header would travel with them).
  * The output file is created with mode 0600. Values can hold secrets (system properties,
    JVM arguments, environment MBeans): treat the file like a heap dump.

Exit: 0 done, 1 a sample failed, 2 usage (including an --out that cannot be opened), 130 SIGINT, 143 SIGTERM.
"""
import argparse
import base64
import csv
import io
import ipaddress
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PRESETS = {
    "jvm": [
        ("java.lang:type=Memory", "HeapMemoryUsage"),
        ("java.lang:type=Memory", "NonHeapMemoryUsage"),
        ("java.lang:type=Threading", "ThreadCount"),
        ("java.lang:type=OperatingSystem", "ProcessCpuLoad"),
        ("java.lang:type=ClassLoading", "LoadedClassCount"),
    ],
}


class SampleError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # urllib then raises HTTPError for the 3xx answer


def is_loopback(host: str) -> bool:
    if host in ("localhost", "localhost.localdomain"):
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


def resolve_auth():
    user = os.environ.get("JOLOKIA_USER", "")
    password = os.environ.get("JOLOKIA_PASSWORD", "")
    cmd = os.environ.get("JOLOKIA_PASSWORD_CMD", "")
    if not password and cmd:
        try:
            # Only stdout carries the password; stderr passes through ("not signed in" and the like).
            result = subprocess.run(["/bin/sh", "-c", cmd], stdout=subprocess.PIPE, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            raise SampleError("JOLOKIA_PASSWORD_CMD timed out")
        if result.returncode != 0:
            raise SampleError("JOLOKIA_PASSWORD_CMD failed (exit %d)" % result.returncode)
        password = result.stdout.strip("\r\n")
    if bool(user) != bool(password):
        raise SampleError("set both JOLOKIA_USER and a password (JOLOKIA_PASSWORD or JOLOKIA_PASSWORD_CMD)")
    return (user, password) if user else None


def flatten(prefix, value, out):
    """Composite values (HeapMemoryUsage) become one column per key: HeapMemoryUsage.used."""
    if isinstance(value, dict):
        for key in sorted(value):
            flatten(f"{prefix}.{key}", value[key], out)
    else:
        out[prefix] = value


def sample_once(opener, url, reads, auth_header, timeout):
    body = json.dumps([{"type": "read", "mbean": m, "attribute": a} for m, a in reads]).encode()
    headers = {"Content-Type": "application/json"}
    if auth_header:
        headers["Authorization"] = auth_header
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with opener.open(request, timeout=timeout) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        raise SampleError(f"HTTP {exc.code} from {urllib.parse.urlsplit(url).netloc}")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise SampleError(f"request failed: {exc}")
    if not isinstance(payload, list) or len(payload) != len(reads):
        got = len(payload) if isinstance(payload, list) else "non-list"
        raise SampleError(f"expected {len(reads)} items in the bulk answer, got {got}")
    row = {}
    for (mbean, attribute), item in zip(reads, payload):
        status = item.get("status") if isinstance(item, dict) else None
        if status != 200:
            error = (item.get("error") if isinstance(item, dict) else None) or "no error text"
            raise SampleError(f"{mbean} {attribute}: status {status}: {error}")
        flatten(f"{mbean}/{attribute}", item.get("value"), row)
    return row


def main(argv=None):
    parser = argparse.ArgumentParser(prog="jmx-sample.py", description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--url", required=True, help="Jolokia endpoint, e.g. http://127.0.0.1:8778/jolokia/")
    parser.add_argument("--read", nargs=2, action="append", metavar=("MBEAN", "ATTRIBUTE"), default=[])
    parser.add_argument("--preset", choices=sorted(PRESETS), help="a ready-made attribute set")
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between samples (default 5)")
    parser.add_argument("--count", type=int, default=0, help="number of samples; 0 = until interrupted")
    parser.add_argument("--format", choices=("jsonl", "csv"), default="jsonl")
    parser.add_argument("--out", default="-", help="output file (mode 0600) or - for stdout")
    parser.add_argument("--timeout", type=float, default=10.0, help="per request, seconds")
    parser.add_argument("--insecure-http", action="store_true",
                        help="allow HTTP Basic over plain http:// to a non-loopback host")
    args = parser.parse_args(argv)

    reads = list(PRESETS.get(args.preset, [])) + [tuple(r) for r in args.read]
    if not reads:
        parser.error("give --read MBEAN ATTRIBUTE or --preset")
    if any("*" in m or "*" in a for m, a in reads):
        parser.error("wildcards are not supported (they make the column set unstable)")
    if args.interval <= 0 or args.count < 0:
        parser.error("--interval must be > 0 and --count >= 0")

    parts = urllib.parse.urlsplit(args.url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        parser.error("--url must be an http:// or https:// URL")
    if parts.username or parts.password:
        parser.error("credentials in the URL are refused; use JOLOKIA_USER and JOLOKIA_PASSWORD(_CMD)")

    try:
        auth = resolve_auth()
    except SampleError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    auth_header = None
    if auth:
        if parts.scheme == "http" and not is_loopback(parts.hostname) and not args.insecure_http:
            print("error: refusing HTTP Basic over plain http:// to a non-loopback host "
                  "(use https:// or --insecure-http)", file=sys.stderr)
            return 2
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        auth_header = f"Basic {token}"

    # The handler chain has no proxy handler on purpose: a proxy would see the credentials.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)

    existing_header = None  # header line of a CSV file that already has content
    try:
        if args.format == "csv" and args.out != "-":
            try:
                with open(args.out, encoding="utf-8", newline="") as existing:
                    first = existing.readline().rstrip("\r\n")
            except FileNotFoundError:
                first = ""
            if first:
                existing_header = next(csv.reader([first]))

        if args.out == "-":
            sink = sys.stdout
        else:
            fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.fchmod(fd, 0o600)  # also tighten a pre-existing file
            sink = os.fdopen(fd, "a", encoding="utf-8", newline="")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"error: cannot open --out {args.out}: {exc}", file=sys.stderr)
        return 2

    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda s, _f: stop.append(s))

    taken = 0
    columns = None
    header_written = False
    try:
        while not stop and (args.count == 0 or taken < args.count):
            started = time.monotonic()
            try:
                row = sample_once(opener, args.url, reads, auth_header, args.timeout)
            except SampleError as exc:
                print(f"error: sample {taken + 1} failed: {exc}", file=sys.stderr)
                print(f"{taken} samples written before the failure", file=sys.stderr)
                return 1
            # Millisecond resolution: --interval accepts fractions of a second.
            stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            if args.format == "jsonl":
                sink.write(json.dumps({"time": stamp, **row}, separators=(",", ":")) + "\n")
            else:
                if columns is None:
                    columns = list(row)
                    if existing_header is not None:
                        if existing_header != ["time", *columns]:
                            print("error: the existing CSV file has a different header; "
                                  "use a new file per attribute set", file=sys.stderr)
                            return 2
                        header_written = True  # same columns: append rows, no second header
                elif list(row) != columns:
                    print("error: the set of columns changed between samples", file=sys.stderr)
                    return 1
                buf = io.StringIO()
                writer = csv.writer(buf, lineterminator="\n")
                if not header_written:
                    writer.writerow(["time", *columns])
                    header_written = True
                writer.writerow([stamp, *[row[c] for c in columns]])
                sink.write(buf.getvalue())
            sink.flush()
            taken += 1
            if args.count and taken >= args.count:
                break
            deadline = started + args.interval
            while not stop and time.monotonic() < deadline:
                time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))
    finally:
        if sink is not sys.stdout:
            sink.close()
    print(f"{taken} samples written", file=sys.stderr)
    if stop:
        return 128 + stop[0]
    return 0


if __name__ == "__main__":
    sys.exit(main())
