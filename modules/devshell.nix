{ ... }:
{
  perSystem = { pkgs, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [
        pkgs.nodejs
        pkgs.nodePackages.pnpm
        pkgs.pulumi
        pkgs.pulumiPackages.pulumi-language-nodejs
        pkgs.sops
      ];

      shellHook = ''
        echo "nix-darwin infra shell — pulumi $(pulumi version), node $(node --version)"
      '';
    };
  };
}
