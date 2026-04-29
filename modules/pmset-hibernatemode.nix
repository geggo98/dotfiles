{ ... }:
{
  flake.modules.darwin.pmset-hibernatemode = { pkgs, ... }:
    let
      pmset-hibernatemode = pkgs.writeShellApplication {
        name = "pmset-hibernatemode";
        text = ''
          mode="''${1:-}"
          case "$mode" in
            standby-ram)  hm=3  ;;
            disk)         hm=25 ;;
            *)
              {
                echo "Usage: $(basename "$0") {standby-ram|disk}"
                echo "  standby-ram  hibernatemode=3 (Apple Silicon default; sleep keeps RAM powered, fast wake)"
                echo "  disk         hibernatemode=25 (RAM written to disk, memory powered off; saves battery, slower wake)"
              } >&2
              exit 64
              ;;
          esac
          exec /usr/bin/pmset -a hibernatemode "$hm"
        '';
      };
    in
    {
      environment.systemPackages = [ pmset-hibernatemode ];

      security.sudo.extraConfig = ''
        %admin ALL=(root) NOPASSWD: /run/current-system/sw/bin/pmset-hibernatemode
      '';
    };
}
