{ config, inputs, ... }:
let
  inherit (config.flake.modules) darwin homeManager;
in
{
  configurations.darwin.FCX19GT9XR.module = {
    imports = [
      inputs.home-manager.darwinModules.home-manager
      darwin.macos
      darwin.determinate
      darwin.homebrew
      darwin.overlays
    ];

    nixpkgs.hostPlatform = "aarch64-darwin";
    nixpkgs.config.allowUnfree = true;

    users.users.stefan.home = /Users/stefan;
    system.primaryUser = "stefan";

    # Host-specific homebrew
    homebrew.brews = [ ];
    homebrew.casks = [
      "affinity-designer"
      "affinity-photo"
      "affinity-publisher"
      "balenaetcher"
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
      "Faxbot" = 640079107;
      "MoneyMoney" = 872698314;
      "Spark Desktop" = 6445813049;
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "hm.bak";
      users.stefan = {
        imports = [
          homeManager.shell
          homeManager.git
          homeManager.neovim
          homeManager.mcp-servers
          homeManager.aichat
          homeManager.ai-tools
          homeManager.packages
          homeManager.misc
          homeManager.secrets-FCX19GT9XR
        ];
        home.stateVersion = "25.11";
      };
    };
  };
}
