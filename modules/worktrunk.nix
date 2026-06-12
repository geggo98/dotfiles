{ inputs, ... }:
{
  flake.modules.homeManager.worktrunk = { config, pkgs, ... }: {
    imports = [ inputs.worktrunk.homeModules.default ];

    programs.worktrunk = {
      enable = true;
      package = inputs.worktrunk.packages.${pkgs.stdenv.hostPlatform.system}.default;
      enableFishIntegration = true;
      enableZshIntegration = true;
      enableBashIntegration = true;
    };

    xdg.configFile."worktrunk/config.toml".source =
      (pkgs.formats.toml { }).generate "worktrunk-config.toml" {
        worktree-path = ".worktrees/{{ branch | sanitize }}";
        commit.generation.command =
          "CLAUDECODE= MAX_THINKING_TOKENS=0 ${config.home.profileDirectory}/bin/+agent-claude"
          + " -p --no-session-persistence --model=haiku --tools=''"
          + " --disable-slash-commands --setting-sources='' --system-prompt=''";
        # Den von git-hooks.nix erzeugten .pre-commit-config.yaml-Symlink (gitignored,
        # zeigt auf einen store-stabilen /nix/store/...-Pfad) in jeden neuen Worktree
        # spiegeln. Ohne das scheitert der erste `git commit` im Worktree mit
        # "config file not found: .pre-commit-config.yaml". `cp -P` kopiert den Symlink
        # selbst (nicht dereferenziert); `|| true` macht den Hook zum No-op fuer Repos
        # ohne git-hooks-Symlink, sodass er nie blockiert.
        #
        # Bewusst pre-start (blockierend), NICHT post-start (Hintergrund): nur so ist
        # der Symlink garantiert da, bevor `wt switch` zurueckkehrt und bevor der erste
        # Commit laeuft. Post-start liefe asynchron und ein sofortiger Commit (so wie
        # ihn die Fix-Agenten machen) gewaenne das Rennen gegen das Kopieren.
        pre-start = [
          { precommit = "cp -P {{ primary_worktree_path }}/.pre-commit-config.yaml {{ worktree_path }}/.pre-commit-config.yaml 2>/dev/null || true"; }
        ];
      };
  };
}
