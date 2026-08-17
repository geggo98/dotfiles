{ config, ... }:
let
  hm = config.flake.modules.homeManager;
in
{
  # Default home-manager aspect set imported by every host. Composes the
  # cross-cutting aspects that have no host-specific dependencies. Hosts
  # add `homeManager.secrets-<host>` and any host-only aspects (boundary,
  # vault, tunnelblick-raycast) on top.
  flake.modules.homeManager.base = {
    imports = [
      hm.shell
      # Split from `shell` so that aspect can be imported by hosts without
      # sops-nix (the NixOS VPS). Kept here so the workstations are unchanged.
      hm.shell-secrets
      hm.git
      hm.gpg
      hm.gradle
      hm.neovim
      hm.mcp-servers
      hm.ai-tools
      hm.camoufox
      hm.packages
      hm.supply-chain-hardening
      hm.misc
      hm.vscode
      hm.gram
      hm.voxscriber
      hm.yt-dlp
      hm.worktrunk
      hm.nix-tarball-cache-repack
    ];
  };
}
