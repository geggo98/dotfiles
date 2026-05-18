{ ... }: {
  flake.modules.darwin.identity = { lib, config, ... }:
    let
      cfg = config.my.identity;
    in
    {
      options.my.identity = {
        hostName = lib.mkOption {
          type = lib.types.str;
          description = "Canonical hostname (ASCII, no spaces). Used for BSD HostName, LocalHostName, and SMB NetBIOSName.";
        };
        computerName = lib.mkOption {
          type = lib.types.str;
          description = "Display name shown in System Settings (may contain spaces/Unicode).";
        };
      };

      config = {
        networking.hostName = cfg.hostName;
        networking.localHostName = cfg.hostName;
        networking.computerName = cfg.computerName;
        system.defaults.smb.NetBIOSName = cfg.hostName;
      };
    };
}
