#!/usr/bin/env python3
"""+errlog — run a command, keep its stderr out of the caller's context.

usage: +errlog [options] [--] CMD [ARGS...]

  stderr of CMD goes to a 0600 file (path announced on stderr), with the exit
  code and run statistics appended. stdin/stdout are inherited untouched, the
  exit code of CMD is passed through. Known secrets are masked in the file.

options (none of them takes a secret VALUE; values come from files or env):
  --dir DIR           directory for the log file      (env ERRLOG_DIR, default $TMPDIR)
  --file PATH         exact log file path; must not exist yet
  --tail N            on failure, print the last N masked lines (default 10, 0 = off)
  --mask-file PATH    mask every non-empty line of PATH     (repeatable; env ERRLOG_MASK_FILES, ':'-separated)
  --mask-env NAME     mask the value of environment variable NAME
                                                            (repeatable; env ERRLOG_MASK_ENVS, ','-separated)
  --timestamps        prefix each logged line with "[+secs] "
  --grace SEC         after CMD exited, keep reading stderr this long for
                      descendants that still hold it open (default 2)

exit codes: CMD's own; 128+N if killed by signal N; 126 not executable;
127 not found; 125 errlog itself failed before starting CMD.
"""
import collections
import datetime
import os
import re
import select
import shlex
import shutil
import signal
import socket
import sys
import threading
import time
import urllib.parse

EX_USAGE = 125
VERSION = 1
MASK = b"***"
PARTIAL_FLUSH_BYTES = 64 * 1024
PARTIAL_FLUSH_IDLE = 0.2
TAIL_LINE_MAX = 500


def die(msg, code=EX_USAGE):
    print(f"[errlog] error: {msg}", file=sys.stderr)
    sys.exit(code)


def warn(msg):
    try:
        print(f"[errlog] warning: {msg}", file=sys.stderr)
    except OSError:
        pass


# --------------------------------------------------------------------------
# argument parsing: options up to "--" or the first non-option word
# --------------------------------------------------------------------------

VALUE_OPTS = {"--dir", "--file", "--tail", "--mask-file", "--mask-env", "--grace"}
FLAG_OPTS = {"--timestamps"}


def parse_args(argv):
    opts = {
        "dir": os.environ.get("ERRLOG_DIR") or None,
        "file": None,
        "tail": 10,
        "mask_files": [p for p in os.environ.get("ERRLOG_MASK_FILES", "").split(":") if p],
        "mask_envs": [n for n in os.environ.get("ERRLOG_MASK_ENVS", "").split(",") if n],
        "timestamps": False,
        "grace": 2.0,
    }
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            sys.exit(0)
        if not arg.startswith("-") or arg == "-":
            break
        name, eq, val = arg.partition("=")
        if name in FLAG_OPTS and not eq:
            opts["timestamps"] = True
        elif name in VALUE_OPTS:
            if not eq:
                i += 1
                if i >= len(argv):
                    die(f"{name} needs a value")
                val = argv[i]
            try:
                if name == "--dir":
                    opts["dir"] = val
                elif name == "--file":
                    opts["file"] = val
                elif name == "--tail":
                    opts["tail"] = int(val)
                    if opts["tail"] < 0:
                        raise ValueError
                elif name == "--grace":
                    opts["grace"] = float(val)
                    if opts["grace"] < 0:
                        raise ValueError
                elif name == "--mask-file":
                    opts["mask_files"].append(val)
                elif name == "--mask-env":
                    opts["mask_envs"].append(val)
            except ValueError:
                die(f"invalid value for {name}: {val!r}")
        else:
            die(f"unknown option {arg!r} (secrets are never passed as values; "
                f"use --mask-file / --mask-env; command goes after '--')")
        i += 1
    cmd = argv[i:]
    if not cmd:
        die("no command given (usage: +errlog [options] -- CMD [ARGS...])")
    return opts, cmd


# --------------------------------------------------------------------------
# masking
# --------------------------------------------------------------------------

def variants(raw):
    """raw, URL-encoded and URL-decoded form (same idea as the database skill's redact.pl)."""
    out = {raw, urllib.parse.unquote_to_bytes(raw), urllib.parse.quote_from_bytes(raw, safe="").encode()}
    return {v for v in out if v}


class Masker:
    def __init__(self, values):
        values = sorted({v for raw in values for v in variants(raw)}, key=lambda v: (-len(v), v))
        self.maxlen = max((len(v) for v in values), default=0)
        # every proper prefix of a secret: only a tail that is one of these can
        # still turn into a secret, so only that tail is ever held back
        self.prefixes = {v[:k] for v in values for k in range(1, len(v))}
        self.rx = re.compile(b"|".join(re.escape(v) for v in values)) if values else None
        self.replacements = 0

    def __call__(self, data):
        if not self.rx:
            return data
        out, n = self.rx.subn(MASK, data)
        self.replacements += n
        return out

    def safe_cut(self, raw):
        """How many leading bytes of a partial line may be written now: all but a
        tail that could still be the start of a secret (usually nothing, so a
        message without newline is not held back), and never a cut through the
        middle of a match."""
        cut = len(raw)
        for k in range(min(self.maxlen - 1, len(raw)), 0, -1):
            if raw[-k:] in self.prefixes:
                cut = len(raw) - k
                break
        if self.rx:
            for m in self.rx.finditer(raw):
                if m.start() < cut < m.end():
                    cut = m.start()
                    break
        return cut


def read_mask_values(opts):
    values, sources = [], []
    for path in opts["mask_files"]:
        try:
            with open(path, "rb") as fh:
                lines = [ln.rstrip(b"\r\n") for ln in fh.read().split(b"\n")]
        except OSError as e:
            die(f"cannot read mask file {path}: {e.strerror}")
        found = [ln for ln in lines if ln]
        if not found:
            die(f"mask file {path} contains no value")
        values += found
        sources.append(f"file:{path}")
    for name in opts["mask_envs"]:
        val = os.environ.get(name, "")
        found = [ln for ln in os.fsencode(val).replace(b"\r", b"").split(b"\n") if ln]
        if not found:
            die(f"environment variable {name} is unset or empty")
        values += found
        sources.append(f"env:{name}")
    short = sum(1 for v in values if len(v) < 4)
    if short:
        warn(f"{short} mask value(s) shorter than 4 bytes; masking them anyway (expect over-masking)")
    return values, sources


# --------------------------------------------------------------------------
# log sink: masked bytes in, file + line counting + tail out
# --------------------------------------------------------------------------

class Sink:
    def __init__(self, fh, timestamps, tail, t0):
        self.fh, self.timestamps, self.t0 = fh, timestamps, t0
        self.tail = collections.deque(maxlen=tail) if tail else None
        self.lines = 0
        self.errors = 0
        self.at_line_start = True
        self.cur = bytearray()
        self.last_byte = b"\n"

    def _write(self, data):
        if not data:
            return
        try:
            self.fh.write(data)
        except OSError as e:
            if not self.errors:
                warn(f"cannot write log file: {e.strerror}; continuing to drain stderr")
            self.errors += 1
        self.last_byte = data[-1:]

    def emit(self, data):
        parts = data.split(b"\n")
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            if last and not part:
                break
            if self.timestamps and self.at_line_start:
                self._write(f"[+{time.monotonic() - self.t0:.3f}s] ".encode())
            self.at_line_start = False
            self._write(part)
            self.cur += part
            if not last:
                self._write(b"\n")
                self.lines += 1
                if self.tail is not None:
                    self.tail.append(bytes(self.cur))
                self.cur.clear()
                self.at_line_start = True
        self.flush()

    def finish(self):
        if self.cur:
            self.lines += 1
            if self.tail is not None:
                self.tail.append(bytes(self.cur))
            self.cur.clear()
        if self.last_byte != b"\n":
            self._write(b"\n")
        self.flush()

    def flush(self):
        try:
            self.fh.flush()
        except OSError:
            self.errors += 1


def pump(fd, mask, sink, stop, stats):
    """Read the child's stderr until EOF (or until told to stop), masking as we go."""
    pending = b""
    pending_since = 0.0          # when the current unterminated fragment started waiting
    while True:
        ready, _, _ = select.select([fd], [], [], PARTIAL_FLUSH_IDLE / 2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            stats["bytes"] += len(data)
            pending += data
            cut = pending.rfind(b"\n") + 1
            if cut:
                sink.emit(mask(pending[:cut]))
                pending = pending[cut:]
                pending_since = time.monotonic()
            elif not pending_since:
                pending_since = time.monotonic()
        # Age of the waiting fragment, not time since the last read: a progress
        # bar that keeps trickling in must not starve behind its own activity.
        if pending and (len(pending) > PARTIAL_FLUSH_BYTES
                        or time.monotonic() - pending_since >= PARTIAL_FLUSH_IDLE):
            cut = mask.safe_cut(pending)
            if cut:
                sink.emit(mask(pending[:cut]))
                pending = pending[cut:]
            pending_since = time.monotonic()
        if stop.is_set():
            break
    if pending:
        sink.emit(mask(pending))
    sink.finish()


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def fmt_duration(s):
    if s < 60:
        return f"{s:.1f}s"
    m, s = divmod(int(round(s)), 60)
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"


def fmt_bytes(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n} B" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def iso(ts):
    return datetime.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def resolve(cmd0):
    found = shutil.which(cmd0)
    if found:
        return found
    if "/" in cmd0 and os.path.exists(cmd0):
        die(f"{cmd0}: permission denied", 126)
    die(f"{cmd0}: command not found", 127)


def create_log(opts, cmd0):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    if opts["file"]:
        path = os.path.abspath(opts["file"])
        try:
            return path, os.open(path, flags, 0o600)
        except OSError as e:
            die(f"cannot create log file {path}: {e.strerror}")
    base = opts["dir"] or os.environ.get("TMPDIR") or "/tmp"
    stem = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(cmd0))[:40] or "cmd"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for _ in range(20):
        path = os.path.join(os.path.abspath(base), f"errlog-{stem}-{stamp}-{os.urandom(3).hex()}.log")
        try:
            return path, os.open(path, flags, 0o600)
        except FileExistsError:
            continue
        except OSError as e:
            die(f"cannot create log file in {base}: {e.strerror}")
    die("cannot find a free log file name")


def foreground_of_tty():
    """True when we are the foreground process group of a terminal: then the
    terminal already delivered Ctrl-C/Ctrl-\\ to the child and forwarding again
    would be a second interrupt (Gradle reads that as 'abort hard')."""
    for fd in (0, 1, 2):
        try:
            if os.isatty(fd):
                return os.tcgetpgrp(fd) == os.getpgrp()
        except OSError:
            continue
    return False


# --------------------------------------------------------------------------

def main():
    opts, cmd = parse_args(sys.argv[1:])
    values, sources = read_mask_values(opts)
    mask = Masker(values)
    exe = resolve(cmd[0])
    log_path, log_fd = create_log(opts, cmd[0])
    fh = os.fdopen(log_fd, "wb", buffering=64 * 1024)

    forwarded, early = [], []
    child = {"pid": None}

    def on_signal(signum, _frame):
        name = signal.Signals(signum).name
        if signum in (signal.SIGINT, signal.SIGQUIT) and foreground_of_tty():
            return
        if child["pid"] is None:
            early.append(signum)
            return
        try:
            os.kill(child["pid"], signum)
            forwarded.append(name)
        except OSError:
            pass

    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT,
              signal.SIGUSR1, signal.SIGUSR2):
        signal.signal(s, on_signal)

    env = dict(os.environ, ERRLOG_FILE=log_path)
    rfd, wfd = os.pipe()
    t_start = time.time()
    t0 = time.monotonic()
    try:
        pid = os.fork()
    except OSError as e:
        os.unlink(log_path)
        die(f"fork failed: {e.strerror}")
    if pid == 0:                                        # child
        try:
            os.close(rfd)
            os.dup2(wfd, 2)
            os.close(wfd)
            for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT,
                      signal.SIGUSR1, signal.SIGUSR2):
                signal.signal(s, signal.SIG_DFL)
            os.execve(exe, cmd, env)
        except OSError as e:
            os.write(2, f"[errlog] cannot execute {cmd[0]}: {e.strerror}\n".encode())
            os._exit(126 if e.errno in (13, 8) else 127)
        os._exit(127)
    os.close(wfd)
    child["pid"] = pid
    for signum in early:
        on_signal(signum, None)

    shown = " ".join(
        shlex.quote(os.fsdecode(mask(os.fsencode(a)))) for a in cmd)
    header = [
        f"errlog: version={VERSION}",
        f"errlog: command={shown}",
        f"errlog: cwd={os.getcwd()}  start={iso(t_start)}  wrapper_pid={os.getpid()}  "
        f"child_pid={pid}  host={socket.gethostname()}",
        f"errlog: mask_sources={','.join(sources) or '-'}  mask_values={len(values)}",
        "----- stderr -----",
    ]
    fh.write(("\n".join(header) + "\n").encode("utf-8", "surrogateescape"))
    fh.flush()
    print(f"[errlog] stderr -> {log_path} (pid {pid})", file=sys.stderr, flush=True)

    sink = Sink(fh, opts["timestamps"], opts["tail"], t0)
    stats = {"bytes": 0}
    stop = threading.Event()
    reader = threading.Thread(target=pump, args=(rfd, mask, sink, stop, stats), daemon=True)
    reader.start()

    _, status, ru = os.wait4(pid, 0)
    t_end = time.time()
    reader.join(opts["grace"])
    held_open = reader.is_alive()
    if held_open:
        stop.set()
        reader.join()
    os.close(rfd)

    if os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        code, sig_name = 128 + sig, signal.Signals(sig).name
    else:
        code, sig_name = os.WEXITSTATUS(status), None
    rss = ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024
    duration = t_end - t_start

    footer = [
        "----- end of stderr -----",
        f"errlog: end={iso(t_end)}  duration_s={duration:.3f}",
        f"errlog: exit_code={code}" + (f"  signal={sig_name}" if sig_name else ""),
        f"errlog: cpu_user_s={ru.ru_utime:.3f}  cpu_sys_s={ru.ru_stime:.3f}  max_rss_bytes={rss}",
        f"errlog: ctx_switches_vol={ru.ru_nvcsw}  ctx_switches_invol={ru.ru_nivcsw}  "
        f"block_in={ru.ru_inblock}  block_out={ru.ru_oublock}",
        f"errlog: stderr_lines={sink.lines}  stderr_bytes={stats['bytes']}  "
        f"masked_replacements={mask.replacements}",
        f"errlog: signals_forwarded={','.join(forwarded) or '-'}  "
        f"stderr_open_after_exit={'yes' if held_open else 'no'}  log_write_errors={sink.errors}",
    ]
    try:
        fh.write(("\n".join(footer) + "\n").encode())
        fh.close()
    except OSError:
        pass

    try:
        err = sys.stderr.buffer
        if code != 0 and sink.tail:
            n = len(sink.tail)
            err.write(f"[errlog] last {n} of {sink.lines} stderr lines (masked):\n".encode())
            for line in sink.tail:
                line = line.replace(b"\r", b"\\r")
                if len(line) > TAIL_LINE_MAX:
                    line = line[:TAIL_LINE_MAX] + b"..."
                err.write(b"| " + line + b"\n")
        what = f"exit={code}" + (f" ({sig_name})" if sig_name else "")
        err.write((f"[errlog] {what} after {fmt_duration(duration)}, {sink.lines} stderr lines "
                   f"({fmt_bytes(stats['bytes'])}) -> {log_path}\n").encode())
        err.flush()
    except OSError:
        pass
    return code


if __name__ == "__main__":
    sys.exit(main())
