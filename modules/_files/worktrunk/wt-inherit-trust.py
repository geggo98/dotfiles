#!/usr/bin/env python3
"""+wt-inherit-trust — let a new worktree inherit the direnv and devenv approval of the primary worktree.

usage: +wt-inherit-trust PRIMARY-WORKTREE WORKTREE

  direnv: runs `direnv allow` in WORKTREE only if
    - WORKTREE has an .envrc,
    - that .envrc is byte-identical to the one in PRIMARY-WORKTREE, and
    - direnv reports the primary .envrc as allowed.
  devenv: runs `devenv allow` in WORKTREE only if
    - WORKTREE has a devenv.nix,
    - devenv.nix and devenv.yaml are byte-identical to those in PRIMARY-WORKTREE
      (both absent counts as identical), and
    - PRIMARY-WORKTREE is listed in devenv's allowed-directories file.

  Origin: worktrunk runs this as a user pre-start hook (modules/worktrunk.nix). A blind
  `direnv allow` or `devenv allow` would run code from a foreign branch without asking:
  .envrc and devenv.nix are tracked, so a checked-out pull request brings its own.
  Inheriting the approval of the primary worktree limits it to content the user has
  already reviewed. devenv's own approval is per directory, not per content, so the
  helper does the content comparison itself.
  Limit: files that devenv.nix imports (other .nix files, devenv.lock) are not compared.

exit codes: 0 always, for every decision and every failed `allow`: the hook is a
pre-start hook, and a non-zero exit would abort the creation of the worktree.
Each decision and each failure is one line on stderr. 2: wrong arguments.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

EX_USAGE = 2


def say(msg: str) -> None:
    print(f"wt-inherit-trust: {msg}", file=sys.stderr)


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess | None:
    """Run cmd; None if the program is missing (already reported)."""
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    except OSError as e:
        say(f"{cmd[0]}: cannot run ({e.strerror or e})")
        return None


def allow(cmd: list[str], cwd: Path, label: str) -> None:
    r = run(cmd, cwd)
    if r is None:
        return
    if r.returncode == 0:
        say(f"{label}: allowed")
    else:
        detail = (r.stderr.strip() or r.stdout.strip()).splitlines()
        say(f"{label}: `{' '.join(cmd)}` failed with exit {r.returncode}"
            + (f": {detail[-1]}" if detail else ""))


def same_content(a: Path, b: Path) -> bool:
    """True if both files are absent, or both exist with the same bytes."""
    if a.is_file() != b.is_file():
        return False
    return not a.is_file() or a.read_bytes() == b.read_bytes()


def inherit_direnv(primary: Path, wt: Path) -> None:
    envrc, primary_envrc = wt / ".envrc", primary / ".envrc"
    if not envrc.is_file():
        say("direnv: skip, no .envrc in the worktree")
        return
    if not primary_envrc.is_file():
        say("direnv: skip, the primary worktree has no .envrc")
        return
    if envrc.read_bytes() != primary_envrc.read_bytes():
        say("direnv: skip, .envrc differs from the primary worktree (not inherited)")
        return
    r = run(["direnv", "status", "--json"], primary)
    if r is None:
        return
    try:
        # matches: {"state": {"foundRC": {"allowed": 0, "path": "/…/.envrc"}}}   (0 = allowed)
        found = json.loads(r.stdout)["state"]["foundRC"]
        path, status = found["path"], found["allowed"]
    except (ValueError, KeyError, TypeError):
        say("direnv: skip, cannot read `direnv status --json` for the primary worktree")
        return
    if os.path.realpath(path) != os.path.realpath(primary_envrc):
        say(f"direnv: skip, direnv found a different .envrc for the primary worktree: {path}")
        return
    if status != 0:
        say("direnv: skip, the primary .envrc is not allowed")
        return
    allow(["direnv", "allow", str(envrc)], wt, "direnv")


def inherit_devenv(primary: Path, wt: Path) -> None:
    if not (wt / "devenv.nix").is_file():
        say("devenv: skip, no devenv.nix in the worktree")
        return
    for name in ("devenv.nix", "devenv.yaml"):
        if not same_content(primary / name, wt / name):
            say(f"devenv: skip, {name} differs from the primary worktree (not inherited)")
            return
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    allowed_file = Path(data_home) / "devenv" / "allowed"
    try:
        lines = [ln for ln in allowed_file.read_text().splitlines() if ln.strip()]
    except OSError as e:
        say(f"devenv: skip, cannot read {allowed_file} ({e.strerror or e})")
        return
    try:
        # matches: {"path":"/Users/example/devel/project"}   (one JSON object per line)
        allowed = {os.path.realpath(json.loads(ln)["path"]) for ln in lines}
    except (ValueError, KeyError, TypeError):
        say(f"devenv: skip, unknown format in {allowed_file}")
        return
    if os.path.realpath(primary) not in allowed:
        say("devenv: skip, the primary worktree is not allowed")
        return
    allow(["devenv", "allow"], wt, "devenv")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: +wt-inherit-trust PRIMARY-WORKTREE WORKTREE", file=sys.stderr)
        return EX_USAGE
    primary, wt = Path(argv[0]), Path(argv[1])
    if not primary.is_dir() or not wt.is_dir():
        say(f"not a directory: {primary if not primary.is_dir() else wt}")
        return EX_USAGE
    if os.path.realpath(primary) == os.path.realpath(wt):
        say("skip, this is the primary worktree")
        return 0
    inherit_direnv(primary, wt)
    inherit_devenv(primary, wt)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
