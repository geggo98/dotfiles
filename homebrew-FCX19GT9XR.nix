{ pkgs, ... }:
{
  homebrew.enable = true;
  homebrew.caskArgs = {
    appdir = "~/Applications";
    # require_sha = true;
    # no_quarantine = true;
  };
  homebrew.brews = [
    "chatblade"
  ];
  homebrew.casks = [
    "1password"
    "affinity-designer"
    "affinity-photo"
    "affinity-publisher"
    "bartender"
    "brave-browser"
    "dash" # Dash 6
    "daisydisk"
    "devutils" # https://devutils.app/
    # "Dropbox"
    "firefox"
    "google-chrome"
    "http-toolkit"
    # "iina" # VLC video player replacement https://iina.io
    "iterm2"
    "istat-menus"
    "jetbrains-toolbox"
    "keka" # Archive utility, supports encrypted ZIP files, https://www.keka.io/
    "kekaexternalhelper" # Register Keka as default app for archives
    "krita"
    "lens" # K8s IDE
    "losslesscut" # Simple video editor: https://github.com/mifi/lossless-cut
    "lunar"
    "lm-studio"
    "localsend/localsend/localsend"
    "omnigraffle"
    "orbstack"
    "macgpt"
    "macwhisper"
    "microsoft-office"
    # "maestral" # Leightweight Dropbox client optimized for M1
    "monodraw"
    # "mosaic" # Window manager
    # "multipass" # Ubuntu VMs https://multipass.run
    "obsidian"
    "raindropio"
    "raycast"
    "resilio-sync"
    "red-canary-mac-monitor" # System event viewer (Process Monitor / procmon), https://github.com/redcanaryco/mac-monitor
    "shottr"
    # "slack"
    # "soundsource"
    # "studio-3t"
    "steam"
    "tripmode"
    "visual-studio-code"

    # Display resolution manager
    # "betterdisplay" # https://github.com/waydabber/BetterDisplay
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
    # AlDente # Battery Manager
    # Brother PrinterDrivers ColorLaser
    # Strongsync # Clound Mount
    # YourKit Profiler
    # iTerm Shell Integration
  ];
  homebrew.masApps = {
    "1Blocker" = 1365531024;
    "1Password for Safari" = 1569813296;
    "Amphetamine" = 937984704;
    # "Bear" = 1091189122;
    "Cascadea" =1432182561;
    "Compressor" = 424390742;
    "DaVinci Resolve" = 571213070;
    "DockTime" = 508034739;
    # "Dynamo" = 1445910651; # Safari Extension to block YouTube Ads
    "Faxbot" = 640079107;
    "File Cabinet Pro" = 1150565778;
    "Final Cut Pro" = 424389933;
    "Friendly Streaming" = 553245401;
    "Gifski" = 1351639930;
    "Goodnotes" = 1444383602;
    "iMazing HEIC Converter" = 1292198261;
    "Infuse" = 1136220934;
    "Horo" = 1437226581;
    #mas "Ka-Block!", id: 1335413823
    "Keynote" = 409183694;
    "Logic Pro" = 634148309;
    "Logoist 5" = 6443412717;
    "MainStage" = 634159523;
    "Moom" = 419330170;
    "MoneyMoney" = 872698314;
    "Motion" = 434290957;
    "Paste - Clipboard Manager" = 967805235;
    # "PhotoScape X", id: 929507092 
    "Pixelmator Pro"= 1289583905;
    "PopClip" = 445189367;
    "Save to Raindrop.io" = 1549370672;
    "Omnivore: Read-it-later" = 1564031042;
    "rcmd" = 1596283165;
    "Shortery" = 1594183810;
    # "Spark Mail – AI-Mails & Inbox" = -2144121543;
    "SponsorBlock for YouTube - Skip Sponsorships" = 1573461917;
    "Tabby" = 1586203406; # Tab switcher for Safari
    "Vectornator"= 1219074514; # Linearity Curve / Vectornator
    # "Tabs Switcher" = 1406718335; # Switches browser tabs
    "Tailscale" = 1475387142;
    # "TinyStopwatch" = 1447754003;
  };
  homebrew.onActivation.cleanup = "uninstall";
}