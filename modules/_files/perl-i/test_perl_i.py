"""+perl-i: perl -i with one backup directory per run.

Every test runs perl-i.py as a subprocess against files in a temp directory.
A test that asserts "no backup exists" first asserts that the place it looks
in is readable, because a missing directory would "contain no backup" too.
"""
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PERL_I = Path(__file__).parent / "perl-i.py"
PY = sys.executable


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.root = self.tmp / "backups"          # --backup-root, so $TMPDIR stays out of it

    def tearDown(self):
        self._tmp.cleanup()

    def perl_i(self, *args, root=True):
        cmd = [PY, str(PERL_I)]
        if root:
            cmd += ["--backup-root", str(self.root)]
        r = subprocess.run(cmd + [str(a) for a in args], capture_output=True, text=True)
        return r

    def backups(self):
        return sorted(p for p in self.root.iterdir() if p.is_dir()) if self.root.is_dir() else []

    def write(self, rel, text):
        p = self.work / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode())
        return p

    def backup_copy(self, bdir, original):
        return Path(str(bdir) + str(original))


class RunTests(Base):
    def test_edit_applies_and_backup_holds_the_old_content(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("-pe", "s/hello/world/", "--", f)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(f.read_text(), "world\n")
        (bdir,) = self.backups()
        self.assertEqual(self.backup_copy(bdir, f).read_text(), "hello\n")
        sha = hashlib.sha256(b"hello\n").hexdigest()
        self.assertEqual((bdir / "manifest.tsv").read_text(), f"{sha}\t6\t{f}\n")
        self.assertIn(str(bdir), r.stderr)
        self.assertIn("1 changed, 0 unchanged", r.stderr)

    def test_two_runs_on_the_same_file_keep_two_different_backups(self):
        f = self.write("a.txt", "one\n")
        self.assertEqual(self.perl_i("-pe", "s/one/two/", "--", f).returncode, 0)
        self.assertEqual(self.perl_i("-pe", "s/two/three/", "--", f).returncode, 0)
        b1, b2 = self.backups()
        self.assertNotEqual(b1, b2)
        self.assertEqual({self.backup_copy(b, f).read_text() for b in (b1, b2)}, {"one\n", "two\n"})

    def test_same_name_in_two_directories_does_not_collide(self):
        a, b = self.write("x/n.txt", "A\n"), self.write("y/n.txt", "B\n")
        self.assertEqual(self.perl_i("-pe", "s/$/!/", "--", a, b).returncode, 0)
        (bdir,) = self.backups()
        self.assertEqual(self.backup_copy(bdir, a).read_text(), "A\n")
        self.assertEqual(self.backup_copy(bdir, b).read_text(), "B\n")

    def test_missing_separator_exits_2_and_touches_nothing(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("-pe", "s/hello/world/", f)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(f.read_text(), "hello\n")
        self.assertFalse(self.root.exists())

    def test_no_files_after_separator_exits_2(self):
        r = self.perl_i("-pe", "1", "--")
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.root.exists())

    def test_own_i_switch_is_refused(self):
        f = self.write("a.txt", "hello\n")
        for switches in (["-pi", "-e", "s/h/j/"], ["-i.bak", "-pe", "s/h/j/"], ["-pie", "s/h/j/"]):
            r = self.perl_i(*switches, "--", f)
            self.assertEqual(r.returncode, 2, switches)
            self.assertEqual(f.read_text(), "hello\n")
        self.assertFalse(self.root.exists())

    def test_letter_i_inside_the_code_is_not_a_switch(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("-pe", "s/hello/hi there/i", "--", f)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(f.read_text(), "hi there\n")

    def test_symlink_and_missing_file_are_refused(self):
        real = self.write("real.txt", "x\n")
        link = self.work / "link.txt"
        link.symlink_to(real)
        self.assertEqual(self.perl_i("-pe", "1", "--", link).returncode, 2)
        self.assertEqual(self.perl_i("-pe", "1", "--", self.work / "nope").returncode, 2)
        self.assertTrue(link.is_symlink())
        self.assertFalse(self.root.exists())

    def test_file_that_becomes_empty_fails_and_warns(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("-ne", "print if 0", "--", f)
        self.assertEqual(r.returncode, 1)
        self.assertIn("WARNING", r.stderr)
        self.assertIn("shrank from 6 bytes to 0", r.stderr)
        self.assertEqual(f.read_bytes(), b"")
        (bdir,) = self.backups()
        self.assertEqual(self.backup_copy(bdir, f).read_text(), "hello\n")

    def test_allow_empty_turns_the_failure_off_but_keeps_the_warning(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("--allow-empty", "-ne", "print if 0", "--", f)
        self.assertEqual(r.returncode, 0)
        self.assertIn("WARNING", r.stderr)

    def test_an_empty_file_staying_empty_is_no_warning(self):
        f = self.write("a.txt", "")
        r = self.perl_i("-pe", "s/a/b/", "--", f)
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("WARNING", r.stderr)

    def test_perl_failure_passes_the_exit_code_and_keeps_the_backup(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("-pe", "s/(/x/", "--", f)         # regex syntax error
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(f.read_text(), "hello\n")
        (bdir,) = self.backups()
        self.assertEqual(self.backup_copy(bdir, f).read_text(), "hello\n")

    def test_a_run_that_changes_nothing_says_so(self):
        f = self.write("a.txt", "hello\n")
        r = self.perl_i("-pe", "s/nomatch/x/", "--", f)
        self.assertEqual(r.returncode, 0)
        self.assertIn("0 changed, 1 unchanged", r.stderr)

    def test_unwritable_backup_root_stops_before_perl_runs(self):
        f = self.write("a.txt", "hello\n")
        blocker = self.tmp / "file-not-dir"
        blocker.write_text("x")
        r = self.perl_i("--backup-root", blocker / "sub", "-pe", "s/hello/world/", "--", f, root=False)
        self.assertEqual(r.returncode, 125)
        self.assertEqual(f.read_text(), "hello\n")

    def test_default_root_is_below_tmpdir(self):
        f = self.write("a.txt", "hello\n")
        env = dict(os.environ, TMPDIR=str(self.tmp))
        r = subprocess.run([PY, str(PERL_I), "-pe", "s/hello/world/", "--", str(f)],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(list((self.tmp / "perl-i").iterdir())), 1)


class RestoreTests(Base):
    def test_restore_brings_back_the_bytes(self):
        f = self.write("a.txt", "héllo\n\x00bin\n")
        original = f.read_bytes()
        self.assertEqual(self.perl_i("-pe", "s/l/L/g", "--", f).returncode, 0)
        self.assertNotEqual(f.read_bytes(), original)
        (bdir,) = self.backups()
        r = self.perl_i("--restore", bdir, root=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(f.read_bytes(), original)
        self.assertIn("restored 1 file(s)", r.stderr)

    def test_restore_with_a_damaged_backup_restores_nothing(self):
        a, b = self.write("a.txt", "A\n"), self.write("b.txt", "B\n")
        self.assertEqual(self.perl_i("-pe", "s/$/!/", "--", a, b).returncode, 0)
        (bdir,) = self.backups()
        self.backup_copy(bdir, b).write_text("tampered\n")
        r = self.perl_i("--restore", bdir, root=False)
        self.assertEqual(r.returncode, 1)
        self.assertEqual((a.read_text(), b.read_text()), ("A!\n", "B!\n"))

    def test_restore_of_a_directory_without_manifest_fails(self):
        r = self.perl_i("--restore", self.tmp, root=False)
        self.assertEqual(r.returncode, 1)


class ListTests(Base):
    def test_list_shows_newest_first(self):
        f = self.write("a.txt", "1\n")
        for old, new in (("1", "2"), ("2", "3")):
            self.assertEqual(self.perl_i("-pe", f"s/{old}/{new}/", "--", f).returncode, 0)
        r = self.perl_i("--list", "--backup-root", self.root, root=False)
        self.assertEqual(r.returncode, 0)
        lines = r.stdout.splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines, sorted(lines, reverse=True))
        self.assertIn("1 file(s)", lines[0])

    def test_list_without_backups_is_not_an_error(self):
        r = self.perl_i("--list", "--backup-root", self.root, root=False)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")


if __name__ == "__main__":
    unittest.main()
