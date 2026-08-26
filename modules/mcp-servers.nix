{ inputs, ... }:
let
  llm-agents-pkgs = system: inputs.nixpkgs-llm-agents.packages.${system};

  mkMcpServersModule = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = llm-agents-pkgs pkgs.stdenv.hostPlatform.system;
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
        zai-mcp-server = "0.1.4";
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
          exec npx -y "@upstash/context7-mcp@${npmVersions.context7-mcp}" --api-key "''${CONTEXT7_API_KEY}"
        '';
      });

      mcp-javadocs = (pkgs.writeShellApplication {
        name = "+mcp-javadocs";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          exec npx -y "mcp-remote@${npmVersions.mcp-remote}" https://www.javadocs.dev/mcp
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
          exec npx -y "mcp-remote@${npmVersions.mcp-remote}" "https://mcp.tavily.com/mcp/?tavilyApiKey=''${TRAVILY_API_KEY}"
        '';
      });

      mcp-zai-search = (pkgs.writeShellApplication {
        name = "+mcp-zai-search";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret Z_AI_API_KEY z_ai_api_key
          require_secrets Z_AI_API_KEY
          exec npx -y "mcp-remote@${npmVersions.mcp-remote}" "https://api.z.ai/api/mcp/web_search_prime/mcp" "--header" "Authorization: Bearer ''${Z_AI_API_KEY}"
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
          exec npx -y "@z_ai/mcp-server@${npmVersions.zai-mcp-server}"
        '';
      });

      mcp-zai-web-reader = (pkgs.writeShellApplication {
        name = "+mcp-zai-web-reader";
        runtimeInputs = [ pkgs.nodejs_24 ];
        text = ''
          ${loadSecretsLib}
          load_from_secret Z_AI_API_KEY z_ai_api_key
          require_secrets Z_AI_API_KEY
          exec npx -y "mcp-remote@${npmVersions.mcp-remote}" "https://api.z.ai/api/mcp/web_reader/mcp" "--header" "Authorization: Bearer ''${Z_AI_API_KEY}"
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

      # Whether this host gets the Atlassian integration at all.
      #
      # Declared as its own tiny module rather than an `options` key on the
      # block below: the moment that block gains an `options` or `config`
      # attribute, every one of its ~80 bare config lines has to move under
      # `config`. `imports` may sit beside bare config attributes; `options`
      # may not.
      #
      # Default off. +mcp-atlassian and the jira / bitbucket-pr skills all need
      # the jira_* / confluence_* secrets, and those are CHECK24 work
      # credentials that live on DKL6GDJ7X1 only (hosts/DKL6GDJ7X1/secrets.nix).
      # On the private Mac the server would appear in the client's list, start,
      # and die on `require_secrets` — worse than not being offered. `bb` is
      # already DKL-only via homeManager.bitbucket-cli, so bitbucket-pr had no
      # working CLI there either.
      #
      # This is the HOST gate. Which *agents* see a server is a separate
      # question, answered by claudeMcpExclude below.
      atlassianOptions = { lib, ... }: {
        options.my.ai.atlassian.enable = lib.mkEnableOption
          "the Atlassian integration — the +mcp-atlassian server plus the jira and bitbucket-pr skills";
      };

      atlassian = config.my.ai.atlassian.enable;

      skillsSrc = ./ai/_files/skills;

      # Filtered at eval time, not in a runCommand: no extra derivation, and
      # with the option on, the path is handed through untouched, so the work
      # host's store path does not move at all.
      #
      # `builtins.path`, NOT `lib.cleanSourceWith`. The latter returns an
      # ATTRSET carrying `outPath`, while `programs.claude-code.skills` wants a
      # path — handed the attrset, the module system descends into its
      # attributes and fails with `A definition for option
      # ...claude-code.skills._isLibCleanSourceWith is not of type ...`, which
      # names the wrapper's marker attribute rather than the mistake.
      # builtins.path returns a real store path and takes the same filter.
      skillsDir =
        if atlassian then skillsSrc
        else
          builtins.path {
            name = "claude-skills";
            path = skillsSrc;
            filter = path: type:
              let rel = lib.removePrefix (toString skillsSrc + "/") (toString path);
              in !(type == "directory" && builtins.elem rel [ "jira" "bitbucket-pr" ]);
          };

      # Single source of truth for which MCP servers exist and which
      # package provides each one. Each agent (claude-code, opencode,
      # codex) consumes this through a small mapping function below.
      # `atlassian` is the only conditional entry — see atlassianOptions above.
      #
      # This attrset feeds FOUR sinks: the claude-code, opencode and codex
      # configs plus home.packages below. Dropping an entry here therefore also
      # takes `+mcp-atlassian` off PATH, which is not what we want — to hide a
      # server from ONE agent, use that agent's own list (claudeMcpExclude).
      mcpServerPkgs = {
        context7 = mcp-context7;
        devenv = mcp-devenv;
        javadocs = mcp-javadocs;
        nixos = mcp-nixos;
        travily = mcp-travily;
        zai-search = mcp-zai-search;
        zai-vision = mcp-zai-vision;
        zai-web-reader = mcp-zai-web-reader;
      } // lib.optionalAttrs atlassian { atlassian = mcp-atlassian; };

      mcpCmd = name: pkg: "${pkg}/bin/+mcp-${name}";

      # Servers CLAUDE does not get. Every other consumer of mcpServerPkgs is
      # unaffected: opencode and codex keep them, and `+mcp-atlassian` stays on
      # PATH for use by hand. Empty this list to hand a server back.
      #
      # atlassian, since 2026-08-25: the `jira` and `bitbucket-pr` skills cover
      # the same ground with a narrower, testable client that Claude already
      # reaches for, so the server was pure duplication here — and it cost one
      # `docker run` per session. `--rm` only fires on a clean exit, so every
      # killed session left its container behind and they accumulated.
      #
      # devenv, since 2026-08-26 — TEMPORARY, remove once upstream is fixed:
      # cachix/devenv#3065, "devenv mcp holds ~4 GiB per process for the
      # lifetime of the process, and ignores SIGTERM" (open as of this date;
      # reported on Linux, observed here on macOS too). It is a fixed
      # initialisation cost rather than growth — ~4 GiB whether the process has
      # run 2 h or 8 h — and because SIGTERM is ignored, each one outlives the
      # session that started it, so they accumulate. Claude starts one in EVERY
      # session, which is why it bites here first.
      #
      # Do not go looking for this in RSS: the report measures ~600 KiB
      # resident against 4.1–4.3 GiB of swap. The same idle server is already on
      # record in nix-tarball-cache-repack.nix holding 1815 open handles into
      # the tarball cache.
      #
      # To hand it back when the issue closes: delete "devenv" below. Nothing
      # else changes — opencode and codex keep the server either way, and
      # `+mcp-devenv` stays on PATH.
      #
      # home-manager renders programs.claude-code.mcpServers into a generated
      # plugin (`claude-code-home-manager`, passed as --plugin-dir), so this
      # one list governs BOTH the MCP entry and the plugin-provided tools —
      # they are the same mechanism, not two switches.
      claudeMcpExclude = [ "atlassian" "devenv" ];

      claudeMcpServers = lib.mapAttrs
        (name: pkg: {
          type = "stdio";
          command = mcpCmd name pkg;
          args = [ ];
        })
        (builtins.removeAttrs mcpServerPkgs claudeMcpExclude);

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
      imports = [ atlassianOptions ];

      programs.claude-code = {
        enable = true;
        package = llm-agents.claude-code;
        settings = {
          # Suppress the automatic "Co-Authored-By: Claude" byline in commits/PRs.
          includeCoAuthoredBy = false;
          # Default every session to "ultracode": xhigh reasoning effort + standing
          # dynamic-workflow orchestration. `ultracode` is a real persisted settings
          # key in claude-code (the resolver maps `settings.ultracode === true` to
          # xhigh effort and turns on standing workflow orchestration). It requires
          # workflows enabled and an xhigh-capable model (Opus 4.8 etc.). The
          # interactive `/effort` slider never writes this; a settings file does.
          # Set `enableWorkflows` explicitly since ultracode depends on it.
          ultracode = true;
          enableWorkflows = true;
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
        skills = skillsDir;
      };

      programs.opencode = {
        enable = true;
        package = llm-agents.opencode;
        settings = {
          autoupdate = false;
          mcp = opencodeMcpServers;
        };
        context = root + "/AGENTS.md";
      };

      # No `programs.codex.settings` here: that would materialize
      # ~/.codex/config.toml as a read-only nix-store symlink, but Codex
      # must write to it (directory trust, model choice via
      # config/batchWrite). The managed part is merged into a regular
      # writable file by the `codexConfig` activation script below.
      programs.codex = {
        enable = true;
        package = llm-agents.codex;
      };

      home.activation.codexConfig =
        let
          managedSettings = (pkgs.formats.toml { }).generate "codex-managed-settings" {
            mcp_servers = codexMcpServers;
          };
          python = pkgs.python3.withPackages (ps: [ ps.tomli-w ]);
        in
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${python}/bin/python3 ${./ai/_files/codex-merge-config.py} \
            ${managedSettings} "$HOME/.codex/config.toml"
        '';

      home.packages = lib.attrValues mcpServerPkgs;

      home.file.".claude/statusline-command.sh" = {
        source = ./ai/_files/statusline-command.sh;
      };

      home.file.".agents/skills" = {
        source = skillsDir;
        recursive = true;
      };
    };
in
{
  flake.modules.homeManager.mcp-servers = mkMcpServersModule;
}
