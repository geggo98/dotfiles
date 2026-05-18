{ inputs, ... }:
{
  flake.modules.homeManager.bitbucket-cli = { pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      version = "0.18.0";
      bitbucket-cli = unstable.buildGoModule {
        pname = "bitbucket-cli";
        inherit version;

        src = unstable.fetchFromGitHub {
          owner = "gildas";
          repo = "bitbucket-cli";
          rev = "v${version}";
          hash = "sha256-mXipSaWMu4B/uToqSz6BOEwK2j4KdipVOJKfTU0RFic=";
        };

        vendorHash = "sha256-Rimgeqv372Y2CiUA1ga+7XjtP/LpXjKrKZbWAsccohI=";

        ldflags = [
          "-s"
          "-w"
          "-X main.commit=v${version}"
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
