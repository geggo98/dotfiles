#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
#
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""Search checkpoint and cache files for known secret values (canaries) and report file modes.

usage: checkpoint-secret-scan.py --canary-env NAME [--canary-env NAME ...] --control STRING
                                 [--chunk-size BYTES] PATH [PATH ...]

Use it on a CRaC checkpoint directory, an AOT/CDS cache file or a heap dump, after a training or
checkpoint run in which the application read a known test value (the canary).

Canaries come only from environment variables. --canary-env takes the NAME of the variable,
never the value, so the value is not in the process list or the shell history. The script never
prints a canary value. A canary must have at least 8 bytes in UTF-8; a shorter value matches
by chance (exit 2).

Every canary and the control are searched in four encodings: UTF-8, Latin-1, UTF-16LE and
UTF-16BE. Files are read in chunks (--chunk-size, default 8 MiB) with an overlap, so a value
that crosses a chunk border is found once. A UTF-16LE string that follows a NUL byte is also a
valid UTF-16BE string; both hits are then reported.

--control is mandatory: a string that must be in the files (for example a class name of the
application, or a value planted on purpose). When it is not found at least once, the scan
proves nothing and the script ends with exit 3 ("blind"). An unreadable file also makes the scan
blind.

Directories are walked recursively. Symbolic links are reported and never followed. Special files
(FIFOs, devices, sockets) are reported and skipped. The mode of every directory and file is
reported; group-readable and world-readable entries are flagged.

The control count is reported per file. A file with 0 control hits is marked NO-CONTROL: one
readable file that holds the control does not show that the scan sees into the file beside it
(for example a compressed checkpoint image). The exit code stays 0 for such a file, because a
file can lack the control string legitimately; read the NO-CONTROL lines.

Read the result precisely: "0 hits for these encodings" says nothing about values that the
application never read before the checkpoint, about other encodings, and about compressed or
encrypted files. It does not prove that the files are free of secrets.

Exit: 0 no hit, 1 at least one hit (wins over 3), 2 usage, 3 blind (control not found or a file
unreadable), 4 internal error, 130 SIGINT, 143 SIGTERM.
"""
import argparse
import os
import signal
import stat
import sys

ENCODINGS = ("utf-8", "latin-1", "utf-16-le", "utf-16-be")
MIN_CANARY_BYTES = 8
DEFAULT_CHUNK = 8 * 1024 * 1024


class Interrupted(Exception):
    pass


def patterns_for(text):
    """Byte patterns of one string, one entry per distinct byte sequence: (bytes, "enc1/enc2")."""
    by_bytes = {}
    for encoding in ENCODINGS:
        try:
            data = text.encode(encoding)
        except UnicodeEncodeError:
            continue  # for example a character outside Latin-1
        by_bytes.setdefault(data, []).append(encoding)
    return [(data, "/".join(names)) for data, names in by_bytes.items()]


def count_in_stream(handle, patterns, chunk_size, stop):
    """Count every pattern in a binary stream. Returns {index: [count, first_offset]}.

    The buffer keeps the last (longest pattern - 1) bytes of the previous chunk. A match counts
    only when it ends inside the new chunk, so a match that lies fully in the kept tail is not
    counted twice.
    """
    keep = max(len(p) for p, _ in patterns) - 1
    found = {}
    tail = b""
    base = 0  # file offset of tail[0]
    while True:
        if stop:
            raise Interrupted()
        chunk = handle.read(chunk_size)
        if not chunk:
            return found
        buffer = tail + chunk
        for index, (pattern, _) in enumerate(patterns):
            position = buffer.find(pattern, max(0, len(tail) - len(pattern) + 1))
            while position != -1:
                entry = found.setdefault(index, [0, base + position])
                entry[0] += 1
                position = buffer.find(pattern, position + 1)
        cut = max(0, len(buffer) - keep)
        base += cut
        tail = buffer[cut:]


def mode_text(mode):
    flags = ""
    if mode & stat.S_IRGRP:
        flags += "  GROUP-READABLE"
    if mode & stat.S_IROTH:
        flags += "  WORLD-READABLE"
    return f"{stat.filemode(mode)} {stat.S_IMODE(mode):04o}{flags}"


def lstat_or_blind(path, report):
    try:
        return os.lstat(path)
    except OSError as exc:
        report.blind(f"cannot stat {path}: {exc.strerror}")
        return None


def walk(paths, report):
    """Yield regular files below `paths` without following symbolic links."""
    for root in paths:
        try:
            info = os.lstat(root)
        except OSError as exc:
            report.blind(f"cannot stat {root}: {exc.strerror}")
            continue
        if stat.S_ISLNK(info.st_mode):
            report.line(f"symlink not followed: {root}")
            continue
        if stat.S_ISREG(info.st_mode):
            yield root, info
            continue
        if not stat.S_ISDIR(info.st_mode):
            report.line(f"special file skipped: {root}  {mode_text(info.st_mode)}")
            continue
        report.line(f"dir  {root}  {mode_text(info.st_mode)}")

        def on_error(exc, _root=root):
            report.blind(f"cannot list {exc.filename}: {exc.strerror}")

        for directory, dirs, files in os.walk(root, onerror=on_error, followlinks=False):
            for name in sorted(dirs):
                path = os.path.join(directory, name)
                sub = lstat_or_blind(path, report)
                if sub is None:
                    continue
                if stat.S_ISLNK(sub.st_mode):
                    report.line(f"symlink not followed: {path}")
                else:
                    report.line(f"dir  {path}  {mode_text(sub.st_mode)}")
            dirs.sort()
            for name in sorted(files):
                path = os.path.join(directory, name)
                sub = lstat_or_blind(path, report)
                if sub is None:
                    continue
                if stat.S_ISLNK(sub.st_mode):
                    report.line(f"symlink not followed: {path}")
                elif stat.S_ISREG(sub.st_mode):
                    yield path, sub
                else:
                    report.line(f"special file skipped: {path}  {mode_text(sub.st_mode)}")


class Report:
    def __init__(self):
        self.blind_reasons = []

    def line(self, text):
        print(text, flush=True)

    def blind(self, text):
        self.blind_reasons.append(text)
        print(f"BLIND: {text}", file=sys.stderr, flush=True)


def scan_file(path, patterns, chunk_size, stop):
    # O_NOFOLLOW: the file can have become a symbolic link since the lstat.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        return count_in_stream(handle, patterns, chunk_size, stop)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="checkpoint-secret-scan.py",
                                     description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--canary-env", action="append", default=[], metavar="NAME", required=True,
                        help="name of an environment variable that holds a canary value (repeatable)")
    parser.add_argument("--control", required=True,
                        help="a string that must be in the files; not found = blind scan (exit 3)")
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK, help="read size in bytes (default 8 MiB)")
    parser.add_argument("paths", nargs="+", metavar="PATH", help="directory or file to scan")
    args = parser.parse_args(argv)

    if args.chunk_size < 1:
        parser.error("--chunk-size must be >= 1")
    canaries = []
    for name in args.canary_env:
        value = os.environ.get(name, "")
        if not value:
            parser.error(f"environment variable {name} is not set or empty")
        if len(value.encode("utf-8")) < MIN_CANARY_BYTES:
            parser.error(f"the value of {name} is shorter than {MIN_CANARY_BYTES} bytes; "
                         "a short value matches by chance")
        canaries.append((name, value))
    if len(args.control.encode("utf-8")) < MIN_CANARY_BYTES:
        parser.error(f"--control must have at least {MIN_CANARY_BYTES} bytes")

    # Pattern table: (bytes, encodings, label). The label is a variable name, never a value.
    patterns = []
    for name, value in canaries:
        patterns += [(data, encodings, name) for data, encodings in patterns_for(value)]
    patterns += [(data, encodings, "--control") for data, encodings in patterns_for(args.control)]
    search = [(data, encodings) for data, encodings, _ in patterns]

    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda s, _f: stop.append(s))

    report = Report()
    hits = 0
    control_hits = 0
    files_without_control = 0
    files = 0
    size = 0
    try:
        for path, info in walk(args.paths, report):
            head = f"file {path}  {mode_text(info.st_mode)}  {info.st_size} bytes"
            try:
                found = scan_file(path, search, args.chunk_size, stop)
            except OSError as exc:
                report.line(f"{head}  unreadable")
                report.blind(f"cannot read {path}: {exc.strerror}")
                continue
            files += 1
            size += info.st_size
            file_control = sum(found[i][0] for i in found if patterns[i][2] == "--control")
            control_hits += file_control
            if file_control == 0:
                files_without_control += 1
            # Per file: one file that holds the control must not vouch for an opaque one beside it.
            report.line(f"{head}  control={file_control}" + ("  NO-CONTROL" if file_control == 0 else ""))
            for index in sorted(found):
                count, first = found[index]
                _data, encodings, label = patterns[index]
                if label == "--control":
                    continue
                hits += count
                report.line(f"HIT  {path}  canary={label}  encoding={encodings}  count={count}  first_offset={first}")
    except Interrupted:
        print(f"interrupted after {files} files; no result", file=sys.stderr)
        return 128 + stop[0]

    if control_hits == 0:
        report.blind("the --control string was not found in any encoding; the scan cannot see the content")
    encodings = ", ".join(ENCODINGS)
    print(f"control found {control_hits} times; {files} files, {size} bytes read", flush=True)
    if files_without_control:
        print(f"{files_without_control} of {files} files without the control (NO-CONTROL): the scan "
              "cannot show that it sees into them; a compressed or encrypted file looks the same")
    if hits:
        print(f"{hits} hits for these encodings ({encodings})")
        if report.blind_reasons:
            print("note: the scan was also partly blind, see BLIND lines on stderr")
        return 1
    if report.blind_reasons:
        print(f"no result: the scan was blind ({len(report.blind_reasons)} reasons on stderr)")
        return 3
    print(f"0 hits for these encodings ({encodings}). This does not prove the files hold no secrets: "
          "values the application never read, other encodings, and compressed or encrypted data "
          "are not covered.")
    return 0


def run():
    try:
        return main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001  # any bug must end with 4, never with 1 ("hits")
        # Type and line only: the exception text could carry file content.
        line = exc.__traceback__.tb_lineno if exc.__traceback__ else "?"
        while exc.__traceback__ and exc.__traceback__.tb_next:
            exc.__traceback__ = exc.__traceback__.tb_next
            line = exc.__traceback__.tb_lineno
        print(f"internal error: {type(exc).__name__} (line {line})", file=sys.stderr)
        return 4


if __name__ == "__main__":
    sys.exit(run())
