{ pkgs, ... }:
{
  system.stateVersion = 5;

  system.defaults.CustomUserPreferences = {
    "NSGlobalDomain" = {
      "NSQuitAlwaysKeepsWindows" = true;
      # Enable web inspector in web views
      "WebKitDeveloperExtras" = true;
      # # Menu Bar Status Item Spacing
      # # https://www.jessesquires.com/blog/2023/12/16/macbook-notch-and-menu-bar-fixes/
      # # https://www.reddit.com/r/MacOS/comments/16lpfg5/hidden_preference_to_alter_the_menubar_spacing/
      # # https://flaky.build/native-fix-for-applications-hiding-under-the-macbook-pro-notch
      # # https://news.ycombinator.com/item?id=39343919
      # "NSStatusItemPadding" = 0;
      # "NSStatusItemSeparation" = 0;
    };
    # For this work, you have to add Terminal to apps with Full Disk Access in Security And Privacy
    "com.apple.Safari" = {
      # Enable debug menu and web inspector
      "IncludeInternalDebugMenu" = true;
      "WebKitDeveloperExtrasEnabledPreferenceKey" = true;
      "com.apple.Safari.ContentPageGroupIdentifier.WebKit2DeveloperExtrasEnabled" = true;
    };
    "com.apple.dock" = {
      "size-immutable" = false;
    };
    "com.apple.desktopservices" = {
      # https://support.apple.com/en-us/102064
      # Suppress the creation of .DS_Store files on network volumes
      "DSDontWriteNetworkStores" = true;
    };
  };
  system.defaults.ActivityMonitor.IconType = 5; # CPU Usage
  system.defaults.NSGlobalDomain.AppleInterfaceStyle = "Dark";
  system.defaults.NSGlobalDomain.AppleKeyboardUIMode = 3;
  system.defaults.NSGlobalDomain.InitialKeyRepeat = 15;
  system.defaults.NSGlobalDomain.KeyRepeat = 2;
  
  # 1 turns on F1,F2, etc. as standard function keys; 0 sets them as special-purpose keys
  system.defaults.NSGlobalDomain."com.apple.keyboard.fnState" = true;
  system.defaults.NSGlobalDomain."com.apple.mouse.tapBehavior" = 1;
  system.defaults.dock.autohide = true;
  system.defaults.dock.mru-spaces = false;
  # system.defaults.dock.tilesize = ...; # Default = 64
  system.defaults.finder.AppleShowAllExtensions = true;
  system.defaults.finder.QuitMenuItem = true;
  system.defaults.finder.ShowPathbar = true;
  system.defaults.finder.FXPreferredViewStyle = "clmv"; # Column view
  # system.defaults.loginwindow.LoginwindowText = "nixcademy.com";
  system.defaults.magicmouse.MouseButtonMode = "TwoButton";
  system.defaults.menuExtraClock.IsAnalog = true;
  system.defaults.screencapture.location = "~/Downloads";
  # system.defaults.screensaver.askForPasswordDelay = 10;
  system.defaults.trackpad.Clicking = true;
  system.defaults.trackpad.Dragging = true;
  system.defaults.trackpad.TrackpadRightClick = true;
  system.defaults.trackpad.TrackpadThreeFingerDrag = true;
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToEscape = true;
}