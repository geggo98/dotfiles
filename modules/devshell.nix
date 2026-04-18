{ inputs, ... }:
{
  imports = [ inputs.devenv.flakeModule ];

  perSystem = { config, pkgs, ... }: {
    devenv.shells.default = {
      name = "nix-darwin";

      packages = [
        pkgs.nodejs
        pkgs.nodePackages.pnpm
        pkgs.pulumi
        pkgs.pulumiPackages.pulumi-language-nodejs
        pkgs.sops
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
