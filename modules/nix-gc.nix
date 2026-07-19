# Weekly automatic garbage collection of the Nix store.
#
# nix-darwin's built-in `nix.gc.*` options are INERT here: Determinate Nix owns
# the daemon (`nix.enable = false`, see modules/determinate.nix), so nix-darwin
# never emits its GC launchd job. We therefore schedule GC directly as a launchd
# daemon. Running as root, it prunes BOTH the system profile and per-user
# profiles, keeping only generations from the last 7 days; older generations are
# unrooted and their now-dead store paths swept.
#
# Manual runs: `just gc` (user-level) and `just optimise` (dedup). A one-off full
# system sweep is `sudo nix-collect-garbage --delete-older-than 7d`.
{ ... }:
{
  flake.modules.darwin.nix-gc = { ... }:
    {
      launchd.daemons.nix-gc = {
        # Determinate's default-profile path is stable across generations and on the
        # daemon's minimal PATH; /run/current-system/sw/bin has no nix-collect-garbage.
        command = "/nix/var/nix/profiles/default/bin/nix-collect-garbage --delete-older-than 7d";
        serviceConfig = {
          RunAtLoad = false;
          # Sundays at 03:00 local time.
          StartCalendarInterval = [{ Weekday = 0; Hour = 3; Minute = 0; }];
          StandardOutPath = "/var/log/nix-gc.log";
          StandardErrorPath = "/var/log/nix-gc.log";
        };
      };
    };
}
