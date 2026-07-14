{ config, ... }:
let
  inherit (config.flake.modules) darwin homeManager;
in
{
  configurations.darwin.DKL6GDJ7X1.module = {
    imports = [
      darwin.home-manager
      darwin.identity
      darwin.macos
      darwin.determinate
      darwin.nix-cache
      darwin.homebrew
      darwin.overlays
      darwin.pmset-hibernatemode
    ];

    nixpkgs.hostPlatform = "aarch64-darwin";
    nixpkgs.config.allowUnfree = true;
    # pnpm-9.15.9 is an offline, build-time-only dependency of `prettier` (pulled
    # in by nvf's conform-nvim formatter → @oxc-parser/binding-wasm32-wasi, which
    # nixpkgs still builds with pnpm_9). nixpkgs marked pnpm_9 insecure over
    # pnpm-as-package-manager CVEs, which don't apply to a sandboxed FOD build
    # step. A clean pnpm_10 override isn't possible: prettier hardcodes the
    # pnpm-deps FOD hash in an inner let-derivation, so `.override` can't reach
    # it. Drop this once nixpkgs bumps binding-wasm32-wasi to pnpm_10.
    nixpkgs.config.permittedInsecurePackages = [ "pnpm-9.15.9" ];

    my.identity = {
      hostName = "DKL6GDJ7X1";
      computerName = "DKL6GDJ7X1";
    };

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
        homeManager.bitbucket-cli
        homeManager.boundary
        homeManager.vault
        homeManager.tunnelblick-raycast
      ];
      home.stateVersion = "26.05";
    };
  };
}
