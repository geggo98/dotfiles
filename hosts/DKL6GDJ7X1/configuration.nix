{ pkgs, lib, ... }:
{
  # Disable the nix-daemon, since it clashes with Falcon CrowdStrike
  # nix.useDaemon = lib.mkForce false;
  # services.nix-daemon.enable = lib.mkForce false;
  # nix.gc.user = "stefan.schwetschke";
  # sudo chmod +a "${USER} allow read,write,execute,delete,readattr,writeattr,readextattr,writeextattr,readsecurity,writesecurity,chown,add_file,add_subdirectory,delete_child,file_inherit,directory_inherit" /nix/store

  # For Sequoia migration run: `curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- repair sequoia --move-existing-users`
  # ids.uids.nixbld = 300;
  # With Seqoia, the Nix build user group ID must be changed from 30000 to 350
  # ids.gids.nixbld = 30000;

  # For home-manager
  users.users."stefan.schwetschke".home = /Users/stefan.schwetschke;
}