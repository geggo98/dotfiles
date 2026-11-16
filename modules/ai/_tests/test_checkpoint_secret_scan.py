"""checkpoint-secret-scan.py against planted canaries in temporary files; no JVM needed."""
import importlib.util
import io
import os
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import random
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parent.parent / "_files/skills/java-fast-startup/scripts/checkpoint-secret-scan.py"

# Non-ASCII on purpose: UTF-8 and Latin-1 then give different bytes, and each encoding is a
# separate pattern. "ß" and "ä" exist in Latin-1, so all four encodings apply.
CANARY = "Pässwort-ß-canary-93"
ASCII_CANARY = "plain-canary-0815"
CONTROL = "com/example/app/Main"
ENC_LABEL = {"utf-8": "utf-8", "latin-1": "latin-1", "utf-16-le": "utf-16-le", "utf-16-be": "utf-16-be"}


def noise(size, seed):
    # Deterministic filler from bytes 0x01-0x1f: no letter of a canary appears by chance, and no
    # NUL. A NUL in front of a UTF-16LE string makes it a UTF-16BE match as well (both are real
    # hits), which would blur the per-encoding expectations.
    rng = random.Random(seed)
    return bytes(rng.randrange(1, 0x20) for _ in range(size))


class ScanTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.dir = self.tmp / "checkpoint"
        self.dir.mkdir(mode=0o700)
        self.env = {**os.environ, "CANARY_A": CANARY, "CANARY_B": ASCII_CANARY}

    def tearDown(self):
        for path in self.tmp.rglob("*"):
            if not path.is_symlink():
                path.chmod(0o700)
        self._tmp.cleanup()

    def write(self, name, data, mode=0o600):
        path = self.dir / name
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def control_file(self):
        return self.write("classes.bin", noise(500, 1) + CONTROL.encode() + noise(500, 2))

    def scan(self, *extra, canaries=("CANARY_A", "CANARY_B"), control: "str | None" = CONTROL, paths=None):
        argv = [sys.executable, str(SCRIPT)]
        for name in canaries:
            argv += ["--canary-env", name]
        if control is not None:
            argv += ["--control", control]
        argv += list(extra) + [str(p) for p in (paths or [self.dir])]
        result = subprocess.run(argv, capture_output=True, text=True, env=self.env, timeout=60)
        for value in (CANARY, ASCII_CANARY):
            self.assertNotIn(value, result.stdout, "a canary value was printed")
            self.assertNotIn(value, result.stderr, "a canary value was printed")
        return result

    def hits(self, stdout):
        """{(file name, canary, encoding): count} from the HIT lines."""
        found = {}
        for line in stdout.splitlines():
            match = re.match(r"HIT  (?P<path>\S+)  canary=(?P<c>\S+)  encoding=(?P<e>\S+)  count=(?P<n>\d+)", line)
            if match:
                found[(Path(match["path"]).name, match["c"], match["e"])] = int(match["n"])
        return found

    def test_canary_is_found_in_each_of_the_four_encodings(self):
        self.control_file()
        for number, encoding in enumerate(ENC_LABEL):
            self.write(f"{encoding}.img", noise(300, number) + CANARY.encode(encoding) + noise(300, number + 10))
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        expected = {(f"{enc}.img", "CANARY_A", label): 1 for enc, label in ENC_LABEL.items()}
        self.assertEqual(self.hits(result.stdout), expected)
        self.assertIn("4 hits for these encodings", result.stdout)

    def test_ascii_canary_reports_utf8_and_latin1_as_one_pattern(self):
        self.control_file()
        self.write("a.img", noise(100, 3) + ASCII_CANARY.encode() + noise(100, 4) + ASCII_CANARY.encode())
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.hits(result.stdout), {("a.img", "CANARY_B", "utf-8/latin-1"): 2})

    def test_hit_across_every_chunk_border_is_counted_exactly_once(self):
        self.control_file()
        # UTF-16 is the longest pattern and sets the kept tail (its length - 1). The shorter UTF-8
        # form can lie fully inside that tail, which is where a double count would show.
        for encoding in ("utf-16-le", "utf-8"):
            needle = CANARY.encode(encoding)
            for chunk in (1, 2, 7, 16, 64):
                for start in range(0, 40):
                    with self.subTest(encoding=encoding, chunk=chunk, start=start):
                        self.write("split.img", noise(start, start) + needle + noise(40, start + 1))
                        result = self.scan("--chunk-size", str(chunk))
                        self.assertEqual(self.hits(result.stdout),
                                         {("split.img", "CANARY_A", encoding): 1}, result.stdout)
                        offsets = re.findall(r"first_offset=(\d+)", result.stdout)
                        self.assertEqual(offsets, [str(start)])

    def test_no_hit_with_control_found_says_0_hits_never_clean(self):
        self.control_file()
        self.write("other.img", noise(2000, 5))
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0 hits for these encodings", result.stdout)
        self.assertNotIn("clean", result.stdout.lower())
        self.assertIn("does not prove", result.stdout)

    def test_missing_control_makes_the_scan_blind(self):
        self.write("other.img", noise(2000, 6))
        result = self.scan()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("--control", result.stderr)
        self.assertNotIn("0 hits", result.stdout)

    def test_empty_directory_is_blind(self):
        result = self.scan()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_control_is_mandatory(self):
        self.control_file()
        result = self.scan(control=None)
        self.assertEqual(result.returncode, 2, result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root reads files with mode 000")
    def test_unreadable_file_makes_the_scan_blind(self):
        self.control_file()
        self.write("locked.img", CANARY.encode(), mode=0o000)
        result = self.scan()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("cannot read", result.stderr)
        self.assertIn("locked.img", result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root reads files with mode 000")
    def test_hit_wins_over_a_blind_part(self):
        self.control_file()
        self.write("locked.img", b"x", mode=0o000)
        self.write("leak.img", CANARY.encode())
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("partly blind", result.stdout)

    def test_symlinks_are_reported_and_not_followed(self):
        self.control_file()
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "secret.img").write_bytes(CANARY.encode())
        (self.dir / "link-to-file").symlink_to(outside / "secret.img")
        (self.dir / "link-to-dir").symlink_to(outside)
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.hits(result.stdout), {})
        self.assertIn(f"symlink not followed: {self.dir / 'link-to-file'}", result.stdout)
        self.assertIn(f"symlink not followed: {self.dir / 'link-to-dir'}", result.stdout)

    def test_symlink_given_as_the_path_is_not_followed(self):
        self.control_file()
        link = self.tmp / "link"
        link.symlink_to(self.dir)
        result = self.scan(paths=[link])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("symlink not followed", result.stdout)

    def test_world_readable_entries_are_flagged_and_private_ones_are_not(self):
        self.control_file()
        self.write("open.img", noise(10, 7), mode=0o644)
        self.write("private.img", noise(10, 8), mode=0o600)
        self.write("group.img", noise(10, 9), mode=0o640)
        sub = self.dir / "sub"
        sub.mkdir(mode=0o755)
        sub.chmod(0o755)
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = {Path(l.split()[1]).name: l for l in result.stdout.splitlines() if l.startswith(("file ", "dir  "))}
        self.assertIn("WORLD-READABLE", lines["open.img"])
        self.assertIn("0644", lines["open.img"])
        self.assertNotIn("WORLD-READABLE", lines["private.img"])
        self.assertIn("0600", lines["private.img"])
        self.assertNotIn("WORLD-READABLE", lines["group.img"])
        self.assertIn("WORLD-READABLE", lines["sub"])
        self.assertNotIn("WORLD-READABLE", lines["checkpoint"])
        # Group-readable is flagged on its own: a group can hold more users than the owner.
        self.assertIn("GROUP-READABLE", lines["group.img"])
        self.assertIn("0640", lines["group.img"])
        self.assertIn("GROUP-READABLE", lines["open.img"])
        self.assertIn("GROUP-READABLE", lines["sub"])
        self.assertNotIn("GROUP-READABLE", lines["private.img"])
        self.assertNotIn("GROUP-READABLE", lines["checkpoint"])

    def test_control_hits_are_reported_per_file_so_an_opaque_file_shows(self):
        # One readable file with the control must not vouch for an opaque (for example compressed)
        # file next to it: the per-file count shows which file the scan could not see into.
        self.control_file()
        self.write("core.img", noise(3000, 11))
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        per_file = {}
        for line in result.stdout.splitlines():
            match = re.match(r"file (?P<path>\S+)  .*control=(?P<n>\d+)", line)
            if match:
                per_file[Path(match["path"]).name] = (int(match["n"]), line)
        self.assertEqual(per_file["classes.bin"][0], 1, result.stdout)
        self.assertEqual(per_file["core.img"][0], 0, result.stdout)
        self.assertIn("NO-CONTROL", per_file["core.img"][1])
        self.assertNotIn("NO-CONTROL", per_file["classes.bin"][1])
        self.assertIn("1 of 2 files without the control", result.stdout)

    def test_canary_below_8_bytes_is_a_usage_error_and_8_bytes_are_accepted(self):
        self.control_file()
        self.env["SHORT"] = "1234567"
        self.env["EIGHT"] = "12345678"
        self.env["EMPTY"] = ""
        result = self.scan(canaries=["SHORT"])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn("1234567", result.stderr)
        self.assertEqual(self.scan(canaries=["EIGHT"]).returncode, 0)
        self.assertEqual(self.scan(canaries=["EMPTY"]).returncode, 2)
        self.assertEqual(self.scan(canaries=["NOT_SET_ANYWHERE_42"]).returncode, 2)

    def test_internal_error_exits_4_never_1(self):
        self.control_file()
        self.write("leak.img", CANARY.encode())
        spec = importlib.util.spec_from_file_location("scan_module", SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        argv = ["scan", "--canary-env", "CANARY_A", "--control", CONTROL, str(self.dir)]
        out, err = io.StringIO(), io.StringIO()
        boom = RuntimeError("text that must not be printed: " + CANARY)
        with mock.patch.dict(os.environ, {"CANARY_A": CANARY}), mock.patch.object(sys, "argv", argv), \
                mock.patch.object(module, "scan_file", side_effect=boom), redirect_stdout(out), redirect_stderr(err):
            code = module.run()
        self.assertEqual(code, 4)
        self.assertIn("internal error: RuntimeError", err.getvalue())
        self.assertNotIn(CANARY, err.getvalue() + out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
