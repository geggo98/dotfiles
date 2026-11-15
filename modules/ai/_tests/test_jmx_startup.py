"""jmx-startup.sh --print-args-only: the loopback bind is a security control (JMX without auth = code execution)."""
import os
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).parent.parent / "_files/skills/java-debug/scripts/jmx-startup.sh"
BIND = "-Dcom.sun.management.jmxremote.host="


def run(*args, env=None):
    return subprocess.run(["bash", str(SCRIPT), "--print-args-only", *args],
                          capture_output=True, text=True, timeout=20, env=env)


def bind_flag(stdout):
    flags = [f for f in stdout.split() if f.startswith(BIND)]
    return flags[0][len(BIND):] if flags else None


class JmxStartupTests(unittest.TestCase):
    def test_loopback_hostnames_bind_the_listener_to_loopback(self):
        cases = {"127.0.0.1": "127.0.0.1", "127.0.0.2": "127.0.0.2", "localhost": "127.0.0.1",
                 "LOCALHOST": "127.0.0.1", "::1": "::1", "[::1]": "::1"}
        for hostname, expected in cases.items():
            with self.subTest(hostname=hostname):
                result = run("--hostname", hostname)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(bind_flag(result.stdout), expected, result.stdout)
                self.assertNotIn("ALL interfaces", result.stderr)

    def test_default_hostname_binds_to_loopback(self):
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bind_flag(result.stdout), "127.0.0.1")

    def test_remote_hostname_warns_on_stderr_and_keeps_stdout_composable(self):
        result = run("--hostname", "example-service.example-ns.svc.cluster.local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(bind_flag(result.stdout))
        self.assertIn("ALL interfaces", result.stderr)
        self.assertNotIn("WARNING", result.stdout)

    def test_bind_all_skips_the_loopback_bind_and_warns_without_auth(self):
        result = run("--bind-all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(bind_flag(result.stdout))
        self.assertIn("ALL interfaces", result.stderr)

    def test_bind_all_with_auth_does_not_warn(self):
        # Keep PATH: in the Nix sandbox bash is only on the inherited PATH.
        result = run("--bind-all", "--auth", env={**os.environ, "JMX_PASSWORD_FILE": "/nonexistent"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-Dcom.sun.management.jmxremote.authenticate=true", result.stdout)
        self.assertNotIn("ALL interfaces", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
