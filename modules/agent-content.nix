{ config, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
in
{
  flake.modules.homeManager.agent-content = { config, pkgs, lib, ... }:
    let
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
      skillsSrc = ./ai/_files/skills;

      # Filtered at eval time, not in a runCommand: no extra derivation, and
      # with the option on, the path is handed through untouched, so the work
      # host's store path does not move at all.
      #
      # `builtins.path`, NOT `lib.cleanSourceWith`. The latter returns an
      # ATTRSET carrying `outPath`, while `programs.claude-code.skills` wants a
      # path — handed the attrset, the module system descends into its
      # attributes and fails with `A definition for option
      # ...claude-code.skills._isLibCleanSourceWith is not of type ...`, which
      # names the wrapper's marker attribute rather than the mistake.
      # builtins.path returns a real store path and takes the same filter.
      skillsDir =
        if config.my.ai.atlassian.enable then skillsSrc
        else
          builtins.path {
            name = "claude-skills";
            path = skillsSrc;
            filter = path: type:
              let rel = lib.removePrefix (toString skillsSrc + "/") (toString path);
              in !(type == "directory" && builtins.elem rel [ "jira" "bitbucket-pr" ]);
          };

    in
    {
      imports = [ aiOptions ];
      config = lib.mkIf config.my.ai.content.enable {
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
            message = "my.ai.extraRules: only .md files are delivered to every"
              + " agent; got: "
              + lib.concatMapStringsSep ", " (f: f.name) nonMarkdown;
          }
        ];

        my.ai.content.artifacts = {
          inherit skillsDir rulesDir rulesFile;
          # OpenCode's global context used to also carry this repo's own
          # AGENTS.md, concatenated ahead of the global rules. That put a
          # repo-specific 150 KB+ document into EVERY opencode session in
          # EVERY project on this machine (`~/.config/opencode/AGENTS.md`),
          # and doubled it in this repo, since opencode already reads a
          # project's own AGENTS.md itself. Global context should carry only
          # what is actually global: the shared rules.
          opencodeContext = rulesText;
        };
        xdg.configFile = {
          "ai/content/skills" = { source = skillsDir; recursive = true; };
          "ai/content/rules" = { source = rulesDir; recursive = true; };
          "ai/content/rules.md".source = rulesFile;
        };
      };
    };
}
