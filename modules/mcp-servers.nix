{ inputs, ... }:
let
  llm-agents-pkgs = system: inputs.nixpkgs-llm-agents.packages.${system};

  # TEMPORARY claude-code pin, 2.1.258 — the full reasoning is at the
  # llm-agents-claude-code-pin input in flake.nix. Only claude-code comes from
  # that input; opencode and codex below stay on nixpkgs-llm-agents.
  #
  # The version string and the rev in flake.nix belong together; the first
  # assertion below is what keeps them together.
  claude-code-pin-version = "2.1.258";
  claude-code-pinned = system:
    inputs.llm-agents-claude-code-pin.packages.${system}.claude-code;

  mkMcpServersModule = { config, pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      llm-agents = llm-agents-pkgs pkgs.stdenv.hostPlatform.system;
      claude-code = claude-code-pinned pkgs.stdenv.hostPlatform.system;
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
      # secret can be written into, so no renderer below can leak one into
      # /nix/store even by mistake. That is the point of the shape.
      #
      # This attrset feeds FOUR sinks: the claude-code, opencode and codex
      # configs plus home.packages below. Dropping an entry here therefore also
      # takes `+mcp-<name>` off PATH, which is usually not what you want — to
      # hide a server from ONE agent, use that agent's own list
      # (claudeMcpExclude).
      mcpServers = {
        context7 = {
          stdio = mcp-context7;
          remote = {
            url = "https://mcp.context7.com/mcp";
            auth = { kind = "bearer"; secret = "context7_api_key"; var = "CONTEXT7_API_KEY"; };
          };
        };
        devenv = { stdio = mcp-devenv; };
        javadocs = {
          stdio = mcp-javadocs;
          remote = { url = "https://www.javadocs.dev/mcp"; auth = null; };
        };
        nixos = { stdio = mcp-nixos; };
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
      } // lib.optionalAttrs atlassian { atlassian = { stdio = mcp-atlassian; }; };

      # REMOVED 2026-09-10: zai-search, zai-vision, zai-web-reader.
      #
      # Two reasons, and the first is the one that matters. All three passed
      # the key on the COMMAND LINE (`--header "Authorization: Bearer $KEY"`,
      # and zai-vision via its env), so a plain `ps -Ao args` printed the z.ai
      # token in clear text to every process of this user. That is the same
      # class the vault rule documents, and it cannot be fixed by moving the
      # server — only by removing it or by giving it a header helper.
      #
      # Second: nothing referenced them. No skill in modules/ai/_files/skills
      # mentions zai-search, zai-vision or zai-web-reader, and web-research
      # deliberately routes through its own gemini/perplexity scripts instead.
      # They cost 6 processes and 236 MiB per Claude session for that.
      #
      # z_ai_api_key itself STAYS: modules/ai-tools.nix and the
      # CLAUDE_API_KEY helper above still read it. Do not clean it up with them.
      #
      # zai-vision was the only one with no remote MCP endpoint (probed: every
      # api.z.ai/api/mcp/<vision-ish>/mcp path returns 404), so re-adding it
      # would mean re-adding a local node process. If the vision tools are ever
      # wanted back, write a skill CLI like grafana/jira — a CLI reads local
      # image files more naturally than an MCP server does anyway.

      mcpCmd = name: pkg: "${pkg}/bin/+mcp-${name}";

      # Claude runs this at CONNECTION time and parses stdout as a JSON object
      # of headers.
      #
      # It reads the sops FILE rather than an env var, and that is load-bearing
      # rather than stylistic: claude-code runs headersHelpers from plugin
      # sources with scrubCredentialEnv, so an inherited $TRAVILY_API_KEY would
      # arrive EMPTY and we would ship an empty Bearer token — a 401 with no
      # visible cause. Do not "simplify" this to read the variable.
      #
      # jq, not printf: a key containing " or \\ would otherwise produce invalid
      # JSON. require_secrets exiting non-zero is deliberate — claude then fails
      # the connection loudly instead of connecting anonymously.
      mkHeadersHelper = name: auth: (pkgs.writeShellApplication {
        name = "+mcp-headers-${name}";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          ${loadSecretsLib}
          load_from_secret ${auth.var} ${auth.secret}
          require_secrets ${auth.var}
          jq -n --arg v "''${${auth.var}}" '{ Authorization: ("Bearer " + $v) }'
        '';
      });

      # Deliberately NOT in home.packages: these print credentials. Same reason
      # agent-claude-api-key-helper is not on PATH.
      headersHelpers = lib.mapAttrs (name: s: mkHeadersHelper name s.remote.auth)
        (lib.filterAttrs (_: s: s ? remote && s.remote.auth != null) mcpServers);

      headersHelperCmd = name: "${headersHelpers.${name}}/bin/+mcp-headers-${name}";

      # Servers CLAUDE does not get. Every other consumer of mcpServers is
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

      # ONE row per consuming agent. Everything agent-specific lives here and
      # nowhere else, so adding antigravity later is this row plus one
      # `renderFor` call at its config site — not a fifth copy of the mapping.
      #
      #   remote     may this agent use the remote transport at all? Flipping
      #              one of these to true is the whole migration for that agent.
      #   authKinds  which auth kinds it can carry. A server whose auth kind is
      #              not listed falls back to stdio for that agent rather than
      #              silently connecting unauthenticated.
      #
      # Transport support, each verified against the INSTALLED binary on
      # 2026-09-10, not taken from documentation:
      #   claude-code 2.1.258  type/url/headers/headersHelper — bundle grep,
      #                        counted against control tokens first so a
      #                        vacuous zero could not pass as an answer.
      #   codex 0.147.0        url + bearer_token_env_var — `codex mcp add
      #                        --url … --bearer-token-env-var …` into a
      #                        throwaway CODEX_HOME, then read config.toml.
      #   opencode 1.18.18     type="remote" + url + headers — but whether
      #                        {file:…} substitutes INSIDE a nested header
      #                        string is UNVERIFIED, so it stays on stdio.
      authKind = r: if r.auth == null then "none" else r.auth.kind;

      # Built from xdg.configHome, NOT from config.sops.secrets.<n>.path.
      # Dereferencing sops.secrets is an EVAL error on a host that does not
      # declare the secret (AGENTS.md, "Watch for Nix-side references"), and
      # this module reaches both workstations.
      secretFile = n: "${config.xdg.configHome}/sops-nix/secrets/${n}";

      agents = {
        claude = {
          # Remote since 2026-09-10. This is the change that removes the MCP
          # processes: claude-code connects http servers LAZILY, on first tool
          # use, while stdio servers are started at session start. Measured
          # before: 13 processes / 491 MiB per session, none of them computing
          # (0,5-1,5 s CPU over 53 min) — `npx -y` keeps an `npm exec` node VM
          # alive next to every server, so each one cost two processes.
          #
          # Do NOT set alwaysLoad to make failures surface at startup again: it
          # also opts the server out of tool-schema deferral, putting every tool
          # schema into each turn's context. `just mcp-check` is the startup
          # check instead.
          remote = true;
          exclude = claudeMcpExclude;
          authKinds = [ "none" "bearer" ];
          mkRemote = name: r: { type = "http"; url = r.url; }
            // lib.optionalAttrs (r.auth != null) { headersHelper = headersHelperCmd name; };
          mkStdio = name: pkg: { type = "stdio"; command = mcpCmd name pkg; args = [ ]; };
        };

        opencode = {
          # false until the {file:…}-inside-a-header question above is settled.
          # mkRemote is already written and already correct; this word is the
          # whole switch.
          remote = false;
          exclude = [ ];
          authKinds = [ "none" "bearer" ];
          mkRemote = _: r: { type = "remote"; url = r.url; enabled = true; }
            // lib.optionalAttrs (r.auth != null) {
            headers.Authorization = "Bearer {file:${secretFile r.auth.secret}}";
          };
          mkStdio = name: pkg: { type = "local"; command = [ (mcpCmd name pkg) ]; enabled = true; };
        };

        codex = {
          remote = false;
          exclude = [ ];
          authKinds = [ "none" "bearer" ];
          mkRemote = _: r: { url = r.url; }
            // lib.optionalAttrs (r.auth != null) { bearer_token_env_var = r.auth.var; };
          mkStdio = name: pkg: { command = mcpCmd name pkg; args = [ ]; };
        };
      };

      renderFor = agent:
        let
          visible = builtins.removeAttrs mcpServers agent.exclude;
          useRemote = s: agent.remote && s ? remote
            && builtins.elem (authKind s.remote) agent.authKinds;
        in
        lib.mapAttrs
          (name: s: if useRemote s then agent.mkRemote name s.remote else agent.mkStdio name s.stdio)
          visible;

      claudeMcpServers = renderFor agents.claude;
      opencodeMcpServers = renderFor agents.opencode;
      codexMcpServers = renderFor agents.codex;

    in
    {
      imports = [ atlassianOptions ];

      # Both of these exist so the TEMPORARY claude-code pin (flake.nix, input
      # llm-agents-claude-code-pin) cannot fail quietly. A pin that outlives its
      # reason, or drifts away from the version everything documents, is the
      # failure class this repo keeps paying for elsewhere.
      assertions = [
        {
          # Tripwire against silent drift: bump the rev in flake.nix without
          # bumping the version here and you would get a different version than
          # the one flake.nix, this file and scripts/supply-chain.toml all name.
          assertion = claude-code.version == claude-code-pin-version;
          message = ''
            llm-agents-claude-code-pin ships claude-code ${claude-code.version},
            expected ${claude-code-pin-version}. The rev in flake.nix and this
            version string belong together -- one was moved without the other.
          '';
        }
        {
          # The pin removes itself instead of standing there forever.
          assertion = lib.versionOlder
            llm-agents.claude-code.version
            claude-code-pin-version;
          message = ''
            nixpkgs-llm-agents now ships claude-code
            ${llm-agents.claude-code.version} >= ${claude-code-pin-version}, so the
            pin has served its purpose. Remove it:
              1. drop the llm-agents-claude-code-pin input from flake.nix
              2. set `package = llm-agents.claude-code;` again below
              3. drop the "claude-code (pinned)" [[packages]] entry from
                 scripts/supply-chain.toml
              4. drop these two assertions and the claude-code-pin-version /
                 claude-code-pinned bindings at the top of this file
          '';
        }
      ];

      programs.claude-code = {
        enable = true;
        package = claude-code;
        settings = {
          # No automatic attribution in commits or PRs.
          #
          # `attribution.commit = ""` replaces the deprecated `includeCoAuthoredBy`
          # ("Deprecated: Use attribution instead" in the settings schema). The two
          # are not additive: once `attribution` carries a `commit` or `pr` key,
          # MkS() stops consulting `includeCoAuthoredBy` altogether, because
          # pCs(e) = e.commit !== undefined || e.pr !== undefined. Leaving the old
          # key beside this block would be dead config that still reads as if it did
          # something. Same outcome either way: fCs(...) === "disabled".
          #
          # `sessionUrl = false` drops the "Claude-Session: https://claude.ai/code/..."
          # trailer and the matching link in PR bodies (anthropics/claude-code#77830).
          # That URL points straight at the account's session, so it is personal data
          # and has no business in the history of a public repository.
          #
          # Measured against claude-code 2.1.233, read out of the bundle:
          #   qMa(): if (env.CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION) return null;
          #          if (settings().attribution?.sessionUrl === false) return null;
          #   Ipt(): let e = MkS(), t = qMa(); if (!t) return e; return DkS(e, t.url)
          # One function feeds both the trailer and the "End git commit messages with"
          # line in the Bash tool's system prompt, so this removes the instruction as
          # well -- but only in sessions started after the switch. The issue reports
          # the key as ineffective; that was measured against an older version.
          #
          # The env var above is the equivalent gate and would work too. Deliberately
          # not set: one source per setting, as with every other credential path here.
          attribution = {
            commit = "";
            pr = "";
            sessionUrl = false;
          };
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

      # Every entry that still has a stdio wrapper. These stay on PATH even for
      # servers an agent reaches remotely: they are the fallback transport for
      # agents not yet migrated, and the way to tell "the endpoint is broken"
      # from "our config is broken" by hand.
      home.packages = lib.attrValues
        (lib.mapAttrs (_: s: s.stdio) (lib.filterAttrs (_: s: s ? stdio) mcpServers));

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
