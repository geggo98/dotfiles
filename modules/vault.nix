{ ... }:
{
  flake.modules.homeManager.vault = { config, pkgs, ... }:
    let
      # `vault` itself is provided by Homebrew (hashicorp/tap/vault in
      # homebrew-common.nix). Keep /opt/homebrew on PATH so the wrapper
      # finds it.
      mkVaultLogin = { name, addrFile }:
        pkgs.writeShellApplication {
          inherit name;
          text = ''
            export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

            VAULT_ADDR="''${VAULT_ADDR:-$(< "${addrFile}")}"
            export VAULT_ADDR

            # A token passed as the first argument skips OIDC and logs in
            # directly — useful when the OIDC flow is unavailable.
            if [ "$#" -ge 1 ]; then
              vault login -address "$VAULT_ADDR" -no-print "$1"
              echo "Logged in to $VAULT_ADDR with the provided token."
              exit 0
            fi

            if vault login -method=oidc -address "$VAULT_ADDR" -no-print; then
              echo "Check your web browser and finish the login there if necessary."
            else
              echo "" >&2
              echo "OIDC login against VAULT_ADDR=$VAULT_ADDR failed." >&2
              echo "Log in via the web UI to grab a token:" >&2
              echo "  $VAULT_ADDR/ui/vault/secrets" >&2
              echo "(the direct URL returns an Internal Server Error)." >&2
              echo "Then pass that token directly. Prepend a space so it" >&2
              echo "stays out of your shell history (it is short-lived anyway):" >&2
              echo "   ${name} <token>" >&2
              exit 1
            fi
          '';
        };
    in
    {
      home.packages = [
        (mkVaultLogin {
          name = "+vault-login-staging";
          addrFile = config.sops.secrets.vault_addr_staging.path;
        })
        (mkVaultLogin {
          name = "+vault-login-production";
          addrFile = config.sops.secrets.vault_addr_production.path;
        })
      ];
    };
}
