{
  # Host-specific secrets for FCX19GT9XR.
  #
  # Each attribute here is merged with sops.secrets and gets
  # sopsFile = hosts/FCX19GT9XR/secrets.enc.yaml. List ONLY secrets
  # actually stored in that host file. Secrets shared across hosts
  # belong in modules/secrets.nix and are read from the global SOPS
  # file by default.
  #
  # BookFusion credentials for the bookfusion-api skill. sops-nix decrypts
  # these to ~/.config/sops-nix/secrets/bookfusion_{username,password}, which
  # the skill reads directly. Their values must be encrypted into
  # ./secrets.enc.yaml (see repo CLAUDE.md / .sops.yaml FCX rule) before
  # `darwin-rebuild switch`.
  bookfusion_username = { };
  bookfusion_password = { };
}
