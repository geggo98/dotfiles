{ inputs, ... }:
{
  flake.modules.homeManager.bitbucket-cli = { pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      # Pinned to dev tip 2026-05-26 because v0.18.0 ships a broken `bb pr update`
      # (gildas/bitbucket-cli#92 — "unsupported protocol scheme \"\"" in the
      # fetch-before-PATCH GET). Fix series ends at dcb23cf; this tip also
      # picks up the workspace-resolution follow-ups required to make the
      # command actually succeed end-to-end. Drop the pin once v0.18.1 ships.
      version = "0.18.1-unstable-2026-05-26";
      rev = "7963b7c88008379adc107d7ac78ece3ee5c435b8";
      bitbucket-cli = unstable.buildGoModule {
        pname = "bitbucket-cli";
        inherit version;

        src = unstable.fetchFromGitHub {
          owner = "gildas";
          repo = "bitbucket-cli";
          inherit rev;
          hash = "sha256-+kVcNieqidC2D/8ruJtMe2Mo/WqkD6gC8dpSYT3hOuk=";
        };

        vendorHash = "sha256-Rimgeqv372Y2CiUA1ga+7XjtP/LpXjKrKZbWAsccohI=";

        ldflags = [
          "-s"
          "-w"
          "-X main.commit=${builtins.substring 0 7 rev}"
          "-X main.stamp=${version}"
        ];

        doCheck = false;

        nativeBuildInputs = [ unstable.installShellFiles ];

        postInstall = ''
          if [ -e "$out/bin/bitbucket-cli" ] && [ ! -e "$out/bin/bb" ]; then
            mv "$out/bin/bitbucket-cli" "$out/bin/bb"
          fi

          installShellCompletion --cmd bb \
            --bash <($out/bin/bb completion bash) \
            --fish <($out/bin/bb completion fish) \
            --zsh  <($out/bin/bb completion zsh)
        '';

        meta = with lib; {
          description = "Bitbucket Cloud CLI (gildas/bitbucket-cli)";
          homepage = "https://github.com/gildas/bitbucket-cli";
          license = licenses.mit;
          mainProgram = "bb";
        };
      };
    in
    {
      home.packages = [ bitbucket-cli ];
    };
}
