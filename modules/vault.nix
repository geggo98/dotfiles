{ ... }:
{
  flake.modules.homeManager.vault = { config, pkgs, lib, ... }:
    let
      stagingAddrFile = config.sops.secrets.vault_addr_staging.path;
      productionAddrFile = config.sops.secrets.vault_addr_production.path;

      # Token helper wired into ~/.vault: the Vault CLI calls it as
      # `vault-token-helper get|store|erase` with VAULT_ADDR in the
      # environment. Storing one token per address lets test and production
      # logins coexist instead of clobbering the single ~/.vault-token.
      vaultTokenHelper = pkgs.writeShellApplication {
        name = "vault-token-helper";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          addr="''${VAULT_ADDR:-}"
          addr="''${addr%/}"
          if [ -z "$addr" ]; then
            echo "vault-token-helper: VAULT_ADDR is not set" >&2
            exit 1
          fi
          dir="''${XDG_STATE_HOME:-$HOME/.local/state}/vault/tokens"
          file="$dir/$(printf '%s' "$addr" | sha256sum | cut -d' ' -f1)"

          case "''${1:-}" in
            get)
              # No token file means "not logged in": print nothing, exit 0.
              if [ -f "$file" ]; then
                cat "$file"
              fi
              ;;
            store)
              umask 077
              mkdir -p "$dir"
              chmod 700 "$dir"
              cat > "$file"
              ;;
            erase)
              rm -f "$file"
              ;;
            *)
              echo "usage: vault-token-helper get|store|erase" >&2
              exit 1
              ;;
          esac
        '';
      };

      # `vault` itself is provided by Homebrew (hashicorp/tap/vault in
      # homebrew-common.nix). Keep /opt/homebrew on PATH so the wrapper
      # finds it.
      mkVaultLogin = { name, addrFile }:
        pkgs.writeShellApplication {
          inherit name;
          text = ''
            export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

            # Force the address: interactive fish exports VAULT_ADDR (test
            # default), which would otherwise silently redirect this login
            # to the wrong vault.
            VAULT_ADDR="$(< "${addrFile}")"
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

      # Runs `vault` pinned to one address, overriding any inherited
      # VAULT_ADDR; the token helper picks the matching token.
      mkVaultCli = { name, addrFile }:
        pkgs.writeShellApplication {
          inherit name;
          text = ''
            export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

            VAULT_ADDR="$(< "${addrFile}")"
            export VAULT_ADDR

            exec vault "$@"
          '';
        };
    in
    {
      home.packages = [
        (mkVaultLogin {
          name = "+vault-login-staging";
          addrFile = stagingAddrFile;
        })
        (mkVaultLogin {
          name = "+vault-login-production";
          addrFile = productionAddrFile;
        })
        (mkVaultCli {
          name = "+vault-test";
          addrFile = stagingAddrFile;
        })
        (mkVaultCli {
          name = "+vault-prod";
          addrFile = productionAddrFile;
        })
      ];

      home.file.".vault".text = ''
        token_helper = "${lib.getExe vaultTokenHelper}"
      '';

      # Default plain `vault` to the test instance. Reads the secret at
      # runtime so the address never lands in the Nix store; intentionally
      # plain fish (no promptInit.fish helpers) to avoid init-order
      # dependencies between modules.
      programs.fish.interactiveShellInit = ''
        if not set -q VAULT_ADDR; and test -r "${stagingAddrFile}"
          set -gx VAULT_ADDR (command cat "${stagingAddrFile}")
        end
      '';
    };
}
