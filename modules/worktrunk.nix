{ inputs, ... }:
{
  flake.modules.homeManager.worktrunk = { pkgs, ... }: {
    imports = [ inputs.worktrunk.homeModules.default ];

    programs.worktrunk = {
      enable = true;
      package = inputs.worktrunk.packages.${pkgs.stdenv.hostPlatform.system}.default;
      enableFishIntegration = true;
      enableZshIntegration = true;
      enableBashIntegration = true;
    };
  };
}
