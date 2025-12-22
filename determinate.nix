{ inputs, ... }:
{
  imports = [
    inputs.determinate.darwinModules.default
  ];

  nix.enable = false; # Let Determinate manage Nix
  determinate-nix.customSettings = {
    # settings get written into /etc/nix/nix.custom.conf
    "download-buffer-size" = "1073741824"; # 1 GiB
  };
}