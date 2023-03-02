#! /bin/sh

# set -Eeuo pipefail
# IFS=$'\n\t'

run_as_root() {
  if [ "$(id -u)" = "0" ]; then
    # we are already root, so just run the command
    "$@"
  elif command -v sudo >/dev/null 2>&1
  then
    # sudo is installed, so use it to run the command
    sudo "$@"
  elif command -v doas >/dev/null 2>&1
  then
    # doas is installed, so use it to run the command
    doas "$@"
  else
    # neither sudo nor doas is installed, so print an error message
    echo "Error: neither sudo nor doas is installed." >&2
    return 1
  fi
}



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
  home.stateVersion = "22.11";

  home.packages = [
    pkgs.htop
    # (pkgs.nerdfonts.override { fonts = [ "Iosevka" "VictorMono" ]; })
    pkgs.ripgrep
    pkgs.fd
    pkgs.watchman
    pkgs.curl
    pkgs.curlie
    pkgs.mcfly
    pkgs.pv
    pkgs.shellcheck
    # pkgs.gitAndTools.git-trim
  ];

  # fonts.fontconfig.enable = true;

  programs.bat.enable = true;
  programs.jq.enable = true;
  programs.direnv.enable = true;
  programs.fish.enable = true;
  programs.fzf.enable = true;
  programs.starship.enable = true;

  programs.git.enable = true;

  programs.tmux.enable = true;

  programs.vim.enable = true; 
}
EOF


if type apt-get
then
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get -y install curl
fi

curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux --no-confirm --init none
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
# nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --update
# if command -v home-manager > /dev/null 2>&1
# then
#   home-manager switch
# else
#   nix-shell '<home-manager>' -A install
#   . "${HOME}/.nix-profile/etc/profile.d/hm-session-vars.sh"
# fi
# . "${HOME}/.nix-profile/etc/profile.d/hm-session-vars.sh"

