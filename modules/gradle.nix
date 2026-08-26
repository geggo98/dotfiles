# User-global Gradle settings, plus the job that makes the idle timeout below
# actually happen.
#
# `org.gradle.daemon.idletimeout` is unreliable on this machine — it works most
# of the time and sometimes does not, and the times it does not are expensive.
# Surveyed 2026-08-26 across every daemon log under ~/.gradle/daemon. Of the nine
# daemons that actually reached the 3 h mark:
#
#   * 6 expired at exactly 3.00 h (Gradle 8.5, 9.4.1 twice, 9.6.1 three times)
#   * 1 expired at 5.37 h
#   * 2 never expired: still logging 16.12 h and 16.75 h after their last build,
#     and both ended by hand rather than by Gradle
#
# Five more were shut down before three hours had passed and say nothing either
# way. So this is not a broken setting and not a version-specific bug — the same
# 9.6.1 appears on both sides of the tally.
#
# The failing case, in detail. Gradle 9.6.1, daemon PID 16611
# (a work project):
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
# The root cause inside Gradle is NOT established. A daemon that fails to expire
# logs nothing at all about it, so there is no evidence to say whether the
# strategy is skipped, mis-evaluated, or never scheduled, and no matching
# upstream issue was found. That a healthy daemon logs `Marking daemon stopped
# due to after being idle for 180 minutes` makes the silence in the other case
# more conspicuous, not more explicable.
#
# Which is the argument for this job rather than against it. A timeout that
# holds in most cases still leaves the 10 GB outcome above whenever it does not,
# and on a 32 GB machine that is not a residual risk worth carrying. The job is
# a safety net under an intermittent mechanism; it is not a replacement for it,
# and it costs nothing on the days Gradle does the right thing — the log then
# reads `no daemon idle for 180 min or more — nothing to do`.
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
        runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.perl ];
        text = ''
          threshold="''${1:-10800}"

          # ALL timestamp arithmetic goes through perl, and that is a correctness
          # decision rather than a style one. The obvious `date -d "$ts" +%s` is
          # GNU-only — /bin/date answers "illegal option -- d" — so it worked here
          # solely because coreutils sits in runtimeInputs. Its failure branch was
          # `|| echo 0` feeding a `-gt 0` test, so the day anyone tidied that
          # dependency away, this job would have reported "nothing to do" forever
          # while reaping nothing: a silent no-op, the exact shape AGENTS.md warns
          # about under "`|| fail` is where the distinction dies".
          #
          # perl is pinned in runtimeInputs like every other tool, and costs
          # nothing extra — perl is already in this system's closure. It is also
          # the repo's documented preference precisely because it behaves the same
          # on macOS and Linux, unlike date, ps or find.
          #
          # Time::Local's timegm_modern is core since 5.10 and does pure UTC
          # arithmetic; the UTC offset out of the log is applied by hand, so there
          # is no local-time or DST case left to get wrong. Cross-checked against
          # GNU date on ten inputs including both 2026 European DST transitions
          # (the pairs one second apart give consecutive epochs), a leap day and a
          # -1200 offset: identical to the second.

          # Answers the only question that matters about a daemon: is a build
          # running, and if not, how long has it been idle? One perl pass replaces
          # grep + tail + date. Prints exactly one of:
          #   inflight | idle <seconds> | nobuild | unparsable <timestamp>
          daemon_log_state() {
            perl -MTime::Local=timegm_modern -ne '
              # Gradle brackets every build with "Command execution: started" and
              # "... completed". Keeping only the LAST match means a build in
              # flight is recognised however long ago it began — a long build must
              # never be reaped just for exceeding the threshold.
              #
              # matches: 2026-08-26T12:10:39.684+0200 [DEBUG] [org.gradle.launcher.daemon.server.exec.LogToClient] Command execution: completed
              if (m{^ (?<ts>\S+) \s .* Command\ execution:\ (?<what>started|completed) }x) {
                ($T, $W) = ($+{ts}, $+{what});
              }
              END {
                unless (defined $W)  { print "nobuild\n";  exit }
                if ($W eq "started") { print "inflight\n"; exit }

                # matches: 2026-08-26T12:10:39.684+0200, and the same without the
                # fractional part or with a colon in the offset (+02:00).
                unless ($T =~ m{
                    ^ (?<Y>\d{4}) - (?<Mo>\d\d) - (?<D>\d\d)
                    T (?<h>\d\d) : (?<mi>\d\d) : (?<s>\d\d)
                      (?: \. \d+ )?
                      (?<sign>[+-]) (?<oh>\d\d) :? (?<om>\d\d) $
                }x) { print "unparsable $T\n"; exit }

                my $off = ($+{oh} * 3600 + $+{om} * 60) * ($+{sign} eq "-" ? -1 : 1);
                my $end = timegm_modern($+{s}, $+{mi}, $+{h}, $+{D}, $+{Mo} - 1, $+{Y}) - $off;
                printf "idle %d\n", time - $end;
              }
            ' "$1"
          }

          # BSD `ps -o etime=` prints [[dd-]hh:]mm:ss and BSD ps has no `etimes`,
          # so it has to be converted. Only reached for daemons whose log we
          # cannot find, i.e. those started with a foreign GRADLE_USER_HOME.
          etime_to_s() {
            perl -e '
              # matches: 07:12 -> 432 | 04:18:18 -> 15498 | 2-03:04:05 -> 183845
              $ARGV[0] =~ m{^ (?: (?<d>\d+) - )? (?: (?<h>\d+) : )? (?<m>\d+) : (?<s>\d+) $}x
                or exit 1;
              my $t = ($+{d} // 0) * 86400 + ($+{h} // 0) * 3600 + $+{m} * 60 + $+{s};
              print $t;
            ' "$1"
          }

          candidates=()

          # `pgrep -f` on the bootstrap class rather than on "gradle": it matches
          # the daemon JVM and nothing else — not the launcher, not the wrapper,
          # not the forked workers (those die with their daemon anyway).
          while read -r pid; do
            [[ -n "$pid" ]] || continue

            log=$(find "$HOME/.gradle/daemon" -maxdepth 2 -name "daemon-$pid.out.log" 2>/dev/null | head -1)

            if [[ -n "$log" ]]; then
              # Evaluated ONCE. Calling it again inside a branch would not just
              # waste a fork, it would race: a build starting between the two
              # calls would be classified by the stale first answer.
              state=$(daemon_log_state "$log")
              case "$state" in
                inflight)
                  echo "$(date -Iseconds) pid $pid: build in flight — skipped"
                  continue
                  ;;
                "idle "*)
                  idle="''${state#idle }"
                  why="idle $(( idle / 60 )) min since last build"
                  ;;
                nobuild)
                  # Log exists but no build ever ran through it.
                  idle=$(etime_to_s "$(ps -o etime= -p "$pid" | tr -d ' ')")
                  why="up $(( idle / 60 )) min, never ran a build"
                  ;;
                *)
                  # Anything else means the log said something we do not
                  # understand. Say so and skip. The previous version had
                  # `|| echo 0` here and a `-gt 0` test, which turned every
                  # parse failure into an indistinguishable silent skip.
                  echo "$(date -Iseconds) pid $pid: unreadable log state ($state) — skipped"
                  continue
                  ;;
              esac
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
        # Gradle honours this most of the time but not always — see the module
        # header for the survey. The gradle-daemon-reap launchd agent enforces
        # the same 3 h as a backstop. Keep the two numbers in step if you change
        # either, or the backstop starts fighting the setting instead of
        # covering for it.
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
