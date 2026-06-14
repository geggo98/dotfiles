{ config, ... }:
let
  inherit (config.flake.modules) darwin homeManager;
in
{
  configurations.darwin.FCX19GT9XR.module = {
    imports = [
      darwin.home-manager
      darwin.identity
      darwin.macos
      darwin.determinate
      darwin.homebrew
      darwin.overlays
      darwin.pmset-hibernatemode
    ];

    nixpkgs.hostPlatform = "aarch64-darwin";
    nixpkgs.config.allowUnfree = true;

    my.identity = {
      hostName = "FCX19GT9XR";
      computerName = "FCX19GT9XR";
    };

    users.users.stefan.home = /Users/stefan;
    system.primaryUser = "stefan";

    # Host-specific homebrew
    my.homebrew.trustedTaps = [ "localsend/localsend" ];
    homebrew.brews = [ ];
    homebrew.casks = [
      "affinity-designer"
      "affinity-photo"
      "affinity-publisher"
      "balenaetcher"
      "calibre" # nixpkgs calibre is broken on aarch64-darwin; use the cask
      "crossover"
      "chatgpt"
      "jdownloader"
      "karabiner-elements"
      "localsend/localsend/localsend"
      "microsoft-office"
      "openaudible"
      "parallels"
      "resilio-sync"
      "saleae-logic"
      "shortcat"
      "steam"
      "tripmode"
      "vlc"
      "vuescan"
    ];
    homebrew.masApps = {
      "AusweisApp Bund" = 948660805;
      "Brother iPrint&Scan" = 1193539993;
      "Cascadea" = 1432182561;
      "Civilization VII" = 6744373452;
      "ContextMenu" = 1236813619;
      "Cult Of The Lamb" = 1639580858;
      "DeArrow" = 6451469297;
      "Faxbot" = 640079107;
      "Folder Preview" = 6698876601;
      "GarageBand" = 682658836;
      "HACK" = 1464477788;
      "iMovie" = 408981434;
      "Key Codes" = 414568915;
      "MoneyMoney" = 872698314;
      "Moom Classic" = 419330170; # review: superseded by the "moom" cask (Moom 4)?
      "Music Control" = 1490166845;
      "Numbers" = 409203825;
      "Obsidian Web Clipper" = 6720708363;
      "Pages" = 409201541;
      "PopClip" = 445189367;
      "Raycast Companion" = 6738274497;
      "Spark Desktop" = 6445813049;
      "Yomu" = 562211012;
      # Uninstalled 2026-06-06 — kept for later review; do NOT re-declare (would reinstall):
      # "StayFree" = 6465950045;
      # "Stayfree" = 6468659272;
      # "Tabby" = 1586203406;
      # "Tabs Switcher" = 1406718335;
    };

    home-manager.users.stefan = {
      programs.gpg.settings.default-key = "FCX19GT9XR@schwetschke.de";
      imports = [
        homeManager.base
        homeManager.secrets-FCX19GT9XR
      ];
      home.stateVersion = "26.05";
    };
  };
}
