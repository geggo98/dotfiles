{ ... }:
{
  flake.modules.homeManager.vault = { config, pkgs, ... }:
    let
      vaultAddrFile = config.sops.secrets.vault_addr.path;

      # `vault` itself is provided by Homebrew (hashicorp/tap/vault in
      # homebrew-common.nix). Keep /opt/homebrew on PATH so the wrapper
      # finds it; everything else (tmux) comes via runtimeInputs.
      vaultLoginPackage = pkgs.writeShellApplication {
        name = "+vault-login";
        runtimeInputs = [ pkgs.tmux ];
        text = ''
          export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

          VAULT_ADDR="''${VAULT_ADDR:-$(< "${vaultAddrFile}")}"
          export VAULT_ADDR

          if [ -t 0 ]; then
            vault login -method=oidc -address "$VAULT_ADDR" -no-print
            echo "Check your web browser and finish the login there if necessary."
          else
            SESSION_NAME="vault-login-$$"
            echo "Running vault login in tmux session: $SESSION_NAME"
            echo "Attach with: tmux attach -t $SESSION_NAME"
            tmux new-session -d -s "$SESSION_NAME" \
              "vault login -method=oidc -address \"$VAULT_ADDR\" -no-print; RC=\$?; if [ \$RC -ne 0 ]; then echo \"Vault login failed (exit \$RC). Press Enter to close.\"; read -r; fi; exit \$RC"
            tmux set-hook -t "$SESSION_NAME" session-closed \
              "run-shell 'tmux wait-for -S $SESSION_NAME'"
            tmux wait-for "$SESSION_NAME" || true
            echo "Vault login session finished."
          fi
        '';
      };
    in
    {
      home.packages = [ vaultLoginPackage ];
    };
}
