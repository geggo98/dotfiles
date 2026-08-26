{ ... }:
{
  # VS Code: the GENERAL extension set is managed here; anything with a language
  # toolchain behind it belongs in the project's own .vscode/extensions.json.
  # The full inventory and the reasoning per extension is in
  # modules/_files/vscode/EXTENSIONS.md.
  flake.modules.homeManager.vscode = { config, pkgs, lib, ... }:
    let
      # Both registries are needed. Open VSX is NOT a faithful mirror of the
      # marketplace: measured 2026-08-26, it serves path-intellisense 2.8.0 (2022)
      # against the marketplace's 2.10.0, markdown-all-in-one 3.6.2 against 3.6.3,
      # and it answers 404 for vscode-dash entirely. Choosing one registry for
      # everything would silently pin stale versions, so the choice is per
      # extension and the reason is written next to the ones that differ.
      #
      # The `-release` variants, not the plain ones: `open-vsx` and
      # `vscode-marketplace` include pre-releases. Measured on gitlens, where the
      # plain set yields 2026.8.251013 (the pre-release channel) while
      # `open-vsx-release` yields 18.3.0.
      ovsx = pkgs.nix-vscode-extensions.open-vsx-release;
      vsmp = pkgs.nix-vscode-extensions.vscode-marketplace-release;

      # Same wrapper shape as mkZshScript in modules/nix-cache.nix. PATH is set
      # explicitly rather than inherited: an activation script gets almost none, and the
      # script's python3 must not depend on what happens to be installed.
      regenScript = pkgs.writeTextFile {
        name = "+vscode-regen-extensions";
        destination = "/bin/+vscode-regen-extensions";
        executable = true;
        text = ''
          #!${pkgs.zsh}/bin/zsh
          export PATH="${lib.makeBinPath [ pkgs.python3 pkgs.coreutils ]}:/usr/bin:/bin"
          ${builtins.readFile ./_files/vscode/regenerate-extensions-json}
        '';
      };

      generalExtensions = [
        # -- Markdown, docs, diagrams ------------------------------------
        ovsx.davidanson.vscode-markdownlint
        vsmp.yzhang.markdown-all-in-one # Open VSX is stuck on 3.6.2 (2024-01)
        ovsx.jebbs.plantuml
        vsmp.pomdtr.excalidraw-editor # Open VSX is stuck on 3.9.0

        # -- Containers and Kubernetes -----------------------------------
        ovsx.docker.docker
        vsmp.ms-azuretools.vscode-containers # Open VSX lags: 2.4.5 vs 2.5.0
        ovsx.ms-kubernetes-tools.vscode-kubernetes-tools

        # -- Git ---------------------------------------------------------
        ovsx.eamodio.gitlens

        # -- This repo's own languages -----------------------------------
        ovsx.jnoortheen.nix-ide
        ovsx.redhat.vscode-yaml
        ovsx.bmalehorn.vscode-fish

        # -- Editor comfort ----------------------------------------------
        ovsx.vscode-icons-team.vscode-icons
        vsmp.christian-kohler.path-intellisense # Open VSX: 2.8.0 from 2022
        ovsx.marclipovsky.string-manipulation
        ovsx.ms-vscode.hexeditor
        vsmp.deerawan.vscode-dash # not on Open VSX at all (404)
      ];
    in
    {
      programs.vscode = {
        enable = true;

        # VS Code itself stays on the Homebrew cask (homebrew-common.nix).
        # `null` is the supported value for that, not a trick: mkVscodeModule.nix
        # gates `home.packages` on `cfg.package != null`, and the extension
        # directory name (".vscode") is fixed by the module's caller, not derived
        # from the package. Three measurements from 2026-08-26 argue against
        # moving the editor into Nix:
        #   - the cask serves 1.134.0; nixpkgs 26.05 has 1.119.0, unstable 1.133.0
        #   - vscode is not in any binary cache for aarch64-darwin (unfree)
        #   - so it would be built locally, and the R2 post-build-hook would push
        #     Microsoft's non-redistributable build into a world-readable bucket
        #     (infra/README.md). That is also why Hydra does not build it.
        # The cost is honest: the cask stays unpinned, one of 83.
        package = null;

        # One symlink per extension instead of one symlink for the whole
        # directory. Required, not a preference: ~/.vscode/extensions is a real
        # directory that VS Code writes (extensions.json, .obsolete), and
        # project-specific extensions keep being installed into it by hand.
        mutableExtensionsDir = true;

        profiles.default = {
          # Writes extensions.autoCheckUpdates = false. Without it VS Code
          # installs a newer gallery copy NEXT TO the nix symlink and loads the
          # higher version — the pin would survive and do nothing.
          enableExtensionUpdateCheck = false;

          extensions = generalExtensions;

          userSettings = {
            # Theme
            "workbench.colorTheme" = "Turbo Vision (based on Gerry Cyberpunk Plus)";
            "workbench.preferredHighContrastColorTheme" = "Turbo Vision (based on Gerry Cyberpunk Plus)";
            # Was unset until 2026-08-26, which made both installed icon themes
            # inert. Named explicitly so the managed one is the one in effect.
            "workbench.iconTheme" = "vscode-icons";

            # Editor font: Operator Mono Lig → Maple Mono NF (OSS) → Victor Mono → Monaspace Radon
            "editor.fontFamily" = "'Operator Mono Lig', 'Maple Mono NF', 'Victor Mono', 'Monaspace Radon', 'JetBrainsMono Nerd Font Mono', monospace";
            "editor.fontSize" = 18;
            "editor.fontLigatures" = true;
            "editor.lineHeight" = 1.2;

            "editor.accessibilitySupport" = "off";
            "editor.lineNumbers" = "relative";

            "notebook.lineNumbers" = "on";

            # Terminal font: BerkeleyMono Nerd Font → IoskeleyMono Nerd Font (OSS) → JetBrains Mono Nerd Font
            "terminal.integrated.fontFamily" = "'BerkeleyMono Nerd Font', 'IoskeleyMono Nerd Font', 'JetBrainsMono Nerd Font', 'Victor Mono', monospace";
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
            #
            # VS Code 1.134.0 marks every property in this block with "Property
            # editorBracketPairGuide.background1 is not allowed." The values are correct and
            # the colors ARE applied; the schema is at fault. A `[Theme]` block is validated
            # against `{ $ref: "vscode://schemas/workbench-colors", additionalProperties: false }`,
            # and the bundled JSON language service now follows draft-2019-09 semantics, where
            # a `$ref` no longer contributes the `properties` annotation that
            # `additionalProperties` consults — so every property inside the block is rejected,
            # while the same keys one level up validate. microsoft/vscode#328165, closed for
            # 1.135.0. Do not silence it by unscoping: that leaks these colors into every theme.
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

            # The other half of enableExtensionUpdateCheck above: that option only
            # stops the CHECK. This stops the install. Both are needed, and the
            # cost is deliberate — hand-installed project extensions stop
            # updating themselves too, which is the same cooldown posture
            # modules/supply-chain-hardening.nix already takes for npm/uv/pnpm/bun.
            #
            # A STRING, and that is not cosmetic. VS Code 1.134.0 declares this as
            # `{ type: "string", enum: ["on", "off"], default: "on" }` and registers a
            # migration beside it that rewrites the old boolean — `false` → `"off"`. The
            # migration runs on EVERY start and its result can never be persisted, because
            # settings.json is a read-only /nix/store symlink. Measured 2026-08-26 with
            # `false` here, four seconds after launch:
            #   [error] Unable to write file 'vscode-userdata:…/User/settings.json'
            #           (EntryWriteLocked (FileSystemError): EACCES: permission denied)
            # `just vscode-settings-check` is the standing check for that whole class:
            # a value VS Code wants to rewrite is invisible until someone reads the log.
            "extensions.autoUpdate" = "off";

            "claudeCode.preferredLocation" = "sidebar";
            "excalidraw.theme" = "auto";
            "github.copilot.chat.claudeAgent.enabled" = true;
            "gitlens.plusFeatures.enabled" = false;
            "gitlens.showWhatsNewAfterUpgrades" = false;
            "git.autofetch" = true;
            "git.confirmSync" = false;
            "git.enableSmartCommit" = true;
            "git.suggestSmartCommit" = false;
          };
        };
      };

      # VS Code does not rescan its extension directory: extensions.json is the
      # authority, and a symlink appearing beside it changes nothing. home-manager ships
      # an onChange hook for exactly this, gated on `package != null` — so the `package =
      # null` above switches it off. This puts it back. The reasoning, the measurement
      # and the .obsolete trap it guards against are in the script itself.
      #
      # The file's content is the canonical extension list, so it changes precisely when
      # the managed set does. Nothing reads it; it exists to trigger onChange.
      home.file.".vscode/extensions/.nix-managed-extensions.json" = {
        text = pkgs.vscode-utils.toExtensionJson generalExtensions;
        # `|| [ $? -eq 1 ]` tolerates exit 1 and ONLY exit 1. The script uses 1 for a
        # deliberate refusal with a printed reason — a state a human resolves, not a
        # reason to abort a whole system activation. A real error (2) still propagates,
        # and a plain `|| true` would have swallowed that too.
        onChange = "${regenScript}/bin/+vscode-regen-extensions || [ $? -eq 1 ]";
      };

      # Also on PATH, because the one case the hook cannot handle is the one that needs
      # a human: extensions queued for deletion have to be cleared by starting VS Code
      # once, and only then can the registry be rebuilt.
      home.packages = [ regenScript ];

      # The Turbo Vision theme stays a hand-built local extension: it exists in no
      # registry, so nix-vscode-extensions cannot supply it. Leaf files inside a real
      # directory rather than a directory symlink, so VS Code's own writes to that
      # directory keep working.
      #
      # Its entry in extensions.json carries no `metadata` block, unlike every gallery
      # install. That was once read here as proof that VS Code discovers new directories
      # by scanning — it is not. It only proves the directory was scanned ONCE, whenever
      # this theme first appeared. Measured 2026-08-26: VS Code did not pick up sixteen
      # freshly planted symlinks until extensions.json was deleted. Hence regenScript.
      home.file.".vscode/extensions/local-turbo-vision-theme/package.json".source =
        ./_files/vscode/turbo-vision-package.json;
      home.file.".vscode/extensions/local-turbo-vision-theme/themes/turbo-vision-color-theme.json".source =
        ./_files/vscode/turbo-vision-color-theme.json;
    };
}
