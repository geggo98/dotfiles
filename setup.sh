#! /bin/sh

mkdir -p "${HOME}/.config/nixpkgs/"
cat > "${HOME}/.config/nixpkgs/home.nix" <<EOF

{ config, pkgs, ... }:

{
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "$(whoami)";
  home.homeDirectory = "${HOME}";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "20.09";

  home.packages = [
    pkgs.htop
    pkgs.fortune
    (pkgs.nerdfonts.override { fonts = [ "Iosevka" "VictorMono" ]; })
    pkgs.ripgrep
    pkgs.fd
    pkgs.watchman
    pkgs.curl
    pkgs.curlie
    pkgs.sops
    pkgs.mcfly
    pkgs.visidata
    pkgs.glances
    pkgs.dive
    pkgs.mkcert
    pkgs.step-cli
    pkgs.hexyl
    pkgs.pv
    pkgs.shellcheck
    pkgs.pueue
    pkgs.vips
    pkgs.gitAndTools.git-trim
  ];

  fonts.fontconfig.enable = true;

  programs.bat.enable = true;
  programs.jq.enable = true;
  programs.direnv.enable = true;
  programs.fish.enable = true;
  programs.fzf.enable = true;
  programs.starship.enable = true;

  programs.git.enable = true;

  programs.tmux.enable = true;

  programs.emacs = {
    enable = true;
    package = pkgs.emacs-nox;
  };

  programs.vim.enable = true; 

  #home.file.".emacs.d" = {
  #  # don't make the directory read only so that impure melpa can still happen
  #  # for now
  #  recursive = true;
  #  source = pkgs.fetchFromGitHub {
  #    owner = "syl20bnr";
  #    repo = "spacemacs";
  #    rev = "7e38f2e64e1c5cc74966cdbccf6b4adc2f89fc44";
  #    sha256 = "0bjbmk4c7f1pr5vrpbapv594mcz379krvwvfzs4g91yvmsva6g9z";
  #  };
  #};

  # spacemacs
  home.file = { 
    ".emacs.d" = {
       source = pkgs.fetchFromGitHub {
         owner = "syl20bnr";
         repo = "spacemacs";
         rev = "1f93c05";
         sha256 = "1x0s5xlwhajgnlnb9mk0mnabhvhsf97xk05x79rdcxwmf041h3fd";
       };
       recursive = true;
    };
  };
  
  home.activation = {
    spacemacs = ''
      $DRY_RUN_CMD touch ~/.spacemacs
    '';
  };
}
EOF


if type apt-get
then
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -y install curl xz-util
fi

curl -L https://nixos.org/nix/install | sh
. "${HOME}/.nix-profile/etc/profile.d/nix.sh"
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --update
if type home-manager
then
  home-manager switch
else
  nix-shell '<home-manager>' -A install
  . "${HOME}/.nix-profile/etc/profile.d/hm-session-vars.sh"
fi
. "${HOME}/.nix-profile/etc/profile.d/hm-session-vars.sh"

