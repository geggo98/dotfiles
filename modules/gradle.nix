# User-global Gradle settings, plus the job that makes the idle timeout below
# actually happen.
#
# `org.gradle.daemon.idletimeout` does not work on this machine. Measured
# 2026-08-26 against Gradle 9.6.1, daemon PID 16611 (a work project):
#
#   * The setting is read and applied. The daemon's own log records
#     `idleTimeout=10800000` 63 times.
#   * The idle timer is armed correctly. The last build finished
#     2026-08-25T17:11:16, logged as `Command execution: completed` followed by
#     `resetting idle timer`, then `daemon is running. Sleeping until state
#     changes.`
#   * The timer is never disturbed afterwards: 0 occurrences of `resetting idle
#     timer` after 17:11:17.
#   * The periodic check runs the whole time — 3502 `periodic daemon health
#     check` pairs, one every 10 s, through to 2026-08-26T09:56.
#   * And the daemon was still there 16 h 45 min later, against a 3 h timeout,
#     having logged not one expiration message.
#
# The cost is not the daemon itself but what it keeps alive. That JVM held
# 10 forked `Gradle Worker Daemon` compilers at ~600 MB each: the daemon runs on
# zulu-21 from the Nix store while the project needs a Java 25 toolchain, so
# Gradle cannot run javac in-process and forks one worker per compile task.
# `org.gradle.workers.max` is unset, so the default is the core count (12), and
# `org.gradle.parallel=true` starts them all. Thirteen JVMs, 11.5 GB of
# footprint, 0.0 % CPU, idle since the previous afternoon.
#
# On a 32 GB machine that is the difference between working and not. Reaping
# them took this machine from load 15.8 / 0.6 % idle / 16 GB compressor /
# 15 swapfiles to load 2.28 / 76.6 % idle / 4.5 GB compressor / 5 swapfiles.
#
# The root cause inside Gradle is NOT established. The daemon logs nothing at
# all about expiration, so there is no evidence to say whether the strategy is
# skipped, mis-evaluated, or never scheduled, and no matching upstream issue was
# found. Treat the mechanism as open — this job enforces the outcome, it does
# not fix Gradle.
#
# Why SIGTERM and not `gradle --stop`: `--stop` needs a matching Gradle
# distribution per version (28 live under ~/.gradle/daemon here) and only sees
# daemons in the registry — the Gradle 8.5 daemon observed that day had an empty
# registry.bin and was invisible to it. SIGTERM reaches every daemon and shuts
# them down cleanly: the reap above produced `Abort requested. Destroying
# process: Gradle Worker Daemon 20/21/26/27/28/86` in the daemon log, and all
# 13 JVMs were gone within 20 s with no orphaned workers.
#
# Manual run: `gradle-daemon-reap` (optional argument = idle seconds, default
# 10800). `gradle-daemon-reap 0` reaps every idle daemon regardless of age.
{ ... }:
{
  flake.modules.homeManager.gradle = { config, pkgs, ... }:
    let
      gradle-daemon-reap = pkgs.writeShellApplication {
        name = "gradle-daemon-reap";
        runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
        text = ''
          threshold="''${1:-10800}"
          now=$(date +%s)

          # BSD ps prints [[dd-]hh:]mm:ss. Used only for daemons whose log we
          # cannot find, i.e. those started with a foreign GRADLE_USER_HOME.
          etime_to_s() {
            local t="$1" d=0 h=0 m=0 s=0 a b c
            if [[ "$t" == *-* ]]; then d="''${t%%-*}"; t="''${t#*-}"; fi
            IFS=: read -r a b c <<< "$t"
            if [[ -n "''${c:-}" ]]; then h="$a"; m="$b"; s="$c"; else m="$a"; s="''${b:-0}"; fi
            echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
          }

          candidates=()

          # `pgrep -f` on the bootstrap class rather than on "gradle": it matches
          # the daemon JVM and nothing else — not the launcher, not the wrapper,
          # not the forked workers (those die with their daemon anyway).
          while read -r pid; do
            [[ -n "$pid" ]] || continue

            log=$(find "$HOME/.gradle/daemon" -maxdepth 2 -name "daemon-$pid.out.log" 2>/dev/null | head -1)

            if [[ -n "$log" ]]; then
              # Gradle brackets every build with `Command execution: started`
              # and `... completed`. If the newer of the two is `started`, a
              # build is in flight — regardless of how long ago it began. A long
              # build must never be reaped just for exceeding the threshold.
              last=$(grep -E 'Command execution: (started|completed)' "$log" | tail -1 || true)

              if [[ "$last" == *"Command execution: started"* ]]; then
                echo "$(date -Iseconds) pid $pid: build in flight — skipped"
                continue
              fi

              if [[ -n "$last" ]]; then
                since=$(date -d "''${last%% *}" +%s 2>/dev/null || echo 0)
                [[ "$since" -gt 0 ]] || continue
                idle=$(( now - since ))
                why="idle $(( idle / 60 )) min since last build"
              else
                # Log exists but no build ever ran through it.
                idle=$(etime_to_s "$(ps -o etime= -p "$pid" | tr -d ' ')")
                why="up $(( idle / 60 )) min, never ran a build"
              fi
            else
              # No log under ~/.gradle: started with GRADLE_USER_HOME pointing
              # somewhere else (CLAUDE.md has agents use `mktemp -d` for
              # verification-metadata work). Those are throwaway by definition,
              # and `gradlew --stop` in a normal shell never sees them.
              idle=$(etime_to_s "$(ps -o etime= -p "$pid" | tr -d ' ')")
              why="up $(( idle / 60 )) min, foreign GRADLE_USER_HOME"
            fi

            if [[ "$idle" -ge "$threshold" ]]; then
              candidates+=("$pid|$why")
            fi
          done < <(pgrep -f 'org.gradle.launcher.daemon.bootstrap.GradleDaemon' || true)

          if [[ ''${#candidates[@]} -eq 0 ]]; then
            echo "$(date -Iseconds) no daemon idle for $(( threshold / 60 )) min or more — nothing to do"
            exit 0
          fi

          # Last gate before killing: cumulative CPU time must not move. The log
          # check above can only be as fresh as what the daemon wrote; this
          # catches anything busy that the log did not describe. One sample for
          # all candidates, not one per daemon.
          declare -A before=()
          for entry in "''${candidates[@]}"; do
            pid="''${entry%%|*}"
            before[$pid]=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ' || true)
          done
          sleep 5

          for entry in "''${candidates[@]}"; do
            pid="''${entry%%|*}"
            why="''${entry#*|}"
            after=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ' || true)

            if [[ -z "$after" ]]; then
              echo "$(date -Iseconds) pid $pid: exited on its own — skipped"
              continue
            fi
            if [[ "''${before[$pid]}" != "$after" ]]; then
              echo "$(date -Iseconds) pid $pid: burning CPU ''${before[$pid]} -> $after — skipped"
              continue
            fi

            echo "$(date -Iseconds) pid $pid: $why — SIGTERM"
            kill -TERM "$pid" 2>/dev/null || true
          done

          # Gradle shuts its workers down on SIGTERM, but that walk takes a
          # moment on a machine that has swapped the daemon out.
          sleep 20
          for entry in "''${candidates[@]}"; do
            pid="''${entry%%|*}"
            if kill -0 "$pid" 2>/dev/null; then
              echo "$(date -Iseconds) pid $pid: still alive after 20 s — SIGKILL"
              kill -KILL "$pid" 2>/dev/null || true
            fi
          done

          # BSD pgrep has no -c; count the lines instead. `|| left=0` covers
          # the exit status 1 pgrep returns when nothing matches.
          left=$(pgrep -f 'org.gradle.launcher.daemon.bootstrap.GradleDaemon' | wc -l | tr -d ' ') || left=0
          echo "$(date -Iseconds) done — $left daemon(s) left"
        '';
      };
    in
    {
      home.packages = [ gradle-daemon-reap ];

      # The local build cache lives at ~/.gradle/caches/build-cache-1/ and is
      # keyed on task inputs (sources, classpath, toolchain) — not on the
      # worktree path — so identical modules across worktrees of the same repo
      # share cache entries.
      home.file.".gradle/gradle.properties".text = ''
        # Managed by nix-darwin (modules/gradle.nix). Do not edit by hand.

        org.gradle.caching=true
        org.gradle.parallel=true

        # Stop idle daemons after 3 h. One daemon per project/JVM-args combo,
        # so many parallel worktrees would otherwise hold a lot of RAM.
        #
        # Gradle does not honour this — see the module header. The
        # gradle-daemon-reap launchd agent enforces the same 3 h instead. Keep
        # the two numbers in step if you change either.
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

      launchd.agents.gradle-daemon-reap = {
        enable = true;
        config = {
          ProgramArguments = [ "${gradle-daemon-reap}/bin/gradle-daemon-reap" ];
          RunAtLoad = false;
          # Every 30 min rather than a calendar slot: idleness is continuous, so
          # what matters is the worst-case overshoot past 3 h, not the hour of
          # day. launchd coalesces intervals missed while asleep and fires once
          # on wake — launchd.plist(5) — so a closed lid costs one run, not the
          # rest of the day.
          StartInterval = 1800;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/gradle-daemon-reap.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gradle-daemon-reap.log";
        };
      };
    };
}
