{ inputs, ... }:
{
  flake.modules.homeManager.ai-tools = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = inputs.nixpkgs-llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
      # The nixos queries as a CLI instead of an MCP server, since 2026-09-10.
      #
      # mcp-nixos is a stateless aggregator over public HTTP APIs
      # (search.nixos.org, NixHub, FlakeHub, Noogle, wiki, nix.dev). Run as an
      # MCP server it held one resident process per agent session — measured
      # 15,2 MiB in each of nine concurrent Claude sessions — and computed
      # nothing in between. As a CLI it costs nothing between calls.
      #
      # nixos-cli.py reimplements NOTHING: mcp_nixos.server.nix and
      # .nix_versions are FastMCP tool objects whose coroutine is reachable at
      # `.fn`, so the CLI parses arguments and calls upstream. That keeps ~3300
      # lines of data-source logic upstream where it belongs — and makes this a
      # dependency on an INTERNAL API. The smoke test in the skill's tests/ is
      # what turns an upstream rename into a build failure instead of a runtime
      # one.
      #
      # Reuse the interpreter and sys.path bootstrap that mcp-nixos's OWN
      # entrypoint already carries, rather than building a python env around it.
      #
      # The obvious `python3.withPackages [ (toPythonModule mcp-nixos) ]` was
      # tried and rejected on measurement: mcp-nixos is a buildPythonApplication,
      # so converting it forces an UNCACHED source rebuild — test suite included,
      # minutes of it — of a package cache.nixos.org already serves as a signed
      # binary (verified: narinfo HTTP 200, `ultimate: false`). That cost would
      # recur on both Macs at every nixpkgs-unstable bump, for nothing.
      #
      # The `case` guard is what keeps this honest: if a future mcp-nixos stops
      # putting its bootstrap on line 3, the BUILD fails with a message naming
      # the cause, instead of shipping a +nix-query that cannot import anything.
      nixos-cli = pkgs.runCommand "+nix-query" { } ''
        src=${unstable.mcp-nixos}/bin/.mcp-nixos-wrapped
        shebang=$(head -n1 "$src")
        bootstrap=$(sed -n '3p' "$src")
        case "$bootstrap" in
          *addsitedir*) ;;
          *) echo "mcp-nixos entrypoint no longer carries its sys.path bootstrap on line 3" >&2
             exit 1 ;;
        esac
        mkdir -p $out/bin
        {
          printf '%s\n' "$shebang" "$bootstrap"
          cat ${./ai/_files/mcp-nixos/nixos-cli.py}
        } > $out/bin/+nix-query
        chmod +x $out/bin/+nix-query
      '';

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

        nixos-cli
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
