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
        # auto-optimise-store is deliberately OFF. It hard-links every new file
        # against /nix/store/.links under a global lock, and that directory had
        # grown to 675_925 entries here — `ls` on it did not finish in 120 s.
        # Measured 02.09.2026, same derivation, 4000 small files, two runs each:
        #
        #   auto-optimise-store = true    58.8 s / 58.0 s
        #   auto-optimise-store = false   14.0 s / 13.1 s      -> 4.3x slower
        #
        # That is far worse than the +48 % this repo had already measured on the
        # Linux builder (modules/_files/linux-builder/entrypoint.sh) — the cost
        # grows with the link count, so it gets worse over time on the machine
        # that has been running longest.
        #
        # Deduplication is not given up, only moved off the write path:
        # modules/nix-gc.nix runs `nix store optimise` weekly, and `just optimise`
        # does it on demand. Existing hard links are untouched by this change.
        #
        # NEEDS ONE `just daemon-restart`. This is a DAEMON-side setting and
        # Determinate's nix-daemon reads /etc/nix/nix.custom.conf only at
        # startup, exactly like the post-build-hook string in
        # modules/nix-cache.nix — and `darwin-rebuild switch` does not restart it
        # (nix.enable = false). Measured 02.09.2026, after a switch that wrote
        # `auto-optimise-store = false`, on a daemon started 3 h earlier: a fresh
        # build of a derivation containing two identical files still produced one
        # inode with nlink=3, i.e. the daemon was still deduplicating. `nix config
        # show` is NOT evidence here — a client parses the files itself and
        # happily reports `false` while the daemon does the opposite.
        #
        # The same caveat applies to the removal of download-buffer-size above.
        "auto-optimise-store" = "false";

        # download-buffer-size is deliberately NOT set. It stood at 1 GiB here
        # from 15.03.2026 until 02.09.2026, and this repo had already recorded
        # why that was wrong — modules/_files/linux-builder/entrypoint.sh says of
        # the same setting: "1 MiB is the current upstream default, and since the
        # pause-based backpressure landed in Nix 2.33 the release notes say
        # raising it is no longer recommended. The Mac's value is the stale one."
        # It was measured NOT to be the cause of slow substitution here either:
        # that was per-path latency and, on 02.09.2026, a post-build-hook
        # blocking the build loop. Leaving the default in place keeps one fewer
        # divergence between these Macs and the Linux builder.
        "trusted-users" = [ "root" "stefan" "stefan.schwetschke" ];
        "eval-cores" = "0";
      };
    };
  };
}
