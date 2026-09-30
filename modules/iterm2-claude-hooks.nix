{ ... }:
{
  # iTerm2's Claude Code status integration (tab status/badge via cc-status).
  # Docs: https://iterm2.com/claude-code-integration.html
  # iTerm2 installs these hooks by rewriting ~/.claude/settings.json itself,
  # which replaces the HM store symlink with a plain file. Declaring them here
  # keeps the managed file identical to what iTerm2 wants.
  flake.modules.homeManager.iterm2-claude-hooks = { config, lib, pkgs, ... }:
    let
      cfg = config.my.iterm2.claudeCodeHooks;
      events = [
        "Notification"
        "PermissionRequest"
        "PostToolUse"
        "PreToolUse"
        "SessionEnd"
        "SessionStart"
        "Stop"
        "StopFailure"
        "SubagentStop"
        "UserPromptSubmit"
      ];
      # Symlink maintained by iTerm2 itself, pointing into iTerm.app.
      ccStatus = "${config.home.homeDirectory}/.config/iterm2/cc-status";
    in
    {
      options.my.iterm2.claudeCodeHooks.enable =
        lib.mkEnableOption "iTerm2's Claude Code status hooks (cc-status)";

      config = lib.mkIf cfg.enable {
        assertions = [{
          assertion = pkgs.stdenv.hostPlatform.isDarwin;
          message = "my.iterm2.claudeCodeHooks: iTerm2 exists on macOS only.";
        }];
        programs.claude-code.settings.hooks = lib.genAttrs events (_: [
          { hooks = [{ type = "command"; command = ccStatus; }]; }
        ]);
      };
    };
}
