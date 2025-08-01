{ ... }:
{
  imports = [
    ../../modules/homebrew-common.nix
  ];

  homebrew.brews = [
  ];
  homebrew.casks = [
    "affinity-designer"
    "affinity-photo"
    "affinity-publisher"
    "balenaetcher" # Writing iamges to SD Cards
    "crossover"
    "chatgpt"
    "jdownloader"
    "karabiner-elements"
    "localsend/localsend/localsend"
    "microsoft-office"
    "openaudible"
    "resilio-sync"
    "shortcat" # Command palette for every application, but slower than Homerow
    # "slack"
    # "soundsource"
    "steam"
    "tripmode"
    "vlc"
    "vuescan"

    # Manual install:
    # AlDente # Battery Manager
    # Brother PrinterDrivers ColorLaser
    # Strongsync # Clound Mount
  ];
  homebrew.masApps = {
    "AusweisApp Bund" = 948660805;
    "Brother iPrint&Scan" = 1193539993; # Adds Brother drivers for printer and scanner
    "Faxbot" = 640079107;
    "MoneyMoney" = 872698314;
    "Spark Desktop" = 6445813049;
  };
}