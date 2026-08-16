# Scheduled consolidation of Nix's tarball cache (~/.cache/nix/tarball-cache-v2).
#
# Upstream Nix expects this maintenance and ships no job to do it. From
# src/libfetchers/git-utils.cc:1516-1518, on the cache format itself:
#
#   /* v1: Had either only loose objects or thin packfiles referring to loose objects
#    * v2: Must have only packfiles with no loose objects. Should get repacked periodically
#    * for optimal packfiles.
#    */
#
# Nothing in Nix ever performs that periodic repack. Its fetcher appends one pack
# file per tarball import and never consolidates, so the cache degenerates. By
# 2026-08 this machine's cache held 2032 packs / 886 MB, with a single nixpkgs
# revision smeared across 276 of them. In that state flake evaluation failed with
# `object not found - no match for id (libgit2 error code = 9)`, naming a
# DIFFERENT nixpkgs file on every run.
#
# What was measured (2026-08-16), and is solid:
#   * No data loss. All 90607 objects of the pinned nixpkgs tree were present and
#     readable via the git CLI; a full object-by-object diff before/after the
#     repair showed 0 missing.
#   * 2032 packs held only 588775 distinct objects — ~136000 duplicates, i.e.
#     several processes had been importing overlapping tarballs concurrently.
#     The pack count grew 2022 -> 2032 during the debugging session itself.
#   * libgit2 1.9.2 (which Nix uses for lazy-trees) has DEFAULT_FILE_LIMIT = 0
#     (src/libgit2/mwindow.c:25), so it never closes a pack file once opened —
#     an idle `devenv mcp` was holding 1815 open handles into this cache.
#
# What was NOT pinned down: the exact libgit2/Nix code path that turns "2032
# packs + a concurrent writer" into a failed object lookup. An early theory
# blamed `backend->refresh = nullptr` (git-utils.cc:414), but that is applied
# only to the short-lived clones from GitRepoImpl::getPool() — the tarball import
# writer and a transient rev-count walk. The long-lived reader handle
# (git-utils.cc:1523) keeps refresh intact and does rescan on a miss, so that
# theory does not explain the reader side. Treat the mechanism as open.
#
# Source-line anchors above were read against Determinate Nix 3.21.9
# (= Nix 2.34.8) and libgit2 1.9.2; expect them to drift with either.
#
# What is certain is the cure: consolidating the packs makes it go away, and it
# stayed away. Manual run: `nix-tarball-cache-repack`
# (optional argument = pack-count threshold, default 250).
#
# Why daily rather than weekly: the pack count, not the calendar, decides whether
# any work happens — under the threshold this costs one `find | wc -l` (~2 ms)
# and exits. Checking every day means a machine that was powered off during one
# slot simply catches up the next day. (A *sleeping* Mac needs no such fallback:
# launchd coalesces missed StartCalendarInterval events and fires them on wake —
# launchd.plist(5). Only a powered-off machine misses a slot outright.)
#
# XDG_CACHE_HOME is a trap here. Nix locates this cache via getCacheDir(), i.e.
# $XDG_CACHE_HOME or ~/.cache — but a launchd agent inherits only PATH,
# SSH_AUTH_SOCK and the XPC keys, never what your shell exports. Export that
# variable from fish/zsh alone and Nix writes to one directory while this agent
# repacks another, reporting "nothing to do" and exit 0 every single day while the
# real cache degenerates. Two guards below: the agent is handed XDG_CACHE_HOME
# whenever home-manager itself would export it, and a missing cache is a loud
# warning that names the variable rather than a bland no-op line.
#
# Companion to modules/nix-gc.nix, which sweeps the store itself.
{ ... }:
{
  flake.modules.homeManager.nix-tarball-cache-repack = { config, pkgs, ... }:
    let
      nix-tarball-cache-repack = pkgs.writeShellApplication {
        name = "nix-tarball-cache-repack";
        runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.findutils ];
        text = ''
          # Same resolution Nix's getCacheDir() uses — see the XDG_CACHE_HOME note
          # in the module header before changing this.
          cache="''${XDG_CACHE_HOME:-$HOME/.cache}/nix/tarball-cache-v2"
          threshold="''${1:-250}"

          count_packs() {
            find "$cache/objects/pack" -maxdepth 1 -name '*.idx' | wc -l | tr -d ' '
          }

          if [[ ! -d "$cache/objects/pack" ]]; then
            {
              echo "$(date -Iseconds) WARNING: no tarball cache at $cache"
              echo "  Either Nix has not fetched a flake input yet, or XDG_CACHE_HOME"
              echo "  differs between your shell and this job. A launchd agent inherits"
              echo "  only PATH, SSH_AUTH_SOCK and the XPC keys, so exporting it from"
              echo "  fish/zsh alone leaves Nix writing one directory while this job"
              echo "  repacks another — silently, every day, forever."
              echo "  Compare:  launchctl getenv XDG_CACHE_HOME   vs   printenv XDG_CACHE_HOME"
            } >&2
            exit 0
          fi

          packs="$(count_packs)"
          if (( packs < threshold )); then
            echo "$(date -Iseconds) $packs pack(s), below threshold $threshold — nothing to do"
            exit 0
          fi

          echo "$(date -Iseconds) repacking $cache — $packs packs, $(du -sh "$cache" | cut -f1)"

          # -k is MANDATORY: this repo has no refs at all (Nix keeps the
          # narHash -> tree mapping in fetcher-cache-v*.sqlite instead), so every
          # object is unreachable and a plain `repack -a -d` would delete the
          # entire cache. -l keeps it local; bitmaps are pointless without refs.
          git -C "$cache" repack -a -d -k -l --no-write-bitmap-index

          echo "$(date -Iseconds) done — $(count_packs) pack(s), $(du -sh "$cache" | cut -f1)"
        '';
      };
    in
    {
      home.packages = [ nix-tarball-cache-repack ];

      launchd.agents.nix-tarball-cache-repack = {
        enable = true;
        config = {
          ProgramArguments = [ "${nix-tarball-cache-repack}/bin/nix-tarball-cache-repack" ];
          # Hand the agent the same XDG_CACHE_HOME the session gets, since it
          # inherits no shell environment of its own. Gated on `xdg.enable`
          # because that is exactly the condition under which home-manager
          # exports the variable at all (its modules/misc/xdg.nix uses
          # `mkIf cfg.enable`). Forwarding it unconditionally would invent a
          # mismatch on a config that sets xdg.cacheHome while leaving
          # xdg.enable off — there the session still resolves ~/.cache.
          EnvironmentVariables =
            if config.xdg.enable
            then { XDG_CACHE_HOME = config.xdg.cacheHome; }
            else null;
          RunAtLoad = false;
          # Every day at 13:30 — Weekday omitted is a launchd wildcard. Mid-day so
          # a laptop is actually awake; the threshold makes the usual run a no-op.
          StartCalendarInterval = [{ Hour = 13; Minute = 30; }];
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/nix-tarball-cache-repack.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/nix-tarball-cache-repack.log";
        };
      };
    };
}
