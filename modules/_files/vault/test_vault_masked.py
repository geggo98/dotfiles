"""vault-masked: tokens masked in stdout and stderr, hint shown, exit codes kept.

All tokens are synthetic. Every "X does not appear" assertion first asserts that
the stream it inspects is non-empty — an empty stream would hold no token either.
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).parent / "vault-masked.py"
PY = sys.executable
STORED = "hvs.STOREDtoken0123456789abcdef"     # in the token helper's directory
LEGACY = "hvs.LEGACYtoken0123456789abcdef"     # in ~/.vault-token
UNSEEN = "hvb.UNSEENtoken0123456789abcdefg"    # in no store: only the format knows it
HINT = "--show-tokens"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        tokens = self.tmp / "state" / "vault" / "tokens"
        tokens.mkdir(parents=True)
        (tokens / ("a" * 64)).write_text(STORED + "\n")
        (self.tmp / ".vault-token").write_text(LEGACY)
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.tmp),
                    "XDG_STATE_HOME": str(self.tmp / "state")}

    def run_tool(self, script, env=None, timeout=20):
        p = subprocess.run([PY, str(TOOL), "--", PY, "-c", script], capture_output=True,
                           env={**self.env, **(env or {})}, timeout=timeout)
        return p.returncode, p.stdout.decode(), p.stderr.decode()


class Masking(Base):
    def test_known_tokens_masked_on_both_streams_with_hint(self):
        code, out, err = self.run_tool(
            f"import sys; print('id {STORED}'); print('x {LEGACY}', file=sys.stderr)")
        self.assertIn("id ***", out)
        self.assertTrue(out.strip() and err.strip())
        for secret in (STORED, LEGACY):
            self.assertNotIn(secret, out + err)
        self.assertIn(HINT, err)
        self.assertIn("2 token value(s)", err)
        self.assertEqual(code, 0)

    def test_stdout_and_stderr_stay_separate(self):
        _, out, err = self.run_tool(f"import sys; print('{STORED}'); print('oops', file=sys.stderr)")
        self.assertEqual(out, "***\n")
        self.assertTrue(err.startswith("oops\n"))

    def test_token_in_no_store_is_masked_by_format(self):
        _, out, err = self.run_tool(f"print('{{\"client_token\":\"{UNSEEN}\"}}')")
        self.assertIn('"client_token":"***"', out)
        self.assertNotIn(UNSEEN, out + err)

    def test_vault_token_env_is_masked(self):
        _, out, _ = self.run_tool("import os; print(os.environ['VAULT_TOKEN'])",
                                  env={"VAULT_TOKEN": "legacy-style-token-value"})
        self.assertEqual(out, "***\n")

    def test_token_split_across_writes_is_masked(self):
        script = (f"import sys, time; t='{STORED}'; sys.stdout.write('id '+t[:9]); sys.stdout.flush();"
                  f"time.sleep(0.6); sys.stdout.write(t[9:]+'\\n')")
        _, out, err = self.run_tool(script)
        self.assertEqual(out, "id ***\n")
        self.assertNotIn(STORED[:9], out)

    def test_split_format_token_is_masked(self):
        script = (f"import sys, time; t='{UNSEEN}'; sys.stdout.write('id '+t[:6]); sys.stdout.flush();"
                  f"time.sleep(0.6); sys.stdout.write(t[6:]+'\\n')")
        _, out, _ = self.run_tool(script)
        self.assertEqual(out, "id ***\n")

    def test_prompt_without_newline_is_not_held_back(self):
        script = ("import sys, time; sys.stdout.write('Token (will be hidden): '); sys.stdout.flush();"
                  "time.sleep(0.2); sys.stdin.readline()")
        p = subprocess.Popen([PY, str(TOOL), "--", PY, "-c", script], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, env=self.env)
        got = os.read(p.stdout.fileno(), 100)          # would block, then time out, if held back
        p.stdin.write(b"\n"); p.stdin.close()
        p.wait(timeout=10)
        p.stdout.close()
        self.assertEqual(got, b"Token (will be hidden): ")

    def test_clean_output_gets_no_hint(self):
        code, out, err = self.run_tool("print('nothing secret'); print('hvs. is a prefix')")
        self.assertEqual(out, "nothing secret\nhvs. is a prefix\n")
        self.assertNotIn(HINT, err)
        self.assertEqual(err, "")


class ExitCodes(Base):
    def test_exit_code_passes_through(self):
        for want in (0, 2, 130):
            with self.subTest(code=want):
                code, _, _ = self.run_tool(f"import sys; sys.exit({want})")
                self.assertEqual(code, want)

    def test_killed_by_signal_is_128_plus_n(self):
        code, _, _ = self.run_tool("import os, signal; os.kill(os.getpid(), signal.SIGKILL)")
        self.assertEqual(code, 137)

    def test_command_not_found_is_127(self):
        p = subprocess.run([PY, str(TOOL), "--", "no-such-command-xyz"], capture_output=True, env=self.env)
        self.assertEqual(p.returncode, 127)
        self.assertIn("command not found", p.stderr.decode())

    def test_no_token_files_still_masks_by_format(self):
        for f in (self.tmp / ".vault-token", *(self.tmp / "state" / "vault" / "tokens").iterdir()):
            f.unlink()
        _, out, _ = self.run_tool(f"print('{UNSEEN}')")
        self.assertEqual(out, "***\n")


if __name__ == "__main__":
    unittest.main()
