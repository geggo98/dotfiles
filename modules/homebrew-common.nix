{ inputs, ... }:
{
  flake.modules.darwin.homebrew = { config, lib, pkgs, ... }:
    let
      # Reproduce nix-darwin's generated Brewfile so our scoped cleanup reconciles against
      # the exact same declared state (nix-darwin keeps its own copy as an internal `let`).
      brewfile = pkgs.writeText "Brewfile" config.homebrew.brewfile;
    in
    {
      # nix-homebrew installs a Nix-managed, version-pinned brew (see flake input
      # `brew-src`), so the `brew` binary is always Homebrew 6.0+ (with `brew trust`)
      # and identical across hosts. It sets up the prefix via mkBefore on the homebrew
      # activation script — the trust step below runs after it (mkOrder 750).
      imports = [ inputs.nix-homebrew.darwinModules.nix-homebrew ];

      options.my.homebrew.trustedTaps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "hashicorp/tap" ];
        description = ''
          Third-party Homebrew taps to `brew trust` before `brew bundle` runs.
          Required since Homebrew 6.0, which refuses to load formulae/casks from
          untrusted taps. Definitions from all modules concatenate.
        '';
      };

      config = {
        my.homebrew.trustedTaps = [ "hashicorp/tap" "typewhisper/tap" ];

        # Nix-managed Homebrew installation. `user` is the prefix owner (per host,
        # via system.primaryUser). autoMigrate adopts the existing /opt/homebrew,
        # keeping installed formulae/casks. mutableTaps keeps tap management with
        # brew (so `brew bundle` can tap) and avoids having to pin core/cask taps.
        nix-homebrew = {
          enable = true;
          autoMigrate = true;
          user = config.system.primaryUser;
          mutableTaps = true;
        };

        homebrew.enable = true;
        homebrew.caskArgs = {
          appdir = "~/Applications";
        };

        homebrew.taps = [
          "hashicorp/tap"
        ];
        homebrew.brews = [
          "hashicorp/tap/vault"
        ];
        homebrew.casks = [
          "1password"
          "appcleaner"
          "thaw" # Menu bar manager, open-source Bartender replacement (stonerl/Thaw)
          "beardie"
          "brave-browser"
          "chatgpt"
          "claude"
          "conductor"
          "dash"
          "daisydisk"
          "devutils"
          "elgato-stream-deck"
          "firefox"
          "font-maple-mono-nf" # OSS Operator Mono alternative — cursive italic + ligatures + NF
          "google-chrome"
          "gpg-suite-no-mail"
          "hammerspoon"
          "homerow"
          "http-toolkit"
          "iterm2"
          "itermai"
          "itermbrowserplugin"
          "istat-menus"
          "jdk-mission-control"
          "jetbrains-toolbox"
          "keka"
          "kekaexternalhelper"
          "krita"
          "languagetool-desktop"
          "launchcontrol"
          "lens"
          "losslesscut"
          "lunar"
          "lm-studio"
          "marked-app"
          "marta"
          "MonitorControl"
          "msty"
          "notunes"
          "octarine"
          "omnigraffle"
          "orion"
          "orbstack"
          "macwhisper"
          "moom"
          "monodraw"
          "obsidian"
          "raindropio"
          "raycast"
          "mac-monitor"
          "redis-insight"
          "sf-symbols"
          "shottr"
          "soundsource"
          "suspicious-package"
          "stratoshark"
          "visual-studio-code"
          "wireshark-app"
          "yubico-yubikey-manager"
          "zed"
          "betterdisplay"
          "tabtab"
          { name = "typewhisper/tap/typewhisper"; }
          "bettermouse"
        ];
        homebrew.masApps = {
          "1Blocker" = 1365531024;
          "1Password for Safari" = 1569813296;
          "Amphetamine" = 937984704;
          "CloudMounter" = 1130254674;
          "Compressor" = 424390742;
          "Corner Time" = 6746757189;
          "Countdown" = 6744842468;
          "DaVinci Resolve" = 571213070;
          "DockTime" = 508034739;
          "Display Maid" = 450063525;
          "File Cabinet Pro" = 1150565778;
          "Final Cut Pro" = 424389933;
          "Friendly Streaming" = 553245401;
          "Gifski" = 1351639930;
          "Goodnotes" = 1444383602;
          "HomeAtmo" = 1359795390;
          "iMazing HEIC Converter" = 1292198261;
          "Infuse" = 1136220934;
          "Horo" = 1437226581;
          "Keynote" = 409183694;
          "Logic Pro" = 634148309;
          "Logoist 5" = 6443412717;
          "MainStage" = 634159523;
          "MeetingBar" = 1532419400;
          "MenubarX" = 1575588022;
          "Motion" = 434290957;
          "Paste - Clipboard Manager" = 967805235;
          "Pixelmator Pro" = 1289583905;
          "Pointer" = 6736710502;
          "Plash" = 1494023538;
          "PLIST Editor" = 1157491961;
          "Save to Raindrop.io" = 1549370672;
          "Omnivore: Read-it-later" = 1564031042;
          "rcmd" = 1596283165;
          "Shortery" = 1594183810;
          "Source Files: Git Storage" = 6450856155;
          "StopTheMadness Pro" = 6471380298;
          "SponsorBlock for YouTube - Skip Sponsorships" = 1573461917;
          "Tailscale" = 1475387142;
          "UTM" = 1538878817;
          "Vectornator" = 1219074514;
          "Velja" = 1607635845;
          "Video Converter" = 1518836004;
        };
        homebrew.onActivation.cleanup = "none"; # was "uninstall"; replaced by postActivation cleanup below

        # Trust third-party taps before nix-darwin runs `brew bundle`. Homebrew 6.0 refuses to
        # load formulae/casks from untrusted taps. This shares the homebrew activation script
        # with nix-homebrew's prefix setup (mkBefore, order 500) and nix-darwin's `brew bundle`
        # (default, order 1000), so we order it strictly between them with mkOrder 750:
        # nix-homebrew installs the pinned brew (6.0.x, `brew trust` present) -> we trust the
        # taps on it -> bundle loads them. Self-contained (own PATH + sudo drop to the brew
        # user), mirroring the cleanup block below. brew trust canonicalizes each tap's git
        # remote, so it is robust against the .git-suffix matching bug (brew #22604).
        system.activationScripts.homebrew.text = lib.mkOrder 750 (lib.optionalString (config.my.homebrew.trustedTaps != [ ]) ''
          if [ -f "${config.homebrew.prefix}/bin/brew" ]; then
            echo >&2 "Trusting third-party Homebrew taps (Homebrew 6 tap trust): ${lib.concatStringsSep ", " config.my.homebrew.trustedTaps}"
            PATH="${config.homebrew.prefix}/bin:$PATH" \
            sudo \
              --preserve-env=PATH \
              --user=${lib.escapeShellArg config.homebrew.user} \
              --set-home \
              env HOMEBREW_NO_AUTO_UPDATE=1 \
              brew trust --taps ${lib.escapeShellArgs config.my.homebrew.trustedTaps}
          fi
        '');

        # MAS-safe Homebrew cleanup. nix-darwin's `onActivation.cleanup = "uninstall"` runs
        # `brew bundle install --cleanup`, which since Homebrew #22395 (issue #22450) also
        # uninstalls every App Store app not in masApps, with no way to exempt MAS on that code
        # path. So we disable nix-darwin's cleanup and run our own scoped cleanup here (it runs
        # right after the homebrew activation script), restricted to casks/formulae/taps — MAS
        # apps are never touched. Mirrors nix-darwin's own brew invocation (PATH + drop to user).
        system.activationScripts.postActivation.text = lib.mkAfter ''
          if [ -f "${config.homebrew.prefix}/bin/brew" ]; then
            echo >&2 "Homebrew cleanup (casks/formulae/taps; App Store apps preserved)..."
            PATH="${config.homebrew.prefix}/bin:${lib.makeBinPath [ pkgs.mas ]}:$PATH" \
            sudo \
              --preserve-env=PATH \
              --user=${lib.escapeShellArg config.homebrew.user} \
              --set-home \
              env HOMEBREW_NO_AUTO_UPDATE=1 \
              brew bundle cleanup --force --cask --formula --tap --file='${brewfile}'
          fi
        '';
      };
    };
}
