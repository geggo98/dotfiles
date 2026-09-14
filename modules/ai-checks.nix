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
        (noAgents mcpOnly.config && noAgentWrappers mcpOnly.config)
        (!(mcpOnly.config.home.file ? ".claude/settings.json"))
        (!(mcpOnly.config.home.activation ? codexConfig))
        (noAgents contentOnly.config && noAgentWrappers contentOnly.config && noMcpWrappers contentOnly.config)
        (contentOnly.config.xdg.configFile ? "ai/content/skills")
        (!(contentOnly.config.home.file ? ".agents/skills"))
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
          python3 tests/test_codex_config.py
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
