{ inputs, ... }:
{
  flake.modules.homeManager.bitbucket-cli = { pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      # Newest tag that builds with nixpkgs-unstable's Go (1.26.x): v0.18.6 and later
      # declare `go 1.27` in go.mod ("go.mod requires go >= 1.27"). Re-check before bumping.
      version = "0.18.5";
      rev = "82e360722844f1ff9fcef34d3bdfb33a8b8d2cce"; # tag v0.18.5
      bitbucket-cli = unstable.buildGoModule {
        pname = "bitbucket-cli";
        inherit version;

        src = unstable.fetchFromGitHub {
          owner = "gildas";
          repo = "bitbucket-cli";
          inherit rev;
          hash = "sha256-u61dRrNzLO9WvPytpCZ06ojz+2s5l0gEsO0M+T1BUGs=";
        };

        vendorHash = "sha256-p4jlcxvOslGOXk58X3dJ6/WiFOEjCACnx5pwsvH0o28=";

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
