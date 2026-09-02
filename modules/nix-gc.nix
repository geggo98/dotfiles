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
          # Sundays at 03:00 local time, with a 15:00 fallback for a Mac that was
          # powered off at 03:00. A *sleeping* Mac needs no fallback — launchd
          # coalesces missed StartCalendarInterval events and fires them on wake
          # (launchd.plist(5)); only a powered-off machine misses a slot outright.
          # A second run the same day is a no-op: --delete-older-than 7d finds
          # nothing new to sweep.
          StartCalendarInterval = [
            { Weekday = 0; Hour = 3; Minute = 0; }
            { Weekday = 0; Hour = 15; Minute = 0; }
          ];
          StandardOutPath = "/var/log/nix-gc.log";
          StandardErrorPath = "/var/log/nix-gc.log";
        };
      };

      # Store deduplication, moved OFF the write path. It used to happen inline
      # via `auto-optimise-store = true`, which hard-links every new file against
      # /nix/store/.links under a global lock — measured 02.09.2026 at 4.3x the
      # wall clock on a 4000-file derivation, with 675_925 links already there.
      # See the comment in modules/determinate.nix for the numbers.
      #
      # A SEPARATE daemon, not appended to the GC command above: nix-darwin wraps
      # `command` as `… && exec <command>`, so a second command after `&&` would
      # never run. An hour after the GC, so the two do not fight over the big
      # lock; if the GC overruns, `nix store optimise` simply waits for it.
      launchd.daemons.nix-optimise = {
        command = "/nix/var/nix/profiles/default/bin/nix store optimise";
        serviceConfig = {
          RunAtLoad = false;
          StartCalendarInterval = [
            { Weekday = 0; Hour = 4; Minute = 0; }
            { Weekday = 0; Hour = 16; Minute = 0; }
          ];
          # Deduplication is pure background work and must never compete with
          # someone waiting on a build.
          LowPriorityIO = true;
          Nice = 10;
          StandardOutPath = "/var/log/nix-gc.log";
          StandardErrorPath = "/var/log/nix-gc.log";
        };
      };

      # This log was unrotated and had reached 1.7 MB; launchd appends to it
      # forever. macOS runs newsyslog itself and reads this directory.
      #   fields: file  mode count size(KB) when flags   (J = bzip2 the rotations)
      environment.etc."newsyslog.d/nix-gc.conf".text =
        "/var/log/nix-gc.log    644  5  1024  *  J\n";
    };
}
