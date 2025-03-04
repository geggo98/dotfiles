{ pkgs, ... }:
{
  # This module appends to the existing home.packages list
  home.packages = with pkgs; [
    (pkgs.writeShellScriptBin "boundary_auth" ./scripts/boundary_auth.sh)
    (pkgs.writeShellScriptBin "boundary_connect" ./scripts/boundary_connect_defaults.sh)
  ];
}