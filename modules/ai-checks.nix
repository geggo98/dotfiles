{ config, inputs, lib, ... }:
let
  hm = config.flake.modules.homeManager;
in
{
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; config.allowUnfree = true; };
      python = pkgs.python3.withPackages (ps: [ ps.tomli-w ]);
      # Deliberately no workstation base, secrets, or agent package overlays.
      makeHome = aspects: settings: (inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = aspects ++ [{
          home.username = "example";
          home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/example" else "/home/example";
          home.stateVersion = "25.11";
          my.ai = settings;
        }];
      });
      allAspects = [ hm.agents hm.agent-content hm.mcp-servers hm.agent-integration hm.worktrunk ];
      allOff = makeHome allAspects { };
      agentsOnly = makeHome allAspects { agents.enable = true; };
      mcpOnly = makeHome [ hm.mcp-servers ] {
        mcp.enable = true;
        mcp.exports = [ "claude" "codex" "opencode" "antigravity" ];
      };
      devenvReenabled = makeHome [ hm.mcp-servers ] {
        mcp.enable = true;
        mcp.servers.devenv.enable = true;
      };
      contentOnly = makeHome [ hm.agent-content ] { content.enable = true; };
      full = makeHome allAspects {
        agents.enable = true;
        content.enable = true;
        mcp.enable = true;
        atlassian.enable = true;
      };
      withoutCodexMcp = makeHome allAspects {
        agents.enable = true;
        mcp.enable = true;
        mcp.clients.codex.enable = false;
      };
      withoutClaude = makeHome allAspects {
        agents.enable = true;
        agents.claude.enable = false;
        mcp.enable = true;
      };
      withoutCodex = makeHome allAspects {
        agents.enable = true;
        agents.codex.enable = false;
      };
      codexLeafHooks = pkgs.writeText "codex-leaf-hooks.json" (builtins.toJSON (
        map
          (home: {
            enabled = home.config.programs.codex.enable;
            hook = home.config.home.activation.codexConfig.data;
          }) [ agentsOnly withoutCodexMcp full allOff withoutCodex ]
      ));
      noAgents = c: !c.programs.claude-code.enable && !c.programs.codex.enable && !c.programs.opencode.enable;
      noMcp = c: c.programs.claude-code.mcpServers == { }
        && !(c.programs.opencode.settings ? mcp)
        && c.my.ai.agents.codex.environmentScript == ""
        && !(c.home.file ? ".gemini/config/plugins/nix-darwin/mcp_config.json");
      names = c: map lib.getName c.home.packages;
      noAgentWrappers = c: !(builtins.any (n: lib.hasPrefix "+agent-" n) (names c));
      noMcpWrappers = c: !(builtins.any (n: lib.hasPrefix "+mcp-" n) (names c));
      assertions = [
        (noAgents allOff.config && noAgentWrappers allOff.config && noMcpWrappers allOff.config)
        (noMcp allOff.config && noMcp agentsOnly.config && noMcpWrappers agentsOnly.config)
        (agentsOnly.config.programs.claude-code.settings.model == "opusplan")
        (agentsOnly.config.my.ai.agents.codex.model == "gpt-5.6-terra")
        (agentsOnly.config.my.ai.agents.codex.reasoningEffort == "medium")
        (agentsOnly.config.my.ai.agents.codex.planReasoningEffort == "xhigh")
        (noAgents mcpOnly.config && noAgentWrappers mcpOnly.config)
        (!(mcpOnly.config.home.file ? ".claude/settings.json"))
        (!(mcpOnly.config.home.activation ? codexConfig))
        (noAgents contentOnly.config && noAgentWrappers contentOnly.config && noMcpWrappers contentOnly.config)
        (contentOnly.config.xdg.configFile ? "ai/content/skills")
        (!(contentOnly.config.home.file ? ".agents/skills"))
        (builtins.all (client: !(client ? devenv)) (lib.attrValues full.config.my.ai.mcp.rendered))
        (builtins.all (client: client ? devenv) (lib.attrValues devenvReenabled.config.my.ai.mcp.rendered))
        (builtins.elem "+mcp-devenv" (names mcpOnly.config))
        (full.config.my.ai.mcp.rendered.claude ? context7)
        (!(full.config.my.ai.mcp.rendered.claude ? atlassian))
        (full.config.my.ai.mcp.rendered.codex ? atlassian)
        (full.config.my.ai.mcp.rendered.codex.context7.bearer_token_env_var == "CONTEXT7_API_KEY")
        (withoutCodexMcp.config.my.ai.agents.codex.environmentScript == "")
        (withoutCodexMcp.config.programs.claude-code.mcpServers ? context7)
        (!withoutClaude.config.programs.claude-code.enable)
        (!(builtins.elem "+agent-claude" (names withoutClaude.config)))
      ];
      # Real closure tests catch transitive agent/ACP dependencies, not only
      # packages directly installed by the aspect.
      mcpClosure = pkgs.closureInfo { rootPaths = [ mcpOnly.activationPackage ]; };
      disabledClosure = pkgs.closureInfo { rootPaths = [ allOff.activationPackage ]; };
      exports = mcpOnly.config.xdg.configFile;
      worktrunkWithoutClaude = withoutClaude.config.xdg.configFile."worktrunk/config.toml".source;
    in
    {
      checks.ai-composition =
        assert lib.assertMsg (builtins.all (x: x) assertions) "AI aspect composition invariant failed";
        pkgs.runCommand "ai-composition-check" { nativeBuildInputs = [ python pkgs.zsh pkgs.perl ]; } ''
          export PYTHONDONTWRITEBYTECODE=1
          cp -R ${./ai/_tests} tests
          mkdir -p _files
          cp ${./ai/_files/codex-merge-config.py} _files/codex-merge-config.py
          # The source tests use the same relative layout as the repository.
          cp ${./ai/_files/merge-rules-block} _files/merge-rules-block
          mkdir -p _files/skills/devenv/scripts
          cp ${./ai/_files/skills/devenv/scripts/devenv-tools.sh} _files/skills/devenv/scripts/devenv-tools.sh
          chmod +x _files/skills/devenv/scripts/devenv-tools.sh
          patchShebangs _files/skills/devenv/scripts/devenv-tools.sh
          python3 tests/test_devenv_tools.py
          python3 tests/test_codex_config.py
          python3 - ${codexLeafHooks} <<'PY'
          import json, re, sys, tomllib
          for case in json.load(open(sys.argv[1])):
              # Matches the generated /nix/store/...-codex-managed-settings argument.
              path = re.search(r"/nix/store/[^\s]+-codex-managed-settings", case["hook"])
              assert path, "managed settings missing from activation"
              with open(path.group(), "rb") as stream:
                  settings = tomllib.load(stream)
              items = settings.get("tui", {}).get("status_line")
              if case["enabled"]:
                  assert items == [
                      "run-state", "model-with-reasoning", "current-dir", "git-branch",
                      "context-used", "five-hour-limit", "weekly-limit", "branch-changes",
                      "task-progress", "thread-title",
                  ], items
                  assert settings.get("model") == "gpt-5.6-terra", settings.get("model")
                  assert settings.get("model_reasoning_effort") == "medium", settings.get("model_reasoning_effort")
                  assert settings.get("plan_mode_reasoning_effort") == "xhigh", settings.get("plan_mode_reasoning_effort")
              else:
                  assert items is None, items
                  assert settings.get("model") is None, settings.get("model")
                  assert settings.get("model_reasoning_effort") is None, settings.get("model_reasoning_effort")
                  assert settings.get("plan_mode_reasoning_effort") is None, settings.get("plan_mode_reasoning_effort")
          PY
          python3 tests/test_rules.py
          python3 ${./ai/_tests/check_exports.py} \
            ${exports."ai/mcp/claude.json".source} \
            ${exports."ai/mcp/codex.toml".source} \
            ${exports."ai/mcp/opencode.json".source} \
            ${exports."ai/mcp/antigravity.json".source} \
            ${worktrunkWithoutClaude} \
            ${mcpClosure}/store-paths ${disabledClosure}/store-paths
          touch "$out"
        '';
    };
}
