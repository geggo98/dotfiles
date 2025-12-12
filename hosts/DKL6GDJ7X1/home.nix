{ pkgs, ... }:
{
  imports = [
    ../../modules/boundary-pm2.nix
  ];

  # This module appends to the existing home.packages list
  home.packages = with pkgs; [
  ];
}
