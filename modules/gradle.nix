{ ... }:
{
  # User-global Gradle settings. The local build cache lives at
  # ~/.gradle/caches/build-cache-1/ and is keyed on task inputs (sources,
  # classpath, toolchain) — not on the worktree path — so identical modules
  # across worktrees of the same repo share cache entries.
  flake.modules.homeManager.gradle = {
    home.file.".gradle/gradle.properties".text = ''
      # Managed by nix-darwin (modules/gradle.nix). Do not edit by hand.

      org.gradle.caching=true
      org.gradle.parallel=true

      # Stop idle daemons after 3 h. One daemon per project/JVM-args combo,
      # so many parallel worktrees would otherwise hold a lot of RAM.
      org.gradle.daemon.idletimeout=10800000
    '';

    # Bumps the local cache TTL from the 7-day default to 30 days, which
    # survives longer worktree rotations. Uses the `beforeSettings { caches }`
    # form (Gradle 8.0+) instead of the legacy
    # `settingsEvaluated { buildCache.local.removeUnusedEntriesAfterDays }`,
    # which was removed in Gradle 9.0.
    home.file.".gradle/init.d/cache.gradle.kts".text = ''
      beforeSettings {
          caches {
              buildCache.setRemoveUnusedEntriesAfterDays(30)
          }
      }
    '';
  };
}
