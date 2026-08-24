{ inputs, ... }:
{
  flake.modules.homeManager.ai-tools = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = inputs.nixpkgs-llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
      loadSecretsLib = builtins.readFile ./_files/shell/load-secrets.sh;

      # Bound rather than inlined below, because each is now consumed by a
      # wrapper of the SAME name instead of being installed directly. The
      # wrapper loads the key from its sops-nix file per invocation, so nothing
      # has to be exported into every shell — see the note in modules/shells.nix.
      # Neither tool has another key source: `llm` keeps keys in keys.json,
      # which is empty here and unmanaged, so it read those env vars and nothing
      # else.
      llmPkg = unstable.python313Packages.llm.withPlugins {
        llm-openrouter = true;
        llm-groq = true;
        llm-ollama = true;
        llm-anthropic = true;
        llm-gemini = true;
        llm-cmd = true;
      };
    in
    {
      home.packages = [
        # `ollama` and `llm` keep their own names: these wrappers REPLACE the
        # bare packages rather than sitting beside them, so the commands people
        # (and llm's own activation script) already type keep working. Inside
        # the wrapper runtimeInputs come first on PATH, so `exec ollama` / `exec
        # llm` reach the real binary, not the wrapper again.
        (pkgs.writeShellApplication {
          name = "ollama";
          runtimeInputs = [ unstable.ollama ];
          text = ''
            ${loadSecretsLib}
            # Not required: the launchd server on localhost needs no auth, and
            # the key is only for ollama.com cloud models. Load it if present,
            # never fail without it.
            load_from_secret OLLAMA_API_KEY ollama_api_key
            exec ollama "$@"
          '';
        })
        (pkgs.writeShellApplication {
          name = "llm";
          runtimeInputs = [ llmPkg ];
          text = ''
            ${loadSecretsLib}
            # The llm-* plugins read these names; llm itself has no key store
            # configured here. Not required — `llm` has plenty of subcommands
            # (aliases, logs, models) that need no credential at all, and the
            # activation script below calls one of them.
            load_from_secret OPENROUTER_API_KEY  openrouter_api_key
            load_from_secret LLM_OPENROUTER_KEY  openrouter_api_key
            load_from_secret OPENROUTER_KEY      openrouter_api_key
            load_from_secret LLM_GEMINI_KEY      gemini_api_key
            load_from_secret GEMINI_API_KEY      gemini_api_key
            load_from_secret LLM_GROQ_KEY        groq_api_key
            load_from_secret GROQ_API_KEY        groq_api_key
            load_from_secret OPENAI_API_KEY      openai_api_key
            exec llm "$@"
          '';
        })
        # Prebuilt release binary rather than llm-agents/nixpkgs: both of those
        # build the pnpm dashboard, whose deps FOD resolves time-dependently
        # (pnpm minimumReleaseAge) and so drifts off its pinned hash. See
        # modules/agent-browser.nix.
        pkgs.agent-browser
        llm-agents.ccusage
        pkgs.tmux # required by the tmux skill for headless interactive sessions

        (pkgs.writeShellApplication {
          name = "+agent-claude";
          runtimeInputs = [ llm-agents.claude-agent-acp ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              export CLAUDE_CODE_EXECUTABLE="/etc/profiles/per-user/''${USER}/bin/claude"
              shift
              exec claude-agent-acp --thinking-display summarized "$@"
            fi
            # Enables Claude Code's full-screen TUI mode
            # (https://code.claude.com/docs/en/fullscreen). The name CLAUDE_CODE_NO_FLICKER
            # is misleading: it unlocks the full-screen TUI, not merely "no flicker".
            # Interactive mode only — intentionally NOT set for ACP.
            export CLAUDE_CODE_NO_FLICKER=1
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
