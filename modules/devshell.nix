{ inputs, ... }:
{
  imports = [ inputs.devenv.flakeModule ];

  perSystem = { config, pkgs, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      devenv.shells.default = {
        name = "nix-darwin";

        packages = [
          pkgs.nodejs
          pkgs.nodePackages.pnpm
          unstable.pulumi-bin
          pkgs.sops
          pkgs.just # justfile
          pkgs.moreutils # ts
        ];

        git-hooks.hooks = {
          gitleaks = {
            enable = true;
            name = "gitleaks";
            entry = "${pkgs.gitleaks}/bin/gitleaks protect --staged --verbose --redact";
            pass_filenames = false;
          };
          nixpkgs-fmt.enable = true;
          check-merge-conflicts.enable = true;
          trim-trailing-whitespace.enable = true;
        };

        enterShell = ''
          echo "nix-darwin infra shell — pulumi $(pulumi version), node $(node --version)"
        '';
      };
    };
}
