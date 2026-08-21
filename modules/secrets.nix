{ inputs, lib, ... }:
let
  root = ./..;

  mkSecretsModule = hostId: { config, ... }:
    let
      globalSopsFile = root + "/secrets/secrets.enc.yaml";
      hostSecretsFile = root + "/hosts/${hostId}/secrets.enc.yaml";
      hostSecretsModule = root + "/hosts/${hostId}/secrets.nix";

      # Contract: hosts/<host>/secrets.nix lists exactly the secret
      # keys stored in this host's encrypted YAML. Each entry receives
      # `sopsFile = hostSecretsFile` (overridable per entry); base
      # secrets keep `defaultSopsFile = globalSopsFile`.
      hostSecrets =
        if builtins.pathExists hostSecretsModule then import hostSecretsModule else { };

      hostSecretsWithFile = lib.mapAttrs
        (_: secret: { sopsFile = hostSecretsFile; } // secret)
        hostSecrets;

      baseSecrets = {
        "aws/credentials".path = "${config.home.homeDirectory}/.aws/credentials";
        "aws/credentials".mode = "0600";
        "aws/config".path = "${config.home.homeDirectory}/.aws/config";
        "aws/config".mode = "0600";
        openai_api_key = { };
        openrouter_api_key = { };
        groq_api_key = { };
        gemini_api_key = { };
        context7_api_key = { };
        ollama_api_key = { };
        travily_api_key = { };
        z_ai_api_key = { };
        huggingface_ro_token = { };
        slack_c24_api_key = { };
        atlassian_c24_bitbucket_api_token = { };
        confluence_url = { };
        confluence_username = { };
        confluence_personal_token = { };
        jira_url = { };
        jira_username = { };
        jira_api_token = { };
        absence_io_api_id = { };
        absence_io_api_key = { };
        "c24_bi_kfz_test_stefan_schwetschke.json" = { };
        "c24_bi_kfz_prod_stefan_schwetschke.json" = { };
        "c24_bi_kfz_test_liquibase.json" = { };
        "c24_bi_kfz_prod_liquibase.json" = { };

        # GROUPED IN THE YAML, FLAT ON DISK. `key` says where a value sits in the
        # encrypted file; `name` (the attribute) still decides the filename,
        # because sops-nix defaults `path` to "${defaultSymlinkPath}/${name}"
        # and never to ${key}. Nothing that reads these files changes —
        # modules/_files/nix-cache/nix-cache-push:44-46 still opens
        # r2_access_key_id, r2_secret_access_key and nix_cache_signing_key by
        # those exact names.
        #
        # The grouping is not tidiness. Flat, these two pairs were neighbours:
        #
        #   r2_access_key_id           nix-cache, read+write, on both Macs,
        #                              used by an automated hook many times a day
        #   restic_r2_access_key_id    backup, read+write, the credential that
        #                              can destroy the only copy of the data
        #
        # Same provider, same shape, different blast radius, told apart by a
        # prefix. Grouping makes reaching for the wrong one a structural
        # impossibility rather than a matter of care.
        #
        # R2 binary cache (modules/nix-cache.nix): S3 push credentials + NAR
        # signing secret key. Read by nix-cache-push (user) and the root
        # post-build-hook (root reads the user's decrypted files).
        r2_access_key_id.key = "nix_cache/r2/access_key_id";
        r2_secret_access_key.key = "nix_cache/r2/secret_access_key";
        nix_cache_signing_key.key = "nix_cache/signing_key";

        # Encrypted file backups (infra/src/backup.ts, R2 bucket `restic-backup`).
        # A SEPARATE R2 credential from the three above, on purpose: those are used by
        # a root post-build-hook on every build and therefore sit on every workstation,
        # and a backup that may temporarily be the only copy of the data must not be
        # reachable with them. The token is scoped to the `restic-backup` bucket alone
        # (permission groups "Workers R2 Storage Bucket Item Read" and "… Item Write").
        #
        # Unlike r2_secret_access_key, this is the NATIVE S3 secret Cloudflare shows in
        # the token dialog, not a `cfat_…` value: restic's S3 backend reads
        # AWS_SECRET_ACCESS_KEY literally and has no equivalent of nix-cache-push's
        # SHA-256 derivation.
        #
        # restic_password is the repository password. Losing it loses the backup
        # outright — there is no recovery path, by design — so it lives here *and* in
        # 1Password. One copy of it is the real single point of failure in the whole
        # arrangement, not the bucket.
        #
        # `restic/r2/token` is deliberately NOT declared here although it is stored in
        # the same file: it is the Cloudflare token the two S3 values were derived from,
        # worth keeping to inspect or rotate the token later, but nothing on a
        # workstation reads it. Declaring it would write it to disk for no reason.
        #
        # Note there is a THIRD R2 credential which is deliberately absent from this
        # file: the read-only one, declared in hosts/p-ion-berlin-xs56r6/secrets.nix
        # under restic/r2_ro. It belongs to the VPS that copies the backup to Dropbox
        # and lives only there — no workstation needs it, and a credential that cannot
        # write is worth nothing here.
        restic_r2_access_key_id.key = "restic/r2/access_key_id";
        restic_r2_secret_access_key.key = "restic/r2/secret_access_key";
        restic_password.key = "restic/password";
      };
    in
    {
      imports = [ inputs.sops-nix.homeManagerModules.sops ];

      sops = {
        age.sshKeyPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519_sops_nopw" ];
        defaultSopsFile = globalSopsFile;
        secrets = lib.recursiveUpdate baseSecrets hostSecretsWithFile;
      };
    };
in
{
  flake.modules.homeManager = {
    secrets-FCX19GT9XR = mkSecretsModule "FCX19GT9XR";
    secrets-DKL6GDJ7X1 = mkSecretsModule "DKL6GDJ7X1";
  };
}
