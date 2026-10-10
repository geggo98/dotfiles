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

      # lucax88x.codeacejumper — hash-pinned OUTSIDE nix-vscode-extensions, deliberately.
      # Every other extension in this file rides the dated snapshot: `just update` moves
      # it forward once the whole revision clears the 14-day bar, with no human looking at
      # the individual version. That is the wrong posture here. The upstream repo has
      # carried an open "Maintainer wanted" issue since 2022-01-31
      # (github.com/lucax88x/CodeAceJumper/issues/439) — exactly the situation in which
      # open-source projects get taken over by a malicious new maintainer, per the user.
      # A silent version bump two weeks after a takeover is the failure mode to prevent,
      # for an extension with `activationEvents: ["*"]` (loads on every VS Code start) and
      # only 28k installs to notice something wrong.
      #
      # So: a content hash pin (nix build fails on any byte difference from what was
      # audited below), not a registry lookup. `just audit-extensions` still runs against
      # it (scripts/supply-chain.toml's `pin` field), but it now asks "is 3.4.0 still the
      # newest release and still listed", not "what is newest and how old is it" — see
      # PIN_BEHIND in scripts/supply-chain.py. Bumping the version means repeating the
      # audit below, not just editing a number.
      #
      # Audited 2026-09-27, version 3.4.0 (the only version on the VS Marketplace; not on
      # Open VSX at all — 404):
      #   - no git tag for 3.4.0; matches master@866e983 (PR #443, merged 2025-06-25
      #     14:07:07Z, published 17 minutes later at 14:24:56Z). package.json in the VSIX
      #     is identical to master's except `version`.
      #   - dist/extension.js (76 KB, one bundled line) calls only `require("vscode")` —
      #     no child_process, no http/fetch, no eval, no process.env, no atob/base64.
      #   - bundled node_modules (lodash 4.17.21, ramda 0.26.1, xmlbuilder 13.0.2) is never
      #     loaded from the bundle; lodash's two current advisories (GHSA-xxjr-mmjv-4gpg,
      #     GHSA-r5fr-rjxr-66jc) are in `_.unset`/`_.omit`/`_.template`, none of which the
      #     bundle calls.
      #   - hash below downloaded directly from gallery.vsassets.io and confirmed to match
      #     nix-vscode-extensions rev 41316674b7 (2026-09-08)'s cache entry independently.
      codeAceJumper = pkgs.vscode-utils.extensionFromVscodeMarketplace {
        publisher = "lucax88x";
        name = "codeacejumper";
        version = "3.4.0";
        hash = "sha256-zJNhifpThxktVB6IoLfVhFAxCn9e49c1CVefWcC8rAQ=";
      };

      # Drift guard for the pin above: scripts/supply-chain.toml carries its OWN copy of
      # the version, under [[extensions]] id = "lucax88x.codeacejumper", so
      # `just audit-extensions` can ask "is this still the newest release" (PIN_BEHIND in
      # scripts/supply-chain.py) without this file granting it write access to a hash pin.
      # Two independent copies of the same fact drift exactly when only one is edited —
      # the assertion below is what turns that into a build failure instead of a silent
      # mismatch.
      supplyChainManifest = builtins.fromTOML (builtins.readFile ../scripts/supply-chain.toml);
      codeAceJumperAudit = lib.findFirst (e: (e.id or null) == "lucax88x.codeacejumper")
        null
        (supplyChainManifest.extensions or [ ]);

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
        # vstirbu's markdown.markdownItPlugins + markdown.previewScripts (the
        # built-in Markdown preview integration) and bierner.markdown-mermaid
        # both claim the same preview webview. Root cause, not a config gap:
        # vstirbu 2.1.2 — the version `nix-vscode-extensions` pinned as of
        # 2026-08-28 — predates the vendor splitting cloud/AI/account
        # features into a separate "Mermaid Chart" extension
        # (MermaidChart.vscode-mermaid-chart) and still carried that cruft,
        # including a malformed `activationEvents: ["onLanguage"]` (missing a
        # language id) and an API-proposal declaration VS Code rejects
        # outright. Measured 2026-09-17: with bierner + vstirbu 2.1.2,
        # mermaid fences self-nested a "No diagram type detected … for
        # text: No diagram type detected … for text:" error (the second
        # script re-rendering the first script's already-failed output);
        # with vstirbu 2.1.2 alone, fences rendered NOTHING anywhere (no
        # error either); setting `mermaid.languages = []` below — an
        # undocumented key read straight out of vstirbu's minified
        # `out/extension.js` — changed nothing in either combination.
        #
        # Fix: vstirbu 2.2.0 (2026-09-04) explicitly re-focused on "free,
        # local diagram previewing" and lists "Mermaid rendering in Markdown
        # preview" as a still-supported feature post-split — confirmed
        # working here. `nix-vscode-extensions` had no revision old enough to
        # clear its 14-day extension cooldown (scripts/supply-chain.toml)
        # that also carried 2.2.0, so the cooldown was deliberately
        # overridden per AGENTS.md's "Undercutting a cooldown" protocol:
        # `nix flake lock --override-input nix-vscode-extensions
        # github:nix-community/nix-vscode-extensions/41316674b…` — the
        # OLDEST revision (2026-09-08) that carries it, chosen specifically
        # to minimize drift in every other pinned extension. Verified before
        # overriding: repo transferred to the Mermaid-Chart org (creators of
        # mermaid.js itself), verified marketplace publisher, no GitHub
        # security advisories, no security-labeled issues, 10-year-old repo
        # with continuous activity. Diffing the two `nix-vscode-extensions`
        # revisions' full registry caches against every extension in this
        # file's managed set found exactly one other change:
        # `eamodio.gitlens` 19.0.0 → 19.1.0 (Open VSX; GitKraken, no
        # advisories, released 2026-09-01) — accepted as the unavoidable
        # side effect of moving the whole dated snapshot, not chosen
        # independently.
        #
        # `mermaid.languages = []` and bierner.markdown-mermaid stay for now
        # because the verified-working combination includes both — neither
        # has been re-tested for necessity against 2.2.0 alone. Revisit once
        # there is a reason to simplify.
        vsmp.vstirbu.vscode-mermaid-preview # Open VSX is stuck on 1.6.3 (2022-06)
        ovsx.bierner.markdown-mermaid
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
        codeAceJumper # hash-pinned, not from vsmp/ovsx — see the binding above
      ];

      # Named rather than inline so the Settings Sync ignore list below can be
      # generated from its key set. Everything VS Code reads out of settings.json
      # is in here.
      managedSettings = {
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

        # Undocumented — not in vstirbu.vscode-mermaid-preview's
        # `contributes.configuration`, so it won't appear in the Settings UI
        # and VS Code may flag it as an unknown setting. Its
        # `extendMarkdownIt` reads it via `getConfiguration("mermaid").get
        # ("languages", ["mermaid"])` to decide which fenced-code languages
        # its own Markdown-preview integration claims. Intent: stop vstirbu
        # from also hooking the preview webview bierner.markdown-mermaid
        # renders into (see the comment by vstirbu.vscode-mermaid-preview
        # above for why both are installed). NOT verified to do that,
        # though — it made no observable difference against the vstirbu
        # 2.1.2 bug that comment describes (same failure with or without
        # it), and hasn't been re-tested since the fix (vstirbu 2.2.0). Left
        # in because the verified-working combination includes it; revisit
        # together with whether bierner is still needed at all.
        "mermaid.languages" = [ ];

        "claudeCode.preferredLocation" = "sidebar";
        "excalidraw.theme" = "auto";

        # The AWS Toolkit's CloudFormation language server writes this itself
        # (defaulting to true) on first start, which fails on the read-only
        # settings.json. Declared here so the opt-out is explicit.
        "aws.cloudformation.telemetry.enabled" = false;

        # AceJump, matched to the IntelliJ AceJump behaviour these keybindings mirror
        # (see profiles.default.keybindings below). Defaults are onlyInitialLetter=true
        # (word-initial letters only) and jumpToLineEndings=false (line-start marks only);
        # both are the opposite of IntelliJ's default reach.
        "aceJump.finder.onlyInitialLetter" = false; # match anywhere in the text, not just word starts
        "aceJump.finder.jumpToLineEndings" = true; # Line mode marks both line start AND end

        # Without this, codeAceJumper never activates in an untrusted workspace (this
        # repo, opened fresh, is one by default) — and does so SILENTLY: no error, no
        # log line anywhere, it simply never appears in the eager-activation list.
        # Confirmed 2026-09-27 directly against the installed 1.135.0 build's own source
        # (workbench.desktop.main.js): `getExtensionUntrustedWorkspaceSupportType` returns
        # the manifest's declared `capabilities.untrustedWorkspaces.supported` and, absent
        # one, falls through to a default of `false` for any extension that has a `main`
        # entry point (i.e. runs code at all) — codeAceJumper has `main` and declares no
        # `capabilities` block, so it gets the conservative default. This user setting is
        # VS Code's own documented per-extension override for exactly that gap (Extensions
        # view: "Manage Workspace Trust" does the same thing through the UI).
        #
        # Granting it is consistent with the audit already on file next to the
        # `codeAceJumper` binding above: the bundle calls only `require("vscode")` — no
        # child_process, no network, no eval, no filesystem access beyond the extension
        # API — which is exactly the profile workspace trust exists to gate.
        #
        # `version` pins the grant to the audited version, the same way the hash pin
        # above does: bumping codeAceJumper's version without also updating this value
        # makes VS Code revert to the conservative default until the grant is renewed,
        # rather than carrying an old audit's trust forward onto unreviewed code.
        "extensions.supportUntrustedWorkspaces" = {
          "lucax88x.codeacejumper" = {
            supported = true;
            version = codeAceJumper.version;
          };
        };
        "github.copilot.chat.claudeAgent.enabled" = true;
        "gitlens.plusFeatures.enabled" = false;
        "gitlens.showWhatsNewAfterUpgrades" = false;
        "git.autofetch" = true;
        "git.confirmSync" = false;
        "git.enableSmartCommit" = true;
        "git.suggestSmartCommit" = false;
      };
    in
    {
      assertions = [
        {
          assertion = codeAceJumperAudit != null
            && (codeAceJumperAudit.pin or null) == codeAceJumper.version;
          message = ''
            modules/vscode.nix pins lucax88x.codeacejumper at version
            "${codeAceJumper.version}", but scripts/supply-chain.toml's [[extensions]]
            entry for id = "lucax88x.codeacejumper" names pin =
            "${toString (codeAceJumperAudit.pin or null)}" (or that entry is missing
            entirely). The two must always agree -- when bumping the version, edit both
            in the same change, after repeating the audit documented next to the
            codeAceJumper binding in this file.
          '';
        }
      ];

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

          # Settings Sync must not touch what Nix writes here — see the section in
          # AGENTS.md. Generated rather than hand-listed, because a hand-listed set
          # drifts exactly where nobody looks. Two details:
          #   - `extensions.autoCheckUpdates` is named explicitly because home-manager
          #     merges it in AFTER this attrset (mkVscodeModule.nix, out of
          #     enableExtensionUpdateCheck), so attrNames cannot see it.
          #   - `settingsSync.ignoredSettings` itself is deliberately absent: it carries
          #     `disallowSyncIgnore`, is filtered out at runtime regardless, and listing
          #     it would read as "Value is not accepted" against its own enum schema.
          userSettings = managedSettings // {
            "settingsSync.ignoredSettings" = builtins.attrNames
              (managedSettings // { "extensions.autoCheckUpdates" = false; });
          };

          # Nix-managed keybindings.json (a list here, not a path) turns it into a
          # read-only /nix/store symlink, same as userSettings above — home-manager backs
          # up the old file as keybindings.json.hm.bak (backupFileExtension in
          # modules/home-manager-darwin.nix). Editing a shortcut in the VS Code UI after
          # this will fail silently the same way a settings.json edit does; see
          # `just vscode-settings-check`.
          #
          # The first two reproduce what keybindings.json already held by hand. The rest
          # map codeAceJumper's four commands (extension.aceJump{,.multiChar,.line,
          # .selection}, see the binding above) onto the IntelliJ CodeAceJumper shortcuts
          # in the screenshot the user supplied — this extension has no built-in defaults
          # at all, unlike IntelliJ's plugin. Not mapped: IntelliJ's "Reverse Cycle" and
          # the "All Line Ends/Indents/Starts" modes, none of which this extension has a
          # command for, and the mode-cycle-on-repeated-press behaviour, which this
          # extension does not implement either — each press re-triggers the same jump.
          # F19 alone (no modifier) is Escape via Hammerspoon's nix_f19.lua, which the
          # extension's own `escape` keybinding (package.json) uses to cancel a pending
          # jump; F19 with a modifier passes through unchanged, so shift+f19 reaches VS
          # Code as such.
          keybindings = [
            {
              key = "cmd+`";
              command = "workbench.action.terminal.toggleTerminal";
              when = "editorTextFocus";
            }
            {
              key = "cmd+`";
              command = "workbench.action.terminal.toggleTerminal";
              when = "terminalFocus";
            }
            {
              # IntelliJ: "Activate / Cycle AceJump Mode"
              key = "ctrl+;";
              command = "extension.aceJump.multiChar";
              when = "editorTextFocus";
            }
            {
              key = "shift+f19";
              command = "extension.aceJump.multiChar";
              when = "editorTextFocus";
            }
            {
              # IntelliJ: "Start AceJump in All Line Marks Mode"
              key = "shift+cmd+;";
              command = "extension.aceJump.line";
              when = "editorTextFocus";
            }
            {
              key = "ctrl+shift+;";
              command = "extension.aceJump.line";
              when = "editorTextFocus";
            }
          ];
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
