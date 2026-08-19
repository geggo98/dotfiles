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

        # devenv.root defaults to `builtins.getEnv "PWD"`, which is "" under the
        # pure evaluation `nix flake check` uses — tripping devenv's "could not
        # determine the current directory" assertion. Fall back to the flake
        # source path so the shell still evaluates for `nix flake check`;
        # interactive shells (direnv / `nix develop --no-pure-eval`) set PWD and
        # keep the original behaviour.
        devenv.root =
          let pwd = builtins.getEnv "PWD";
          in if pwd != "" then pwd else toString inputs.self;

        packages = [
          pkgs.nodejs
          pkgs.pnpm
          unstable.pulumi-bin
          pkgs.sops
          pkgs.just # justfile
          pkgs.moreutils # ts

          # Backup tooling. Here rather than in home-manager's packages for the same
          # reason pulumi is: it is used to operate infrastructure from this
          # repository, not to work on a laptop.
          #
          # rclone is not an alternative to restic but a dependency of one path
          # through it: restic's rclone backend works by spawning
          # `rclone serve restic --stdio`, so a repository like `rclone:dropbox:…`
          # fails outright without it. Nothing references it by name, so without this
          # note a future tidy-up would remove it as unused.
          pkgs.rclone
          pkgs.restic
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
