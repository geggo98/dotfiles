{
  # Host-specific secrets for DKL6GDJ7X1.
  #
  # Each attribute here is merged with sops.secrets and gets
  # sopsFile = hosts/DKL6GDJ7X1/secrets.enc.yaml. List ONLY secrets
  # actually stored in that host file. Secrets shared across hosts
  # live in modules/secrets.nix and are read from the global SOPS
  # file by default.
  openai_api_key = { };
  office_vpn_prefix = { };
  boundary_cluster_url = { };
  boundary_services = { };
  vault_addr_staging = { };
  vault_addr_production = { };

  # CHECK24 work credentials, moved out of the global file on 2026-08-24.
  # They have no consumer on the private Mac: the Atlassian ones feed
  # +mcp-atlassian and the jira / bitbucket-pr skills, absence.io is used
  # ad hoc, and the C24-BI service accounts are read by nothing in this
  # repo at all -- they are only made available on disk.
  #
  # This scopes DEPLOYMENT, not readability. Every rule in .sops.yaml
  # carries the same age recovery key, so the other workstation can still
  # decrypt this file; what changes is which host writes the values into
  # ~/.config/sops-nix/secrets.
  jira_url = { };
  jira_username = { };
  jira_api_token = { };
  confluence_url = { };
  confluence_username = { };
  confluence_personal_token = { };
  absence_io_api_id = { };
  absence_io_api_key = { };
  "c24_bi_kfz_test_stefan_schwetschke.json" = { };
  "c24_bi_kfz_prod_stefan_schwetschke.json" = { };
  "c24_bi_kfz_test_liquibase.json" = { };
  "c24_bi_kfz_prod_liquibase.json" = { };
}
