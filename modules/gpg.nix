{ ... }:
{
  flake.modules.homeManager.gpg = { config, ... }:
    {
      programs.gpg = {
        enable = true;

        # Written to ~/.gnupg/gpg.conf. In home-manager's `programs.gpg.settings`,
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
