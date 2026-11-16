#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
#
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""Measure how long an HTTP service needs from process start until a URL answers 200.

usage: startup-bench.py [--url URL] [--runs N] [--timeout S] [--poll-ms MS]
                        [--baseline-repeat] [--out FILE] [--log FILE] [--kill-grace S]
                        [--lock-file FILE] [--allow-remote] -- COMMAND [ARG ...]

Each run starts COMMAND (no shell: the words after `--` are the argument vector), polls URL
in this process until it answers HTTP 200, records the time, and stops the process group
(SIGTERM, then SIGKILL after --kill-grace seconds). The default URL is
http://127.0.0.1:8080/actuator/health. The script executes COMMAND as given, so whoever runs it
must check the command first.

Only http:// is accepted. A service on loopback usually has a self-signed certificate, and the
TLS check would fail on every poll until the timeout; measure the plain-HTTP management port.
A poll that connects waits for its answer up to the remaining --timeout, so a slow first request
counts in ready_ms instead of being cut off and retried.

A run counts only when all of these hold; otherwise the benchmark stops with exit 1:
  * the port of URL is free before the start (a leftover process would answer instead),
  * the started process is still alive when the 200 arrives,
  * the 200 arrives before --timeout (a timeout or an early exit is an error, not a sample).

--baseline-repeat runs the same series a second time and reports the difference of the two
medians in percent. This is the noise floor: a difference between two variants that is not
clearly larger than this delta means nothing.

Output (JSON on stdout, or --out FILE written atomically with mode 0600): ready_ms per run,
median/min/max, the URL without query string and fragment, RSS of the process group at the 200 (ps), peak RSS and CPU seconds until exit
(wait4: the started process and the descendants it waited for), the configured and the observed
poll interval, Python and OS. The command line and the output of the command are never written
into the JSON. Command output goes to a log file (mode 0600); its path is printed on stderr.

Limits: the page cache is never dropped, so every run is a warm-cache run. CPU and peak RSS
include the shutdown after SIGTERM. Descendants that the started process does not wait for are
not counted in peak RSS and CPU.

Exit: 0 done, 1 a run failed, 2 usage (also: the lock file is a symbolic link), 4 internal error
(an unexpected exception, for example an --out directory that does not exist), 75 another
benchmark holds the lock, 130 SIGINT, 143 SIGTERM.
"""
import argparse
import errno
import fcntl
import ipaddress
import json
import os
import platform
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_URL = "http://127.0.0.1:8080/actuator/health"


class RunError(Exception):
    pass


class Stopped(Exception):
    pass


class StopSignal:
    """Records SIGINT/SIGTERM. During a poll the handler raises Stopped at once, because a poll can
    wait up to the remaining --timeout for its answer; elsewhere the loop checks the flag."""

    def __init__(self):
        self.signals = []
        self.interruptible = False

    def __bool__(self):
        return bool(self.signals)

    def handler(self, sig, _frame):
        self.signals.append(sig)
        if self.interruptible:
            self.interruptible = False
            raise Stopped()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a 3xx is not ready; urllib raises HTTPError for it


def is_loopback(host):
    if host in ("localhost", "localhost.localdomain"):
        return True
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


def port_in_use(host, port):
    """True when something accepts connections on host:port."""
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def kib_from_maxrss(value):
    # ru_maxrss is in bytes on macOS and in KiB on Linux.
    return value // 1024 if sys.platform == "darwin" else value


def group_rss_kib(pgid):
    """Sum of RSS over all processes of one process group, from ps (macOS and Linux)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    total = 0
    found = False
    for line in out.splitlines():
        # matches: "  4711  183424"  ->  pgid 4711, rss 183424 KiB
        fields = line.split()
        if len(fields) == 2 and fields[0] == str(pgid) and fields[1].isdigit():
            total += int(fields[1])
            found = True
    return total if found else None


class Child:
    """The started process. Reaped only through wait4, so its rusage is not lost."""

    def __init__(self, command, log):
        # Keep the Popen object: a dropped one lands in subprocess's cleanup list, and the next
        # Popen (the ps call) would reap the child and lose its rusage.
        self.proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                     start_new_session=True)
        self.pid = self.proc.pid
        self.exit_code = None
        self.rusage = None

    def _reaped(self, pid, status, usage):
        if pid == self.pid:
            self.exit_code = os.waitstatus_to_exitcode(status)
            self.rusage = usage
            self.proc.returncode = self.exit_code
            return True
        return False

    def alive(self):
        if self.rusage is not None:
            return False
        return not self._reaped(*os.wait4(self.pid, os.WNOHANG))

    def stop(self, grace):
        """SIGTERM to the process group, SIGKILL after `grace` seconds; returns the rusage."""
        signal_group(self.pid, signal.SIGTERM)
        deadline = time.monotonic() + grace
        while self.alive():
            if time.monotonic() >= deadline:
                signal_group(self.pid, signal.SIGKILL)
                self._reaped(*os.wait4(self.pid, 0))
                break
            time.sleep(0.02)
        # Members of the group that outlived the leader (grandchildren) get SIGKILL as well.
        signal_group(self.pid, signal.SIGKILL)
        return self.rusage


def signal_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def wait_port_free(host, port, seconds):
    deadline = time.monotonic() + seconds
    while port_in_use(host, port):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True


def one_run(args, opener, host, port, log, stop):
    if port_in_use(host, port):
        raise RunError(f"port {port} on {host} is busy before the start; stop the process that holds it")
    started = time.monotonic()
    child = Child(args.command, log)
    gaps = []
    ready_ms = None
    rss_at_ready = None
    try:
        last_attempt = None
        while True:
            if stop:
                raise Stopped()
            now = time.monotonic()
            if last_attempt is not None:
                gaps.append((now - last_attempt) * 1000)
            last_attempt = now
            if not child.alive():
                raise RunError(f"the command exited with code {child.exit_code} "
                               f"before {args.report_url} answered 200")
            remaining = args.timeout - (now - started)
            if remaining <= 0:
                raise RunError(f"timeout: no HTTP 200 from {args.report_url} within {args.timeout:g} s")
            status = None
            # The whole remaining time: a connected poll waits for a slow first answer instead of
            # being cut off and retried. A refused connection still returns at once.
            stop.interruptible = True
            try:
                if stop:
                    raise Stopped()
                with opener.open(args.url, timeout=remaining) as response:
                    status = response.status
            except urllib.error.HTTPError as exc:
                status = exc.code
            except (urllib.error.URLError, OSError):
                status = None
            finally:
                stop.interruptible = False
            if status == 200:
                ready_ms = (time.monotonic() - started) * 1000
                if not child.alive():
                    raise RunError("HTTP 200 arrived, but the started process had already exited "
                                   "(another process answered)")
                rss_at_ready = group_rss_kib(child.pid)
                break
            time.sleep(args.poll_ms / 1000)
    finally:
        rusage = child.stop(args.kill_grace)
    if not wait_port_free(host, port, 10):
        raise RunError(f"port {port} is still busy 10 s after the process group was stopped")
    return {
        "ready_ms": round(ready_ms, 1),
        "ready_rss_kib": rss_at_ready,
        "peak_rss_kib": kib_from_maxrss(rusage.ru_maxrss),
        "cpu_s": round(rusage.ru_utime + rusage.ru_stime, 3),
    }, gaps


def summarise(name, runs):
    values = [r["ready_ms"] for r in runs]
    return {
        "name": name,
        "runs": runs,
        "median_ms": round(statistics.median(values), 1),
        "min_ms": min(values),
        "max_ms": max(values),
    }


def take_lock(path):
    # O_NOFOLLOW: a symbolic link planted at the lock path would make the write below land in its
    # target. open() then fails with ELOOP, and main() refuses the lock file.
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        try:
            holder = os.read(fd, 200).decode("utf-8", "replace").strip() or "unknown holder"
        finally:
            os.close(fd)
        return None, holder
    os.ftruncate(fd, 0)
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    os.write(fd, f"pid={os.getpid()} start={stamp}\n".encode())
    return fd, None


def write_atomic(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".startup-bench.", dir=directory)  # mkstemp creates mode 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv=None):
    raw = sys.argv[1:] if argv is None else list(argv)
    if "--" in raw:
        split = raw.index("--")
        own, command = raw[:split], raw[split + 1:]
    else:
        own, command = raw, []
    parser = argparse.ArgumentParser(prog="startup-bench.py", description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--url", default=DEFAULT_URL, help=f"readiness URL (default {DEFAULT_URL})")
    parser.add_argument("--runs", type=int, default=5, help="runs per series (default 5)")
    parser.add_argument("--timeout", type=float, default=300.0, help="seconds per run until 200 (default 300)")
    parser.add_argument("--poll-ms", type=float, default=5.0, help="pause between polls in ms (default 5)")
    parser.add_argument("--baseline-repeat", action="store_true",
                        help="run the series twice and report the median delta (noise floor)")
    parser.add_argument("--out", help="JSON output file (mode 0600, written atomically); default stdout")
    parser.add_argument("--log", help="file for the command output (mode 0600); default a new temp file")
    parser.add_argument("--kill-grace", type=float, default=10.0,
                        help="seconds between SIGTERM and SIGKILL (default 10)")
    parser.add_argument("--lock-file", default=os.path.join(tempfile.gettempdir(), "startup-bench.lock"),
                        help="one benchmark at a time per lock file (default in $TMPDIR)")
    parser.add_argument("--allow-remote", action="store_true", help="allow a URL host that is not loopback")
    args = parser.parse_args(own)
    args.command = command

    if not command:
        parser.error("give the command after --, e.g. -- java -jar app.jar")
    if args.runs < 1 or args.timeout <= 0 or args.poll_ms <= 0 or args.kill_grace < 0:
        parser.error("--runs >= 1, --timeout > 0, --poll-ms > 0 and --kill-grace >= 0 are required")
    parts = urllib.parse.urlsplit(args.url)
    if parts.scheme == "https":
        parser.error("https:// is refused: on loopback the certificate is usually self-signed and every "
                     "poll would fail until the timeout; use the plain-HTTP port")
    if parts.scheme != "http" or not parts.hostname:
        parser.error("--url must be an http:// URL")
    if parts.username or parts.password:
        parser.error("credentials in the URL are refused")
    if not is_loopback(parts.hostname) and not args.allow_remote:
        parser.error(f"--url host {parts.hostname} is not loopback; give --allow-remote to measure it anyway")
    host = parts.hostname
    port = parts.port or 80
    # The report keeps scheme, host, port and path only: a query string or fragment can carry a token.
    report_url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    args.report_url = report_url

    try:
        lock_fd, holder = take_lock(args.lock_file)
    except OSError as exc:
        if exc.errno != errno.ELOOP:
            raise
        print(f"refused: the lock file {args.lock_file} is a symbolic link", file=sys.stderr)
        return 2
    if lock_fd is None:
        print(f"already running: {holder} (lock {args.lock_file})", file=sys.stderr)
        return 75

    if args.log:
        log_fd = os.open(args.log, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        os.fchmod(log_fd, 0o600)
        log_path = args.log
    else:
        log_fd, log_path = tempfile.mkstemp(prefix="startup-bench-", suffix=".log")
    log = os.fdopen(log_fd, "a", encoding="utf-8")
    print(f"command output -> {log_path}", file=sys.stderr)

    stop = StopSignal()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop.handler)

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
    series_names = ["main", "baseline-repeat"] if args.baseline_repeat else ["main"]
    total = args.runs * len(series_names)
    series = []
    all_gaps = []
    done = 0
    t0 = time.monotonic()
    try:
        for name in series_names:
            runs = []
            for number in range(1, args.runs + 1):
                log.write(f"=== {name} run {number} ===\n")
                log.flush()
                result, gaps = one_run(args, opener, host, port, log, stop)
                runs.append(result)
                all_gaps.extend(gaps)
                done += 1
                elapsed = time.monotonic() - t0
                eta = elapsed / done * (total - done)
                print(f"{done}/{total} {name} run {number}: ready {result['ready_ms']:.0f} ms"
                      f"  elapsed {elapsed:.0f}s  ETA {eta:.0f}s", file=sys.stderr, flush=True)
            series.append(summarise(name, runs))
    except Stopped:
        print(f"stopped: {done}/{total} runs done, the running one discarded, nothing written",
              file=sys.stderr)
        return 128 + stop.signals[0]
    except RunError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print(f"{done}/{total} runs done before the failure, nothing written; see {log_path}", file=sys.stderr)
        return 1
    finally:
        log.close()

    repeat = None
    if args.baseline_repeat:
        first, second = series[0]["median_ms"], series[1]["median_ms"]
        repeat = {"delta_median_pct": round((second - first) / first * 100, 1)}
    report = {
        "tool": "startup-bench",
        "measured_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "url": report_url,
        "runs_per_series": args.runs,
        "series": series,
        "baseline_repeat": repeat,
        "poll_ms": args.poll_ms,
        "observed_poll_gap_ms": round(statistics.median(all_gaps), 1) if all_gaps else None,
        "cache": "warm (the page cache is never dropped)",
        "python": platform.python_version(),
        "os": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
    }
    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        write_atomic(args.out, text)
        print(f"result -> {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def run():
    try:
        return main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001  # a bug must end with 4, never with 1 ("a run failed")
        # Type and line only: the exception text could carry the command line or a URL.
        tb = exc.__traceback__
        while tb is not None and tb.tb_next is not None:
            tb = tb.tb_next
        line = tb.tb_lineno if tb is not None else "?"
        print(f"internal error: {type(exc).__name__} (line {line})", file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(run())
