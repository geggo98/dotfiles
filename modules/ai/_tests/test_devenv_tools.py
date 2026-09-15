"""Run the skill helper against an executable CLI double; no Nix evaluation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).parent.parent / "_files/skills/devenv/scripts/devenv-tools.sh"


class DevenvToolsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fake = self.root / "full cli"
        self.fake.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "if sys.argv[1:] == ['-h']:\n"
            "    print('Commands:\\n  search Search\\n  processes Processes')\n"
            "else:\n"
            "    print(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd()}))\n"
            "    print('native diagnostic', file=sys.stderr)\n"
            "    sys.exit(int(os.environ.get('FAKE_EXIT', '0')))\n"
        )
        self.fake.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.root), "DEVENV_BIN": str(self.fake)}

    def run_helper(self, *args):
        return subprocess.run(
            [str(HELPER), *args], cwd=self.root, env=self.env,
            capture_output=True, text=True, timeout=10,
        )

    def test_all_tools_and_native_output(self):
        cases = [
            (("search_packages", "python tools"), ["search", "--", "python tools"]),
            (("search_options", "python"), ["search", "--", "python"]),
            (("list_processes",), ["processes", "list"]),
            (("get_process_status", "example"), ["processes", "status", "--", "example"]),
            (("get_process_logs", "example"), ["processes", "logs", "--lines", "100", "--", "example"]),
            (("get_process_logs", "example", "0"), ["processes", "logs", "--lines", "0", "--", "example"]),
            (("start_process", "example"), ["processes", "start", "--", "example"]),
            (("stop_process", "example"), ["processes", "stop", "--", "example"]),
            (("restart_process", "example"), ["processes", "restart", "--", "example"]),
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                self.assertEqual(payload["args"], ["--no-tui", *expected])
                self.assertEqual(Path(payload["cwd"]).resolve(), self.root.resolve())
                self.assertEqual(result.stderr, "native diagnostic\n")

    def test_invalid_arguments_do_not_invoke_cli(self):
        for args in [(), ("mcp",), ("list_processes", "extra"),
                     ("search_options", ""), ("search_packages",),
                     ("get_process_status",), ("start_process",), ("stop_process",),
                     ("restart_process", ""), ("get_process_logs",),
                     ("get_process_logs", "example", "-1"),
                     ("get_process_logs", "example", "1.5"),
                     ("get_process_logs", "example", "1", "extra")]:
            with self.subTest(args=args):
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("native diagnostic", result.stderr)

    def test_argument_is_not_shell_code_or_cli_flag(self):
        query = '--help; $(touch marker) `touch marker` "quoted"'
        result = self.run_helper("search_packages", query)
        self.assertEqual(json.loads(result.stdout)["args"], ["--no-tui", "search", "--", query])
        self.assertFalse((self.root / "marker").exists())

    def test_exit_code_is_preserved(self):
        self.env["FAKE_EXIT"] = "7"
        self.assertEqual(self.run_helper("list_processes").returncode, 7)

    def test_help_needs_no_cli(self):
        self.env["DEVENV_BIN"] = "/missing/devenv"
        self.assertEqual(self.run_helper("--help").returncode, 0)

    def test_explicit_invalid_cli_fails_without_fallback(self):
        self.env["DEVENV_BIN"] = "/missing/devenv"
        result = self.run_helper("list_processes")
        self.assertEqual(result.returncode, 2)
        self.assertIn("full devenv CLI not found", result.stderr)

    def test_profile_cli_wins_over_restricted_path_wrapper(self):
        profile = self.root / ".nix-profile/bin"
        profile.mkdir(parents=True)
        (profile / "devenv").symlink_to(self.fake)
        restricted = self.root / "restricted"
        restricted.mkdir()
        wrapper = restricted / "devenv"
        wrapper.write_text(f"#!{sys.executable}\nprint('Commands: tasks test up version')\n")
        wrapper.chmod(0o755)
        self.env["DEVENV_BIN"] = str(wrapper)
        self.assertEqual(self.run_helper("list_processes").returncode, 2)
        del self.env["DEVENV_BIN"]
        self.env["PATH"] = str(restricted) + os.pathsep + self.env["PATH"]
        result = self.run_helper("list_processes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["args"], ["--no-tui", "processes", "list"])


if __name__ == "__main__":
    unittest.main()
