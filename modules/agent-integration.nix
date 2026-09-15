{ config, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
in
{
  flake.modules.homeManager.agent-integration = { config, pkgs, lib, ... }:
    let
      ai = config.my.ai;
      enabled = name: ai.agents.enable && ai.agents.${name}.enable;
      withContent = name: enabled name && ai.content.enable;
      withMcp = name: enabled name && ai.mcp.enable && ai.mcp.clients.${name}.enable;
      mcpFor = name: if withMcp name then ai.mcp.rendered.${name} else { };
      content = ai.content.artifacts;
      codexMcp = mcpFor "codex";
      python = pkgs.python3.withPackages (ps: [ ps.tomli-w ]);
      managedSettings = (pkgs.formats.toml { }).generate "codex-managed-settings" {
        mcp_servers = codexMcp;
        # Native Codex CLI fields, in display order. Activation is authoritative
        # for this leaf; /statusline edits last until the next activation.
        tui = lib.optionalAttrs (enabled "codex") {
          status_line = [
            "run-state"
            "model-with-reasoning"
            "current-dir"
            "git-branch"
            "context-used"
            "five-hour-limit"
            "weekly-limit"
            "branch-changes"
            "task-progress"
            "thread-title"
          ];
        };
      };
      ruleActivation = target: active:
        lib.hm.dag.entryAfter [ "writeBoundary" ] (
          if active then ''
            run ${pkgs.zsh}/bin/zsh ${./ai/_files/merge-rules-block} \
              ${content.rulesFile} "$HOME/${target}"
          '' else ''
            if [[ -f "$HOME/${target}" ]]; then
              run ${pkgs.zsh}/bin/zsh ${./ai/_files/merge-rules-block} --remove "$HOME/${target}"
            fi
          ''
        );
    in
    {
      imports = [ aiOptions ];
      programs.claude-code = {
        mcpServers = lib.mkIf (withMcp "claude") (mcpFor "claude");
        skills = lib.mkIf (withContent "claude") content.skillsDir;
        # Keep CLAUDE.md writable; personal rules live in a separate directory.
        rulesDir = lib.mkIf (withContent "claude") content.rulesDir;
      };
      programs.opencode = {
        settings.mcp = lib.mkIf (withMcp "opencode") (mcpFor "opencode");
        context = lib.mkIf (withContent "opencode") content.opencodeContext;
      };

      # Load only credentials actually used by Codex's selected HTTP servers.
      # Missing MCP credentials must cost one server, not every Codex command.
      my.ai.agents.codex.environmentScript = lib.concatMapStringsSep "\n"
        (name:
          let server = ai.mcp.servers.${name};
          in "load_from_secret ${server.remote.auth.var} ${server.remote.auth.secret}")
        (lib.filter (name: codexMcp.${name} ? bearer_token_env_var) (lib.attrNames codexMcp));

      # This hook remains present when agents/MCP are disabled. Otherwise the
      # old entries in the writable file would continue to start MCP servers.
      home.activation.codexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${python}/bin/python3 ${./ai/_files/codex-merge-config.py} \
          ${managedSettings} "$HOME/.codex/config.toml" \
          --state "${config.xdg.stateHome}/nix-darwin/codex-mcp.json" \
          --previous-activation "''${oldGenPath:-}/activate"
      '';
      home.activation.codexRules = ruleActivation ".codex/AGENTS.md" (withContent "codex");
      home.activation.geminiRules = ruleActivation ".gemini/GEMINI.md"
        (withContent "gemini" || withContent "antigravity");

      home.file = {
        # The shared .agents path is discovered by several agents. Content is
        # exported neutrally when no Nix agent is enabled.
        ".agents/skills" = lib.mkIf
          (ai.content.enable && builtins.any enabled [ "claude" "codex" "opencode" "gemini" "antigravity" ])
          { source = content.skillsDir; recursive = true; };
        # A plugin avoids owning agy's writable root mcp_config.json. Skills
        # and MCP can each keep this plugin alive independently.
        ".gemini/config/plugins/nix-darwin/plugin.json" = lib.mkIf
          (withContent "antigravity" || withMcp "antigravity")
          { text = builtins.toJSON { name = "nix-darwin"; }; };
        ".gemini/config/plugins/nix-darwin/mcp_config.json" = lib.mkIf (withMcp "antigravity") {
          source = (pkgs.formats.json { }).generate "antigravity-mcp-config.json" {
            mcpServers = mcpFor "antigravity";
          };
        };
        ".gemini/config/plugins/nix-darwin/skills" = lib.mkIf (withContent "antigravity") {
          source = content.skillsDir;
          recursive = true;
        };
      };
    };
}
