# superlite: an autonomous build-lifecycle plugin for Claude Code, reachable only
# through its own wrapper.
#
# Why not `programs.claude-code.plugins` like worktrunk and gradle-skills: the
# plugin's SessionStart hook injects the `using-superlite` skill into every
# session, so a plain "build X" starts its own approval flow, and its PreToolUse
# hooks (block-unsafe-kill, block-coordinator-edits, rewrite-test-runs) run on
# every Bash/Edit/Agent call. That is the right trade for a session started to
# run it and the wrong one as a default. `+agent-claude-superlite` loads it with
# --plugin-dir for that one process; plain `claude` is untouched.
#
# The wrapper pins two interpreters, because the plugin resolves both through
# PATH and a hook environment is not the interactive one:
#
#   * bash: the hooks are run as `bash <hook>` and two of them lowercase with
#     `${var,,}` (block-coordinator-edits, record-human-reply), which bash 3.2.57
#     (/bin/bash on macOS) rejects with "bad substitution". Measured 2026-10-29:
#     `/bin/bash -c 'x=ABC; echo "${x,,}"'` fails, bash 5.3 prints abc. Not
#     measured: those hooks mid-run. Their `${var,,}` sits behind an early exit
#     that only a project with an active superlite run passes. (session-start's
#     `${var^^}` is on a Windows-path branch and never runs on a Mac.)
#   * python: the `sl` tools need 3.10+. `sl` honours SUPERLITE_PYTHON and skips
#     its own probe, which also keeps its interpreter cache from going stale when
#     the Nix store path changes.
#
# Nothing is written into the plugin directory: the tools keep state under
# <project>/.superlite and ~/.superlite, the interpreter cache under
# ~/.cache/superlite. Python cannot write __pycache__ into the read-only store
# and silently skips it.
{ inputs, config, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
in
{
  flake.modules.homeManager.superlite = { config, pkgs, lib, ... }:
    let
      enabled = config.my.ai.superlite.enable
        && config.my.ai.agents.enable
        && config.my.ai.agents.claude.enable;

      # Goes through +agent-claude, not `claude`, so the pinned binary, the
      # full-screen TUI flag and the ACP handling stay in one place.
      agent-claude-superlite = pkgs.writeShellApplication {
        name = "+agent-claude-superlite";
        runtimeInputs = [ pkgs.bash pkgs.python3 ];
        text = ''
          export SUPERLITE_PYTHON="${pkgs.python3}/bin/python3"
          exec "${config.home.profileDirectory}/bin/+agent-claude" \
            --plugin-dir "${inputs.superlite}" "$@"
        '';
      };
    in
    {
      imports = [ aiOptions ];

      home.packages = lib.optional enabled agent-claude-superlite;
    };
}
