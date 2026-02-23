{ pkgs, ... }:
{
  imports = [
    ./boundary-pm2.sec.nix
    ./vault.sec.nix
  ];

  # This module appends to the existing home.packages list
  home.packages = with pkgs; [
  ];
}
