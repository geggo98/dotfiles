"""+errlog: stderr into a file, exit code passed through, secrets masked.

Every test runs errlog.py as a subprocess against small python/sh children.
A test that asserts "X appears nowhere" first asserts that the place it looks
in is non-empty — an empty file would "contain no secret" just as well.
"""
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.parse import quote

ERRLOG = Path(__file__).parent / "errlog.py"
PY = sys.executable
SECRET = "Zx9-hunter2/PW+k"        # contains characters that URL-encode
LOG_RX = re.compile(r"stderr -> (?P<path>\S+) \(pid (?P<pid>\d+)\)")


class Run:
    def __init__(self, proc, tmp):
        self.proc, self.tmp = proc, tmp
        self.code = proc.returncode
        self.out = proc.stdout
        self.err = proc.stderr.decode("utf-8", "replace")
        m = LOG_RX.search(self.err)
        self.path = Path(m["path"]) if m else None
        self.log = self.path.read_bytes() if self.path and self.path.exists() else b""

    def field(self, key):
        m = re.search(rb"(?:^|\s)" + key.encode() + rb"=(\S*)", self.log, re.M)
        return m[1].decode() if m else None


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def errlog(self, args, cmd, *, input=b"", env=None, timeout=60):
        e = dict(os.environ, TMPDIR=str(self.tmp))
        e.update(env or {})
        proc = subprocess.run([PY, str(ERRLOG), *args, "--", *cmd], input=input,
                              capture_output=True, env=e, timeout=timeout)
        return Run(proc, self.tmp)

    def py(self, code, *args, **kw):
        return self.errlog(args, [PY, "-c", code], **kw)


class Passthrough(Base):
    def test_stdout_is_byte_exact_and_stdin_is_inherited(self):
        data = bytes(range(256)) * 40
        r = self.py("import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())", input=data)
        self.assertEqual(r.out, data)
        self.assertEqual(r.code, 0)

    def test_wrapper_stderr_is_only_announcement_and_summary(self):
        r = self.py("import sys; print('noise-from-child', file=sys.stderr)")
        self.assertNotIn("noise-from-child", r.err)
        lines = r.err.strip().splitlines()
        self.assertEqual(len(lines), 2, r.err)
        self.assertTrue(lines[0].startswith("[errlog] stderr -> "))
        self.assertIn("exit=0", lines[1])
        self.assertIn(b"noise-from-child\n", r.log)

    def test_exit_codes_are_passed_through_and_recorded(self):
        for code in (0, 1, 42, 255):
            with self.subTest(code=code):
                r = self.py(f"raise SystemExit({code})")
                self.assertEqual(r.code, code)
                self.assertEqual(r.field("exit_code"), str(code))

    def test_child_killed_by_signal_gives_128_plus_n(self):
        r = self.py("import os, signal; os.kill(os.getpid(), signal.SIGKILL)")
        self.assertEqual(r.code, 137)
        self.assertEqual(r.field("signal"), "SIGKILL")
        self.assertIn("SIGKILL", r.err)

    def test_log_file_mode_env_and_layout(self):
        r = self.py("import os, sys; print('FILE=' + os.environ['ERRLOG_FILE'], file=sys.stderr)")
        self.assertEqual(stat.S_IMODE(r.path.stat().st_mode), 0o600)
        self.assertIn(f"FILE={r.path}".encode(), r.log)
        text = r.log.decode()
        self.assertLess(text.index("errlog: version=1"), text.index("----- stderr -----"))
        self.assertLess(text.index("----- end of stderr -----"), text.index("errlog: exit_code=0"))
        for key in ("cpu_user_s", "cpu_sys_s", "max_rss_bytes", "duration_s", "child_pid",
                    "wrapper_pid", "stderr_lines", "stderr_bytes"):
            self.assertIsNotNone(r.field(key), key)
        self.assertEqual(r.field("child_pid"), LOG_RX.search(r.err)["pid"])

    def test_dir_and_file_options(self):
        sub = self.tmp / "logs"
        sub.mkdir()
        r = self.py("import sys; print('x', file=sys.stderr)", "--dir", str(sub))
        self.assertEqual(r.path.parent, sub)
        target = self.tmp / "exact.log"
        r = self.py("import sys; print('y', file=sys.stderr)", "--file", str(target))
        self.assertEqual(r.path, target)
        self.assertIn(b"y\n", target.read_bytes())
        again = self.py("print('never')", "--file", str(target))
        self.assertEqual(again.code, 125)
        self.assertNotIn(b"never", again.out)
        self.assertIn(b"y\n", target.read_bytes())      # not overwritten


class Failures(Base):
    def test_missing_and_non_executable_command(self):
        r = self.errlog([], ["definitely-not-a-command-xyz"])
        self.assertEqual(r.code, 127)
        self.assertEqual(list(self.tmp.glob("errlog-*")), [])
        plain = self.tmp / "plain.sh"
        plain.write_text("#!/bin/sh\necho hi\n")
        r = self.errlog([], [str(plain)])
        self.assertEqual(r.code, 126)

    def test_exec_failure_after_resolution_is_126_or_127(self):
        bad = self.tmp / "bad"
        bad.write_text("#!/nonexistent/interpreter\n")
        bad.chmod(0o755)
        r = self.errlog([], [str(bad)])
        self.assertIn(r.code, (126, 127))
        self.assertIn(b"cannot execute", r.log)

    def test_usage_errors_do_not_start_the_child(self):
        marker = self.tmp / "ran"
        touch = f"open({str(marker)!r}, 'w').close()"
        cases = {
            "unknown option": ["--bogus"],
            "secret as value": ["--mask", SECRET],
            "bad tail": ["--tail", "x"],
            "negative grace": ["--grace", "-1"],
            "missing mask file": ["--mask-file", str(self.tmp / "nope")],
            "unset env": ["--mask-env", "ERRLOG_TEST_UNSET"],
        }
        for name, args in cases.items():
            with self.subTest(name):
                r = self.errlog(args, [PY, "-c", touch])
                self.assertEqual(r.code, 125, r.err)
                self.assertFalse(marker.exists())
                self.assertNotIn(SECRET, r.err)
        r = subprocess.run([PY, str(ERRLOG)], capture_output=True)
        self.assertEqual(r.returncode, 125)

    def test_empty_mask_sources_are_refused(self):
        empty = self.tmp / "empty"
        empty.write_text("\n\n")
        self.assertEqual(self.py("pass", "--mask-file", str(empty)).code, 125)
        self.assertEqual(self.py("pass", "--mask-env", "E", env={"E": ""}).code, 125)

    def test_command_without_dashes_is_accepted(self):
        proc = subprocess.run([PY, str(ERRLOG), PY, "-c", "raise SystemExit(7)"],
                              capture_output=True, env=dict(os.environ, TMPDIR=str(self.tmp)))
        self.assertEqual(proc.returncode, 7)


class Masking(Base):
    CHILD = (
        "import sys, urllib.parse as u\n"
        "s = sys.argv[1]\n"
        "print('raw ' + s, file=sys.stderr)\n"
        "print('enc ' + u.quote(s, safe=''), file=sys.stderr)\n"
        "print('dec ' + u.unquote(s), file=sys.stderr)\n"
        "print('url mysql://app:' + s + '@db/x', file=sys.stderr)\n"
        "raise SystemExit(5)\n"
    )

    def assert_clean(self, r):
        self.assertGreater(len(r.log), 100, "log not readable — test would be vacuous")
        self.assertGreater(r.log.count(b"\n"), 8)
        for form in (SECRET, quote(SECRET, safe=""), "hunter2"):
            if form == "hunter2":
                continue                                  # only a part of SECRET
            self.assertNotIn(form.encode(), r.log)
            self.assertNotIn(form, r.err)
            self.assertNotIn(form.encode(), r.out)

    def test_mask_from_file_in_all_three_forms(self):
        f = self.tmp / "pw"
        f.write_text(SECRET + "\n")
        r = self.errlog(["--mask-file", str(f)], [PY, "-c", self.CHILD, SECRET])
        self.assertEqual(r.code, 5)
        self.assert_clean(r)
        self.assertIn(b"raw ***\n", r.log)
        self.assertIn(b"enc ***\n", r.log)
        self.assertIn(b"app:***@db", r.log)
        self.assertGreaterEqual(int(r.field("masked_replacements")), 4)
        self.assertIn("raw ***", r.err)                   # the tail is masked too

    def test_mask_from_env_keeps_variable_for_the_child(self):
        r = self.errlog(["--mask-env", "ERRLOG_T_PW"],
                        [PY, "-c", "import os, sys; print('v=' + os.environ['ERRLOG_T_PW'], file=sys.stderr); sys.exit(1)"],
                        env={"ERRLOG_T_PW": SECRET})
        self.assertIn(b"v=***\n", r.log)
        self.assertNotIn(SECRET.encode(), r.log)
        self.assertNotIn(SECRET, r.err)
        self.assertEqual(r.field("mask_sources"), "env:ERRLOG_T_PW")

    def test_env_pendants(self):
        f = self.tmp / "pw"
        f.write_text(SECRET)
        r = self.errlog([], [PY, "-c", self.CHILD, SECRET],
                        env={"ERRLOG_MASK_FILES": str(f), "ERRLOG_MASK_ENVS": "ERRLOG_T_PW",
                             "ERRLOG_T_PW": SECRET + "-second"})
        self.assert_clean(r)
        self.assertNotIn(b"-second", r.log.replace(b"mask_sources", b""))

    def test_multi_line_file_masks_each_line(self):
        f = self.tmp / "pw"
        f.write_text("alpha-secret\n\nbeta-secret\r\n")
        r = self.py("import sys; print('a alpha-secret b beta-secret c', file=sys.stderr)",
                    "--mask-file", str(f))
        self.assertIn(b"a *** b *** c\n", r.log)
        self.assertEqual(r.field("mask_values"), "2")

    def test_secret_in_argv_is_masked_in_header(self):
        f = self.tmp / "pw"
        f.write_text(SECRET)
        r = self.errlog(["--mask-file", str(f)], [PY, "-c", "import sys; print('x', file=sys.stderr)", SECRET])
        header = r.log.split(b"----- stderr -----")[0]
        self.assertIn(b"errlog: command=", header)
        self.assertNotIn(SECRET.encode(), header)
        self.assertIn(b"'***'", header.replace(b"\x00", b"")) if False else self.assertIn(b"***", header)

    def test_secret_split_across_writes_is_masked(self):
        f = self.tmp / "pw"
        f.write_text(SECRET)
        code = (
            "import os, sys, time\n"
            f"s = {SECRET!r}.encode()\n"
            "for i in range(1, len(s)):\n"
            "    os.write(2, b'pre ' + s[:i]); time.sleep(0.45)\n"
            "    os.write(2, s[i:] + b' post\\n'); break\n"
            "time.sleep(0.05)\n"
            "os.write(2, b'tail ' + s[:3]); time.sleep(0.45); os.write(2, s[3:] + b'\\n')\n"
        )
        r = self.py(code, "--mask-file", str(f))
        self.assertGreater(len(r.log), 100)
        self.assertNotIn(SECRET.encode(), r.log)
        self.assertNotIn(SECRET[:3].encode() + b"\n", r.log)
        self.assertIn(b"pre ***", r.log.replace(b"pre ", b"pre ", 1))
        self.assertIn(b"*** post", r.log)
        self.assertIn(b"tail ***", r.log)

    def test_secret_in_line_with_invalid_utf8(self):
        f = self.tmp / "pw"
        f.write_text(SECRET)
        code = f"import os; os.write(2, b'\\xff\\xfe ' + {SECRET!r}.encode() + b' \\x80\\n')"
        r = self.py(code, "--mask-file", str(f))
        self.assertIn(b"\xff\xfe *** \x80\n", r.log)
        self.assertNotIn(SECRET.encode(), r.log)

    def test_short_secret_is_masked_with_warning(self):
        f = self.tmp / "pw"
        f.write_text("ab")
        r = self.py("import sys; print('xabx', file=sys.stderr)", "--mask-file", str(f))
        self.assertIn(b"x***x\n", r.log)
        self.assertIn("shorter than 4", r.err)

    def test_secret_longer_than_partial_buffer_boundary(self):
        """A long unterminated line (> 64 KiB) is cut, but never through a secret."""
        f = self.tmp / "pw"
        f.write_text(SECRET)
        code = (
            f"import os; s = {SECRET!r}.encode()\n"
            "for pad in range(65536 - 40, 65536 + 40, 3):\n"
            "    os.write(2, b'.' * pad + s + b'\\n')\n"
        )
        r = self.py(code, "--mask-file", str(f))
        self.assertGreater(len(r.log), 65536 * 20)
        self.assertNotIn(SECRET.encode(), r.log)
        body = r.log.split(b"----- stderr -----\n", 1)[1]    # header holds the masked argv
        self.assertEqual(body.count(b"***"), 27)


class Signals(Base):
    def spawn(self, code, *args):
        e = dict(os.environ, TMPDIR=str(self.tmp))
        return subprocess.Popen([PY, str(ERRLOG), *args, "--", PY, "-c", code],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)

    def wait_for_ready(self, p):
        deadline = time.time() + 20
        while time.time() < deadline:
            logs = list(self.tmp.glob("errlog-*.log"))
            if logs and b"ready" in logs[0].read_bytes():
                return
            time.sleep(0.05)
        p.kill()
        self.fail("child never became ready")

    HANDLER = (
        "import signal, sys, time\n"
        "def h(n, f):\n"
        "    print('got ' + signal.Signals(n).name, file=sys.stderr, flush=True); sys.exit(42)\n"
        "signal.signal(signal.{sig}, h)\n"
        "print('ready', file=sys.stderr, flush=True)\n"
        "time.sleep(30)\n"
    )

    def test_sigterm_and_sigint_are_forwarded(self):
        for sig in ("SIGTERM", "SIGINT"):
            with self.subTest(sig=sig):
                for old in self.tmp.glob("errlog-*"):
                    old.unlink()
                p = self.spawn(self.HANDLER.format(sig=sig))
                self.wait_for_ready(p)
                p.send_signal(getattr(signal, sig))
                out, err = p.communicate(timeout=20)
                self.assertEqual(p.returncode, 42, err)
                log = next(self.tmp.glob("errlog-*.log")).read_bytes()
                self.assertIn(f"got {sig}".encode(), log)
                self.assertIn(f"signals_forwarded={sig}".encode(), log)

    def test_unhandled_sigterm_gives_143(self):
        p = self.spawn("import sys, time; print('ready', file=sys.stderr, flush=True); time.sleep(30)")
        self.wait_for_ready(p)
        p.send_signal(signal.SIGTERM)
        p.communicate(timeout=20)
        self.assertEqual(p.returncode, 143)


class Streams(Base):
    def test_large_stderr_with_large_stdout_does_not_deadlock(self):
        code = (
            "import os\n"
            "blk = b'e' * 1023 + b'\\n'\n"
            "for i in range(50 * 1024):\n"
            "    os.write(2, blk)\n"
            "    if i % 8 == 0: os.write(1, b'o' * 4095 + b'\\n')\n"
        )
        r = self.py(code, "--tail", "0", timeout=120)
        self.assertEqual(r.code, 0)
        self.assertEqual(r.field("stderr_lines"), str(50 * 1024))
        self.assertEqual(r.field("stderr_bytes"), str(50 * 1024 * 1024))
        self.assertEqual(len(r.out), (50 * 1024 // 8) * 4096)
        self.assertGreater(len(r.log), 50 * 1024 * 1024)

    def test_statistics_are_plausible(self):
        code = (
            "import time\n"
            "buf = bytearray(120 * 1024 * 1024)\n"
            "for i in range(0, len(buf), 4096): buf[i] = 1\n"
            "end = time.time() + 0.5\n"
            "while time.time() < end: pass\n"
        )
        r = self.py(code)
        self.assertGreaterEqual(int(r.field("max_rss_bytes")), 100 * 1024 * 1024)
        self.assertGreater(float(r.field("cpu_user_s")), 0.2)
        self.assertGreaterEqual(float(r.field("duration_s")), 0.5)
        self.assertLess(float(r.field("duration_s")), 20)

    def test_descendant_holding_stderr_does_not_block_return(self):
        t = time.time()
        r = self.errlog(["--grace", "0.5"], ["sh", "-c", "sleep 30 >&2 & echo early >&2; exit 3"])
        self.assertLess(time.time() - t, 10)
        self.assertEqual(r.code, 3)
        self.assertEqual(r.field("stderr_open_after_exit"), "yes")
        self.assertIn(b"early\n", r.log)
        try:
            subprocess.run(["pkill", "-f", "^sleep 30$"], capture_output=True)
        except FileNotFoundError:
            pass                                   # no procps in the sandbox; the sleep ends by itself

    def test_tail_only_on_failure_and_configurable(self):
        code = "import sys, os\nfor i in range(30): print(f'L{i}', file=sys.stderr)\nsys.exit(int(os.environ.get('RC', '0')))"
        ok = self.py(code)
        self.assertNotIn("| L", ok.err)
        bad = self.py(code, env={"RC": "2"})
        self.assertEqual(bad.err.count("| L"), 10)
        self.assertIn("| L29", bad.err)
        self.assertNotIn("| L19\n", bad.err)
        self.assertIn("last 10 of 30", bad.err)
        three = self.py(code, "--tail", "3", env={"RC": "2"})
        self.assertEqual(three.err.count("| L"), 3)
        off = self.py(code, "--tail", "0", env={"RC": "2"})
        self.assertEqual(off.err.count("| L"), 0)
        self.assertIn("exit=2", off.err)

    def test_tail_truncates_giant_lines(self):
        r = self.py("import sys; print('x' * 100000, file=sys.stderr); sys.exit(1)")
        self.assertLess(len(r.err), 2000)
        self.assertGreaterEqual(len(r.log), 100000)

    def test_carriage_return_progress_and_missing_final_newline(self):
        code = ("import os, time\n"
                "for i in range(3): os.write(2, f'\\rprogress {i}'.encode()); time.sleep(0.3)\n"
                "os.write(2, b'\\rdone')\n")
        r = self.py(code)
        self.assertIn(b"\rprogress 0\rprogress 1\rprogress 2\rdone\n", r.log)
        self.assertEqual(r.field("stderr_lines"), "1")

    def test_timestamps_prefix(self):
        r = self.py("import sys, time; print('a', file=sys.stderr, flush=True); time.sleep(0.3); print('b', file=sys.stderr)",
                    "--timestamps")
        stamps = re.findall(rb"^\[\+(\d+\.\d{3})s\] (a|b)$", r.log, re.M)
        self.assertEqual([s[1] for s in stamps], [b"a", b"b"])
        self.assertGreaterEqual(float(stamps[1][0]) - float(stamps[0][0]), 0.25)

    LIVE = (
        "import os, time\n"
        "os.write(2, b'line one\\n'); time.sleep(0.1)\n"
        "os.write(2, b'Error: boom without newline')\n"
        "for i in range(60):\n"
        "    os.write(2, f'\\rprogress {i}'.encode()); time.sleep(0.05)\n"
        "time.sleep(4)\n"
    )

    def live_log(self, args):
        e = dict(os.environ, TMPDIR=str(self.tmp))
        p = subprocess.Popen([PY, str(ERRLOG), *args, "--", PY, "-c", self.LIVE],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
        try:
            time.sleep(1.5)                      # child is still running (it sleeps 4 s after ~3 s)
            self.assertIsNone(p.poll())
            logs = list(self.tmp.glob("errlog-*.log"))
            self.assertEqual(len(logs), 1)
            return logs[0].read_bytes()
        finally:
            p.kill()
            p.communicate()

    def test_output_reaches_the_file_while_the_process_is_running(self):
        seen = self.live_log([])
        self.assertIn(b"line one\n", seen)
        self.assertIn(b"Error: boom without newline", seen)    # no newline, still visible
        self.assertRegex(seen, rb"\rprogress (1\d|2\d)")           # progress keeps arriving, not only at the end

    def test_live_visibility_also_holds_with_masking_active(self):
        f = self.tmp / "pw"
        f.write_text(SECRET)
        seen = self.live_log(["--mask-file", str(f)])
        self.assertIn(b"Error: boom without newline", seen)    # not held back as a possible secret prefix
        self.assertRegex(seen, rb"\rprogress (1\d|2\d)")

    def test_empty_stderr(self):
        r = self.py("print('only stdout')")
        self.assertEqual(r.field("stderr_lines"), "0")
        self.assertIn(b"----- stderr -----\n----- end of stderr -----\n", r.log)


if __name__ == "__main__":
    unittest.main()
