"""jmx-sample.py against a fake Jolokia endpoint; no JVM, no network beyond 127.0.0.1."""
import base64
import csv
import io
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).parent.parent / "_files/skills/java-debug/scripts/jmx-sample.py"

MEMORY = "java.lang:type=Memory"
THREADS = "java.lang:type=Threading"


class FakeServer(HTTPServer):
    mode: str = "ok"
    requests: list = []
    followed: list = []  # requests that arrived at the redirect target


class FakeJolokia(BaseHTTPRequestHandler):
    """Behaviour is chosen per test through the server attributes."""

    def log_message(self, format, *args):  # noqa: A002  # keep the test output quiet
        pass

    def do_GET(self):  # the redirect target: urllib turns a followed 302 for a POST into a GET
        server = self.server
        assert isinstance(server, FakeServer)
        server.followed.append({"path": self.path, "auth": self.headers.get("Authorization")})
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        server = self.server
        assert isinstance(server, FakeServer)
        if self.path.startswith("/elsewhere"):
            server.followed.append({"path": self.path, "auth": self.headers.get("Authorization")})
            self.send_response(404)
            self.end_headers()
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        server.requests.append({"body": body, "auth": self.headers.get("Authorization")})
        if server.mode == "redirect":
            # Points back at this server, so a followed redirect would be observed in `followed`.
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{server.server_address[1]}/elsewhere")
            self.end_headers()
            return
        if server.mode == "http500":
            self.send_response(500)
            self.end_headers()
            return
        items = []
        for number, req in enumerate(body):
            key = (req["mbean"], req["attribute"])
            if server.mode == "item403" and key == (THREADS, "ThreadCount"):
                # The real failure mode: HTTP 200 for the bulk call, 403 inside the item.
                items.append({"status": 403, "error": "Operation not allowed by policy", "request": req})
            elif key == (MEMORY, "HeapMemoryUsage"):
                items.append({"status": 200, "value": {"used": 100 + number, "max": 1000}, "request": req})
            else:
                items.append({"status": 200, "value": 7, "request": req})
        if server.mode == "short":
            items = items[:-1]
        payload = json.dumps(items).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class JmxSampleTests(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer(("127.0.0.1", 0), FakeJolokia)
        self.server.mode = "ok"
        self.server.requests = []
        self.server.followed = []
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/jolokia/"
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("JOLOKIA_")}

    def run_script(self, *args, env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args], env=env or self.env,
            capture_output=True, text=True, timeout=20,
        )

    def sample_args(self, *extra):
        return ["--url", self.url, "--read", MEMORY, "HeapMemoryUsage",
                "--read", THREADS, "ThreadCount", "--interval", "0.2", "--count", "2", *extra]

    def test_jsonl_has_flattened_columns_and_one_line_per_sample(self):
        result = self.run_script(*self.sample_args())
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 2, result.stdout)
        row = json.loads(lines[0])
        self.assertEqual(row[f"{MEMORY}/HeapMemoryUsage.used"], 100)
        self.assertEqual(row[f"{MEMORY}/HeapMemoryUsage.max"], 1000)
        self.assertEqual(row[f"{THREADS}/ThreadCount"], 7)
        self.assertRegex(row["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
        self.assertIn("2 samples written", result.stderr)

    def test_only_read_requests_are_sent(self):
        self.run_script(*self.sample_args())
        sent = [r for entry in self.server.requests for r in entry["body"]]
        self.assertTrue(sent)
        self.assertEqual({r["type"] for r in sent}, {"read"})

    def test_csv_writes_the_header_once(self):
        result = self.run_script(*self.sample_args("--format", "csv"))
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 3, result.stdout)  # header + 2 samples
        self.assertTrue(lines[0].startswith("time,"))
        self.assertIn(f"{MEMORY}/HeapMemoryUsage.used", lines[0])
        self.assertEqual(lines[1].count(","), lines[0].count(","))

    def test_item_error_inside_http_200_stops_the_run_and_names_the_item(self):
        self.server.mode = "item403"
        result = self.run_script(*self.sample_args())
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(THREADS, result.stderr)
        self.assertIn("ThreadCount", result.stderr)
        self.assertIn("403", result.stderr)
        self.assertEqual(result.stdout, "", "no row may be written for a failed sample")

    def test_missing_item_in_the_answer_is_an_error(self):
        self.server.mode = "short"
        result = self.run_script(*self.sample_args())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("expected 2 items", result.stderr)

    def test_http_error_status_is_an_error(self):
        self.server.mode = "http500"
        result = self.run_script(*self.sample_args())
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 500", result.stderr)

    def test_unreachable_endpoint_is_an_error(self):
        result = self.run_script("--url", "http://127.0.0.1:1/jolokia/", "--preset", "jvm",
                                 "--count", "1", "--timeout", "2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("request failed", result.stderr)

    def test_redirect_is_not_followed_and_credentials_do_not_travel(self):
        self.server.mode = "redirect"
        env = {**self.env, "JOLOKIA_USER": "u", "JOLOKIA_PASSWORD": "pw"}
        result = self.run_script(*self.sample_args(), env=env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("HTTP 302", result.stderr)
        self.assertEqual(len(self.server.requests), 1)
        self.assertEqual(self.server.followed, [], "the redirect target must never be contacted")

    def test_csv_values_line_up_with_the_header(self):
        result = self.run_script(*self.sample_args("--format", "csv", "--count", "1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = list(csv.DictReader(io.StringIO(result.stdout)))
        self.assertEqual(len(rows), 1, result.stdout)
        # Expected values from the fake server (request 0): used = 100 + 0, max = 1000, threads = 7.
        self.assertEqual(rows[0][f"{MEMORY}/HeapMemoryUsage.used"], "100")
        self.assertEqual(rows[0][f"{MEMORY}/HeapMemoryUsage.max"], "1000")
        self.assertEqual(rows[0][f"{THREADS}/ThreadCount"], "7")

    def test_proxy_from_the_environment_is_not_used(self):
        # A proxy would see the Basic credentials. Port 1 refuses connections, so using it fails the run.
        env = {**self.env, "JOLOKIA_USER": "u", "JOLOKIA_PASSWORD": "pw",
               "http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1", "no_proxy": "", "NO_PROXY": ""}
        result = self.run_script(*self.sample_args("--count", "1"), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.server.requests), 1)

    def test_subsecond_interval_gives_distinct_timestamps(self):
        result = self.run_script(*self.sample_args("--count", "3"))
        self.assertEqual(result.returncode, 0, result.stderr)
        stamps = [json.loads(line)["time"] for line in result.stdout.splitlines()]
        self.assertEqual(len(stamps), 3)
        self.assertEqual(stamps, sorted(set(stamps)), "timestamps must be strictly increasing")

    def test_unwritable_output_path_is_a_usage_error_without_traceback(self):
        out = Path(self.tmp.name) / "missing-dir" / "series.jsonl"
        result = self.run_script(*self.sample_args("--out", str(out)))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("cannot open --out", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.server.requests, [], "no sample may be taken without a place to write it")

    def test_failing_password_command_shows_its_own_message(self):
        env = {**self.env, "JOLOKIA_USER": "u",
               "JOLOKIA_PASSWORD_CMD": "echo 'op: not signed in' >&2; exit 3"}
        result = self.run_script(*self.sample_args(), env=env)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("failed (exit 3)", result.stderr)
        self.assertIn("op: not signed in", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_password_without_user_is_a_usage_error(self):
        env = {**self.env, "JOLOKIA_PASSWORD": "pw"}
        result = self.run_script(*self.sample_args(), env=env)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.server.requests, [])

    def test_basic_auth_is_sent_to_loopback_over_http(self):
        env = {**self.env, "JOLOKIA_USER": "u", "JOLOKIA_PASSWORD": "pw"}
        result = self.run_script(*self.sample_args("--count", "1"), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = "Basic " + base64.b64encode(b"u:pw").decode()
        self.assertEqual(self.server.requests[0]["auth"], expected)
        self.assertNotIn("pw", result.stderr + result.stdout)

    def test_password_command_supplies_the_password(self):
        env = {**self.env, "JOLOKIA_USER": "u", "JOLOKIA_PASSWORD_CMD": "printf cmdsecret"}
        result = self.run_script(*self.sample_args("--count", "1"), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = "Basic " + base64.b64encode(b"u:cmdsecret").decode()
        self.assertEqual(self.server.requests[0]["auth"], expected)

    def test_user_without_password_is_a_usage_error(self):
        env = {**self.env, "JOLOKIA_USER": "u"}
        result = self.run_script(*self.sample_args(), env=env)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.server.requests, [])

    def test_basic_auth_over_http_to_a_remote_host_is_refused_before_any_connection(self):
        env = {**self.env, "JOLOKIA_USER": "u", "JOLOKIA_PASSWORD": "pw"}
        # 192.0.2.1 is TEST-NET-1 and never answers; a connect attempt would hit the timeout.
        result = self.run_script("--url", "http://192.0.2.1:8778/jolokia/", "--preset", "jvm",
                                 "--count", "1", "--timeout", "2", env=env)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("refusing HTTP Basic", result.stderr)

    def test_credentials_in_the_url_are_refused(self):
        result = self.run_script("--url", "http://user:secret@127.0.0.1:1/jolokia/", "--preset", "jvm")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("secret", result.stderr)

    def test_wildcards_are_refused(self):
        result = self.run_script("--url", self.url, "--read", "java.lang:type=*", "Foo")
        self.assertEqual(result.returncode, 2)

    def test_output_file_has_mode_0600_even_when_it_existed_wider(self):
        out = Path(self.tmp.name) / "series.jsonl"
        out.write_text("")
        out.chmod(0o644)
        result = self.run_script(*self.sample_args("--out", str(out)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
        self.assertEqual(len(out.read_text().splitlines()), 2)

    def test_second_csv_run_into_the_same_file_writes_no_second_header(self):
        out = Path(self.tmp.name) / "series.csv"
        for _ in range(2):
            result = self.run_script(*self.sample_args("--format", "csv", "--out", str(out)))
            self.assertEqual(result.returncode, 0, result.stderr)
        lines = out.read_text().splitlines()
        self.assertEqual(len(lines), 5, lines)  # 1 header + 2 samples + 2 samples
        self.assertEqual([line.startswith("time,") for line in lines], [True, False, False, False, False])

    def test_csv_run_into_a_file_with_a_different_header_is_refused_and_leaves_it_untouched(self):
        out = Path(self.tmp.name) / "other.csv"
        original = "time,something/else\n2026-01-01T00:00:00Z,1\n"
        out.write_text(original)
        result = self.run_script(*self.sample_args("--format", "csv", "--out", str(out)))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("header", result.stderr)
        self.assertEqual(out.read_text(), original)

    def test_new_output_file_has_mode_0600(self):
        out = Path(self.tmp.name) / "new.jsonl"
        result = self.run_script(*self.sample_args("--out", str(out), "--count", "1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
