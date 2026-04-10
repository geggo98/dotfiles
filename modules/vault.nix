{ ... }:
{
  flake.modules.homeManager.vault = { pkgs, ... }:
    let
      vaultLoginPackage = pkgs.stdenv.mkDerivation {
        name = "vault-login";
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];

        installPhase = ''
          mkdir -p $out/bin

          cat > $out/bin/+vault-login <<'SCRIPT'
          #!${pkgs.zsh}/bin/zsh
          export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/Users/$USER/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
          VAULT_ADDR=''${VAULT_ADDR:-"https://test-vault.kfz.check24.de"}

          if [ -t 0 ]; then
            vault login -method=oidc -address "$VAULT_ADDR" -no-print
            echo "Check your web browser and finish the login there if necessary."
          else
            SESSION_NAME="vault-login-$$"
            echo "Running vault login in tmux session: $SESSION_NAME"
            echo "Attach with: tmux attach -t $SESSION_NAME"
            ${pkgs.tmux}/bin/tmux new-session -d -s "$SESSION_NAME" \
              "VAULT_ADDR=\"$VAULT_ADDR\" vault login -method=oidc -address \"$VAULT_ADDR\" -no-print; RC=\$?; if [ \$RC -ne 0 ]; then echo \"Vault login failed (exit \$RC). Press Enter to close.\"; read; fi; exit \$RC"
            ${pkgs.tmux}/bin/tmux wait-for "$SESSION_NAME" &
            WAIT_PID=$!
            # Tell tmux to signal when the session's hook fires
            ${pkgs.tmux}/bin/tmux set-hook -t "$SESSION_NAME" session-closed "run-shell '${pkgs.tmux}/bin/tmux wait-for -S $SESSION_NAME'"
            wait $WAIT_PID 2>/dev/null
            echo "Vault login session finished."
          fi
          SCRIPT
          chmod +x $out/bin/+vault-login
        '';
      };
    in
    {
      home.packages = [ vaultLoginPackage ];
    };
}
