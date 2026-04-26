{ inputs, ... }:
{
  flake.modules.homeManager.ai-tools = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = inputs.nixpkgs-llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
      loadSecretsLib = builtins.readFile ./_files/shell/load-secrets.sh;
    in
    {
      home.packages = [
        unstable.ollama
        (unstable.python313Packages.llm.withPlugins {
          llm-openrouter = true;
          llm-groq = true;
          llm-ollama = true;
          llm-anthropic = true;
          llm-gemini = true;
          llm-cmd = true;
        })
        llm-agents.agent-browser
        llm-agents.ccusage
        llm-agents.ccusage-codex
        pkgs.tmux # required by the tmux skill for headless interactive sessions

        (pkgs.writeShellApplication {
          name = "+agent-claude";
          runtimeInputs = [ llm-agents.claude-code-acp ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              export CLAUDE_CODE_EXECUTABLE="/etc/profiles/per-user/''${USER}/bin/claude"
              shift
              exec claude-agent-acp --thinking-display summarized "$@"
            fi
            exec "/etc/profiles/per-user/''${USER}/bin/claude" --thinking-display summarized "$@"
          '';
        })
        (pkgs.writeShellApplication {
          name = "+agent-opencode";
          runtimeInputs = [ ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            ${loadSecretsLib}
            load_from_secret GEMINI_API_KEY      gemini_api_key
            load_from_secret OPENAI_API_KEY      openai_api_key
            load_from_secret OPENROUTER_API_KEY  openrouter_api_key
            load_from_secret Z_AI_API_KEY        z_ai_api_key
            require_secrets GEMINI_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY Z_AI_API_KEY
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
            ${loadSecretsLib}
            load_from_secret OPENAI_API_KEY openai_api_key
            require_secrets OPENAI_API_KEY
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
            ${loadSecretsLib}
            load_from_secret GEMINI_API_KEY gemini_api_key
            require_secrets GEMINI_API_KEY
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

      # Configure LLM aliases and default model
      home.activation.llm = lib.hm.dag.entryAfter [ "installPackages" ] ''
        if command -v llm > /dev/null 2>&1
        then
          run --quiet llm aliases set gemini gemini-2.0-pro-exp-02-05
          run --quiet llm aliases set deepseek openrouter/deepseek/deepseek-r1
          run --quiet llm aliases set auto openrouter/openrouter/auto
          run llm models default gpt-5-mini
        fi
      '';
    };
}
