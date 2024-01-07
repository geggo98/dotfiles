{ pkgs, ... }:
{
  system.defaults.CustomUserPreferences = {
    "NSGlobalDomain" = {
      "NSQuitAlwaysKeepsWindows" = true;
      # Enable web inspector in web views
      "WebKitDeveloperExtras" = true;
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
  };
  system.defaults.ActivityMonitor.IconType = 5; # CPU Usage
  system.defaults.NSGlobalDomain.AppleInterfaceStyle = "Dark";
  system.defaults.NSGlobalDomain.AppleKeyboardUIMode = 3;
  system.defaults.NSGlobalDomain.InitialKeyRepeat = 15;
  system.defaults.NSGlobalDomain.KeyRepeat = 2;
  system.defaults.NSGlobalDomain."com.apple.keyboard.fnState" = false;
  system.defaults.NSGlobalDomain."com.apple.mouse.tapBehavior" = 1;
  system.defaults.dock.autohide = true;
  system.defaults.dock.mru-spaces = false;
  # system.defaults.dock.tilesize = ...; # Default = 64
  system.defaults.finder.AppleShowAllExtensions = true;
  system.defaults.finder.QuitMenuItem = true;
  system.defaults.finder.ShowPathbar = true;
  system.defaults.magicmouse.MouseButtonMode = "TwoButton";
  system.defaults.menuExtraClock.IsAnalog = true;
  system.defaults.trackpad.Clicking = true;
  system.defaults.trackpad.Dragging = true;
  system.defaults.trackpad.TrackpadRightClick = true;
  system.defaults.trackpad.TrackpadThreeFingerDrag = true;
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToEscape = true;
}