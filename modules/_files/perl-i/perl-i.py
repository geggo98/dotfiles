#!/usr/bin/env python3
"""+perl-i — `perl -i` with a backup of every file, one backup directory per run.

usage: +perl-i [--backup-root DIR] [--allow-empty] PERL-SWITCHES… -- FILE…
       +perl-i --list [--backup-root DIR]
       +perl-i --restore BACKUP-DIR

  Copies every FILE into a fresh directory, then runs `perl -i PERL-SWITCHES -- FILE…`.
  The `--` is mandatory: without it the wrapper cannot know which files to save.
  Never pass `-i` yourself; the wrapper adds it, without a backup suffix, so perl
  leaves nothing next to the original.

  Why a fresh directory per run: a second run on the same file must not overwrite
  the only good copy. Why under $TMPDIR: the working tree stays clean.

options:
  --backup-root DIR   where backup directories go     (default $TMPDIR/perl-i)
  --allow-empty       do not fail when a file shrinks from >0 bytes to 0 bytes
  --list              print the backup directories, newest first
  --restore DIR       copy every file of that run back; verifies checksums first

exit codes: perl's own (128+N if killed by signal N); 1 a file became empty
(unless --allow-empty) or --restore failed; 2 usage error, nothing was touched;
125 the backup failed, perl did not run.
"""
import datetime
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from typing import NoReturn

EX_USAGE = 2
EX_BACKUP = 125
MANIFEST = "manifest.tsv"            # one line per file: sha256 TAB size TAB absolute path

# perl switches whose argument runs to the end of the word: no `i` inside it is a switch
ARG_SWITCHES = set("IMmFxdDC")
CODE_SWITCHES = set("eE")           # the code is the rest of the word, or the next word


def say(msg):
    print(f"[perl-i] {msg}", file=sys.stderr)


def die(msg: str, code: int) -> NoReturn:
    say(f"error: {msg}")
    sys.exit(code)


def default_root():
    return os.path.join(os.environ.get("TMPDIR") or "/tmp", "perl-i")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def find_i_switch(switches):
    """Return the offending word if one of the perl switches is `-i…`, else None."""
    skip_next = False
    for word in switches:
        if skip_next:                # the code after a bare -e / -E
            skip_next = False
            continue
        if not word.startswith("-") or word.startswith("--") or word == "-":
            continue
        for pos, ch in enumerate(word[1:], start=1):
            if ch == "i":
                return word
            if ch in CODE_SWITCHES:
                skip_next = pos == len(word) - 1
                break
            if ch in ARG_SWITCHES:
                break
    return None


def parse_run(argv):
    """Split argv at the first `--`; our long options may sit anywhere left of it."""
    if "--" not in argv:
        die("missing `--` between perl switches and files "
            "(usage: +perl-i [--backup-root DIR] SWITCHES… -- FILE…)", EX_USAGE)
    cut = argv.index("--")
    left, files = argv[:cut], argv[cut + 1:]
    root, allow_empty, switches = None, False, []
    it = iter(left)
    for word in it:
        if word == "--backup-root":
            root = next(it, None)
            if root is None:
                die("--backup-root needs a directory", EX_USAGE)
        elif word == "--allow-empty":
            allow_empty = True
        else:
            switches.append(word)
    if not files:
        die("no files after `--`", EX_USAGE)
    bad = find_i_switch(switches)
    if bad:
        die(f"`{bad}` contains -i; +perl-i adds -i itself, without a backup suffix", EX_USAGE)
    return root or default_root(), allow_empty, switches, files


def check_files(files):
    out = []
    for f in files:
        path = os.path.abspath(f)
        if "\t" in path or "\n" in path:
            die(f"tab or newline in path: {f!r}", EX_USAGE)
        if os.path.islink(path):
            # perl -i on a symlink writes a regular file in its place and leaves the
            # target untouched (measured 2026-11-15, perl 5.34.1)
            die(f"{f} is a symlink; pass the real file", EX_USAGE)
        if not os.path.isfile(path):
            die(f"{f} is not a regular file", EX_USAGE)
        out.append(path)
    return out


def make_backup(root, paths):
    """Copy the files, record checksums, verify each copy. Return (dir, {path: (sha, size)})."""
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    os.makedirs(root, mode=0o700, exist_ok=True)
    bdir = tempfile.mkdtemp(prefix=f"{stamp}-", dir=root)      # 0700, unique per run
    before = {}
    lines = []
    for path in paths:
        dest = os.path.join(bdir, path.lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(path, dest)
        digest, size = sha256(dest), os.path.getsize(dest)
        if digest != sha256(path):
            raise OSError(f"copy of {path} differs from the original")
        before[path] = (digest, size)
        lines.append(f"{digest}\t{size}\t{path}\n")
    with open(os.path.join(bdir, MANIFEST), "w") as f:
        f.writelines(lines)
    return bdir, before


def run(argv):
    root, allow_empty, switches, files = parse_run(argv)
    perl = shutil.which("perl")
    if not perl:
        die("perl not found on PATH", EX_USAGE)
    paths = check_files(files)
    try:
        bdir, before = make_backup(root, paths)
    except OSError as e:
        die(f"backup failed, perl did not run: {e}", EX_BACKUP)
    say(f"backup: {bdir}")

    rc = subprocess.run([perl, "-i", *switches, "--", *paths]).returncode
    if rc < 0:
        rc = 128 - rc

    changed = unchanged = 0
    emptied = []
    for path in paths:
        if not os.path.exists(path):
            emptied.append(f"{path} is gone")
            continue
        digest, size = before[path]
        if sha256(path) == digest:
            unchanged += 1
            continue
        changed += 1
        if size > 0 and os.path.getsize(path) == 0:
            emptied.append(f"{path} shrank from {size} bytes to 0")
    say(f"{changed} changed, {unchanged} unchanged")
    for msg in emptied:
        say(f"WARNING: {msg}")
    if rc:
        say(f"perl exited with {rc}")
    say(f"restore: +perl-i --restore {bdir}")
    if rc:
        return rc
    if emptied and not allow_empty:
        say("exit 1 because of the warning above; pass --allow-empty if intended")
        return 1
    return 0


def read_manifest(bdir):
    entries = []
    with open(os.path.join(bdir, MANIFEST)) as f:
        for line in f:
            digest, size, path = line.rstrip("\n").split("\t", 2)
            entries.append((digest, int(size), path))
    return entries


def restore(bdir):
    try:
        entries = read_manifest(bdir)
        if not entries:
            die("manifest is empty, nothing to restore", 1)
        # verify everything first, so a damaged backup restores nothing at all
        for digest, _size, path in entries:
            src = os.path.join(bdir, path.lstrip("/"))
            if sha256(src) != digest:
                die(f"backup copy of {path} does not match its checksum; nothing restored", 1)
        for _digest, _size, path in entries:
            src = os.path.join(bdir, path.lstrip("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = f"{path}.perl-i-restore.{os.getpid()}"
            shutil.copy2(src, tmp)
            os.replace(tmp, path)                           # atomic: never half a file
    except (OSError, ValueError) as e:
        die(f"restore failed: {e}", 1)
    say(f"restored {len(entries)} file(s) from {bdir}")
    return 0


def list_backups(root):
    if not os.path.isdir(root):
        say(f"no backups under {root}")
        return 0
    names = sorted((n for n in os.listdir(root)
                    if os.path.isfile(os.path.join(root, n, MANIFEST))), reverse=True)
    for name in names:
        bdir = os.path.join(root, name)
        print(f"{bdir}\t{len(read_manifest(bdir))} file(s)")
    say(f"{len(names)} backup run(s) under {root}")
    return 0


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else EX_USAGE
    if argv[0] == "--restore":
        if len(argv) != 2:
            die("usage: +perl-i --restore BACKUP-DIR", EX_USAGE)
        return restore(argv[1])
    if argv[0] == "--list":
        root = default_root()
        if argv[1:2] == ["--backup-root"] and len(argv) == 3:
            root = argv[2]
        elif len(argv) != 1:
            die("usage: +perl-i --list [--backup-root DIR]", EX_USAGE)
        return list_backups(root)
    return run(argv)


if __name__ == "__main__":
    sys.exit(main())
