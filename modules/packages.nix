{ inputs, ... }:
{
  flake.modules.homeManager.packages = { pkgs, lib, ... }:
    let
      unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      yt-dlp-pkgs = inputs.nixpkgs-yt-dlp.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      moreutilsWithoutParallel = pkgs.moreutils.overrideAttrs (oldAttrs: {
        preBuild = (oldAttrs.preBuild or "") + ''
          substituteInPlace Makefile --replace " parallel " " " --replace " parallel.1 " " "
        '';
      });
    in
    {
      programs.k9s.enable = true;
      programs.lsd.enable = true;
      programs.eza = {
        enable = true;
        enableBashIntegration = false;
        enableZshIntegration = false;
        enableFishIntegration = false;
      };
      programs.ripgrep.enable = true;
      programs.htop.enable = true;
      programs.htop.settings.show_program_path = true;
      programs.aria2.enable = true;
      programs.yt-dlp = {
        enable = true;
        package = yt-dlp-pkgs.yt-dlp;
        settings = {
          embed-thumbnail = true;
          embed-subs = true;
          sub-langs = "all";
          downloader = "aria2c";
          downloader-args = "aria2c:'-c -x8 -s8 -k1M'";
        };
      };
      programs.yazi = {
        enable = true;
        enableFishIntegration = true;
        enableZshIntegration = true;
        package = pkgs.yazi;
        plugins = {
          git = pkgs.yaziPlugins.git;
        };
        initLua = ''
          require("git"):setup()
        '';
        settings = {
          plugin = {
            prepend_fetchers = [
              {
                id = "git";
                name = "*";
                run = "git";
              }
              {
                id = "git";
                name = "*/";
                run = "git";
              }
            ];
          };
        };
      };

      home.packages = with pkgs; [
        # Basics
        coreutils-prefixed
        curl
        wget

        # Dev
        asciinema
        bun
        deno
        inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
        delta
        git-absorb
        git-machete
        git-trim
        git-credential-manager
        graphviz
        lazygit
        python313Packages.markitdown
        mermaid-cli
        nodePackages.typescript
        nodejs
        neovim
        pandoc
        plantuml-c4
        pixi
        rustup
        uv
        vale

        # Language servers
        gopls
        jdt-language-server
        lua-language-server
        pyright
        typescript-language-server

        # DevOps
        awscli
        dive
        docker-buildx
        docker-client
        docker-credential-helpers
        docker-ls
        gitleaks
        k9s
        kubectl
        kubetail
        lazydocker
        lnav
        krew
        mkcert
        netcat
        ngrok
        pssh
        shellcheck
        step-ca
        step-cli
        socat
        sops
        telepresence2
        topgrade
        tor
        xxh

        # CSV
        jless
        miller
        q-text-as-data
        sc-im
        visidata
        xan

        # CLI helpers
        btop
        bottom
        edir
        fd
        findutils
        hexyl
        jc
        jq
        just
        moreutilsWithoutParallel
        mktemp
        pueue
        parallel
        pv
        python312Packages.ftfy
        rename
        tmuxp
        tldr-hs
        trash-cli
        ugrep
        viddy
        watchexec
        xxd
        yq
        zellij

        # Images
        imagemagickBig
        vips

        # Compression
        p7zip
        xz
        zstd

        # Web
        curlie
        htmlq

        # File explorers
        edir
        ranger
        trash-cli
        vifm

        # Nix tools
        any-nix-shell
        cachix
        unstable.devbox
        nil
        nixd
        nixpkgs-fmt
        nodePackages.node2nix
        zsh-forgit
      ] ++ lib.optionals stdenv.isDarwin [
        mas
        m-cli
      ];
    };
}
