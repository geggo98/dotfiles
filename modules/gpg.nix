{ ... }:
{
  flake.modules.homeManager.gpg = { config, lib, pkgs, ... }:
    let
      # Mirror home-manager's gpg.conf rendering (bool true → bare flag,
      # bool false → omit, list → repeated `key val` lines, else `key val`).
      mkSetting = k: v:
        if lib.isBool v then lib.optionalString v k
        else if lib.isList v then
          lib.concatStringsSep "\n" (map (vv: "${k} ${toString vv}") v)
        else "${k} ${toString v}";

      gpgConfFile = pkgs.writeText "gpg.conf" (
        lib.concatStringsSep "\n"
          (
            lib.filter (s: s != "") (
              lib.mapAttrsToList mkSetting config.programs.gpg.settings
            )
          ) + "\n"
      );
    in
    {
      programs.gpg = {
        enable = true;

        # Rendered to a regular file at ~/.gnupg/gpg.conf via the activation
        # script below (not via home-manager's symlink). In `settings`,
        # `bool true` emits the bare key (a flag), `bool false` omits it, and
        # strings emit `key value`. Lifted verbatim from the user's hand-curated
        # ~/.gnupg/gpg.conf and extended with 2026-era defense-in-depth flags.
        settings = {
          # Algorithm hardening
          cert-digest-algo = "SHA512";
          s2k-cipher-algo = "AES256";
          s2k-digest-algo = "SHA512";
          personal-cipher-preferences = "AES256 AES192 AES";
          personal-digest-preferences = "SHA512 SHA384 SHA256";
          # `Uncompressed` first: compression-before-encryption can leak
          # plaintext patterns (CRIME-class side channel).
          personal-compress-preferences = "Uncompressed ZLIB BZIP2 ZIP";
          default-preference-list = "SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed";

          # Output / UX
          charset = "utf-8";
          keyid-format = "0xlong";
          list-options = "show-uid-validity";
          verify-options = "show-uid-validity";
          fixed-list-mode = true;
          with-fingerprint = true;
          no-comments = true;
          no-emit-version = true;
          no-symkey-cache = true;

          # Trust / agent
          require-cross-certification = true;
          use-agent = true;

          # 2026 hardening additions
          no-greeting = true;
          throw-keyids = true;
          keyserver-options = "no-honor-keyserver-url";

          # default-key is host-specific; set in modules/hosts/<serial>.nix.
        };
      };

      # GnuPG (and some GUI tools) periodically rewrites ~/.gnupg/gpg.conf as
      # a regular file. That collides with home-manager's read-only symlink
      # to /nix/store, so the next `darwin-rebuild switch` aborts with a
      # backup conflict. Disable the symlink and install a plain file via
      # the activation script instead — a later overwrite by GnuPG no longer
      # blocks rebuilds (the next switch just rewrites it).
      home.file."${config.programs.gpg.homedir}/gpg.conf".enable = lib.mkForce false;

      home.activation.gpgConf = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        install -m 0644 ${gpgConfFile} "$HOME/.gnupg/gpg.conf"
      '';

      # home-manager (this pin) only manages gpg.conf and scdaemon.conf via
      # `programs.gpg`. Manage dirmngr.conf, gpg-agent.conf and common.conf
      # via home.file. (services.gpg-agent is Linux/systemd-only.)

      home.file."${config.programs.gpg.homedir}/dirmngr.conf".text = ''
        keyserver hkps://keys.openpgp.org
      '';

      home.file."${config.programs.gpg.homedir}/gpg-agent.conf".text = ''
        default-cache-ttl 600
        max-cache-ttl 7200
      '';

      # `use-keyboxd` intentionally absent: disables keyboxd and falls back
      # to the legacy pubring.kbx keybox. Keyboxd is still considered
      # experimental upstream and has known silent-failure modes.
      home.file."${config.programs.gpg.homedir}/common.conf".text = ''
        # Managed by home-manager.
      '';
    };
}
