{ pkgs, lib, ... }:
{
  # Auto upgrade nix package and the daemon service.
  # services.nix-daemon.enable = true;

  # Left-over from macOS Sequoia migration. Remove after re-install
  # ids.gids.nixbld = 30000;

  # For home-manager
  users.users.stefan.home = /Users/stefan;
}