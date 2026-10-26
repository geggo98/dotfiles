#!/usr/bin/env python3
"""vault-masked — run a command (normally `vault`), mask Vault tokens in its output.

usage: vault-masked [--] CMD [ARGS...]

stdout and stderr of CMD are filtered and passed on to the matching stream of the
caller; stdin is inherited, the exit code of CMD comes back unchanged (128+N if
killed by signal N, 127 if CMD is not found). Masked:

  * every token the token helper has stored, for ALL environments (a production
    token can turn up in staging output), the legacy ~/.vault-token and
    $VAULT_TOKEN;
  * anything shaped like a Vault token (hvs./hvb./hvr. + 16 or more characters),
    which also catches tokens that exist in no store yet (`token create`,
    `login -no-store`, an unwrapped response).

When something was masked, a last line on stderr names the way to see it.
"""
import os
import select
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from masker import MASK, Masker

FLUSH_IDLE = 0.2
SHOW_OPTION = "--show-tokens"

# matches:  hvs.CAESIJlU4zLm_b0xQ7aD3k9Wc2Pq   (service)   hvb.… (batch)   hvr.… (recovery)
FULL = rb"\bhv[sbr]\.[A-Za-z0-9_-]{16,}"
# any prefix of the above, at the end of a chunk:  h  hv  hvs  hvs.  hvs.CAES
PARTIAL = rb"\bh(?:v(?:[sbr](?:\.[A-Za-z0-9_-]*)?)?)?"


def warn(msg):
    print(f"+vault: {msg}", file=sys.stderr)


def token_values():
    """Known tokens as bytes. An unreadable source is a warning, not a stop:
    the format pattern still covers anything that looks like a Vault token."""
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    sources = sorted((state / "vault" / "tokens").glob("*")) + [Path.home() / ".vault-token"]
    values = []
    for src in sources:
        try:
            raw = src.read_bytes()
        except FileNotFoundError:
            continue
        except OSError as e:
            warn(f"cannot read {src}: {e.strerror}; masking by format only for it")
            continue
        values += [ln.strip() for ln in raw.splitlines() if ln.strip()]
    env = os.environ.get("VAULT_TOKEN", "").strip()
    if env:
        values.append(env.encode())
    return values


def pump(src_fd, dst_fd, mask):
    """Copy src to dst, masking. Complete lines go out at once; an unterminated
    fragment (a prompt) is flushed after FLUSH_IDLE, minus any tail that could
    still grow into a token."""
    pending, since = b"", 0.0
    while True:
        ready, _, _ = select.select([src_fd], [], [], FLUSH_IDLE / 2)
        if ready:
            data = os.read(src_fd, 65536)
            if not data:
                break
            pending += data
            cut = pending.rfind(b"\n") + 1
            if cut:
                os.write(dst_fd, mask(pending[:cut]))
                pending = pending[cut:]
            since = since or time.monotonic()
        if pending and time.monotonic() - since >= FLUSH_IDLE:
            cut = mask.safe_cut(pending)
            if cut:
                os.write(dst_fd, mask(pending[:cut]))
                pending = pending[cut:]
            since = time.monotonic()
    if pending:
        os.write(dst_fd, mask(pending))


def main():
    cmd = sys.argv[1:]
    if cmd[:1] == ["--"]:
        cmd = cmd[1:]
    if not cmd:
        warn("no command given (usage: vault-masked -- vault ARGS...)")
        return 125
    values = token_values()
    masks = [Masker(values, [(FULL, PARTIAL)]) for _ in range(2)]   # one per thread: own counter

    try:
        child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        warn(f"{cmd[0]}: command not found")
        return 127
    except OSError as e:
        warn(f"{cmd[0]}: {e.strerror}")
        return 126

    def forward(signum, _frame):
        # On a terminal, Ctrl-C already reaches the child through the foreground
        # process group; a second copy would look like an impatient double press.
        if signum == signal.SIGINT and os.isatty(0):
            return
        try:
            child.send_signal(signum)
        except OSError:
            pass

    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(s, forward)

    threads = [
        threading.Thread(target=pump, args=(child.stdout.fileno(), 1, masks[0])),
        threading.Thread(target=pump, args=(child.stderr.fileno(), 2, masks[1])),
    ]
    for t in threads:
        t.start()
    code = child.wait()
    for t in threads:
        t.join()

    n = sum(m.replacements for m in masks)
    if n:
        warn(f"{n} token value(s) masked as {MASK.decode()}; "
             f"re-run with {SHOW_OPTION} to see them (for you, not for an agent).")
    return 128 - code if code < 0 else code


if __name__ == "__main__":
    sys.exit(main())
