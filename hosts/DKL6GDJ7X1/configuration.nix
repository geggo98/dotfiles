{ pkgs, lib, ... }:
{
  nix.useDaemon = lib.mkforce false;
  services.nix-daemon.enable = false;
}