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
      hm.git
      hm.gpg
      hm.gradle
      hm.neovim
      hm.mcp-servers
      hm.ai-tools
      hm.packages
      hm.supply-chain-hardening
      hm.misc
      hm.vscode
      hm.worktrunk
    ];
  };
}
