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
      s3Url = "s3://nix-cache?endpoint=81e63dbf073ca45ebf67c430beac09a4.r2.cloudflarestorage.com&region=auto";
      publicUrl = "https://nix-cache.pub.schwetschke.dev";
      publicKey = "nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=";

      # Shared push logic; also invoked by `just cache-seed`/`cache-push`.
      pushScript = pkgs.writeShellScriptBin "nix-cache-push"
        (builtins.readFile ./_files/nix-cache/nix-cache-push);

      # post-build-hook — runs as root (nix-daemon) after every local build.
      # Best-effort: `timeout` + `|| true` means a slow/unreachable R2 never
      # fails or hangs a build. $OUT_PATHS are freshly built (= the delta), so
      # no cache.nixos.org filtering is needed here. PATH is set explicitly
      # because the daemon invokes hooks with a minimal environment.
      #
      # SECRETS AVAILABILITY: NIX_CACHE_SECRETS_DIR resolves through the user's
      # sops-nix directory, which on darwin is a symlink into a per-user temp
      # dir populated by home-manager activation (i.e. after login). If the
      # decrypted secrets are not yet present (a build before first login, or
      # after macOS reaps the temp dir), the push script exits early and the
      # `|| true` swallows it — no upload, but the build never fails.
      hookScript = pkgs.writeShellScriptBin "nix-cache-post-build-hook" ''
        export PATH="/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        export NIX_CACHE_S3_URL='${s3Url}'
        export NIX_CACHE_SECRETS_DIR='${secretsDir}'
        ${pkgs.coreutils}/bin/timeout 120 ${pushScript}/bin/nix-cache-push $OUT_PATHS || true
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
