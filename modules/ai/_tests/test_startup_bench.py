"""startup-bench.py against a tiny stdlib HTTP server as the "application"; loopback only, no JVM."""
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import stat
import statistics
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).parent.parent / "_files/skills/java-fast-startup/scripts/startup-bench.py"

# The fake application. argv: STATE_DIR PORT MODE DELAYS_MS
#   DELAYS_MS is a comma list; start number k (counted in STATE_DIR/count) sleeps DELAYS_MS[k % len].
#   MODE serve        sleep, then answer 200 on every GET
#        never        never listen
#        exit         exit with code 3 before listening
#        orphan       fork; the started process waits, the grandchild serves; on the first GET the
#                     grandchild kills the started process and answers 200 only after it is gone
#        ignore-term  like serve, but ignore SIGTERM (only SIGKILL stops it)
#        grandchild   like serve, plus a child in the same process group that ignores SIGTERM and
#                     sleeps; it writes STATE_DIR/gpid (it outlives the started process unless killed)
#        slow-get     like serve, but every GET takes 1.5 s before it answers (a slow first request)
#        hang-get     like serve, but a GET writes STATE_DIR/got-get and then never answers
APP = r'''
import http.server, os, signal, sys, time
state, port, mode, delays = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
count_file = os.path.join(state, "count")
number = int(open(count_file).read()) if os.path.exists(count_file) else 0
open(count_file, "w").write(str(number + 1))
delay = [int(d) for d in delays.split(",")][number % len(delays.split(","))] / 1000
print("APP-OUTPUT-TOKEN stdout", flush=True)
print("APP-OUTPUT-TOKEN stderr", file=sys.stderr, flush=True)
parent = None
if mode == "orphan":
    if os.fork() != 0:
        while True:
            time.sleep(1)
    parent = os.getppid()
open(os.path.join(state, "pid-%d" % (number + 1)), "w").write(str(os.getpid()))
if mode == "exit":
    sys.exit(3)
if mode == "never":
    while True:
        time.sleep(1)
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "grandchild" and os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open(os.path.join(state, "gpid"), "w").write(str(os.getpid()))
    time.sleep(600)
    os._exit(0)
time.sleep(delay)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == "slow-get":
            time.sleep(1.5)
        if mode == "hang-get":
            open(os.path.join(state, "got-get"), "w").close()
            time.sleep(600)
        if parent is not None:
            os.kill(parent, signal.SIGKILL)
            while os.getppid() == parent:  # reparented once the started process has exited
                time.sleep(0.01)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"UP")
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'''

CMDLINE_TOKEN = "--secret-looking-flag=CMDLINE-TOKEN-4711"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def pid_gone(pid, seconds=5.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


class StartupBenchTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.app = self.tmp / "app.py"
        self.app.write_text(APP)
        self.port = free_port()
        self.out = self.tmp / "result.json"
        self.log = self.tmp / "app.log"

    def tearDown(self):
        for pid_file in [*self.state.glob("pid-*"), *self.state.glob("gpid")]:
            try:
                os.kill(int(pid_file.read_text()), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        self._tmp.cleanup()

    def bench_argv(self, mode="serve", delays="100", extra=(), url=None):
        return [sys.executable, str(SCRIPT),
                "--url", url or f"http://127.0.0.1:{self.port}/actuator/health",
                "--out", str(self.out), "--log", str(self.log),
                "--lock-file", str(self.tmp / "bench.lock"), *extra,
                "--", sys.executable, str(self.app), str(self.state), str(self.port), mode, delays,
                CMDLINE_TOKEN]

    def run_bench(self, *args, **kwargs):
        # Bytes, decoded here: text=True would turn a "\r" into "\n" and hide it from the checks.
        result = subprocess.run(self.bench_argv(*args, **kwargs), capture_output=True, timeout=60)
        result.stdout = result.stdout.decode("utf-8")
        result.stderr = result.stderr.decode("utf-8")
        return result

    def starts(self):
        count = self.state / "count"
        return int(count.read_text()) if count.exists() else 0

    def pids(self):
        return [int(p.read_text()) for p in sorted(self.state.glob("pid-*"))]

    def test_runs_are_measured_and_median_min_max_follow_the_per_run_values(self):
        # Median 300, mean 380, first run 100: neither a mean nor "the first run" passes for the median.
        delays = [100, 300, 900, 200, 400]
        result = self.run_bench(delays=",".join(map(str, delays)), extra=["--runs", "5", "--poll-ms", "5"])
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.out.read_text())
        series = report["series"]
        self.assertEqual([s["name"] for s in series], ["main"])
        ready = [r["ready_ms"] for r in series[0]["runs"]]
        self.assertEqual(len(ready), 5)
        for delay, value in zip(delays, ready):
            # Lower bound by construction: the app sleeps `delay` before it listens.
            self.assertGreaterEqual(value, delay, f"run with {delay} ms delay reported {value}")
            self.assertLess(value, delay + 3000, f"run with {delay} ms delay reported {value}")
        self.assertEqual(series[0]["median_ms"], round(statistics.median(ready), 1))
        self.assertEqual(series[0]["min_ms"], ready[0])  # the 100 ms run
        self.assertEqual(series[0]["max_ms"], ready[2])  # the 900 ms run
        for run in series[0]["runs"]:
            self.assertGreater(run["peak_rss_kib"], 1000)  # a Python process needs more than 1 MiB
            self.assertGreater(run["cpu_s"], 0)
        self.assertIsNone(report["baseline_repeat"])
        self.assertEqual(report["poll_ms"], 5)
        self.assertEqual(self.starts(), 5)
        progress = [line for line in result.stderr.splitlines() if " main run " in line]
        self.assertEqual(len(progress), 5, result.stderr)
        self.assertNotIn("\r", result.stderr)
        for pid in self.pids():
            self.assertTrue(pid_gone(pid), f"app pid {pid} still alive after the benchmark")

    def test_baseline_repeat_runs_the_series_twice_and_reports_the_median_delta(self):
        result = self.run_bench(delays="150", extra=["--runs", "2", "--baseline-repeat"])
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.out.read_text())
        names = [s["name"] for s in report["series"]]
        self.assertEqual(names, ["main", "baseline-repeat"])
        self.assertEqual([len(s["runs"]) for s in report["series"]], [2, 2])
        first, second = (s["median_ms"] for s in report["series"])
        expected = round((second - first) / first * 100, 1)
        self.assertEqual(report["baseline_repeat"]["delta_median_pct"], expected)
        self.assertEqual(self.starts(), 4)

    def test_timeout_is_an_error_not_a_sample_and_the_app_is_stopped(self):
        started = time.monotonic()
        result = self.run_bench(mode="never", extra=["--runs", "3", "--timeout", "1"])
        self.assertLess(time.monotonic() - started, 8, "--timeout 1 must end the run after about 1 s")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("timeout", result.stderr)
        self.assertFalse(self.out.exists(), "a failed benchmark must not write a result")
        self.assertEqual(self.starts(), 1, "the benchmark must stop at the first failed run")
        self.assertTrue(pid_gone(self.pids()[0]))

    def test_early_exit_of_the_app_is_an_error(self):
        result = self.run_bench(mode="exit", extra=["--runs", "3", "--timeout", "20"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("exited with code 3", result.stderr)
        self.assertFalse(self.out.exists())

    def test_a_200_after_the_started_process_died_is_an_error(self):
        # The started process dies while its grandchild answers 200: that is not the measured process.
        result = self.run_bench(mode="orphan", extra=["--runs", "1", "--timeout", "20"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("another process answered", result.stderr)
        self.assertFalse(self.out.exists())
        self.assertTrue(pid_gone(self.pids()[0]), "the grandchild in the process group must be killed")

    def test_busy_port_before_the_start_is_an_error_and_the_app_never_starts(self):
        with socket.socket() as holder:
            holder.bind(("127.0.0.1", self.port))
            holder.listen()
            result = self.run_bench(extra=["--runs", "1", "--timeout", "5"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("busy", result.stderr)
        self.assertEqual(self.starts(), 0)

    def test_non_loopback_url_is_refused_without_the_flag(self):
        for url in ("http://192.0.2.1:8080/health", "http://example.invalid:8080/health"):
            with self.subTest(url=url):
                result = self.run_bench(url=url, extra=["--runs", "1", "--timeout", "1"])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("not loopback", result.stderr)
                self.assertEqual(self.starts(), 0)

    def test_usage_errors_exit_2(self):
        cases = {
            "no command": [sys.executable, str(SCRIPT), "--lock-file", str(self.tmp / "l")],
            "zero runs": self.bench_argv(extra=["--runs", "0"]),
            "credentials in url": self.bench_argv(url=f"http://u:p@127.0.0.1:{self.port}/"),
        }
        for name, argv in cases.items():
            with self.subTest(name):
                result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.starts(), 0)

    def test_command_line_and_app_output_stay_out_of_the_result_and_files_are_0600(self):
        result = self.run_bench(extra=["--runs", "1"])
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.out.read_text()
        for leak in ("CMDLINE-TOKEN", str(self.app), "APP-OUTPUT-TOKEN"):
            self.assertNotIn(leak, text)
            self.assertNotIn(leak, result.stdout)
            self.assertNotIn(leak, result.stderr)
        log_text = self.log.read_text()
        self.assertIn("APP-OUTPUT-TOKEN stdout", log_text)
        self.assertIn("APP-OUTPUT-TOKEN stderr", log_text)
        self.assertIn(str(self.log), result.stderr, "the log path must be printed")
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.log.stat().st_mode), 0o600)
        leftovers = [p.name for p in self.tmp.iterdir() if p.name.startswith(".startup-bench.")]
        self.assertEqual(leftovers, [], "the atomic write left a temp file")

    def test_default_log_file_is_0600_and_its_path_is_printed(self):
        argv = self.bench_argv(extra=["--runs", "1"])
        log_at = argv.index("--log")
        del argv[log_at:log_at + 2]
        result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(l for l in result.stderr.splitlines() if l.startswith("command output -> "))
        path = Path(line.split(" -> ", 1)[1])
        try:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertIn("APP-OUTPUT-TOKEN", path.read_text())
        finally:
            path.unlink()

    def test_app_that_ignores_sigterm_is_killed_after_the_grace_period(self):
        started = time.monotonic()
        result = self.run_bench(mode="ignore-term", extra=["--runs", "2", "--kill-grace", "0.5"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 30)
        for pid in self.pids():
            self.assertTrue(pid_gone(pid), f"app pid {pid} survived SIGKILL escalation")

    def test_a_grandchild_that_ignores_sigterm_does_not_outlive_the_benchmark(self):
        result = self.run_bench(mode="grandchild", extra=["--runs", "1", "--kill-grace", "0.5"])
        self.assertEqual(result.returncode, 0, result.stderr)
        gpid_file = self.state / "gpid"
        self.assertTrue(gpid_file.exists(), "the fake app never started its grandchild")
        gpid = int(gpid_file.read_text())
        self.assertTrue(pid_gone(gpid), f"grandchild {gpid} survived the benchmark")

    def test_an_existing_log_file_with_loose_permissions_is_tightened_to_0600(self):
        self.log.write_text("old content\n")
        self.log.chmod(0o644)
        result = self.run_bench(extra=["--runs", "1"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(self.log.stat().st_mode), 0o600)
        self.assertTrue(self.log.read_text().startswith("old content\n"), "the log must be appended to")

    def test_sigterm_stops_with_143_discards_the_run_and_stops_the_app(self):
        bench = subprocess.Popen(self.bench_argv(mode="never", extra=["--runs", "3", "--timeout", "60"]),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 20
            while not self.pids() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(self.pids(), "the app did not start")
            bench.send_signal(signal.SIGTERM)
            _out, err = bench.communicate(timeout=30)
        finally:
            if bench.poll() is None:
                bench.kill()
        self.assertEqual(bench.returncode, 143, err)
        self.assertIn("stopped", err)
        self.assertFalse(self.out.exists())
        self.assertTrue(pid_gone(self.pids()[0]))

    def test_sigterm_during_a_hanging_poll_stops_at_once(self):
        # A poll may wait up to the remaining --timeout; a signal must not wait for it.
        argv = self.bench_argv(mode="hang-get", delays="0", extra=["--runs", "1", "--timeout", "120"])
        bench = subprocess.Popen(argv,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 20
            while not (self.state / "got-get").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue((self.state / "got-get").exists(), "the poll never reached the app")
            signalled = time.monotonic()
            bench.send_signal(signal.SIGTERM)
            _out, err = bench.communicate(timeout=60)
        finally:
            if bench.poll() is None:
                bench.kill()
        self.assertEqual(bench.returncode, 143, err)
        self.assertLess(time.monotonic() - signalled, 15, "the signal waited for the hanging poll")
        self.assertFalse(self.out.exists())

    def test_second_benchmark_on_the_same_lock_exits_75(self):
        lock = self.tmp / "bench.lock"
        with open(lock, "w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            handle.write("pid=1 start=earlier\n")
            handle.flush()
            result = self.run_bench(extra=["--runs", "1"])
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("already running", result.stderr)
        self.assertEqual(self.starts(), 0)

    def test_lock_file_that_is_a_symlink_is_refused_and_its_target_untouched(self):
        target = self.tmp / "victim.txt"
        target.write_text("ORIGINAL CONTENT\n")
        lock = self.tmp / "bench.lock"
        lock.symlink_to(target)
        result = self.run_bench(extra=["--runs", "1"])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("symbolic link", result.stderr)
        self.assertEqual(target.read_text(), "ORIGINAL CONTENT\n", "the lock write followed the symlink")
        self.assertEqual(self.starts(), 0)

    def test_health_request_slower_than_one_second_is_waited_for(self):
        result = self.run_bench(mode="slow-get", delays="100", extra=["--runs", "1", "--timeout", "20"])
        self.assertEqual(result.returncode, 0, result.stderr)
        ready = json.loads(self.out.read_text())["series"][0]["runs"][0]["ready_ms"]
        # Lower bound by construction: 100 ms until it listens, 1.5 s for the answer.
        self.assertGreaterEqual(ready, 1600)
        self.assertLess(ready, 6000)

    def test_query_string_and_fragment_stay_out_of_the_result(self):
        url = f"http://127.0.0.1:{self.port}/actuator/health?token=QUERY-TOKEN-0815#FRAGMENT-TOKEN"
        result = self.run_bench(url=url, extra=["--runs", "1"])
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.out.read_text())
        self.assertEqual(report["url"], f"http://127.0.0.1:{self.port}/actuator/health")
        for leak in ("QUERY-TOKEN", "FRAGMENT-TOKEN"):
            self.assertNotIn(leak, self.out.read_text())
            self.assertNotIn(leak, result.stderr)

    def test_https_url_is_refused(self):
        result = self.run_bench(url=f"https://127.0.0.1:{self.port}/actuator/health", extra=["--runs", "1"])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("https", result.stderr)
        self.assertEqual(self.starts(), 0)

    def test_unexpected_error_exits_4_not_1(self):
        # A real failure outside the measured runs: the output directory does not exist.
        self.out = self.tmp / "no-such-dir" / "result.json"
        result = self.run_bench(extra=["--runs", "1"])
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("internal error: FileNotFoundError", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        for pid in self.pids():
            self.assertTrue(pid_gone(pid))


if __name__ == "__main__":
    unittest.main(verbosity=2)
