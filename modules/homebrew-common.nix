{ ... }:
{
  flake.modules.darwin.homebrew = {
    homebrew.enable = true;
    homebrew.caskArgs = {
      appdir = "~/Applications";
    };

    homebrew.taps = [
      "gildas/tap"
      "hashicorp/tap"
    ];
    homebrew.brews = [
      "llm"
      "gildas/tap/bitbucket-cli"
      "hashicorp/tap/vault"
    ];
    homebrew.casks = [
      "1password"
      "appcleaner"
      "bartender"
      "beardie"
      "brave-browser"
      "claude"
      "conductor"
      "dash"
      "daisydisk"
      "devutils"
      "elgato-stream-deck"
      "firefox"
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
    homebrew.onActivation.cleanup = "uninstall";
  };
}
