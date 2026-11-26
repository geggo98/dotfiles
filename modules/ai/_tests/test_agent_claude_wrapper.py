#!/usr/bin/env python3
"""+agent-claude --code-mode: argument handling of the wrapper.

Origin: Code Mode is off by default and one run switches it on with --code-mode
(decided 2026-11-26; an earlier version had it on in settings.json and used
--no-code-mode). The wrapper hard-codes the path of the real claude, so the test
points that path at a fake that prints what it received.

Usage: AGENT_CLAUDE_WRAPPER=<path to +agent-claude> test_agent_claude_wrapper.py
"""
import os
import re
import stat
import subprocess
import sys
import tempfile

WRAPPER = os.environ["AGENT_CLAUDE_WRAPPER"]
VAR = "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE"

# matches:  "/etc/profiles/per-user/${USER}/bin/claude"
REAL_CLAUDE = re.compile(r'"/etc/profiles/per-user/\$\{USER\}/bin/claude"')


def build(tmp: str) -> str:
    fake = os.path.join(tmp, "fake-claude")
    with open(fake, "w") as f:
        # One line per argument, then the variable: spaces inside an argument survive.
        f.write('#!/bin/sh\nfor a in "$@"; do printf "arg=%s\\n" "$a"; done\n'
                f'printf "var=%s\\n" "${{{VAR}-unset}}"\n')
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
    text = open(WRAPPER).read()
    patched, n = REAL_CLAUDE.subn(f'"{fake}"', text)
    # Two mentions today: CLAUDE_CODE_EXECUTABLE in the --acp branch and the final
    # exec. A changed wrapper must not pass unnoticed.
    assert n == 2, f"expected 2 mentions of the real claude in the wrapper, found {n}"
    script = os.path.join(tmp, "wrapper")
    with open(script, "w") as f:
        f.write(patched)
    os.chmod(script, 0o755)
    return script


def run(script: str, *args: str, preset: str | None = None):
    env = {k: v for k, v in os.environ.items() if k != VAR}
    if preset is not None:
        env[VAR] = preset
    out = subprocess.run([script, *args], env=env, capture_output=True, text=True,
                         check=True).stdout.splitlines()
    got = [l[4:] for l in out if l.startswith("arg=")]
    var = next(l[4:] for l in out if l.startswith("var="))
    return got, var


def main() -> None:
    base = ["--thinking-display", "summarized"]
    cases = [
        # (arguments, expected arguments after the wrapper's own, expected variable)
        (["--code-mode", "foo", "bar"], ["foo", "bar"], "1"),
        (["foo", "--code-mode", "bar"], ["foo", "bar"], "1"),
        (["foo", "bar", "--code-mode"], ["foo", "bar"], "1"),
        (["--code-mode"], [], "1"),
        (["a b", "--code-mode", "c  d", ""], ["a b", "c  d", ""], "1"),
        # The default: no flag, no variable.
        (["foo", "bar"], ["foo", "bar"], "unset"),
        ([], [], "unset"),
        # Only the exact flag counts. The old --no-code-mode is no longer special and
        # must reach claude, which rejects it, instead of being swallowed silently.
        (["--code-mode-x", "--no-code-mode"], ["--code-mode-x", "--no-code-mode"], "unset"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        script = build(tmp)
        for args, want_args, want_var in cases:
            got, var = run(script, *args)
            assert got == base + want_args, f"{args}: arguments {got}"
            assert var == want_var, f"{args}: {VAR}={var}, wanted {want_var}"
        # The flag sets the variable even where the environment holds another value.
        # What Claude Code makes of a preset 0 is not tested here (docs: a 0 wins).
        got, var = run(script, "--code-mode", preset="0")
        assert var == "1", f"preset 0 not overridden by the flag: {var}"
        # Without the flag an existing value stays untouched.
        got, var = run(script, "foo", preset="1")
        assert var == "1", f"preset 1 changed without the flag: {var}"
    print(f"ok: {len(cases) + 2} cases")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
