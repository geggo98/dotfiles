#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
# ]
# [tool.uv]
# exclude-newer = "30 days"
# ///

# Hint: Lock dependencies with `uv lock --script ...`

"""tmux-use.py — tmux session manager for Claude Code agents.

Provides subcommands with sensible defaults for tmux usage, so agents can
avoid raw variable-expansion calls that trigger security prompts.
"""

import argparse
import os
import re
import subprocess
import sys
import time


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TMPDIR = os.environ.get("TMPDIR", "/tmp")
SOCKET_DIR = os.environ.get(
    "CLAUDE_TMUX_SOCKET_DIR", os.path.join(TMPDIR, "tmux-use-sockets")
)
DELTA_DIR = os.path.join(TMPDIR, "tmux-use-delta")


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------


def run_tmux(socket_path: str, args: list[str]) -> subprocess.CompletedProcess:
    """Run a tmux command against the given socket."""
    return subprocess.run(
        ["tmux", "-S", socket_path] + args,
        capture_output=True,
        text=True,
    )


def resolve_target(socket_path: str, target: str | None) -> str:
    """Return an explicit target or auto-detect the first session on the socket."""
    if target:
        return target
    result = run_tmux(socket_path, ["list-sessions", "-F", "#{session_name}"])
    first = (result.stdout.strip().splitlines() or [None])[0]
    if not first:
        print(
            f"No sessions found on socket {socket_path} — specify -t TARGET",
            file=sys.stderr,
        )
        sys.exit(1)
    return f"{first}:0.0"


def delta_key(socket_path: str, target: str) -> str:
    """Filesystem-safe key for storing delta snapshots."""
    return f"{socket_path}::{target}".replace("/", "__")


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_new(socket_path: str, target: str | None, args: list[str]) -> int:
    _ = target  # new always targets the freshly created session
    parser = argparse.ArgumentParser(prog="tmux-use.sh new")
    parser.add_argument("-s", "--session", required=True)
    parser.add_argument("-w", "--window", default="shell")
    parser.add_argument("-c", "--cmd", default="", dest="cmd_to_run")
    opts = parser.parse_args(args)

    result = run_tmux(socket_path, ["new", "-d", "-s", opts.session, "-n", opts.window])
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        return 1

    if opts.cmd_to_run:
        run_tmux(
            socket_path,
            [
                "send-keys",
                "-t",
                f"{opts.session}:0.0",
                "--",
                opts.cmd_to_run,
                "Enter",
            ],
        )

    print(f"Session '{opts.session}' created on socket: {socket_path}")
    print()
    print("To monitor this session yourself:")
    print(f"  tmux -S '{socket_path}' attach -t '{opts.session}'")
    return 0


def cmd_send(socket_path: str, target: str | None, args: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="tmux-use.sh send")
    parser.add_argument("-R", "--raw", action="store_true")
    parser.add_argument("text")
    opts = parser.parse_args(args)

    t = resolve_target(socket_path, target)

    if opts.raw:
        run_tmux(socket_path, ["send-keys", "-t", t, "--", opts.text, "Enter"])
    else:
        run_tmux(socket_path, ["send-keys", "-t", t, "-l", "--", opts.text])
        run_tmux(socket_path, ["send-keys", "-t", t, "Enter"])
    return 0


def cmd_keys(socket_path: str, target: str | None, args: list[str]) -> int:
    if not args or args[0] in ("-h", "--help"):
        print(
            "Usage: tmux-use.sh keys KEY [KEY ...]   (e.g. Enter, C-c, C-d, Escape)"
        )
        return 0 if args else 1

    t = resolve_target(socket_path, target)
    run_tmux(socket_path, ["send-keys", "-t", t] + args)
    return 0


def cmd_capture(socket_path: str, target: str | None, args: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="tmux-use.sh capture")
    parser.add_argument("-l", "--lines", type=int, default=200)
    parser.add_argument("--no-save", action="store_true")
    opts = parser.parse_args(args)

    t = resolve_target(socket_path, target)
    result = run_tmux(
        socket_path, ["capture-pane", "-p", "-J", "-t", t, "-S", f"-{opts.lines}"]
    )
    output = result.stdout
    print(output, end="" if output.endswith("\n") else "\n")

    if not opts.no_save:
        ensure_dir(DELTA_DIR)
        key = delta_key(socket_path, t)
        with open(os.path.join(DELTA_DIR, key), "w") as f:
            f.write(output)
    return 0


def cmd_delta(socket_path: str, target: str | None, args: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="tmux-use.sh delta")
    parser.add_argument("-l", "--lines", type=int, default=200)
    opts = parser.parse_args(args)

    t = resolve_target(socket_path, target)
    key = delta_key(socket_path, t)
    prev_file = os.path.join(DELTA_DIR, key)

    result = run_tmux(
        socket_path, ["capture-pane", "-p", "-J", "-t", t, "-S", f"-{opts.lines}"]
    )
    current = result.stdout

    if os.path.isfile(prev_file):
        # Print only lines added since last snapshot.
        # Mirrors: diff prev current | sed -n 's/^> //p'
        cur_tmp = prev_file + ".cur"
        with open(cur_tmp, "w") as f:
            f.write(current)
        result = subprocess.run(
            ["diff", prev_file, cur_tmp],
            capture_output=True,
            text=True,
        )
        os.unlink(cur_tmp)
        # Extract lines present in current but not in prev (> prefix).
        new_lines = []
        for line in result.stdout.splitlines():
            if line.startswith("> "):
                new_lines.append(line[2:])
        if new_lines:
            print("\n".join(new_lines))
    else:
        print(current, end="" if current.endswith("\n") else "\n")

    # Save current as baseline
    ensure_dir(DELTA_DIR)
    with open(prev_file, "w") as f:
        f.write(current)
    return 0


def cmd_list(socket_path: str, target: str | None, args: list[str]) -> int:
    _ = target  # list shows all sessions, target not applicable
    parser = argparse.ArgumentParser(prog="tmux-use.sh list")
    parser.add_argument("-q", "--query", default="")
    opts = parser.parse_args(args)

    result = run_tmux(
        socket_path,
        [
            "list-sessions",
            "-F",
            "#{session_name}|#{session_attached}|#{session_created_string}",
        ],
    )
    if result.returncode != 0:
        print(f"No tmux server on socket: {socket_path}")
        return 0

    lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
    if opts.query:
        lines = [l for l in lines if opts.query.lower() in l.lower()]

    if not lines:
        print("No sessions found")
        return 0

    for line in lines:
        parts = line.split("|", 2)
        if len(parts) >= 3:
            name, attached, created = parts
            state = "attached" if attached == "1" else "detached"
            print(f"  {name}  ({state}, started {created})")
    return 0


def cmd_kill(socket_path: str, target: str | None, args: list[str]) -> int:
    _ = target  # kill targets by -s name or --all
    parser = argparse.ArgumentParser(prog="tmux-use.sh kill")
    parser.add_argument("-s", "--session", default="")
    parser.add_argument("-A", "--all", action="store_true")
    opts = parser.parse_args(args)

    if opts.all:
        run_tmux(socket_path, ["kill-server"])
        print(f"Killed all sessions on socket: {socket_path}")
    elif opts.session:
        result = run_tmux(socket_path, ["kill-session", "-t", opts.session])
        if result.returncode != 0:
            print(result.stderr.strip(), file=sys.stderr)
            return 1
        print(f"Killed session '{opts.session}'")
    else:
        print("Specify -s SESSION or --all", file=sys.stderr)
        return 1
    return 0


def cmd_wait(socket_path: str, target: str | None, args: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="tmux-use.sh wait")
    parser.add_argument("-p", "--pattern", required=True)
    parser.add_argument("-F", "--fixed", action="store_true")
    parser.add_argument("-T", "--timeout", type=float, default=15)
    parser.add_argument("-i", "--interval", type=float, default=0.5)
    parser.add_argument("-l", "--lines", type=int, default=1000)
    opts = parser.parse_args(args)

    t = resolve_target(socket_path, target)
    deadline = time.monotonic() + opts.timeout

    while True:
        result = run_tmux(
            socket_path, ["capture-pane", "-p", "-J", "-t", t, "-S", f"-{opts.lines}"]
        )
        pane_text = result.stdout

        if opts.fixed:
            if opts.pattern in pane_text:
                return 0
        else:
            if re.search(opts.pattern, pane_text, re.MULTILINE):
                return 0

        if time.monotonic() >= deadline:
            print(
                f"Timed out after {opts.timeout}s waiting for: {opts.pattern}",
                file=sys.stderr,
            )
            print(f"Last {opts.lines} lines from {t}:", file=sys.stderr)
            print(pane_text, file=sys.stderr)
            return 1

        time.sleep(opts.interval)


def cmd_attach(socket_path: str, target: str | None, args: list[str]) -> int:
    _ = args  # attach takes no arguments
    t = resolve_target(socket_path, target)
    sess = t.split(":")[0]
    print("To monitor this session yourself:")
    print(f"  tmux -S '{socket_path}' attach -t '{sess}'")
    print()
    print("Or capture the output once:")
    print(f"  tmux -S '{socket_path}' capture-pane -p -J -t '{t}' -S -200")
    return 0


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

COMMANDS = {
    "new": cmd_new,
    "send": cmd_send,
    "keys": cmd_keys,
    "capture": cmd_capture,
    "delta": cmd_delta,
    "list": cmd_list,
    "kill": cmd_kill,
    "wait": cmd_wait,
    "attach": cmd_attach,
}

USAGE = """\
Usage: tmux-use.sh [global-opts] <command> [command-opts]

Global options (before the command):
  -S, --socket-path PATH   tmux socket path (default: $SOCKET_DIR/tmux.sock)
  -t, --target TARGET      pane target session:window.pane (default: auto-detect)
  -h, --help               show this help

Commands:
  new      Create a new session
  send     Send keys to a pane
  capture  Print current pane content
  delta    Print pane content that changed since last capture/delta
  keys     Send special key (Enter, C-c, C-d, Escape, ...)
  list     List sessions on the socket
  kill     Kill a session or the whole server
  wait     Poll for text in a pane
  attach   Print the attach command for the user (does not attach)

Run 'tmux-use.sh <command> --help' for command-specific help.
"""


def main() -> int:
    ensure_dir(SOCKET_DIR)

    # Parse global options manually (before the subcommand).
    argv = sys.argv[1:]
    socket_path = os.path.join(SOCKET_DIR, "tmux.sock")
    target: str | None = None

    while argv:
        if argv[0] in ("-S", "--socket-path"):
            socket_path = argv[1]
            argv = argv[2:]
        elif argv[0] in ("-t", "--target"):
            target = argv[1]
            argv = argv[2:]
        elif argv[0] in ("-h", "--help"):
            print(USAGE)
            return 0
        elif argv[0].startswith("-"):
            print(f"Unknown global option: {argv[0]}", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            return 1
        else:
            break

    if not argv:
        print(USAGE)
        return 1

    command, *rest = argv

    handler = COMMANDS.get(command)
    if handler is None:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 1

    return handler(socket_path, target, rest)


if __name__ == "__main__":
    sys.exit(main())
