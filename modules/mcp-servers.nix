{ inputs, ... }:
let
  llm-agents-pkgs = system: inputs.nixpkgs-llm-agents.packages.${system};

  mkMcpServersModule = { pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = llm-agents-pkgs pkgs.stdenv.hostPlatform.system;
      dockerPkg = if builtins.hasAttr "docker-client" pkgs then pkgs."docker-client" else pkgs.docker;

      loadSecretsLib = builtins.readFile ./_files/shell/load-secrets.sh;

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
            -e "ENABLED_TOOLS=jira_get_issue,jira_get_sprint_issues,jira_search,jira_transition_issue,jira_add_comment,confluence_get_page,confluence_get_page_children,confluence_get_labels,confluence_search"
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
          exec npx -y @upstash/context7-mcp@v1.0.30 --api-key "''${CONTEXT7_API_KEY}"
        '';
      });

      mcp-javadocs = (pkgs.writeShellApplication {
        name = "+mcp-javadocs";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          exec npx -y mcp-remote@0.1.38 https://www.javadocs.dev/mcp
        '';
      });

      mcp-nixos = (pkgs.writeShellApplication {
        name = "+mcp-nixos";
        runtimeInputs = [ unstable.mcp-nixos ];
        text = ''
          exec mcp-nixos "$@"
        '';
      });

      mcp-travily = (pkgs.writeShellApplication {
        name = "+mcp-travily";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret TRAVILY_API_KEY travily_api_key
          require_secrets TRAVILY_API_KEY
          exec npx -y mcp-remote@0.1.29 "https://mcp.tavily.com/mcp/?tavilyApiKey=''${TRAVILY_API_KEY}"
        '';
      });

      mcp-zai-search = (pkgs.writeShellApplication {
        name = "+mcp-zai-search";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret Z_AI_API_KEY z_ai_api_key
          require_secrets Z_AI_API_KEY
          exec npx -y mcp-remote@0.1.29 "https://api.z.ai/api/mcp/web_search_prime/mcp" "--header" "Authorization: Bearer ''${Z_AI_API_KEY}"
        '';
      });

      mcp-zai-vision = (pkgs.writeShellApplication {
        name = "+mcp-zai-vision";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret Z_AI_API_KEY z_ai_api_key
          require_secrets Z_AI_API_KEY
          export Z_AI_MODE=ZAI
          exec npx -y "@z_ai/mcp-server@0.1.2"
        '';
      });

      mcp-zai-web-reader = (pkgs.writeShellApplication {
        name = "+mcp-zai-web-reader";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret Z_AI_API_KEY z_ai_api_key
          require_secrets Z_AI_API_KEY
          exec npx -y mcp-remote@0.1.29 "https://api.z.ai/api/mcp/web_reader/mcp" "--header" "Authorization: Bearer ''${Z_AI_API_KEY}"
        '';
      });

      agent-claude-api-key-helper = (pkgs.writeShellApplication {
        name = "+agent-claude-apiKeyHelper";
        runtimeInputs = [ ];
        text = ''
          ${loadSecretsLib}
          load_from_secret CLAUDE_API_KEY z_ai_api_key
          require_secrets CLAUDE_API_KEY
          echo -n "''${CLAUDE_API_KEY}"
        '';
      });

      devenvPkg = inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv;

      mcp-devenv = (pkgs.writeShellApplication {
        name = "+mcp-devenv";
        runtimeInputs = [ devenvPkg ];
        text = ''
          exec devenv mcp "$@"
        '';
      });

      # Single source of truth for which MCP servers exist and which
      # package provides each one. Each agent (claude-code, opencode,
      # codex) consumes this through a small mapping function below.
      mcpServerPkgs = {
        atlassian = mcp-atlassian;
        context7 = mcp-context7;
        devenv = mcp-devenv;
        javadocs = mcp-javadocs;
        nixos = mcp-nixos;
        travily = mcp-travily;
        zai-search = mcp-zai-search;
        zai-vision = mcp-zai-vision;
        zai-web-reader = mcp-zai-web-reader;
      };

      mcpCmd = name: pkg: "${pkg}/bin/+mcp-${name}";

      claudeMcpServers = lib.mapAttrs
        (name: pkg: {
          type = "stdio";
          command = mcpCmd name pkg;
          args = [ ];
        })
        mcpServerPkgs;

      opencodeMcpServers = lib.mapAttrs
        (name: pkg: {
          type = "local";
          command = [ (mcpCmd name pkg) ];
          enabled = true;
        })
        mcpServerPkgs;

      codexMcpServers = lib.mapAttrs
        (name: pkg: {
          command = mcpCmd name pkg;
          args = [ ];
        })
        mcpServerPkgs;

      root = ./..;
    in
    {
      programs.claude-code = {
        enable = true;
        package = llm-agents.claude-code;
        settings = {
          enabledPlugins = {
            "jdtls-lsp@claude-plugins-official" = true;
            "lua-lsp@claude-plugins-official" = true;
            "pyright-lsp@claude-plugins-official" = true;
            "rust-analyzer-lsp@claude-plugins-official" = true;
            "gopls-lsp@claude-plugins-official" = true;
            "pr-review-toolkit@claude-plugins-official" = true;
            "typescript-lsp@claude-plugins-official" = true;
            "frontend-design@claude-plugins-official" = true;
            "code-review@claude-plugins-official" = true;
            "commit-commands@claude-plugins-official" = true;
          };
          permissions = {
            defaultMode = "auto";
          };
          skipAutoPermissionPrompt = true;
          skipDangerousModePermissionPrompt = true;
          statusLine = {
            type = "command";
            command = "sh ~/.claude/statusline-command.sh";
          };
        };
        mcpServers = claudeMcpServers;
        skillsDir = ./ai/_files/skills;
      };

      programs.opencode = {
        enable = true;
        package = llm-agents.opencode;
        settings = {
          autoupdate = false;
          mcp = opencodeMcpServers;
        };
        rules = root + "/AGENTS.md";
      };

      programs.codex = {
        enable = true;
        package = llm-agents.codex;
        settings = {
          mcp_servers = codexMcpServers;
        };
      };

      home.packages = lib.attrValues mcpServerPkgs;

      home.file.".claude/statusline-command.sh" = {
        source = ./ai/_files/statusline-command.sh;
      };

      home.file.".agents/skills" = {
        source = ./ai/_files/skills;
        recursive = true;
      };
    };
in
{
  flake.modules.homeManager.mcp-servers = mkMcpServersModule;
}
