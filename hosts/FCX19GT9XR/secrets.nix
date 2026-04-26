{
  # Host-specific secrets for FCX19GT9XR.
  #
  # Each attribute here is merged with sops.secrets and gets
  # sopsFile = hosts/FCX19GT9XR/secrets.enc.yaml. List ONLY secrets
  # actually stored in that host file. Secrets shared across hosts
  # belong in modules/secrets.nix and are read from the global SOPS
  # file by default.
  #
  # The host SOPS file (./secrets.enc.yaml) currently has only the
  # placeholder marker, so this set is empty. Add an entry here when
  # an FCX-only secret is encrypted into that file.
}
