{
  # Host-specific secrets for DKL6GDJ7X1.
  #
  # Each attribute here is merged with sops.secrets and gets
  # sopsFile = hosts/DKL6GDJ7X1/secrets.enc.yaml. List ONLY secrets
  # actually stored in that host file. Secrets shared across hosts
  # (incl. the c24_bi_kfz_*.json bundle) live in modules/secrets.nix
  # and are read from the global SOPS file by default.
  openai_api_key = { };
  office_vpn_prefix = { };
  boundary_cluster_url = { };
  boundary_services = { };
  vault_addr = { };
}
