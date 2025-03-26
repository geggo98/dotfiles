{ ... }:
{
  homebrew.enable = true;
  homebrew.caskArgs = {
    appdir = "~/Applications";
    # require_sha = true;
    # no_quarantine = true;
  };
  homebrew.brews = [
    # "chatblade"
    # "jan" # https://jan.ai
    "hashicorp/tap/boundary"
    "llm" # The Nix version has still problems with plugins
  ];
  homebrew.casks = [
    "1password"
    # "affinity-designer"
    # "affinity-photo"
    # "affinity-publisher"
    "appcleaner"
    "aptakube"
    "bartender"
    "beardie" # Control Media Keys https://github.com/Stillness-2/beardie
    "bleunlock" # Unlock Mac based on mobile phone presence. https://github.com/ts1/BLEUnlock
    "hashicorp/tap/hashicorp-boundary-desktop"
    "brave-browser"
    "cursor"
    "dash" # Dash 6
    "daisydisk"
    "devutils" # https://devutils.app/
    "Dropbox"
    "elgato-stream-deck"
    "firefox"
    "gpg-suite-no-mail"
    "google-chrome"
    "git-credential-manager" # The version in Nix doesn't find its Dotnet SDK
    "hammerspoon"
    "homerow"
    "http-toolkit"
    # "iina" # VLC video player replacement https://iina.io
    "iterm2"
    "itermai" # AI plugin for iTerm2
    "istat-menus"
    "jetbrains-toolbox"
    "keka" # Archive utility, supports encrypted ZIP files, https://www.keka.io/
    "kekaexternalhelper" # Register Keka as default app for archives
    "krita"
    "languagetool"
    "lens" # K8s IDE
    "losslesscut" # Simple video editor: https://github.com/mifi/lossless-cut
    "lunar"
    "lm-studio"# Run LLM locally
    "marked" # "Marked 2" markdown viewer. Thsi version supports pandoc
    "MonitorControl"
    "msty" # Run LLM locally
    "notunes" # Prevents Apple Music from hijacking headset buttons
    "omnigraffle"
    "openvpn-connect"
    "orbstack"
    "postman"
    "postman-cli"
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
    "sf-symbols" # https://developer.apple.com/sf-symbols/
    "shottr"
    "slack" # Also available via the Mac App Store
    # "studio-3t"
    "tunnelblick"
    "visual-studio-code"
    "wireshark"
    # "wireshark-chmodbpf" # Conflicts with "wireshark"
    "yubico-yubikey-manager"
    "zed" # Zed code editor

    # Display resolution manager
    "betterdisplay" # https://github.com/waydabber/BetterDisplay
    # "switchresx"
    
    # Window switcher
    # "alt-tab"
    # "witch"

    # Mouse key manager
    # "mac-mouse-fix"
    "bettermouse"
    # "better-touch-tool"
    # "usb-overdrive"

    # Manual install:
    # YourKit Profiler
    # iTerm Shell Integration
  ];
  homebrew.masApps = {
    "1Blocker" = 1365531024;
    "1Password for Safari" = 1569813296;
    "Amphetamine" = 937984704;
    # "Bear" = 1091189122;
    "Cascadea" = 1432182561;
    "CloudMounter" = 1130254674; # Mounts: Dropbox, Google Drive, OneDrive, Amazon S3, FTP, SFTP, WebDAV
    "Compressor" = 424390742;
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
    # "Moom Classic" = 419330170; # Moom 3
    "Motion" = 434290957;
    "Paste - Clipboard Manager" = 967805235;
    # "PhotoScape X", id: 929507092 
    "Pixelmator Pro"= 1289583905;
    "PopClip" = 445189367;
    "Save to Raindrop.io" = 1549370672;
    "Omnivore: Read-it-later" = 1564031042;
    "rcmd" = 1596283165;
    "Shortery" = 1594183810;
    # "Slack for Desktop"= 803453959; # Also available as Homebrew Cask
    "Source Files: Git Storage" = 6450856155; # Mount Git repos in the finder
    "SponsorBlock for YouTube - Skip Sponsorships" = 1573461917;
    "Tabby" = 1586203406; # Tab switcher for Safari
    # "Tabs Switcher" = 1406718335; # Switches browser tabs
    "Tailscale" = 1475387142;
    # "TinyStopwatch" = 1447754003;
    "UTM" = 1538878817;
    "Vectornator" = 1219074514; # Linearity Curve / Vectornator
    "Velja" = 1607635845; # Open links in specific browser
    "Video Converter" = 1518836004;
  };
  homebrew.onActivation.cleanup = "uninstall";
}
