{ ... }:
{
  flake.modules.darwin.macos = { config, pkgs, ... }: {
    system.stateVersion = 5;

    # PATH for GUI apps launched via launchd (Spotlight, Dock, etc.)
    # Uses launchctl setenv to bypass SIP restrictions on launchd.envVariables.
    launchd.user.agents.set-gui-path =
      let
        path = builtins.concatStringsSep ":" [
          "/nix/var/nix/profiles/default/bin"
          "/etc/profiles/per-user/${config.system.primaryUser}/bin"
          "/run/current-system/sw/bin"
          "/usr/local/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
      in
      {
        serviceConfig = {
          Label = "set-gui-path";
          ProgramArguments = [
            "/bin/launchctl"
            "setenv"
            "PATH"
            path
          ];
          RunAtLoad = true;
        };
      };

    # Determinate uses its own daemon — nix-darwin must not manage Nix.
    nix.enable = false;

    # Shells
    programs.zsh.enable = true;
    programs.fish.enable = true;

    # Apps
    environment.systemPackages = with pkgs; [ ];
    environment.variables = { };

    # Fonts: `/Library/Fonts/Nix Fonts`.
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      nerd-fonts.iosevka
      nerd-fonts.victor-mono
      fira # Fira Sans (fallback for Nokia Sans Wide)
      monaspace # Monaspace Radon (fallback for Operator Mono)
      iosevka
      jetbrains-mono
      victor-mono
    ];

    # TouchID for sudo
    security.pam.services.sudo_local.touchIdAuth = true;

    # Global keyboard shortcuts
    system.defaults.CustomUserPreferences = {
      NSGlobalDomain = {
        NSUserKeyEquivalents = {
          "Emoji & Symbols" = "@^~$e";
        };
        "NSQuitAlwaysKeepsWindows" = true;
        "WebKitDeveloperExtras" = true;
      };
      universalaccess = {
        reduceTransparency = true;
        increaseContrast = true;
        differentiateWithoutColor = true;
        showWindowTitlebarIcons = true;
      };
      "com.apple.Safari" = {
        "IncludeInternalDebugMenu" = true;
        "WebKitDeveloperExtrasEnabledPreferenceKey" = true;
        "com.apple.Safari.ContentPageGroupIdentifier.WebKit2DeveloperExtrasEnabled" = true;
      };
      "com.apple.dock" = {
        "size-immutable" = false;
      };
      "com.apple.desktopservices" = {
        "DSDontWriteNetworkStores" = true;
      };
      "com.superultra.Homerow" = {
        "hide-labels-when-nothing-is-searched" = true;
        "non-search-shortcut" = "⌥F19";
        "scroll-shortcut" = "⌥⌘F19";
        "search-shortcut" = "⌘F19";
        "use-search-predicate" = true;
      };
    };

    system.defaults.ActivityMonitor.IconType = 5;
    system.defaults.NSGlobalDomain.AppleInterfaceStyle = "Dark";
    system.defaults.NSGlobalDomain.AppleKeyboardUIMode = 3;
    system.defaults.NSGlobalDomain.InitialKeyRepeat = 15;
    system.defaults.NSGlobalDomain.KeyRepeat = 2;
    system.defaults.NSGlobalDomain."com.apple.keyboard.fnState" = true;
    system.defaults.NSGlobalDomain."com.apple.mouse.tapBehavior" = 1;
    system.defaults.dock.autohide = true;
    system.defaults.dock.mru-spaces = false;
    system.defaults.finder.AppleShowAllExtensions = true;
    system.defaults.finder.QuitMenuItem = true;
    system.defaults.finder.ShowPathbar = true;
    system.defaults.finder.FXPreferredViewStyle = "clmv";
    system.defaults.magicmouse.MouseButtonMode = "TwoButton";
    system.defaults.menuExtraClock.IsAnalog = true;
    system.defaults.screencapture.location = "~/Downloads";
    system.defaults.trackpad.Clicking = true;
    system.defaults.trackpad.Dragging = true;
    system.defaults.trackpad.TrackpadRightClick = true;
    system.defaults.trackpad.TrackpadThreeFingerDrag = true;
    system.keyboard.enableKeyMapping = false;
  };
}
