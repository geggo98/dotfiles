{ inputs, ... }:
{
  flake.modules.darwin.determinate = {
    imports = [ inputs.determinate.darwinModules.default ];

    nix.enable = false;
    determinateNix = {
      enable = true;
      determinateNixd = {
        builder = {
          state = "enabled";
          memoryBytes = 8589934592;
          cpuCount = 1;
        };
      };
      customSettings = {
        "download-buffer-size" = "1073741824";
        "trusted-users" = [ "root" "stefan" "stefan.schwetschke" ];
        "eval-cores" = "0";
      };
    };
  };
}
