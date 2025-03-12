{ pkgs, ... }:
{
  # This module appends to the existing home.packages list
  home.packages = with pkgs; [
    (pkgs.writeShellScriptBin "+boundary_legacy_auth" ./scripts/boundary_legacy_auth.sec.sh)
    (pkgs.writeShellScriptBin "+boundary_legacy_connect_defaults" ./scripts/boundary_legacy_connect_defaults.sec.sh)
  ];
}