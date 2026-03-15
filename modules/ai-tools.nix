{ inputs, ... }:
{
  flake.modules.homeManager.ai-tools = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = inputs.nixpkgs-llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      home.packages = [
        unstable.aichat
        unstable.ollama
        llm-agents.openskills

        (pkgs.writeShellApplication {
          name = "+agent-claude";
          runtimeInputs = [ llm-agents.claude-code-acp ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              export CLAUDE_CODE_EXECUTABLE="/etc/profiles/per-user/''${USER}/bin/claude"
              shift
              exec claude-code-acp "$@"
            fi
            exec "/etc/profiles/per-user/''${USER}/bin/claude" "$@"
          '';
        })
        (pkgs.writeShellApplication {
          name = "+agent-opencode";
          runtimeInputs = [ ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            SECRETS_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"
            load_from_secret() {
              local var_name="$1" file_name="$2"
              local current_val="''${!var_name-}"
              if [[ -z "''${current_val}" && -r "''${SECRETS_DIR}/''${file_name}" ]]; then
                local val
                val="$(<"''${SECRETS_DIR}/''${file_name}")"
                if [[ -n "''${val}" ]]; then
                  export "''${var_name}=''${val}"
                fi
              fi
              if [[ -z "''${var_name}" ]]; then
                echo "ERROR: Secret ''${var_name} not found" >&2
                exit 1
              fi
            }
            load_from_secret GEMINI_API_KEY      gemini_api_key
            load_from_secret OPENAI_API_KEY      openai_api_key
            load_from_secret OPENROUTER_API_KEY  openrouter_api_key
            load_from_secret Z_AI_API_KEY        z_ai_api_key
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              shift
              exec "/etc/profiles/per-user/''${USER}/bin/opencode" acp "$@"
            fi
            exec "/etc/profiles/per-user/''${USER}/bin/opencode" "$@"
          '';
        })
        (pkgs.writeShellApplication {
          name = "+agent-codex";
          runtimeInputs = [ llm-agents.codex-acp ];
          text = ''
            SECRETS_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"
            load_from_secret() {
              local var_name="$1" file_name="$2"
              local current_val="''${!var_name-}"
              if [[ -z "''${current_val}" && -r "''${SECRETS_DIR}/''${file_name}" ]]; then
                local val
                val="$(<"''${SECRETS_DIR}/''${file_name}")"
                if [[ -n "''${val}" ]]; then
                  export "''${var_name}=''${val}"
                fi
              fi
              if [[ -z "''${var_name}" ]]; then
                echo "ERROR: Secret ''${var_name} not found" >&2
                exit 1
              fi
            }
            load_from_secret OPENAI_API_KEY  openai_api_key
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              shift
              exec codex-acp "$@"
            fi
            exec codex "$@"
          '';
        })
        (pkgs.writeShellApplication {
          name = "+agent-gemini";
          runtimeInputs = [ llm-agents.gemini-cli ];
          text = ''
            SECRETS_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"
            load_from_secret() {
              local var_name="$1" file_name="$2"
              local current_val="''${!var_name-}"
              if [[ -z "''${current_val}" && -r "''${SECRETS_DIR}/''${file_name}" ]]; then
                local val
                val="$(<"''${SECRETS_DIR}/''${file_name}")"
                if [[ -n "''${val}" ]]; then
                  export "''${var_name}=''${val}"
                fi
              fi
              if [[ -z "''${var_name}" ]]; then
                echo "ERROR: Secret ''${var_name} not found" >&2
                exit 1
              fi
            }
            load_from_secret GEMINI_API_KEY  gemini_api_key
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              shift
              exec gemini --experimental-acp "$@"
            fi
            exec gemini "$@"
          '';
        })
      ];

      launchd.agents.ollama = {
        enable = true;
        config = {
          EnvironmentVariables = {
            OLLAMA_ORIGINS = "app://obsidian.md*";
            OLLAMA_CONTEXT_LENGTH = "8192";
          };
          ProgramArguments = [ "${unstable.ollama}/bin/ollama" "serve" ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ollama.out.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ollama.err.log";
        };
      };

      # Install or update LLM plugins
      home.activation.llm = lib.hm.dag.entryAfter [ "installPackages" ] ''
        original_path_B541A0A9="$PATH"
        export PATH="$PATH:/opt/homebrew/bin"
        if command -v llm > /dev/null 2>&1
        then
          echo "Installing or updating LLM plugins"
          run  --quiet llm install -U llm-openrouter llm-groq llm-ollama llm-claude-3 llm-gemini llm-cmd
          run --quiet llm aliases set gemini gemini-2.0-pro-exp-02-05
          run --quiet llm aliases set deepseek openrouter/deepseek/deepseek-r1
          run --quiet llm aliases set auto openrouter/openrouter/auto
          run llm models default gpt-5-mini
        fi
        export PATH="$original_path_B541A0A9"
        unset original_path_B541A0A9
      '';
    };
}
