{ pkgs, ... }:
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
    "llm" # The Nix version has still problems with plugins
  ];
  homebrew.casks = [
    "1password"
    "affinity-designer"
    "affinity-photo"
    "affinity-publisher"
    "appcleaner"
    "bartender"
    "beardie" # Control Media Keys https://github.com/Stillness-2/beardie
    "balenaetcher" # Writing iamges to SD Cards
    "brave-browser"
    "crossover"
    "dash" # Dash 6
    "daisydisk"
    "devutils" # https://devutils.app/
    # "Dropbox"
    "firefox"
    "google-chrome"
    "hammerspoon" # Helper for RCmd with alt-key
    "http-toolkit"
    # "iina" # VLC video player replacement https://iina.io
    "iterm2"
    "itermai" # AI plugin for iTerm2
    "istat-menus"
    "jetbrains-toolbox"
    "karabiner-elements"
    "keka" # Archive utility, supports encrypted ZIP files, https://www.keka.io/
    "kekaexternalhelper" # Register Keka as default app for archives
    "krita"
    "lens" # K8s IDE
    "losslesscut" # Simple video editor: https://github.com/mifi/lossless-cut
    "lunar"
    "lm-studio"
    "localsend/localsend/localsend"
    "MonitorControl"
    "omnigraffle"
    "orbstack"
    # "macgpt"
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
    "sf-symbols" # https://developer.apple.com/sf-symbols/
    "shottr"
    # "slack"
    # "soundsource"
    # "studio-3t"
    "steam"
    "tripmode"
    "vuescan"
    "visual-studio-code"
    "yubico-yubikey-manager"

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
    "Brother iPrint&Scan" = 1193539993; # Adds Brother drivers for printer and scanner
    "Cascadea" =1432182561;
    "CloudMounter" = 1130254674; # Mounts: Dropbox, Google Drive, OneDrive, Amazon S3, FTP, SFTP, WebDAV
    "Compressor" = 424390742;
    "DaVinci Resolve" = 571213070;
    "Display Maid" = 450063525;
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
    "HomeAtmo" = 1359795390; # Netatmo weather station app (humidity, temperature, CO2, etc.)
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
    "Spark Desktop" = 6445813049;
    "SponsorBlock for YouTube - Skip Sponsorships" = 1573461917;
    "Tabby" = 1586203406; # Tab switcher for Safari
    "Velja" = 1607635845; # Open links in specific browser
    "Vectornator"= 1219074514; # Linearity Curve / Vectornator
    # "Tabs Switcher" = 1406718335; # Switches browser tabs
    "Tailscale" = 1475387142;
    # "TinyStopwatch" = 1447754003;
  };
  homebrew.onActivation.cleanup = "uninstall";
}
