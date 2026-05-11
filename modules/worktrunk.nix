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
      };
  };
}
