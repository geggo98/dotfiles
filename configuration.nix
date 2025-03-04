{ pkgs, lib, ... }:
{
  # Determinate uses its own daemon to manage the Nix installation that
  # conflicts with nix-darwin’s native Nix management.
  #
  # To turn off nix-darwin’s management of the Nix installation, set:
  #
  #     nix.enable = false;
  #
  # This will allow you to use nix-darwin with Determinate. Some nix-darwin
  # functionality that relies on managing the Nix installation, like the
  # `nix.*` options to adjust Nix settings or configure a Linux builder,
  # will be unavailable.
  #
  # Put custom parameters into `/etc/nix/nix.custom.conf`
  nix.enable = false;

  # #  Nix configuration ------------------------------------------------------------------------------
  # nix.settings.substituters = [
  #   "https://cache.nixos.org/"
  # ];
  # nix.settings.extra-trusted-public-keys = [
  #   "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  # ];
  # nix.settings.trusted-users = [
  #   "@admin"
  # ];
  # # Enable the Linux builder
  # #   # Example:
  # #   $ nix build \
  # #   --impure \
  # #   --expr '(with import <nixpkgs> { system = "aarch64-linux"; }; runCommand "foo" {} "uname -a > $out")'
  # #   $ cat result
  # #   Linux localhost 6.1.72 #1-NixOS SMP Wed Jan 10 16:10:37 UTC 2024 aarch64 GNU/Linux
  # nix.linux-builder.enable = true;
  # nix.configureBuildUsers = true;
  #
  # # Enable experimental nix command and flakes
  # # Alternatives:
  # # - pkgs.nixVersions.latest
  # # - pkgs.nixVersions.git.legacyPackages.${pkgs.system};
  # # - pkgs.nixVersions.git
  # # nix.package = pkgs.nixUnstable;
  #
  # nix.extraOptions = ''
  #   auto-optimise-store = true
  #   download-buffer-size = 1000000000
  #   experimental-features = nix-command flakes
  # '' + lib.optionalString (pkgs.system == "aarch64-darwin") ''
  #   extra-platforms = x86_64-darwin aarch64-darwin
  # '';
  # # Extra platforms allow to build for Intel and ARM on Apple Silicon:
  # # ```bash
  # # $ nix run nixpkgs#legacyPackages.aarch64-darwin.hello
  # # Hello, world!
  # # $ nix run nixpkgs#legacyPackages.x86_64-darwin.hello
  # # Hello, world!
  # # ```
  # nix.gc = {
  #   automatic = true;
  #   options = "--delete-older-than 30d";
  # };

  # Create /etc/bashrc that loads the nix-darwin environment.
  programs.zsh.enable = true;
  programs.fish.enable = true;
  #programs.direnv.enable = true;
  #programs.starship.enable = true;

  
  # Apps
  # `home-manager` currently has issues adding them to `~/Applications`
  # Issue: https://github.com/nix-community/home-manager/issues/1341
  environment.systemPackages = with pkgs; [
  ];

  # https://github.com/nix-community/home-manager/issues/423
  environment.variables = {
    # TERMINFO_DIRS = "${pkgs.kitty.terminfo.outPath}/share/terminfo";
  };
  programs.nix-index.enable = true;

  # Fonts: `/Library/Fonts/Nix Fonts`.
  # Legacy fonts are in: `/Library/Fonts`.
  # Legacy fonts won't get udpates anymore.
  fonts.packages = with pkgs; [
     recursive
     (nerdfonts.override { fonts = [ "JetBrainsMono" "Iosevka" "IosevkaTerm" "VictorMono" ]; })
     iosevka
     jetbrains-mono
     victor-mono
   ];

  # Keyboard
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToEscape = true;

  # Add ability to used TouchID for sudo authentication
  security.pam.enableSudoTouchIdAuth = true;
}