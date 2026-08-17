{ inputs, ... }:
{
  flake.modules.darwin.determinate = {
    imports = [ inputs.determinate.darwinModules.default ];

    nix.enable = false;
    determinateNix = {
      enable = true;
      determinateNixd = {
        # This is a REQUEST, not a capability. Determinate's Native Linux Builder
        # is gated behind a FlakeHub login, and this machine is logged out, so
        # the setting has no effect whatsoever. Measured:
        #   determinate-nixd status   -> Authentication: logged-out
        #   determinate-nixd version  -> features enabled: lazy-trees   (only)
        #   /nix/var/determinate/netrc is 1 byte
        # while the binary's own feature list is `lazy-trees
        # parallel-evaluation provenance native-linux-builder` and it carries
        # the refusal in plain text ("The Native Linux Builder is not currently
        # available. Contact support@determinate.systems").
        #
        # Linux builds therefore go to the Docker builder instead — see
        # modules/linux-builder.nix. Left enabled so that a future FlakeHub
        # login activates it; if that ever happens, decide deliberately which of
        # the two serves x86_64-linux rather than letting both compete.
        builder = {
          state = "enabled";
          memoryBytes = 8589934592;
          cpuCount = 1;
        };
      };
      customSettings = {
        "auto-optimise-store" = "true";
        "download-buffer-size" = "1073741824";
        "trusted-users" = [ "root" "stefan" "stefan.schwetschke" ];
        "eval-cores" = "0";
      };
    };
  };
}
