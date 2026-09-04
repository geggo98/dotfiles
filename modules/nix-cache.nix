# Cloudflare R2 as a shared Nix binary cache for both Darwin hosts, plus the one
# upstream substituter these hosts depend on (numtide's, for llm-agents.nix).
#
# Pull:  a public https:// substituter fronted by a Cloudflare custom domain
#        (managed in infra/), so the root nix-daemon needs no credentials.
# Push:  `nix copy` to the S3 API endpoint, signed with our key. Runs either as
#        the user (`just cache-seed` / `cache-push`) or as root from the
#        nix-cache-drain LaunchDaemon — both read the same user-owned sops-nix
#        secrets (root is allowed to read the user's decrypted files).
#
#        The push is NOT part of the build any more. The post-build-hook only
#        appends to a spool and returns in ~20 ms; the daemon empties it every
#        300 s. See the hook's own comment below for the measurements that
#        forced the split, and "The push is asynchronous, and why" in AGENTS.md.
#
# The bucket + custom domain are provisioned by Pulumi; see infra/src/index.ts.
{ ... }:
{
  flake.modules.darwin.nix-cache = { config, lib, pkgs, ... }:
    let
      user = config.system.primaryUser;
      homeDir = toString config.users.users.${user}.home;
      secretsDir = "${homeDir}/.config/sops-nix/secrets";

      # S3 API endpoint (push target). Public pull URL is the custom domain below.
      # compression=zstd: the default (xz) compresses large NARs so slowly that
      # the push blows the post-build-hook timeout below (observed 27.07.2026:
      # every path >~200 MB was silently dropped). Compression is recorded
      # per-path in each narinfo, so zstd coexists with the existing xz content.
      s3Url = "s3://nix-cache?endpoint=81e63dbf073ca45ebf67c430beac09a4.r2.cloudflarestorage.com&region=auto&compression=zstd";
      publicUrl = "https://nix-cache.pub.schwetschke.dev";

      # Upstream's cache for the llm-agents.nix inputs, listed here rather than
      # in a module of its own for a mechanical reason: determinateNix
      # customSettings is attrsOf (atom OR list of atom), and a LIST counts as an
      # atom there, so a second module defining "extra-substituters" would
      # collide instead of merging. One definition site, therefore this one.
      #
      # flake.nix declares the same host in nixConfig. That is not redundant and
      # not a substitute: measured 2026-09-02, a value already present in
      # /etc/nix/nix.custom.conf is still reported as
      # "ignoring untrusted flake configuration setting" — nix asks per SETTING,
      # against the whole value string, and does not filter out what is already
      # configured. The two therefore cover different callers: this entry serves
      # the daemon with no acceptance at all, nixConfig serves a machine that has
      # not been switched yet. .envrc passes --accept-flake-config so direnv,
      # which cannot answer a prompt, never blocks on the difference.
      upstreamUrl = "https://cache.numtide.com";
      upstreamKey = "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=";
      publicKey = "nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=";

      # Beside /var/log/nix-gc.log. /var/log is root:wheel drwxr-xr-x and the
      # daemon runs as root, so the file lands 644 and is readable without sudo.
      logFile = "/var/log/nix-cache-push.log";

      # The spool the hook fills and the drainer empties. /var/spool is 0755
      # root:wheel on macOS and already hosts cups/postfix — the conventional
      # place for exactly this. 0755 rather than 0700 so `just cache-queue` can
      # answer "is anything stuck?" without sudo; the file NAMES are store paths,
      # which are derivable by anyone who evaluates this public flake anyway.
      spoolDir = "/var/spool/nix-cache-push";
      drainLock = "/var/run/nix-cache-drain.lock";
      drainLog = "/var/log/nix-cache-drain.log";

      # Per-project, per-checkout build products that are rebuilt on every
      # `direnv reload` and that the OTHER Mac can never reuse.
      #
      # THIS IS A PREFIX MATCH, and the first version of it was not — that was a
      # disclosure bug, not a tuning miss. Listing the four names that happened
      # to appear in the timeout records (devenv-profile, -shell, -shell-env,
      # -python-virtualenv) let every OTHER devenv output through, and those are
      # the ones that carry project detail: a `devenv-files` output is a script
      # containing the checkout's absolute path, and `devenv-processes-<name>`
      # takes <name> verbatim from the project's own `processes.*` keys — which
      # then becomes the StorePath: line of a world-readable narinfo in a bucket
      # that is public by design (see "The public cache mirrors system closures"
      # in AGENTS.md). Measured in this store: devenv-files 58, -files-cleanup
      # 60, -git-hooks-install 11, -git-hooks-run 10, -enterShell 6,
      # -container-copy 6, -python-uv 4, -test 3, -processes-* 3, -flake-* 4.
      # Selecting by "what timed out" was the wrong criterion — those outputs are
      # small, so they never timed out, which is exactly why they were missed.
      #
      # Because a binary cache has to be referentially complete, `nix copy
      # devenv-profile` also drags that profile's whole substituted closure into
      # R2 (4.12 GB / 202 paths, measured), so the saving is not small either.
      #
      # The carve-out keeps the devenv PACKAGE, whose store names are `devenv`,
      # `devenv-<version>` and `devenv-wrapped-<version>`. `rust_devenv-*` and
      # `+mcp-devenv*` do not start with `devenv-` after the hash is stripped and
      # are unaffected.
      hookKeep = [ "devenv" "devenv-[0-9]*" "devenv-wrapped-*" ];
      hookFilter = [ "devenv-*" ];

      # A BACKSTOP against one absurd output, NOT a cost policy — and the
      # difference is the whole reason this number is so large.
      #
      # Closure size is what `nix copy` walks, so it looks like the right meter.
      # It is off by three orders of magnitude, because `nix copy` asks the
      # destination first and uploads only what R2 lacks. Measured 02.09.2026,
      # the same paths under both regimes:
      #
      #   darwin-system         closure 24.35 GB   ->  push took 2-4 s
      #   home-manager-generation       21.63 GB   ->  push took 2 s
      #   activation-<user>             21.63 GB   ->  push took 3 s
      #
      # A 3 GiB cap was tried first and skipped every one of them — i.e. exactly
      # the closures this shared cache exists to hand to the other Mac, at a real
      # cost of seconds. The genuinely expensive case is bounded elsewhere and
      # honestly: the drainer's 3600 s timeout, the retry backoff, and finally
      # status=GIVEUP. Those measure the actual work instead of guessing at it.
      #
      # So this only catches something pathological (a multi-hundred-GB output).
      # 0 disables it. Whatever it drops is LOGGED with its size — a silent cap
      # would read as "cached" and surface weeks later as a miss on the other Mac.
      maxClosureBytes = "68719476736"; # 64 GiB

      # zsh, per AGENTS.md, and `writeShellScriptBin` hardcodes bash — hence
      # writeTextFile with an explicit shebang. It is `${pkgs.zsh}` rather than
      # /bin/zsh so the interpreter is pinned like every other tool these scripts
      # call; the source file carries its own /bin/zsh line for direct invocation
      # from `just`, which Nix's prepended shebang then shadows. zsh is free here
      # — zsh-5.9.1 is already in the system closure.
      mkZshScript = name: text: pkgs.writeTextFile {
        inherit name;
        destination = "/bin/${name}";
        executable = true;
        text = ''
          #!${pkgs.zsh}/bin/zsh
          ${text}
        '';
      };

      # Shared push logic; also invoked by `just cache-seed`/`cache-push`.
      pushScript = mkZshScript "nix-cache-push"
        (builtins.readFile ./_files/nix-cache/nix-cache-push);

      # post-build-hook — runs as root (nix-daemon) after every local build.
      #
      # IT ONLY ENQUEUES. Nix runs post-build-hooks SYNCHRONOUSLY, blocking its
      # own build loop, and this hook used to run the whole `nix copy` to R2
      # inline behind a 600 s `timeout`. What that cost, measured here:
      #
      #   02.09.2026   322 invocations, 8182 s (a mid-afternoon snapshot, not a
      #                 full day — the log was read while the problem was live)
      #   25.08.2026    67 invocations, 9040 s total, 11 of them killed at 600 s
      #   whole log     13 records with exit=124, of which 10 name a devenv
      #                 output (profile x4, shell x3, shell-env x2, virtualenv x1)
      #   worst single record   dur=601s on a devenv-profile whose closure is
      #                         4.12 GB across 202 paths
      #
      # And a killed push registers NOTHING, so the next `direnv reload` paid the
      # same 601 s again. The cost never amortised. A 20-minute `direnv reload`
      # was 601 s + 208 s of this hook; the "Downloading … 11m24s" line the user
      # saw was a FROZEN progress line, not a slow transfer — that same NAR is
      # 29 MB and `curl`s in 0.69 s.
      #
      # So the hook now writes one empty file per path into ${spoolDir}/queue and
      # returns in ~20 ms; nix-cache-drain does the upload out of band. See
      # ./_files/nix-cache/nix-cache-drain.py for the spool's shape and why the
      # state lives in file names rather than in a progress file.
      #
      # NO EXTERNAL COMMANDS, hence no PATH and no forks: `mkdir` comes from
      # zsh/files, `strftime` from zsh/datetime, `printf` is a builtin. PATH is
      # still set, minimally, so that a future edit reaching for a real command
      # finds one instead of failing silently in a daemon with no environment.
      hookScript = mkZshScript "nix-cache-post-build-hook" ''
        export PATH="/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        zmodload zsh/datetime
        zmodload -F zsh/files b:mkdir

        mkdir -p '${spoolDir}/queue' '${spoolDir}/retry' 2>/dev/null

        # ''${=VAR}, not $VAR. zsh does NOT word-split unquoted parameters — the
        # very property AGENTS.md praises it for — and $OUT_PATHS is a
        # space-separated list that must arrive as separate words. Measured:
        # `V="x y z"; set -- $V` gives argc=1 under zsh, 3 under bash.
        q=0 f=0 e=0 first=-
        for p in ''${=OUT_PATHS}; do
          n=''${p##*/}
          [[ $first == - ]] && first=$n
          # ''${n#*-} strips the 32-character hash, leaving the derivation name.
          # matches:  8c7icbdn…8rpa-devenv-profile   ->   devenv-profile
          # The keep-arm must come FIRST: zsh takes the first matching arm, and
          # `devenv-wrapped-2.2.2` matches both patterns.
          case ''${n#*-} in
            (${lib.concatStringsSep "|" hookKeep}) ;;
            (${lib.concatStringsSep "|" hookFilter}) (( f++ )); continue ;;
          esac
          # One open(O_CREAT) is atomic, and the file NAME is the entire payload,
          # so there is no half-written entry to recover from. `> file` rather
          # than `: > file` would be a redirection with no command, which zsh
          # turns into a `cat` — the empty-file idiom needs the colon.
          if : > '${spoolDir}/queue/'$n 2>/dev/null; then (( q++ )); else (( e++ )); fi
        done

        # ONE RECORD = ONE printf. A single write() under O_APPEND is atomic
        # (measured: 40 writers x 50 records, 2000 intact lines, zero torn),
        # while `command >> log` writes many times and can interleave. Records
        # stay short for the same reason — the guarantee holds below one write().
        strftime -s now '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS
        printf '%s pid=%d status=queued exit=0 paths=%d filtered=%d enqfail=%d dur=0s first=%s\n' \
          "$now" "$$" "$q" "$f" "$e" "$first" >>'${logFile}' 2>/dev/null || true

        # An unwritable /var/log or /var/spool must never fail a build, hence the
        # `|| true` above and the unconditional exit. enqfail= is how a broken
        # spool is noticed instead of silently swallowing the path.
        exit 0
      '';

      # The drainer. stdlib-only python3, deliberately WITHOUT the PEP-723/uv
      # header AGENTS.md prescribes for skill scripts: there is nothing to lock,
      # and `uv run --frozen` inside a root LaunchDaemon would additionally need
      # a writable UV_CACHE_DIR. Precedent for a Nix-built stdlib-python script
      # in this repo: modules/boundary.nix.
      drainPy = pkgs.writeText "nix-cache-drain.py"
        (builtins.readFile ./_files/nix-cache/nix-cache-drain.py);

      # Every value is baked in at BUILD time rather than passed through
      # launchd's EnvironmentVariables, for the reason AGENTS.md gives about
      # launchd jobs: they inherit no shell environment, so a value that is only
      # exported from a shell is simply absent. Baking also guarantees that a
      # manual `nix-cache-drain` and the daemon's run see identical settings.
      # The python side reads each one with os.environ[...] and exits 2 naming
      # the missing variable — never a default that would quietly drain into the
      # wrong spool while reporting success.
      drainScript = mkZshScript "nix-cache-drain" ''
        export PATH="/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        export NIX_CACHE_S3_URL='${s3Url}'
        export NIX_CACHE_SECRETS_DIR='${secretsDir}'
        export NIX_CACHE_SPOOL='${spoolDir}'
        export NIX_CACHE_LOG='${logFile}'
        export NIX_CACHE_DRAIN_LOCK='${drainLock}'
        export NIX_CACHE_MAX_CLOSURE_BYTES='${maxClosureBytes}'
        export NIX_CACHE_PUSH='${pushScript}/bin/nix-cache-push'
        exec ${pkgs.python3}/bin/python3 ${drainPy} "$@"
      '';
    in
    {
      # Merged with modules/determinate.nix's customSettings → /etc/nix/nix.custom.conf.
      determinateNix.customSettings = {
        "extra-substituters" = [ publicUrl upstreamUrl ];
        "extra-trusted-public-keys" = [ publicKey upstreamKey ];

        # Nix's default is 3600. That number is tuned for a public cache that
        # rarely gains a path you are waiting for; it is wrong for a cache we
        # push to ourselves, because of this sequence:
        #
        #   host 1 asks for X   -> 404
        #   host 2 asks for X   -> 404, and remembers it for an hour
        #   host 1 builds X and uploads it
        #   host 2 needs X      -> still believes the 404, rebuilds it for nothing
        #
        # The rebuild is the expensive part, so the TTL has to be shorter than
        # the window between one host publishing and another looking again.
        # 60 s means host 2 re-checks a minute after host 1's push instead of an
        # hour. Staleness on the host that did the building is irrelevant — it
        # already has the path locally.
        #
        # The cost is re-querying genuine misses more often. It is bounded: a
        # single closure asks for each path once regardless, so this only shows
        # up across repeated runs, and a cache.nixos.org miss answers in ~235 ms.
        "narinfo-cache-negative-ttl" = "60";

        # Point at the STABLE /run/current-system path, not the hook's raw store
        # path. The Determinate nix-daemon caches the post-build-hook *string* at
        # startup (darwin-rebuild does not restart it — nix.enable = false), and
        # execs it fresh each build. A stable string keeps resolving to the
        # current generation's script, so:
        #   * script changes take effect on the next switch with NO daemon restart;
        #   * GC of old generations can never leave the daemon pointed at a
        #     deleted store path (the raw-store-path form could — the old path
        #     was only GC-rooted by the superseded generation).
        # Only the FIRST enable needs one daemon restart, to load this string:
        #   just daemon-restart
        # (which kickstarts systems.determinate.nix-daemon, or reboot).
        # Substituter/pull settings are read per client invocation
        # and never need a restart.
        "post-build-hook" = "/run/current-system/sw/bin/nix-cache-post-build-hook";
      };

      # The drainer that empties what the hook enqueues. It is a LaunchDaemon
      # (root) and not a LaunchAgent, for four reasons in this order:
      #
      #  1. The writer is root (the nix-daemon runs the hook). Same uid on both
      #     ends means no cross-uid permission construction to get subtly wrong.
      #  2. ${logFile} is root:wheel 644. An agent could not append to it, and a
      #     second, user-writable log would end `just cache-log` as the one
      #     source of truth.
      #  3. Nobody logged in: an agent does not run at all, while the daemon can
      #     still write one `status=DEFER reason=secrets` line. Silence is
      #     exactly the ambiguity this log exists to remove (see above).
      #  4. Precedent: modules/nix-gc.nix is already a root LaunchDaemon with the
      #     same log-and-rotate shape.
      #
      # Root reading the user's sops-nix secrets is not new trust — the old
      # inline hook did the same thing.
      #
      # StartInterval, not QueueDirectories. QueueDirectories looks like the
      # purpose-built mechanism and is the wrong one here: launchd re-runs the
      # job for as long as the directory is non-empty, so an entry deliberately
      # sitting out a 4 h backoff would spin the job continuously — and the
      # collection window that makes coalescing possible would disappear.
      launchd.daemons.nix-cache-drain = {
        command = "${drainScript}/bin/nix-cache-drain";
        serviceConfig = {
          # Drain once right after a switch, then every 5 minutes. launchd never
          # starts a second instance of the same label, and the drainer's own
          # flock covers a manual run racing the scheduled one.
          RunAtLoad = true;
          StartInterval = 300;
          ThrottleInterval = 60;
          # The upload competes with interactive work for disk and CPU (zstd),
          # and being late costs nothing.
          LowPriorityIO = true;
          Nice = 5;
          # `nix copy`'s own multi-line chatter goes HERE, not into ${logFile}:
          # it must not break the one-printf-per-record atomicity over there.
          StandardOutPath = drainLog;
          StandardErrorPath = drainLog;
        };
      };

      # The hook creates these itself, but only on the first build after a
      # switch. Creating them at activation means `just cache-queue` and a
      # manual drain work immediately, and the modes are stated in one place
      # rather than implied by root's umask.
      system.activationScripts.postActivation.text = ''
        ${pkgs.coreutils}/bin/install -d -o root -g wheel -m 0755 '${spoolDir}' '${spoolDir}/queue' '${spoolDir}/retry'
      '';

      # `nix-cache-push` (interactive/ad-hoc), the hook, and the drainer on PATH.
      # The hook must be there for the stable
      # /run/current-system/sw/bin/nix-cache-post-build-hook path above to
      # resolve; the drainer so a human can run one on demand.
      environment.systemPackages = [ pushScript hookScript drainScript ];

      # Rotation, because the hook writes one line per built derivation and a
      # nixpkgs bump builds thousands in one switch. macOS runs newsyslog itself
      # and reads this directory — no launchd job of ours needed.
      #   fields: file  mode count size(KB) when flags   (J = bzip2 the rotations)
      # 5 x 1 MB caps this at ~5 MB, which is far more history than the log is
      # ever consulted for.
      environment.etc."newsyslog.d/nix-cache-push.conf".text =
        "${logFile}    644  5  1024  *  J\n";

      # The drainer's own log gets a line per run (288/day at StartInterval 300)
      # plus whatever `nix copy` prints. Same cap, same reasoning.
      environment.etc."newsyslog.d/nix-cache-drain.conf".text =
        "${drainLog}    644  5  1024  *  J\n";
    };
}
