# Global agent rules: one source, three agents.
#
# These rules describe the MACHINE, not this repository — the difftastic trap
# below is set by modules/git.nix into ~/.config/git/config and therefore
# applies in every git repository on the host. Documenting it only in this
# repo's AGENTS.md would leave an agent working anywhere else blind to it.
#
# Some rules describe only SOME machines. A rule about a wrapper that one host
# does not have is worse than no rule, so an aspect module contributes its own
# through `my.ai.extraRules` and it ships exactly where that aspect is
# imported — modules/vault.nix is the worked example.
#
# That gating covers the RULES layer only, and the limit is worth knowing before
# anyone leans on it. opencode additionally receives this repo's own AGENTS.md
# as global context on every host that imports this aspect — both workstations,
# since p-ion-berlin-xs56r6 deliberately takes `homeManager.shell` instead of
# `homeManager.base` — and AGENTS.md describes both machines.
# Measured 03.09.2026: `+vault` occurs 7 times in FCX19GT9XR's opencode context
# — all of them from AGENTS.md — against 14 on DKL6GDJ7X1, where the gated rule
# file contributes the other 7. Containment is complete for claude-code
# (rulesDir) and codex (the merged rules block), which receive rule files and
# nothing else.
#
# Each agent reads a different file, so the same text is delivered three ways:
#
#   claude-code  ~/.claude/rules/*.md      loaded automatically in every project
#   opencode     ~/.config/opencode/AGENTS.md   via programs.opencode.context
#   codex        ~/.codex/AGENTS.md        merged block, file stays writable
{ ... }:
let
  mkAgentRulesModule = { config, pkgs, lib, ... }:
    let
      root = ./..;
      rulesSrc = ./ai/_files/rules;

      baseRules = map (n: { name = n; path = rulesSrc + "/${n}"; }) (
        lib.filter (n: lib.hasSuffix ".md" n) (lib.attrNames (builtins.readDir rulesSrc))
      );
      extraRules = map (p: { name = baseNameOf p; path = p; }) config.my.ai.extraRules;

      # Base rules are filtered to `.md`; contributed ones are not, and that gap
      # is not cosmetic. rulesText concatenates whatever it is handed, so a
      # `notes.txt` would reach opencode and codex while claude-code loads only
      # markdown out of rulesDir — one rule, two agents, and no error anywhere.
      # A contributed DIRECTORY (types.path accepts one) fails later still, on a
      # `cp` without -r, with a message that names neither the option nor the
      # cause.
      nonMarkdown = lib.filter (f: !lib.hasSuffix ".md" f.name) extraRules;

      # Sorted so the concatenation is reproducible; readDir gives no order,
      # and a contributed rule must not depend on module merge order either.
      ruleFiles = lib.sort (a: b: a.name < b.name) (baseRules ++ extraRules);

      ruleNames = map (f: f.name) ruleFiles;
      duplicateNames = lib.unique (
        lib.filter (n: lib.count (m: m == n) ruleNames > 1) ruleNames
      );

      # One document for the two agents that read a single file. claude-code
      # gets a directory and keeps the files separate.
      rulesText = lib.concatMapStringsSep "\n\n" (f: builtins.readFile f.path) ruleFiles;

      rulesFile = pkgs.writeText "agent-global-rules.md" rulesText;

      # A plain directory of regular files — the same shape rulesSrc had before
      # contributed rules existed, so nothing about the delivery path changes.
      # escapeShellArg on the NAME only. It must not touch the path: the
      # function calls `toString`, which strips a path's string context, and the
      # derivation then no longer records the source as an input. Nix says so —
      # "references the store path … without a proper context … unreliable and
      # may stop working in the future" — and the warning is the only sign.
      # Unquoted `${f.path}` is safe anyway, because a store path is limited to
      # [a-zA-Z0-9+._?=-]. The name is the part an author chooses, and `$`, a
      # backtick, `"` or `\` in one would write somewhere else entirely.
      # preferLocalBuild because asking a substituter for a `cp` costs more than
      # doing it.
      rulesDir = pkgs.runCommand "agent-global-rules-dir"
        {
          preferLocalBuild = true;
          allowSubstitutes = false;
        } ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n"
          (f: ''cp ${f.path} "$out"/${lib.escapeShellArg f.name}'')
          ruleFiles}
      '';
    in
    {
      options.my.ai.extraRules = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        example = lib.literalExpression "[ ./_files/vault/rules/vault-address.md ]";
        description = ''
          Rule files contributed by an aspect module. Delivered exactly like the
          files in modules/ai/_files/rules/, but only on hosts importing the
          contributing aspect — which is the point: a rule about `+vault` must
          not reach a machine that has no `+vault`.

          Keep such a file next to its aspect, not in modules/ai/_files/rules/;
          that directory is read wholesale and would ship it everywhere.
        '';
      };

      config = {
        # `cp` would overwrite one rule with another without a word, and a rule
        # that silently disappears is the worst possible failure here.
        assertions = [
          {
            assertion = duplicateNames == [ ];
            message = "my.ai.extraRules: duplicate rule file names: "
              + lib.concatStringsSep ", " duplicateNames;
          }
          {
            assertion = nonMarkdown == [ ];
            message = "my.ai.extraRules: only .md files are delivered to all three"
              + " agents; got: "
              + lib.concatMapStringsSep ", " (f: f.name) nonMarkdown;
          }
        ];

        # Verified against Claude Code's own docs: "Personal rules in
        # ~/.claude/rules/ apply to every project on your machine", discovered
        # recursively and loaded at session start with no configuration.
        #
        # Deliberately NOT programs.claude-code.context: that option writes
        # ~/.claude/CLAUDE.md as a read-only store symlink, and both `/memory`
        # and "add this to CLAUDE.md" then fail with EACCES — the same trap the
        # VS Code settings.json section in AGENTS.md documents at length.
        #
        # A derivation rather than a source path: the option is
        # `nullOr path`, and a derivation satisfies `types.path`.
        programs.claude-code.rulesDir = rulesDir;

        # A STRING, not a derivation. The module branches on `lib.isPath`, and a
        # writeText derivation is not a path — it would fall through to the
        # `.text` branch and write the store path itself as the file contents.
        programs.opencode.context = builtins.readFile (root + "/AGENTS.md") + "\n\n" + rulesText;

        home.activation.codexRules = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${pkgs.zsh}/bin/zsh ${./ai/_files/codex-merge-rules} \
            ${rulesFile} "$HOME/.codex/AGENTS.md"
        '';
      };
    };
in
{
  flake.modules.homeManager.agent-rules = mkAgentRulesModule;
}
