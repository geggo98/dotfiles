{ inputs, ... }:
{
  flake.modules.darwin.determinate = {
    imports = [ inputs.determinate.darwinModules.default ];

    nix.enable = false;
    determinateNix = {
      enable = true;
      customSettings = {
        "download-buffer-size" = "1073741824";
        "trusted-users" = [ "root" "stefan" "stefan.schwetschke" ];
        "eval-cores" = "0";
      };
    };
  };
}
