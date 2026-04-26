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
        anthropic_api_key = { };
        openrouter_api_key = { };
        groq_api_key = { };
        gemini_api_key = { };
        context7_api_key = { };
        ollama_api_key = { };
        travily_api_key = { };
        z_ai_api_key = { };
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
