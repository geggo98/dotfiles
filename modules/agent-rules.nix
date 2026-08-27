# Global agent rules: one source, three agents.
#
# These rules describe the MACHINE, not this repository — the difftastic trap
# below is set by modules/git.nix into ~/.config/git/config and therefore
# applies in every git repository on the host. Documenting it only in this
# repo's AGENTS.md would leave an agent working anywhere else blind to it.
#
# Each agent reads a different file, so the same text is delivered three ways:
#
#   claude-code  ~/.claude/rules/*.md      loaded automatically in every project
#   opencode     ~/.config/opencode/AGENTS.md   via programs.opencode.context
#   codex        ~/.codex/AGENTS.md        merged block, file stays writable
{ ... }:
let
  mkAgentRulesModule = { pkgs, lib, ... }:
    let
      root = ./..;
      rulesSrc = ./ai/_files/rules;

      # Sorted so the concatenation is reproducible; readDir gives no order.
      ruleNames = lib.sort (a: b: a < b) (
        lib.filter (n: lib.hasSuffix ".md" n) (lib.attrNames (builtins.readDir rulesSrc))
      );

      # One document for the two agents that read a single file. claude-code
      # gets the directory itself and keeps the files separate.
      rulesText = lib.concatMapStringsSep "\n\n" (n: builtins.readFile (rulesSrc + "/${n}")) ruleNames;

      rulesFile = pkgs.writeText "agent-global-rules.md" rulesText;
    in
    {
      # Verified against Claude Code's own docs: "Personal rules in
      # ~/.claude/rules/ apply to every project on your machine", discovered
      # recursively and loaded at session start with no configuration.
      #
      # Deliberately NOT programs.claude-code.context: that option writes
      # ~/.claude/CLAUDE.md as a read-only store symlink, and both `/memory`
      # and "add this to CLAUDE.md" then fail with EACCES — the same trap the
      # VS Code settings.json section in AGENTS.md documents at length.
      programs.claude-code.rulesDir = rulesSrc;

      # A STRING, not a derivation. The module branches on `lib.isPath`, and a
      # writeText derivation is not a path — it would fall through to the
      # `.text` branch and write the store path itself as the file contents.
      programs.opencode.context = builtins.readFile (root + "/AGENTS.md") + "\n\n" + rulesText;

      home.activation.codexRules = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${pkgs.zsh}/bin/zsh ${./ai/_files/codex-merge-rules} \
          ${rulesFile} "$HOME/.codex/AGENTS.md"
      '';
    };
in
{
  flake.modules.homeManager.agent-rules = mkAgentRulesModule;
}
