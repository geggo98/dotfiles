{ config, inputs, ... }:
let
  inherit (config.flake.modules) darwin homeManager;
in
{
  configurations.darwin.DKL6GDJ7X1.module = {
    imports = [
      inputs.home-manager.darwinModules.home-manager
      darwin.macos
      darwin.determinate
      darwin.homebrew
      darwin.overlays
    ];

    nixpkgs.hostPlatform = "aarch64-darwin";
    nixpkgs.config.allowUnfree = true;

    users.users."stefan.schwetschke".home = /Users/stefan.schwetschke;
    system.primaryUser = "stefan.schwetschke";

    # Host-specific homebrew
    homebrew.brews = [
      "hashicorp/tap/boundary"
    ];
    homebrew.casks = [
      "aptakube"
      "bleunlock"
      "hashicorp/tap/hashicorp-boundary-desktop"
      "cursor"
      "Dropbox"

      "openvpn-connect"
      "postman"
      "postman-cli"
      "slack"
      "tunnelblick"
    ];
    homebrew.masApps = { };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "hm.bak";
      users."stefan.schwetschke" = {
        programs.git.settings.user.email = "stefan.schwetschke@check24.de";
        imports = [
          homeManager.shell
          homeManager.git
          homeManager.neovim
          homeManager.mcp-servers
          homeManager.ai-tools
          homeManager.packages
          homeManager.supply-chain-hardening
          homeManager.misc
          homeManager.vscode
          homeManager.secrets-DKL6GDJ7X1
          homeManager.boundary
          homeManager.vault
          homeManager.tunnelblick-raycast
        ];
        home.stateVersion = "25.11";
      };
    };
  };
}
