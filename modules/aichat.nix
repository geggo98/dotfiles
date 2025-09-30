{ config, lib, pkgs, nixpkgs-unstable ? null, ... }:

let
  vendoredFunctionsSrc = ./aichat-functions;

  systemPkgs =
    if nixpkgs-unstable == null then { }
    else nixpkgs-unstable.legacyPackages.${pkgs.system};

  aichatPkg = if systemPkgs ? aichat then systemPkgs.aichat else pkgs.aichat;

  llmFunctions = pkgs.stdenvNoCC.mkDerivation {
    pname = "aichat-functions";
    version = "1.0";
    src = vendoredFunctionsSrc;

    nativeBuildInputs = [
      pkgs.argc
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.bash
      pkgs.curl
    ];

    buildPhase = ''
      set -euo pipefail
      mkdir -p "$TMPDIR"
      echo "Generating tools.txt from ./tools"
      ls tools | grep -E '\.(sh|js|py)$' | sort > tools.txt
      echo "tools.txt:"; cat tools.txt

      ${pkgs.argc}/bin/argc build
      ${pkgs.argc}/bin/argc check || true
    '';

    installPhase = ''
      set -euo pipefail
      outDir="$out/share/aichat-functions"
      mkdir -p "$outDir"
      cp -r tools "$outDir/"
      [ -d bin ] && cp -r bin "$outDir/"
      [ -f functions.json ] && cp functions.json "$outDir/"
      [ -f tools.txt ] && cp tools.txt "$outDir/"
      [ -f Argcfile.sh ] && cp Argcfile.sh "$outDir/"
    '';
  };

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
      export AICHAT_FUNCTIONS_DIR="${llmFunctions}/share/aichat-functions"

      export OPENAI_API_KEY="''${OPENAI_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/openai_api_key" 2>/dev/null || true)}"
      export OPENROUTER_API_KEY="''${OPENROUTER_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/openrouter_api_key" 2>/dev/null || true)}"
      export GEMINI_API_KEY="''${GEMINI_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/gemini_api_key" 2>/dev/null || true)}"
      export TAVILY_API_KEY="''${TAVILY_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/tavily_api_key" 2>/dev/null || true)}"
      export OLLAMA_API_KEY="''${OLLAMA_API_KEY:-$(cat "$HOME/.config/sops-nix/secrets/ollama_api_key" 2>/dev/null || true)}"

      if [ -d "$AICHAT_FUNCTIONS_DIR" ]; then
        pushd "$AICHAT_FUNCTIONS_DIR" >/dev/null
        ${pkgs.argc}/bin/argc mcp start 1>/dev/null || true
        popd >/dev/null
      fi

      exec ${aichatPkg}/bin/aichat "$@"
    '';
    executable = true;
  };

  xdg.configFile."aichat/config.yaml".source = ./aichat-config.yaml;

  xdg.configFile."aichat/functions".source = "${llmFunctions}/share/aichat-functions";

  # xdg.configFile."aichat/functions".source =
  #   config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.config/aichat-functions";
  # home.activation.llmFunctionsBuild = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  #   if [ -d "${config.home.homeDirectory}/.config/aichat-functions" ]; then
  #     ${pkgs.argc}/bin/argc -C "${config.home.homeDirectory}/.config/aichat-functions" build || true
  #   fi
  # '';
}
