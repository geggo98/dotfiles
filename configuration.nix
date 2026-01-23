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

  # Create /etc/bashrc that loads the nix-darwin environment.
  programs.zsh.enable = true;
  programs.fish.enable = true;
  #programs.direnv.enable = true;
  #programs.starship.enable = true;

  
  # Apps
  # `home-manager` currently has issues adding them to `~/Applications`
  # Issue: https://github.com/nix-community/home-manager/issues/1341
  environment.systemPackages = with pkgs;
  [ ];

  # https://github.com/nix-community/home-manager/issues/423
  environment.variables = {
    # TERMINFO_DIRS = "${pkgs.kitty.terminfo.outPath}/share/terminfo";
  };
  # programs.nix-index.enable = true;

  # Fonts: `/Library/Fonts/Nix Fonts`.
  # Legacy fonts are in: `/Library/Fonts`.
  # Legacy fonts won't get udpates anymore.
  fonts.packages = with pkgs;
  [
     nerd-fonts.jetbrains-mono
     nerd-fonts.iosevka
     nerd-fonts.victor-mono
     iosevka
     jetbrains-mono
     victor-mono
   ];

  # Add ability to used TouchID for sudo authentication
  security.pam.services.sudo_local.touchIdAuth = true;

  # Set up global keyboard shortcuts.
  #
  # The following sets up a system-wide shortcut for the "Emoji & Symbols"
  # menu item. The name must match exactly, including spaces and punctuation.
  #
  # The value is a string representing the key combination:
  #   ^ : Control
  #   ~ : Option (Alt)
  #   @ : Command (Apple)
  #   $ : Shift
  #   E : The letter key
  system.defaults.CustomUserPreferences = {
    NSGlobalDomain = {
      NSUserKeyEquivalents = {
        "Emoji & Symbols" = "@^~$e";
      };
    };
  };
}
