{ ... }:
{
  homebrew.enable = true;
  homebrew.caskArgs = {
    appdir = "~/Applications";
    # require_sha = true;
    # no_quarantine = true;
  };
  homebrew.brews = [
    "llm" # The Nix version has still problems with plugins
  ];
  homebrew.casks = [
    "1password"
    "appcleaner"
    "bartender"
    "beardie" # Control Media Keys https://github.com/Stillness-2/beardie
    "brave-browser"
    "dash" # Dash 6
    "daisydisk"
    "devutils" # https://devutils.app/
    "elgato-stream-deck"
    "firefox"
    "google-chrome"
    "gpg-suite-no-mail"
    "hammerspoon"
    "homerow"
    "http-toolkit"
    # "iina" # VLC video player replacement https://iina.io
    "iterm2"
    "itermai" # AI plugin for iTerm2
    "istat-menus"
    "jdk-mission-control"
    "jetbrains-toolbox"
    "keka" # Archive utility, supports encrypted ZIP files, https://www.keka.io/
    "kekaexternalhelper" # Register Keka as default app for archives
    "krita"
    "languagetool-desktop"
    "launchcontrol" # Debug launch agents
    "lens" # K8s IDE
    "losslesscut" # Simple video editor: https://github.com/mifi/lossless-cut
    "lunar"
    "lm-studio"# Run LLM locally
    "marked-app" # "Marked 2" markdown viewer. Thsi version supports pandoc
    "marta" # Orthodox file manager
    "MonitorControl"
    "msty" # Run LLM locally
    "notunes" # Prevents Apple Music from hijacking headset buttons
    "omnigraffle"
    "orion" # Kagi Orion Browser
    "orbstack"
    # "macgpt"
    "macwhisper"
    # "maestral" # Leightweight Dropbox client optimized for M1
    "moom" # Moom 4
    "monodraw"
    # "mosaic" # Window manager
    # "multipass" # Ubuntu VMs https://multipass.run
    "obsidian"
    "raindropio"
    "raycast"
    "red-canary-mac-monitor" # System event viewer (Process Monitor / procmon), https://github.com/redcanaryco/mac-monitor
    "redis-insight"
    "sf-symbols" # https://developer.apple.com/sf-symbols/
    "shottr"
    # "studio-3t"
    "suspicious-package" # Inspect and unpack PKG files
    "visual-studio-code"
    "wireshark-app"
    # "wireshark-chmodbpf" # Conflicts with "wireshark"
    "yubico-yubikey-manager"
    "zed" # Zed code editor

    # Display resolution manager
    "betterdisplay" # https://github.com/waydabber/BetterDisplay
    # "switchresx"

    # Window switcher
    # "alt-tab"
    # "witch"
    "tabtab"

    # Mouse key manager
    # "mac-mouse-fix"
    "bettermouse"
    # "better-touch-tool"
    # "usb-overdrive"
  ];
  homebrew.masApps = {
    "1Blocker" = 1365531024;
    "1Password for Safari" = 1569813296;
    "Amphetamine" = 937984704;
    # "Bear" = 1091189122;
    # "Cascadea" = 1432182561; # Seems to be missing from the App store
    "CloudMounter" = 1130254674; # Mounts: Dropbox, Google Drive, OneDrive, Amazon S3, FTP, SFTP, WebDAV
    "Compressor" = 424390742;
    "Corner Time" = 6746757189;
    "Countdown" = 6744842468;
    "DaVinci Resolve" = 571213070;
    "DockTime" = 508034739;
    "Display Maid" = 450063525;
    # "Dynamo" = 1445910651; # Safari Extension to block YouTube Ads
    "File Cabinet Pro" = 1150565778;
    "Final Cut Pro" = 424389933;
    "Friendly Streaming" = 553245401;
    "Gifski" = 1351639930;
    "Goodnotes" = 1444383602;
    "HomeAtmo" = 1359795390; # Netatmo weather station app (humidity, temperature, CO2, etc.)
    "iMazing HEIC Converter" = 1292198261;
    "Infuse" = 1136220934;
    "Horo" = 1437226581;
    # "Ka-Block!", id: 1335413823
    "Keynote" = 409183694;
    "Logic Pro" = 634148309;
    "Logoist 5" = 6443412717;
    "MainStage" = 634159523;
    # "Marked 2" = 890031187; # Use Homebrew version, it supports pandoc
    "MeetingBar" = 1532419400; # Quickly join online meetings from the menus bar
    "MenubarX" = 1575588022;
    # "Moom Classic" = 419330170; # Moom 3
    "Motion" = 434290957;
    "Paste - Clipboard Manager" = 967805235;
    # "PhotoScape X", id: 929507092
    "Pixelmator Pro"= 1289583905;
    "Pointer" = 6736710502; # adds a virtual laser pointer and virtual white board for presentations
    "Plash" =  1494023538; # Use any website as desktop wallpaper
    "PLIST Editor" = 1157491961;
    # "PopClip" = 445189367; # Seems to be missing from the App store
    "Save to Raindrop.io" = 1549370672;
    "Omnivore: Read-it-later" = 1564031042;
    "rcmd" = 1596283165;
    "Shortery" = 1594183810;
    # "Slack for Desktop"= 803453959; # Also available as Homebrew Cask
    "Source Files: Git Storage" = 6450856155; # Mount Git repos in the finder
    "StopTheMadness Pro" = 6471380298; # Ad blocker
    "SponsorBlock for YouTube - Skip Sponsorships" = 1573461917;
    # "Tabby" = 1586203406; # Tab switcher for Safari # Replaced by tabtab
    # "Tabs Switcher" = 1406718335; # Switches browser tabs # Replaced by tabtab
    "Tailscale" = 1475387142;
    # "TinyStopwatch" = 1447754003;
    "UTM" = 1538878817;
    "Vectornator" = 1219074514; # Linearity Curve / Vectornator
    "Velja" = 1607635845; # Open links in specific browser
    "Video Converter" = 1518836004;
  };
  homebrew.onActivation.cleanup = "uninstall";
}
