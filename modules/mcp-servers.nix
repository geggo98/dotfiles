{ inputs, config, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
in
{
  flake.modules.homeManager.mcp-servers = { config, pkgs, lib, ... }:
    let
      dockerPkg = if builtins.hasAttr "docker-client" pkgs then pkgs."docker-client" else pkgs.docker;

      loadSecretsLib = builtins.readFile ./_files/shell/load-secrets.sh;

      # Pinned NPM versions for `npx -y <pkg>@<ver>` wrappers. Picks
      # must be at least 14 days old (matches the cooldown enforced by
      # supply-chain-hardening.nix for unpinned installs) and account
      # for known-bad versions. mcp-remote < 0.1.38 has runtime
      # regressions and supply-chain risk and must not be used.
      npmVersions = {
        mcp-remote = "0.1.38";
        context7-mcp = "3.2.1";
      };

      mcp-atlassian = (pkgs.writeShellApplication {
        name = "+mcp-atlassian";
        runtimeInputs = [ dockerPkg ];
        text = ''
          ${loadSecretsLib}
          load_from_secret CONFLUENCE_URL            confluence_url
          load_from_secret CONFLUENCE_USERNAME       confluence_username
          load_from_secret CONFLUENCE_PERSONAL_TOKEN confluence_personal_token
          load_from_secret JIRA_URL                  jira_url
          load_from_secret JIRA_USERNAME             jira_username
          load_from_secret JIRA_API_TOKEN            jira_api_token
          require_secrets \
            CONFLUENCE_URL CONFLUENCE_USERNAME CONFLUENCE_PERSONAL_TOKEN \
            JIRA_URL JIRA_USERNAME JIRA_API_TOKEN
          IMAGE="''${MCP_ATLASSIAN_IMAGE:-ghcr.io/sooperset/mcp-atlassian:latest}"
          args=(
            run -i --rm
            -e CONFLUENCE_URL
            -e CONFLUENCE_USERNAME
            -e CONFLUENCE_PERSONAL_TOKEN
            -e JIRA_URL
            -e JIRA_USERNAME
            -e JIRA_API_TOKEN
            -e "ENABLED_TOOLS=jira_get_issue,jira_get_sprint_issues,jira_search,jira_create_issue,jira_update_issue,jira_transition_issue,jira_add_comment,confluence_get_page,confluence_get_page_children,confluence_get_labels,confluence_search"
            -e "JIRA_PROJECTS_FILTER=VUKFZIF,VUKFZOPS,VUKFZCORE"
            "$IMAGE"
          )
          exec docker "''${args[@]}" "$@"
        '';
      });

      mcp-context7 = (pkgs.writeShellApplication {
        name = "+mcp-context7";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret CONTEXT7_API_KEY context7_api_key
          require_secrets CONTEXT7_API_KEY
          # No --api-key: the server falls back to the variable itself
          # (dist/index.js in 3.2.1: `cliOptions.apiKey || process.env.CONTEXT7_API_KEY`),
          # and an argument would put the key into `ps -Ao args` for every
          # process of this user.
          # Argv-free since 2026-09-11.
          exec npx -y "@upstash/context7-mcp@${npmVersions.context7-mcp}"
        '';
      });

      mcp-javadocs = (pkgs.writeShellApplication {
        name = "+mcp-javadocs";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          exec npx -y "mcp-remote@${npmVersions.mcp-remote}" https://www.javadocs.dev/mcp
        '';
      });

      mcp-travily = (pkgs.writeShellApplication {
        name = "+mcp-travily";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret TRAVILY_API_KEY travily_api_key
          require_secrets TRAVILY_API_KEY
          # The key travels as a header VARIABLE, never as a value in argv.
          # mcp-remote expands `''${VAR}` inside header values from its own
          # environment (0.1.38, dist/chunk-65X3S4HB.js:20851:
          # `value.replace(/\$\{([^}]+)}/g, … process.env[envVarName])`), and
          # load_from_secret has exported the variable already. Its log names
          # the pattern, never the value. Until 2026-09-11 the key sat in the
          # URL (`?tavilyApiKey=…`), which `ps -Ao args` printed to every
          # process of this user.
          # What ps shows now is the literal `''${TRAVILY_API_KEY}`. The Bearer
          # form is the one claude has used at this endpoint since 2026-09-10.
          # SC2016 is the point: the single quotes keep bash from expanding it.
          # shellcheck disable=SC2016
          exec npx -y "mcp-remote@${npmVersions.mcp-remote}" "https://mcp.tavily.com/mcp/" \
            --header 'Authorization: Bearer ''${TRAVILY_API_KEY}'
        '';
      });

      devenvPkg = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;

      # Requires devenv.nix in the working directory. Otherwise the MCP server
      # exits during startup and clients may report it as failed.
      # Example error: File devenv.nix does not exist.
      mcp-devenv = (pkgs.writeShellApplication {
        name = "+mcp-devenv";
        runtimeInputs = [ devenvPkg ];
        text = ''
          exec devenv mcp "$@"
        '';
      });

      # THE single source of truth. One entry per MCP server.
      #
      #   stdio   the +mcp-<name> writeShellApplication. It is what lands on
      #           PATH, and it is the fallback transport for every agent that
      #           cannot (yet) speak remote.
      #
      #   remote  present only where the SAME server is reachable as a
      #           streamable HTTP MCP endpoint. Measured 2026-09-10 by POSTing
      #           `initialize` (protocol 2025-06-18) at each one.
      #     .url   the endpoint
      #     .auth  null                               -- no credential needed
      #            { kind = "bearer"; secret; var; }  -- Authorization: Bearer
      #
      # NOTE WHAT THIS SHAPE CANNOT EXPRESS: a credential VALUE. `secret` is a
      # sops-nix FILE NAME under $XDG_CONFIG_HOME/sops-nix/secrets, read at
      # runtime; `var` is the env var it is loaded into. There is no field a
      # secret can be written into, so no client renderer can leak one into
      # /nix/store even by mistake. That is the point of the shape.
      #
      catalog = {
        context7 = {
          stdio = mcp-context7;
          remote = {
            url = "https://mcp.context7.com/mcp";
            auth = { kind = "bearer"; secret = "context7_api_key"; var = "CONTEXT7_API_KEY"; };
          };
        };
        devenv = {
          stdio = mcp-devenv;
          # Temporary: https://github.com/cachix/devenv/issues/3065
          # Keep the wrapper for later reactivation; the skill uses direct CLI calls.
          # Set my.ai.mcp.servers.devenv.enable = true once the fix is verified.
          enable = lib.mkDefault false;
        };
        # Complemented, not replaced, by modules/devdocs.nix's offline
        # `+devdocs` (openjdk~25 plus Kotlin/Groovy/Scala/Spring
        # Boot/Clojure among its 39 docs): this MCP is the only source for
        # an arbitrary third-party Maven artifact's javadoc, which devdocs
        # cannot serve at all. It also fails/times out repeatedly in
        # practice (the reason devdocs.nix exists), and the `devdocs` skill
        # tells an agent to try +devdocs first for anything the JDK itself
        # covers. Revisit removing this entry only if DevDocs' openjdk
        # coverage is verified sufficient for the symbols people actually
        # ask about AND a replacement source for third-party GAV coordinates
        # exists -- until then this stays, the same self-removing-comment
        # style as the pin assertions in modules/agents.nix.
        javadocs = {
          stdio = mcp-javadocs;
          remote = { url = "https://www.javadocs.dev/mcp"; auth = null; };
        };
        travily = {
          stdio = mcp-travily;
          # kind = "bearer", NOT the ?tavilyApiKey= query parameter the stdio
          # wrapper uses: measured 2026-09-10, tavily answers 200 to an
          # Authorization: Bearer header and 401 to no auth at all. That is the
          # difference between a key that can live in a headersHelper and a key
          # that would have to be baked into a URL in /nix/store.
          remote = {
            url = "https://mcp.tavily.com/mcp/";
            auth = { kind = "bearer"; secret = "travily_api_key"; var = "TRAVILY_API_KEY"; };
          };
        };
      } // lib.optionalAttrs config.my.ai.atlassian.enable { atlassian = { stdio = mcp-atlassian; }; };

    in
    {
      imports = [ aiOptions ];
      config = lib.mkIf config.my.ai.mcp.enable {
        my.ai.mcp.servers = catalog;
        home.packages = map (s: s.stdio) (lib.attrValues config.my.ai.mcp.servers);
      };
    };
}
