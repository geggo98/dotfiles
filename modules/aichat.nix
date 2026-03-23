{ inputs, ... }:
{
  flake.modules.homeManager.aichat = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      aichatPkg = if builtins.hasAttr "aichat" unstable then unstable.aichat else pkgs.aichat;
    in
    {
      home.packages = [
        aichatPkg
        pkgs.jq
        pkgs.curl
        pkgs.argc
      ];

      home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" ];

      home.file.".local/bin/aichat" = {
        text = ''
          #!/usr/bin/env bash
          set -euo pipefail

          export AICHAT_CONFIG_DIR="$HOME/.config/aichat"

          export OPENAI_API_KEY="''${OPENAI_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/openai_api_key" 2>/dev/null || true)}"
          export OPENROUTER_API_KEY="''${OPENROUTER_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/openrouter_api_key" 2>/dev/null || true)}"
          export GEMINI_API_KEY="''${GEMINI_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/gemini_api_key" 2>/dev/null || true)}"
          export TAVILY_API_KEY="''${TAVILY_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/tavily_api_key" 2>/dev/null || true)}"
          export OLLAMA_API_KEY="''${OLLAMA_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/ollama_api_key" 2>/dev/null || true)}"

          exec ${aichatPkg}/bin/aichat "$@"
        '';
        executable = true;
      };

      xdg.configFile."aichat/config.yaml".source = ./_files/ai/aichat-config.yaml;
    };
}
