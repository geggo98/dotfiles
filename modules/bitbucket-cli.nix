{ inputs, ... }:
{
  flake.modules.homeManager.bitbucket-cli = { pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      version = "0.18.2";
      rev = "ab8655edd3f042eaa6ee4a6244a15bd21603c1fa"; # tag v0.18.2
      bitbucket-cli = unstable.buildGoModule {
        pname = "bitbucket-cli";
        inherit version;

        src = unstable.fetchFromGitHub {
          owner = "gildas";
          repo = "bitbucket-cli";
          inherit rev;
          hash = "sha256-XAyvB0opkmOriIEj8L3iYrAUPJCNsrzkBu/cd2tpuuc=";
        };

        vendorHash = "sha256-S1tH62vQ1+JyzkXxdN6t+yHMSmiqQ6QIkRyYGCROGlg=";

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
