{ config, ... }:
let
  hm = config.flake.modules.homeManager;
in
{
  # Default home-manager aspect set imported by every DARWIN host. Composes the
  # cross-cutting aspects that have no host-specific dependencies. Hosts
  # add `homeManager.secrets-<host>` and any host-only aspects (boundary,
  # vault, tunnelblick-raycast) on top. NOT every host: p-ion-berlin-xs56r6
  # deliberately takes `homeManager.shell` and `neovim-server` instead, so
  # anything reasoned about as "every host" — the agent rules in
  # `modules/agent-rules.nix`, for one — means the two workstations.
  flake.modules.homeManager.base = {
    imports = [
      hm.shell
      # Split from `shell` so that aspect can be imported by hosts without
      # sops-nix (the NixOS VPS). Kept here so the workstations are unchanged.
      hm.shell-secrets
      hm.git
      hm.gpg
      # Which vaults the 1Password SSH agent may offer keys from. Per-machine
      # state that 1Password does not sync, so a new Mac starts without it —
      # and a key outside the personal vault is then never offered at all.
      hm.onepassword
      hm.gradle
      hm.neovim
      hm.mcp-servers
      # Globale Agentenregeln (difftastic, Skriptstil, PII) fuer alle drei
      # Agenten. Eigenes Modul, weil es die Maschine beschreibt, nicht dieses Repo.
      hm.agent-rules
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
