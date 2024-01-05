{ config, pkgs, lib, astronvim, ... }:

{
  home.stateVersion = "22.05";

  # https://github.com/malob/nixpkgs/blob/master/home/default.nix

  # Direnv, load and unload environment variables depending on the current directory.
  # https://direnv.net
  # https://rycee.gitlab.io/home-manager/options.html#opt-programs.direnv.enable
  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
  
  programs.zsh.enable = true;
  programs.fish = {
    enable = true;
    interactiveShellInit = builtins.readFile ./config/fish/promptInit.fish;
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
      "+ll" = "lsd -l";
      "+lla" = "lsd -la";
      "+llt" = "lsd --long --tree --ignore-glob .git --ignore-glob node_modules";
      "+lt" = "lsd --tree --ignore-glob .git --ignore-glob node_modules";

      # YubiKey
      "+ssh-add-yubikey" = "env SSH_AUTH_SOCK={$HOME}.ssh/agent ssh-add {$HOME}/.ssh/id_es255519_sk";

      # yt-dlp
      "+yt-dlp" = "yt-dlp -i --format 'bestvideo[ext=mp4]+bestaudio/best[ext=m4a]/best' --merge-output-format mp4 --no-post-overwrites --output ~/Downloads/yt-dlp/'%(title)s.%(ext)s'";

      # Nix
      "+darwin-rebuild-switch" = "darwin-rebuild switch --flake ~/.config/nix-darwin";
    };
  };
  programs.nix-index.enable = true;
  programs.nnn.enable = true;
  programs.starship.enable = true;

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
  };
  programs.gh.enable = true;
  programs.lazygit.enable = true;
  
  programs.bat.enable = true;
  programs.fzf.enable = true;
  programs.gpg.enable = true;
  programs.k9s.enable = true;
  programs.lsd.enable = true;
  programs.mcfly.enable = true;
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
    coreutils
    curl
    wget

    # Dev stuff
    # (agda.withPackages (p: [ p.standard-library ]))
    jq
    just # https://github.com/casey/just
    nodePackages.typescript
    nodePackages.ts-node
    nodejs
    neovim

    # Command line helper
    fd
    pv
    xxd

    # Useful nix related tools
    cachix # adding/managing alternative binary caches hosted by Cachix
    comma # run software from without installing it
    nodePackages.node2nix # Convert node packages to Nix

    # chatblade # Broken, use brew version

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

}