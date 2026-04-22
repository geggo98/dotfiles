{ ... }:
{
  flake.modules.homeManager.vscode = { config, pkgs, lib, ... }: {
    # Deploy the Turbo Vision theme as a local VS Code extension.
    # VS Code itself is installed via homebrew cask (see homebrew-common.nix).
    home.file.".vscode/extensions/local-turbo-vision-theme/package.json".source =
      ./_files/vscode/turbo-vision-package.json;
    home.file.".vscode/extensions/local-turbo-vision-theme/themes/turbo-vision-color-theme.json".source =
      ./_files/vscode/turbo-vision-color-theme.json;

    # VS Code settings (managed declaratively — symlinked to nix store)
    home.file."Library/Application Support/Code/User/settings.json".text =
      builtins.toJSON {
        # Theme
        "workbench.colorTheme" = "Turbo Vision (based on Gerry Cyberpunk Plus)";
        "workbench.preferredHighContrastColorTheme" = "Turbo Vision (based on Gerry Cyberpunk Plus)";

        # Editor font: Operator Mono Lig → Victor Mono → Monaspace Radon
        "editor.fontFamily" = "'Operator Mono Lig', 'Victor Mono', 'Monaspace Radon', 'JetBrainsMono Nerd Font Mono', monospace";
        "editor.fontSize" = 18;
        "editor.fontLigatures" = true;
        "editor.lineHeight" = 1.2;

        "editor.accessibilitySupport" = "off";
        "editor.lineNumbers" = "relative";

        "notebook.lineNumbers" = "on";

        # Terminal font: BerkeleyMono Nerd Font → JetBrains Mono Nerd Font
        "terminal.integrated.fontFamily" = "'BerkeleyMono Nerd Font', 'JetBrainsMono Nerd Font', 'Victor Mono', monospace";
        "terminal.integrated.fontSize" = 13;

        # Terminal profiles: Nix-managed shells
        "terminal.integrated.profiles.osx" = {
          "fish ❄️" = {
            path = "/etc/profiles/per-user/${config.home.username}/bin/fish";
            args = [ "-l" ];
          };
          "zsh ❄️" = {
            path = "/etc/profiles/per-user/${config.home.username}/bin/zsh";
            args = [ "-l" ];
          };
          "Agent (Claude)" = {
            path = "/etc/profiles/per-user/${config.home.username}/bin/+agent-claude";
          };
        };
        "terminal.integrated.defaultProfile.osx" = "fish ❄️";

        # UI font hint: Nokia Sans Wide → Fira Sans (limited VS Code support)
        "editor.inlayHints.fontFamily" = "'Nokia Sans Wide', 'Fira Sans', sans-serif";

        # Editor behavior matching the IntelliJ theme
        "editor.cursorBlinking" = "smooth";
        "editor.cursorSmoothCaretAnimation" = "on";
        "editor.smoothScrolling" = true;
        "editor.renderWhitespace" = "boundary";
        "editor.bracketPairColorization.enabled" = true;
        "editor.guides.bracketPairs" = true;
        "editor.guides.bracketPairsHorizontal" = "active";
        "editor.guides.highlightActiveIndentation" = true;
        "editor.semanticHighlighting.enabled" = true;

        # Rainbow brackets & indent guides — colors scoped to the active theme
        # See https://stackoverflow.com/a/72125627
        "workbench.colorCustomizations" = {
          "[Turbo Vision (based on Gerry Cyberpunk Plus)]" = {
            "editorBracketPairGuide.background1" = "#FFB86C";
            "editorBracketPairGuide.background2" = "#FF75B5";
            "editorBracketPairGuide.background3" = "#45A9F9";
            "editorBracketPairGuide.background4" = "#B084EB";
            "editorBracketPairGuide.background5" = "#E6E6E6";
            "editorBracketPairGuide.background6" = "#19F9D8";
            "editorBracketPairGuide.activeBackground1" = "#FFB86C";
            "editorBracketPairGuide.activeBackground2" = "#FF75B5";
            "editorBracketPairGuide.activeBackground3" = "#45A9F9";
            "editorBracketPairGuide.activeBackground4" = "#B084EB";
            "editorBracketPairGuide.activeBackground5" = "#E6E6E6";
            "editorBracketPairGuide.activeBackground6" = "#19F9D8";
          };
        };

        "files.autoSave" = "onFocusChange";

        # Mark vendored/external source files as read-only
        "files.readonlyInclude" = {
          "**/.cargo/registry/src/**/*.rs" = true;
          "**/.cargo/git/checkouts/**/*.rs" = true;
          "**/lib/rustlib/src/rust/library/**/*.rs" = true;
        };

        "claudeCode.preferredLocation" = "sidebar";
        "excalidraw.theme" = "auto";
        "github.copilot.chat.claudeAgent.enabled" = true;
        "gitlens.plusFeatures.enabled" = false;
        "gitlens.showWhatsNewAfterUpgrades" = false;
        "git.autofetch" = true;
      };
  };
}
