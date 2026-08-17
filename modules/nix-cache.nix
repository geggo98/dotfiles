# Cloudflare R2 as a shared Nix binary cache for both Darwin hosts.
#
# Pull:  a public https:// substituter fronted by a Cloudflare custom domain
#        (managed in infra/), so the root nix-daemon needs no credentials.
# Push:  `nix copy` to the S3 API endpoint, signed with our key. Runs either as
#        the user (`just cache-seed` / `cache-push`) or as root via the
#        post-build-hook — both read the same user-owned sops-nix secrets
#        (root is allowed to read the user's decrypted files).
#
# The bucket + custom domain are provisioned by Pulumi; see infra/src/index.ts.
{ ... }:
{
  flake.modules.darwin.nix-cache = { config, pkgs, ... }:
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
      publicKey = "nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=";

      # Beside /var/log/nix-gc.log. /var/log is root:wheel drwxr-xr-x and the
      # daemon runs as root, so the file lands 644 and is readable without sudo.
      logFile = "/var/log/nix-cache-push.log";

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
      # Best-effort: `timeout` + `|| true` means a slow/unreachable R2 never
      # fails or hangs a build. 600 s (not less): `nix copy` pushes the CLOSURE
      # of $OUT_PATHS, and compress+upload of ~1 GB outputs (pulumi-bin,
      # codex-vendor) must fit or they are silently lost. $OUT_PATHS are freshly
      # built (= the delta), so no cache.nixos.org filtering is needed here.
      # PATH is set explicitly because the daemon invokes hooks with a minimal
      # environment.
      #
      # SECRETS AVAILABILITY: NIX_CACHE_SECRETS_DIR resolves through the user's
      # sops-nix directory, which on darwin is a symlink into a per-user temp
      # dir populated by home-manager activation (i.e. after login). If the
      # decrypted secrets are not yet present (a build before first login, or
      # after macOS reaps the temp dir), the push script exits early and the
      # `|| true` swallows it — no upload, but the build never fails.
      #
      # LOGGING: `|| true` is right, but it used to also mean *silent*. A failed
      # push (R2 rate limit, secrets not yet decrypted, an upload past the 600 s
      # timeout) dropped the path with no trace anywhere — the daemon log holds
      # zero hook output — and surfaced weeks later as a cache miss on the other
      # Mac. Every invocation now leaves one line in ${logFile}, successes
      # included: logging only failures would make an empty file mean either
      # "all good" or "the hook never ran", which is the ambiguity this exists to
      # remove.
      hookScript = mkZshScript "nix-cache-post-build-hook" ''
        export PATH="/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        export NIX_CACHE_S3_URL='${s3Url}'
        export NIX_CACHE_SECRETS_DIR='${secretsDir}'

        # The XXXXXX are required, not decoration: GNU coreutils rejects a
        # template with fewer than three X's ("too few X's in template"), and the
        # `|| true` then falls through to /dev/null — which discards exactly the
        # error text the FAIL branch exists to report. Caught in testing, where
        # the success path looked perfect and every failure logged err="".
        out=$(${pkgs.coreutils}/bin/mktemp -t nix-cache-push.XXXXXX 2>/dev/null || true)
        [ -n "$out" ] || out=/dev/null
        start=$(${pkgs.coreutils}/bin/date +%s)

        # ''${=VAR}, not $VAR. zsh does NOT word-split unquoted parameters — the
        # very property AGENTS.md praises it for — and $OUT_PATHS is a
        # space-separated list that must arrive as separate arguments. Plain
        # $OUT_PATHS here would hand nix-cache-push one bogus argument and every
        # push would fail. Measured: `V="x y z"; set -- $V` gives argc=1 under
        # zsh, 3 under bash.
        ${pkgs.coreutils}/bin/timeout 600 ${pushScript}/bin/nix-cache-push ''${=OUT_PATHS} >"$out" 2>&1
        rc=$?

        # ONE RECORD = ONE printf. This is why the push output is captured to a
        # file and folded, rather than simply redirected: the hook runs once per
        # derivation, so with max-jobs > 1 several instances append concurrently.
        # A single printf under O_APPEND is atomic (measured: 40 writers x 50
        # records, 2000 intact lines, zero torn); `command >> log` is not, because
        # it writes many times. Records stay short for the same reason — the
        # guarantee holds below one write().
        now=$(${pkgs.coreutils}/bin/date +%Y-%m-%dT%H:%M:%S%z)
        dur=$(( $(${pkgs.coreutils}/bin/date +%s) - start ))
        n=$(printf '%s\n' ''${=OUT_PATHS} | ${pkgs.coreutils}/bin/wc -l | ${pkgs.coreutils}/bin/tr -d ' ')
        first=$(printf '%s\n' ''${=OUT_PATHS} | ${pkgs.coreutils}/bin/head -1)
        first=''${first##*/}

        if [ "$rc" -eq 0 ]; then
          printf '%s pid=%d status=ok   exit=0 paths=%s dur=%ss first=%s\n' \
            "$now" "$$" "$n" "$dur" "$first" >>'${logFile}' 2>/dev/null || true
        else
          # Fold to one line, keep the TAIL: the diagnosis is at the end of the
          # output, and the record must stay inside the atomic-write bound.
          err=$(${pkgs.coreutils}/bin/tr '\n\r\t' '   ' <"$out" \
                | ${pkgs.coreutils}/bin/tr -s ' ' \
                | ${pkgs.coreutils}/bin/tail -c 240)
          printf '%s pid=%d status=FAIL exit=%d paths=%s dur=%ss first=%s err="%s"\n' \
            "$now" "$$" "$rc" "$n" "$dur" "$first" "$err" >>'${logFile}' 2>/dev/null || true
        fi

        # An unwritable /var/log must not fail a build either, hence the
        # `|| true` on both printfs and the unconditional exit.
        [ "$out" = /dev/null ] || ${pkgs.coreutils}/bin/rm -f "$out"
        exit 0
      '';
    in
    {
      # Merged with modules/determinate.nix's customSettings → /etc/nix/nix.custom.conf.
      determinateNix.customSettings = {
        "extra-substituters" = [ publicUrl ];
        "extra-trusted-public-keys" = [ publicKey ];

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
        #   sudo launchctl kickstart -k system/systems.determinate.nix-daemon
        # (or reboot). Substituter/pull settings are read per client invocation
        # and never need a restart.
        "post-build-hook" = "/run/current-system/sw/bin/nix-cache-post-build-hook";
      };

      # `nix-cache-push` (interactive/ad-hoc) + the hook on PATH so the stable
      # /run/current-system/sw/bin/nix-cache-post-build-hook path above resolves.
      environment.systemPackages = [ pushScript hookScript ];
    };
}
