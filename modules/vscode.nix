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

        "editor.lineNumbers" = "relative";
        "notebook.lineNumbers" = "on";

        # Terminal font: BerkeleyMono Nerd Font → JetBrains Mono Nerd Font
        "terminal.integrated.fontFamily" = "'BerkeleyMono Nerd Font', 'JetBrainsMono Nerd Font', 'Victor Mono', monospace";
        "terminal.integrated.fontSize" = 13;

        # UI font hint: Nokia Sans Wide → Fira Sans (limited VS Code support)
        "editor.inlayHints.fontFamily" = "'Nokia Sans Wide', 'Fira Sans', sans-serif";

        # Editor behavior matching the IntelliJ theme
        "editor.cursorBlinking" = "smooth";
        "editor.cursorSmoothCaretAnimation" = "on";
        "editor.smoothScrolling" = true;
        "editor.renderWhitespace" = "boundary";
        "editor.bracketPairColorization.enabled" = true;
        "editor.guides.bracketPairs" = "active";
        "editor.semanticHighlighting.enabled" = true;

        # Mark vendored/external source files as read-only
        "files.readonlyInclude" = {
          "**/.cargo/registry/src/**/*.rs" = true;
          "**/.cargo/git/checkouts/**/*.rs" = true;
          "**/lib/rustlib/src/rust/library/**/*.rs" = true;
        };
      };
  };
}
