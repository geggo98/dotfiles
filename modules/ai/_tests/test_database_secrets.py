"""db.sh must keep DSN passwords out of argv and out of every output stream.

The database CLIs are replaced by fakes that behave like the real ones in the
two ways that matter: they echo their own argv to stderr (MariaDB's
"unknown variable 'uri=...'" is how the original leak happened) and, on
request, print the secret in several shapes to stdout and stderr.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).parent.parent / "_files/skills/database/scripts"
DB = SCRIPTS / "db.sh"
SECRET = "GEHEIM123"

# dialect -> (DSN, extra db.sh args, fake binaries the wrapper may call)
DIALECTS = {
    "mysql": (f"mysql://testuser:{SECRET}@127.0.0.1:3306/testdb", [], "mysql"),
    "postgres": (f"postgresql://testuser:{SECRET}@127.0.0.1:5432/testdb", [], "psql"),
    "usql": (f"clickhouse://testuser:{SECRET}@127.0.0.1:9000/testdb", [], "usql"),
    "mongo": (f"mongodb://testuser:{SECRET}@127.0.0.1:27017/testdb", ["--write"], "mongosh"),
    "mssql": (f"mssql://testuser:{SECRET}@127.0.0.1:1433/testdb", [], "sqlcmd"),
    "oracle": (f"oracle://testuser:{SECRET}@127.0.0.1:1521/svc", [], "sqlcl"),
}

FAKE = r'''#!{python}
import json, os, sys
tool = os.path.basename(sys.argv[0])
secret = {secret!r}
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
contents = []
candidates = list(sys.argv[1:]) + [
    os.environ.get(n, "") for n in ("PGPASSFILE", "USQLPASS", "MYSQL_HOME")
]
for item in candidates:
    path = item.split("=", 1)[1] if item.startswith("--") and "=" in item else item
    if os.path.isfile(path):
        contents.append(open(path).read())
reached = any(secret in c for c in contents) or secret in stdin or any(
    secret in os.environ.get(n, "")
    for n in ("SQLCMDPASSWORD", "DB_MONGO_URI", "PGPASSWORD")
)
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({{
        "tool": tool, "argv": sys.argv[1:], "reached": reached,
        "argv_has_secret": any(secret in a for a in sys.argv[1:]),
    }}) + "\n")
# Like MariaDB's "unknown variable": the whole argv goes back to the caller.
print(tool + ": argv: " + " ".join(sys.argv[1:]), file=sys.stderr)
if os.environ.get("FAKE_LEAK"):
    for stream in (sys.stdout, sys.stderr):
        print("connect failed: mysql://testuser:" + secret + "@127.0.0.1:3306/x", file=stream)
        print("Server=h;Password=" + secret + ";Uid=u", file=stream)
        print("bare " + secret + " in a line", file=stream)
print("row-1")
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
'''


class DatabaseSecretsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "fake.log"
        for _, _, tool in DIALECTS.values():
            fake = self.bin / tool
            fake.write_text(FAKE.format(python=sys.executable, secret=SECRET))
            fake.chmod(0o755)
        # Tools the wrapper itself needs. Linked one by one so that a real
        # mysql on this machine's PATH cannot shadow the fake or hide its absence.
        self.base = self.root / "base"
        self.base.mkdir()
        for name in ("bash", "env", "sh", "cat", "mktemp", "dirname", "wc", "head",
                     "tr", "rm", "stat", "perl", "awk", "mkdir", "chmod", "sleep",
                     "gtimeout", "timeout"):
            found = shutil.which(name)
            if found:
                (self.base / name).symlink_to(found)
        self.env = {
            "HOME": str(self.root), "TMPDIR": str(self.root),
            "PATH": f"{self.bin}:{self.base}", "FAKE_LOG": str(self.log),
        }

    def db(self, *args, env=None, path=None):
        run_env = {**self.env, **(env or {})}
        if path is not None:
            run_env["PATH"] = path
        return subprocess.run(
            [str(DB), *args], cwd=self.root, env=run_env,
            capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
        )

    def fake_calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def dsn_variants(self, dsn):
        dsn_file = self.root / "dsn"
        dsn_file.write_text(dsn)
        dsn_file.chmod(0o600)
        return {
            "--dsn": ["--dsn", dsn],
            "--dsn-file": ["--dsn-file", str(dsn_file)],
            "--dsn-cmd": ["--dsn-cmd", f"printf %s '{dsn}'"],
        }

    def assert_clean(self, text, where):
        self.assertNotIn(SECRET, text, f"secret visible in {where}")

    def test_filter_is_able_to_see_the_secret(self):
        # Validate the scan before believing "no hits": the fake must really
        # print the secret, otherwise every assert_clean below is vacuous.
        raw = subprocess.run(
            [str(self.bin / "psql")], env={**self.env, "FAKE_LEAK": "1"},
            capture_output=True, text=True, stdin=subprocess.DEVNULL,
        )
        self.assertIn(SECRET, raw.stdout)
        self.assertIn(SECRET, raw.stderr)

    def test_every_dialect_and_dsn_source(self):
        for dialect, (dsn, extra, tool) in DIALECTS.items():
            for source, dsn_args in self.dsn_variants(dsn).items():
                for output_mode in ("buffered", "file"):
                    with self.subTest(dialect=dialect, source=source, mode=output_mode):
                        self.log.unlink(missing_ok=True)
                        out_file = self.root / "result.txt"
                        out_file.unlink(missing_ok=True)
                        mode_args = ["--output", str(out_file)] if output_mode == "file" else []
                        proc = self.db(
                            *extra, *dsn_args, *mode_args, "query", "SELECT 1",
                            env={"FAKE_LEAK": "1", "FAKE_EXIT": "7"},
                        )
                        self.assertEqual(proc.returncode, 7, proc.stderr)
                        self.assert_clean(proc.stdout, "stdout")
                        self.assert_clean(proc.stderr, "stderr")
                        if output_mode == "file":
                            self.assert_clean(out_file.read_text(), "output file")
                        calls = [c for c in self.fake_calls() if c["tool"] == tool]
                        self.assertEqual(len(calls), 1, self.fake_calls())
                        self.assertFalse(calls[0]["argv_has_secret"], calls[0]["argv"])
                        self.assertTrue(calls[0]["reached"], "secret never reached the tool")

    def test_options_may_follow_the_subcommand(self):
        dsn = DIALECTS["postgres"][0]
        proc = self.db("query", "--dsn-cmd", f"printf %s '{dsn}'", "--timeout", "2m", "SELECT 1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("row-1", proc.stdout)

    def test_sql_comment_is_not_taken_for_an_option(self):
        dsn = DIALECTS["postgres"][0]
        proc = self.db("--dsn", dsn, "query", "-- note\nSELECT 1")
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_patterns_are_redacted_without_knowing_the_value(self):
        # `raw` output is not the wrapper's own secret: only the patterns can help.
        proc = self.db(
            "--dsn", "sqlite::memory:", "raw", "--", "sh", "-c",
            "echo mysql://app:hunter2@h/x; echo 'Server=h;Pwd=hunter3;Uid=u'; "
            "echo 'IDENTIFIED BY \"hunter4\"'; echo '{\"api_token\": \"hunter5\"}'; "
            "printf -- '-----BEGIN PRIVATE KEY-----\\nhunter6\\n-----END PRIVATE KEY-----\\nafter\\n'",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for leaked in ("hunter2", "hunter3", "hunter4", "hunter5", "hunter6"):
            self.assertNotIn(leaked, proc.stdout)
        self.assertIn("after", proc.stdout)
        self.assertIn("app", proc.stdout)  # the user name stays, only the password goes

    def test_plain_results_pass_through_unchanged(self):
        proc = self.db("--dsn", "sqlite::memory:", "raw", "--", "sh", "-c",
                       "printf 'a\\tb\\n1\\tÄö\\n'")
        self.assertEqual(proc.stdout, "a\tb\n1\tÄö\n")

    def test_error_messages_do_not_echo_a_mistyped_option(self):
        proc = self.db(f"--dsn=mysql://testuser:{SECRET}@h/x", "query", "SELECT 1")
        self.assertNotEqual(proc.returncode, 0)
        self.assert_clean(proc.stdout + proc.stderr, "error text")

    def test_missing_tool_message_does_not_echo_the_dsn(self):
        # No mysql and no nix on PATH: ensure_pkgs prints the original argv.
        proc = self.db(
            "--dsn", DIALECTS["mysql"][0], "query", "SELECT 1",
            path=str(self.base),
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("missing tool", proc.stdout + proc.stderr)
        self.assert_clean(proc.stdout + proc.stderr, "bootstrap message")

    def test_dsn_command_stderr_is_redacted(self):
        proc = self.db(
            "--dsn-cmd", f"echo 'vault: bad token=hunter9 for mysql://u:hunter8@h' >&2; "
            f"printf %s '{DIALECTS['postgres'][0]}'", "query", "SELECT 1",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for leaked in ("hunter9", "hunter8"):
            self.assertNotIn(leaked, proc.stderr)


if __name__ == "__main__":
    unittest.main()
