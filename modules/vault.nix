{ ... }:
{
  flake.modules.homeManager.vault = { pkgs, ... }:
    let
      vaultLoginPackage = pkgs.stdenv.mkDerivation {
        name = "vault-login";
        dontUnpack = true;

        installPhase = ''
                    mkdir -p $out/bin

                    cat > $out/bin/+vault-login <<'EOF'
          #!${pkgs.zsh}/bin/zsh
          VAULT_ADDR=''${VAULT_ADDR:-"https://test-vault.kfz.check24.de"}
          vault login -method=oidc -address "$VAULT_ADDR" -no-print
          echo Check your web browser and finish the login there if necessary.
          EOF
                    chmod +x $out/bin/+vault-login
        '';
      };
    in
    {
      home.packages = [ vaultLoginPackage ];
    };
}
