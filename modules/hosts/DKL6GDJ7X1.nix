{ config, ... }:
let
  inherit (config.flake.modules) darwin homeManager;
in
{
  configurations.darwin.DKL6GDJ7X1.module = {
    imports = [
      darwin.home-manager
      darwin.macos
      darwin.determinate
      darwin.homebrew
      darwin.overlays
      darwin.pmset-hibernatemode
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

    home-manager.users."stefan.schwetschke" = {
      programs.git.settings.user.email = "stefan.schwetschke@check24.de";
      programs.gpg.settings.default-key = "DKL6GDJ7X1@schwetschke.de";
      imports = [
        homeManager.base
        homeManager.secrets-DKL6GDJ7X1
        homeManager.boundary
        homeManager.vault
        homeManager.tunnelblick-raycast
      ];
      home.stateVersion = "25.11";
    };
  };
}
