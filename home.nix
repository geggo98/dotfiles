{ config, pkgs, nixpkgs-unstable, lib, astronvim, sops-nix, nix-index-database, ... }:
let
  moreutilsWithoutParallel = pkgs.moreutils.overrideAttrs(oldAttrs: rec {
        preBuild = oldAttrs.preBuild + ''
          substituteInPlace Makefile --replace " parallel " " " --replace " parallel.1 " " "
        '';
      });
  unstable = nixpkgs-unstable.legacyPackages.${pkgs.system};
in
{
  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  # https://nix-community.github.io/home-manager/release-notes.xhtml
  home.stateVersion = "22.05";

  # Import home-manager modules
  # Import them here instead of in the flake input to avoid importing NixOS modules not compatible with macOS Darwin
  imports = [
    nix-index-database.hmModules.nix-index
    sops-nix.homeManagerModules.sops
  ];

  sops = {
    # age.keyFile = "~/.config/sops/keys/age";
    # SSH keys must be passwordless and in Ed25519 format
    # `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_sops_nopw -N ""`
    # Convert them with the ssh-to=age command: `ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw`
    # Edit file with `env SOPS_AGE_KEY=(, ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key ) sops secrets/secrets.enc.yaml`
    age.sshKeyPaths = [ "/Users/stefan/.ssh/id_ed25519_sops_nopw" ];
    defaultSopsFile = ./secrets/secrets.enc.yaml;
    secrets = {
      openai_api_key = {};
      anthropic_api_key = {};
    };
  };

  # https://github.com/malob/nixpkgs/blob/master/home/default.nix

  # Direnv, load and unload environment variables depending on the current directory.
  # https://direnv.net
  # https://rycee.gitlab.io/home-manager/options.html#opt-programs.direnv.enable
  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;

  programs.nix-index-database.comma.enable = true;
  
  programs.zsh.enable = true;
  programs.fish = {
    enable = true;
    interactiveShellInit = (builtins.readFile ./config/fish/promptInit.fish)
      + ''
        export_nix_sops_secret_path OPENAI_API_KEY_PATH "${config.sops.secrets.openai_api_key.path}"
        export_nix_sops_secret_value OPENAI_API_KEY "${config.sops.secrets.openai_api_key.path}"
        export_nix_sops_secret_path ANTHROPIC_API_KEY_PATH "${config.sops.secrets.anthropic_api_key.path}"
        export_nix_sops_secret_value ANTHROPIC_API_KEY "${config.sops.secrets.anthropic_api_key.path}"
        '';
    plugins = [
      { name = "z"; src = pkgs.fishPlugins.z.src; }
      { name = "fzf"; src = pkgs.fishPlugins.fzf-fish.src; }
      { name = "forgit"; src = pkgs.fishPlugins.forgit.src; }
      { name = "github-copilot-cli"; src = pkgs.fishPlugins.github-copilot-cli-fish.src; }
      { name = "bass"; src = pkgs.fishPlugins.bass.src; }
    ];
    shellAbbrs = {
      # Abbreviations for "forgit": https://github.com/wfxr/forgit
      # You can also use completion on "forgit::"
      "+git-add-interactive" = "ga";
      "+git-checkout-branch" = "gcb";
      "+git-checkout-commit" = "gco";
      "+git-checkout-file" = "gcf";
      "+git-checkout-tag" = "gct";
      "+git-commit-fixup" = "gfu";
      "+git-delete-branch-interactive" = "gbd";
      "+git-diff-interactive" = "gd";
      "+git-ignore-generator" = "gi";
      "+git-log-viewer" = "glo";
      "+git-reset-head" = "grh";
      "+git-revert-commit" = "grc";
      "+git-stash-push" = "gsp";
      "+git-stash-viewer" = "gss";

      # lsd dir colors
      "+l" = "lsd";
      "+la" = "lsd -a";
      "+ll" = "lsd -l --git";
      "+lla" = "lsd -la --git";
      "+llt" = "lsd --long --tree --git --ignore-glob .git --ignore-glob node_modules";
      "+lt" = "lsd --tree --ignore-glob .git --ignore-glob node_modules";

      # YubiKey
      "+ssh-add-yubikey" = "env SSH_AUTH_SOCK={$HOME}.ssh/agent ssh-add {$HOME}/.ssh/id_es255519_sk";

      # yt-dlp
      "+yt-dlp" = "yt-dlp -i --format 'bestvideo[ext=mp4]+bestaudio/best[ext=m4a]/best' --merge-output-format mp4 --no-post-overwrites --output ~/Downloads/yt-dlp/'%(title)s.%(ext)s'";

      # Nix
      "+darwin-rebuild-switch" = "darwin-rebuild switch --flake ~/.config/nix-darwin";

      # Grep
      "+grep" = "ug";
      "+grep-tui" = "ug -Q";
    };
  };
  programs.nix-index.enable = true;
  programs.nnn.enable = true;
  programs.starship= {
    enable = true;
    enableTransience = true;
  };

  programs.git = {
    enable = true;
    userName = "stefan.schwetschke";
    userEmail = "stefan@schwetschke.de";
    lfs = {
      enable = true;
    };
    difftastic = {
      # Note: For big files, use "delta" instead. 
      # It's faster, also has syntax highlightning, but doesn't interpret structure.
      enable = true;
    };
    extraConfig = {
      # `echo '*.enc.yaml diff=sopsdiffer' >> .gitattributes`
      diff."sopsdiffer".textconv = "${pkgs.sops}/bin/sops -d";
    };
  };
  programs.gh.enable = true;
  programs.lazygit.enable = true;
  
  programs.atuin= {
    enable = true;
    settings = {
      dialect = "uk"; # Date format
      workspaces = true;
      enter_accept = true;
    };
    # https://atuin.sh/docs/commands/sync
  };
  programs.bat.enable = true;
  programs.fzf.enable = true;
  programs.gpg.enable = true;
  programs.k9s.enable = true;
  programs.lsd.enable = true;
  programs.ripgrep.enable = true;

  # Htop
  # https://rycee.gitlab.io/home-manager/options.html#opt-programs.htop.enable
  programs.htop.enable = true;
  programs.htop.settings.show_program_path = true;

  programs.aria2.enable = true;
  programs.yt-dlp = {
    enable = true;
    settings = {
      embed-thumbnail = true;
      embed-subs = true;
      sub-langs = "all";
      downloader = "aria2c";
      downloader-args = "aria2c:'-c -x8 -s8 -k1M'";
    };
  };

  home.packages = with pkgs; [
    # Some basics
    coreutils-prefixed # Command line utils with more options than their macOS / BSD counterparts.
    curl
    wget

    # Dev stuff
    # (agda.withPackages (p: [ p.standard-library ]))
    asciinema
    git-branchless
    git-machete
    git-trim
    git-credential-manager # Manages HTTPS tokens for Azure DevOps, Bitbucket, GitHub, and GitLab. `git credential-manager configure`
    lazygit
    # gitu # https://github.com/altsem/gitu - GIT TUI client
    # tig # https://jonas.github.io/tig/
    nodePackages.typescript
    nodePackages.ts-node
    nodejs
    neovim

    # DevOps tools
    awscli
    dive # Inspect Docker images
    docker-buildx
    docker-client
    docker-credential-helpers # Safely store docker credentials: https://github.com/docker/docker-credential-helpers
    docker-ls # Query docker registries https://github.com/mayflower/docker-ls
    k9s
    kubectl
    kubetail
    lazydocker
    lnav # Log file viewer https://lnav.org/
    mkcert
    mosh
    netcat
    ngrok
    pssh
    shellcheck
    step-ca
    step-cli # https://github.com/smallstep/cli
    socat
    sops
    # tor
    # torsocks # https://www.jamieweb.net/blog/tor-is-a-great-sysadmin-tool/
    xxh # ssh with better shell supporton the remote site

    # CSV processing
    jless
    miller
    q-text-as-data
    # sc-im # Has open CVE in libxls-1.6.2
    visidata
    xsv

    # Password management
    # pkgs._1password
    pass
    passExtensions.pass-audit
    passExtensions.pass-checkup
    passExtensions.pass-genphrase
    passExtensions.pass-import
    passExtensions.pass-otp
    passExtensions.pass-update

    # Command line helper
    btop
    bottom # Was "ytop", now "btm": https://github.com/ClementTsang/bottom
    fd
    findutils # xargs
    hexyl
    jc # Converts everything to json
    jq
    just # https://github.com/casey/just
    moreutilsWithoutParallel
    mktemp # This version supports the `--tmpdir` option
    pueue # Task manager https://github.com/Nukesor/pueue
    parallel
    pv
    python39Packages.ftfy # Fix broken unicode encoding
    rename
    tmuxp # Tmuxinator like session manager
    tldr-hs # TLDR client with local cache
    ugrep
    viddy # A modern watch alternative
    watchexec
    xxd
    yq
    zellij # Tmux / screen alternative: https://github.com/zellij-org/zellij

    # Pictures / Images
    imagemagickBig
    vips # Image manipulation: https://www.libvips.org/API/current/using-cli.html

    # Compressions
    p7zip # 7-zip with more codecs (Z-Standard, Brotli, Lizerd, AES encrypted ZIP files.
    xz
    zstd

    # Web
    curlie
    htmlq # Like JQ, but for HTML

    # File explorers
    broot
    # nnn
    ranger
    vifm

    # Useful nix related tools
    any-nix-shell
    cachix # adding/managing alternative binary caches hosted by Cachix
    devbox # https://www.jetpack.io/devbox/docs/cli_reference/devbox/
    nil # Nix LSP https://github.com/oxalica/nil
    nodePackages.node2nix # Convert node packages to Nix


    # AI Tools
    unstable.chatblade
    unstable.llm # https://llm.datasette.io/ like chatblade, but also for local models
    github-copilot-cli # ??/!! git?/git! gh?/gh!
    # k8sgpt
    # shell_gpt
    # tabnine


  ] ++ lib.optionals stdenv.isDarwin [
    mas # CLI for the macOS app store
    m-cli # useful macOS CLI commands
  ];

  xdg.configFile = {
    # See https://github.com/maxbrunet/dotfiles/blob/ebd85ceb40cbe79ebd5453bce63d384c1b49274a/nix/home.nix#L62
    astronvim = {
      onChange = "PATH=$PATH:${pkgs.git}/bin ${pkgs.neovim}/bin/nvim --headless +quitall";
      source = ./config/astronvim;
    };
    nvim = {
      onChange = "PATH=$PATH:${pkgs.git}/bin ${pkgs.neovim}/bin/nvim --headless +quitall";
      source = astronvim;
    };
    "starship.toml" = {
      source = ./config/starship-preset-bracketed-segments.toml;
    };
  };


  # Misc configuration files --------------------------------------------------------------------{{{

  # https://docs.haskellstack.org/en/stable/yaml_configuration/#non-project-specific-config
  home.file.".stack/config.yaml".text = lib.generators.toYAML {} {
    templates = {
      scm-init = "git";
      params = {
        author-name = "Stefan Schwetschke"; # config.programs.git.userName;
        author-email = "stefan@schwetschke.de"; # config.programs.git.userEmail;
        github-username = "geggo99";
      };
    };
    nix.enable = true;
  };

  home.file."Library/Application Support/iTerm2/DynamicProfiles/50_Nix.json" = lib.optionalAttrs (pkgs.system == "aarch64-darwin" || pkgs.system == "x86_64-darwin") {
    source = ./config/iTerm2/DynamicProfiles/50_Nix.json;
  };

  home.sessionVariables = {
    # Comma separated list of age recipients.
    # Convert from ssh key with `ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw`
    SOPS_AGE_RECIPIENTS = "age1vygfenpy584kvfdge57ep2vwqqe33zd4auanwu7frmf0tht5jq0q5ugmgd";
    # Doesn't work, because it contains the `%r` placeholder for the sops secrets directory.
    # OPENAI_API_KEY_FILE = config.sops.secrets."open_ai_api_key".path;
  };
}