{ pkgs, lib, ... }:
{
  # Disable the nix-daemon, since it clashes with Falcon CrowdStrike
  nix.useDaemon = lib.mkForce false;
  services.nix-daemon.enable = lib.mkForce false;
  nix.gc.user = "stefan.schwetschke";

  # For home-manager
  users.users."stefan.schwetschke".home = /Users/stefan.schwetschke;
}