{ inputs, ... }:
{
  imports = [
    inputs.determinate.darwinModules.default
  ];

  nix.enable = false; # Let Determinate manage Nix
  determinate-nix.customSettings = {
    # settings get written into /etc/nix/nix.custom.conf
    "download-buffer-size" = "1073741824"; # 1 GiB
    "trusted-users" = "root stefan stefan.schwetschke";
    "eval-cores" = "0"; # https://docs.determinate.systems/determinate-nix/#parallel-evaluation
    # https://determinate.systems/blog/changelog-determinate-nix-384/
    # https://dtr.mn/features 
    # "extra-experimental-features" = "external-builders";
    # "external-builders" = "[{\"systems\":[\"aarch64-linux\",\"x86_64-linux\"],\"program\":\"/usr/local/bin/determinate-nixd\",\"args\":[\"builder\"]}]";
  };
}
