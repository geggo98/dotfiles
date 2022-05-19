{ config, pkgs, lib, ... }:
let
  unstable = import <nixpkgs-unstable> { config = config.nixpkgs.config; }; # nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs-unstable
  pkgs_x86 = import <nixpkgs> { localSystem = "x86_64-darwin"; config = config.nixpkgs.config; overlays = config.nixpkgs.overlays; };
  unstable_x86 = import <nixpkgs-unstable> { localSystem = "x86_64-darwin"; config = config.nixpkgs.config; overlays = config.nixpkgs.overlays; }; # nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs-unstable
in
{
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages =
    [
      pkgs.fish
      pkgs.fishPlugins.done
      pkgs.fishPlugins.foreign-env
      pkgs.fishPlugins.forgit
      # pkgs.fishPlugins.fzf-fish
      pkgs_x86.nix-index # Provides nix-locate
      pkgs.starship
      pkgs.mcfly
      pkgs.gitAndTools.gitFull
      pkgs.git-lfs
      pkgs.any-nix-shell

      # Vim & NeoVim
      # pkgs.vim
      pkgs.vimpager
      unstable.neovim
      # unstable.nvimpager
      unstable.rnix-lsp
      # unstable.treesitter
      unstable.tabnine
      unstable.lua


      pkgs.postgresql_13

      # Backups
      # unstable.maestral
      # pkgs.mackup
      # pkgs.git-annex-remote-dbx

      # Nim programming language
      pkgs.nim
      # pkgs.nrpl
      pkgs.nimlsp

      # Java programming language
      unstable.java-language-server
      unstable.openjdk17
      unstable.gradle_7
      # unstable.graalvm17-ce

      # Clojure programming language
      pkgs.clojure
      # pkgs.clojure-lsp
      pkgs.leiningen
      pkgs_x86.babashka

      # Scala programming language
      unstable.sbt-with-scala-native
      # unstable.sbt-extras

      # JavaScript / TypeScript programming language
      unstable.deno
      unstable.yarn
      unstable.nodejs-17_x
      unstable.esbuild
      unstable.k6 # Load testing: https://github.com/grafana/k6

      # Python programming language
      pkgs.python27Full
      pkgs.python38Full
      pkgs.poetry
      # pkgs.python-language-server

      # Rust programming language
      pkgs.cargo
      pkgs.rls
      pkgs.rust-script
      pkgs.rustc
      pkgs.rustfmt
      # pkgs.rustup

      # Go programming language
      pkgs.go_1_17
      pkgs.gopkgs
      pkgs.gopls
      pkgs.go-tools

      # Haskell programming language
      unstable.stack
      pkgs.ghc


      # UI Tools
      # unstable.handbrake
      # unstable.iterm2
      # unstable.maestral-gui

      # DevOps & Kubernetes
      unstable.colima # Docker on Linux on Max: Replaces Docker Desktop
      unstable.docker-buildx
      unstable.docker-client
      unstable.docker-compose
      unstable.docker-compose_2 # Enable "docker compose" (without dash), so docker cli can directly use compose files.
      unstable.docker-credential-helpers # Safely store docker credentials: https://github.com/docker/docker-credential-helpers
      pkgs.docker-ls # Query docker registries
      pkgs.minikube
      pkgs.nimbo # https://github.com/nimbo-sh/nimbo
      # pkgs.niv
      # pkgs.nixopsUnstable
      pkgs.awscli
      pkgs.cloudflared # https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/run-tunnel/trycloudflare (cloudflared tunnel --url http://localhost:7000)
      pkgs.k9s
      pkgs.kubectl
      pkgs.kubetail
      pkgs.lorri
      # pkgs.helm
      pkgs.mkcert
      pkgs.step-ca
      pkgs.step-cli # https://github.com/smallstep/cli
      pkgs.terraform

      # CSV processing
      pkgs.miller
      pkgs.q-text-as-data
      pkgs.sc-im
      unstable.visidata
      pkgs.xsv

      # Video donwload
      unstable.youtube-dl
      unstable.yt-dlp
      unstable.aria2

      # Password management
      # pkgs._1password
      pkgs.pass
      pkgs.passExtensions.pass-audit
      pkgs.passExtensions.pass-checkup
      pkgs.passExtensions.pass-genphrase
      pkgs.passExtensions.pass-import
      pkgs.passExtensions.pass-otp
      pkgs.passExtensions.pass-update

      # Command line tools
      pkgs.asciinema
      pkgs.bat
      pkgs.bar
      pkgs.broot
      pkgs.bottom # Was "ytop", now "btm": https://github.com/ClementTsang/bottom
      unstable.btop
      unstable.comby # Structural search & replace for source code, https://comby.dev/docs/overview
      pkgs.coreutils # Command line utils with more options than their macOS / BSD counterparts.
      pkgs.curl
      pkgs.curlie
      pkgs.delta # git-delta: https://github.com/dandavison/delta
      unstable.difftastic # difft: https://github.com/Wilfred/difftastic
      pkgs.direnv
      pkgs.nix-direnv
      pkgs.nix-direnv-flakes
      pkgs.exa
      pkgs_x86.eternal-terminal # https://eternalterminal.dev/
      pkgs.fd
      pkgs.findutils # xargs
      pkgs.fzf
      # pkgs.fff
      pkgs.python39Packages.ftfy # Fix unicode, https://ftfy.readthedocs.io/en/latest/
      pkgs.hexyl
      pkgs.git-trim
      pkgs.htop
      pkgs.httpie
      pkgs.hyperfine
      pkgs.jq
      pkgs.lazygit
      unstable.mani # Manage multiple Git repositories at the same time, https://github.com/alajmo/mani 
      pkgs.mktemp # This version supports the `--tmpdir` option
      pkgs.mosh # https://mosh.org/
      unstable.netcat
      pkgs.parallel
      pkgs.python39Packages.ftfy # Fix broken unicode encoding
      pkgs.pv
      pkgs.pwgen
      pkgs.rename
      pkgs.ripgrep
      # pkgs.sagemath
      pkgs.shellcheck
      pkgs.socat
      pkgs.tig
      # pkgs.tmux
      pkgs_x86.tor
      pkgs_x86.torsocks # https://www.jamieweb.net/blog/tor-is-a-great-sysadmin-tool/
      # pkgs.usbutils # lsusb
      pkgs.watch
      pkgs.wget
      pkgs_x86.watchexec
      pkgs.xz
      pkgs.yq
      pkgs.zstd
    ];

  # Use a custom configuration.nix location.
  # $ darwin-rebuild switch -I darwin-config=$HOME/.config/nixpkgs/darwin/configuration.nix
  # environment.darwinConfig = "$HOME/.config/nixpkgs/darwin/configuration.nix";
  environment.darwinConfig = "$HOME/.nixpkgs/darwin-configuration.nix";

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  nix.package = pkgs.nix; # or: pkgs.nixFlakes

  # Enable lorri direnv rebuild: https://github.com/nix-community/lorri
  services.lorri.enable = true;

  # Create /etc/bashrc that loads the nix-darwin environment.
  programs.bash.enable = true;
  programs.zsh.enable = true;
  programs.fish = {
    enable = true;
    promptInit = ''
      if command -v starship > /dev/null
        starship init fish | source
      end
      if command -v vimpager > /dev/null
        set -x MANPAGER (command -v vimpager)
      end
      if command -v bat > /dev/null
        set -x PAGER (command -v bat)
        if command -v fzf > /dev/null
          alias fzf "fzf --preview \"bat --color=always --style=numbers --line-range=:500 {}\"" 
        end
      end

      if command -v {$HOME}/.local/bin/lvim > /dev/null
        alias lvim {$HOME}/.local/bin/lvim
        set -x VISUAL /{$HOME}/.local/bin/lvim
        set -x GIT_EDITOR /{$HOME}/.local/bin/lvim
      else
        set -x GIT_EDITOR vim
      end

      if command -v /opt/homebrew/bin/brew > /dev/null
         /opt/homebrew/bin/brew shellenv | source
      end

      if command -v ${pkgs.mcfly}/bin/mcfly > /dev/null
        ${pkgs.mcfly}/bin/mcfly init fish | source
      end


      test -e {$HOME}/.iterm2_shell_integration.fish ; and source {$HOME}/.iterm2_shell_integration.fish
      test -d {$HOME}/.iterm2 ; and fish_add_path {$HOME}/.iterm2 
    '';
  };

  # programs.direnv = {
  #   enable = true;
  #   enableNixDirenvIntegration = true;
  # };

  # programs.neovim = {
  #     enable = true;
  # };

  programs.vim = {
    enable = true;
    enableSensible = true;
    plugins = [{ names = [ "surround" "vim-nix" "vim-gnupg" "editorconfig-vim" "neorg" ]; }];
  };

  programs.tmux = {
    enable = true;
    enableSensible = true;
    enableMouse = true;
    enableFzf = true;
    enableVim = true;
    defaultCommand = "${pkgs.fish}/bin/fish";
    extraConfig = ''
      # https://github.com/namtzigla/oh-my-tmux
      set -g default-terminal "xterm-256color" # colors!
      setw -g xterm-keys on
      set -s escape-time 10                     # faster command sequences
      set -sg repeat-time 600                   # increase repeat timeout
      set -s focus-events on

      set -g prefix2 C-a                        # GNU-Screen compatible prefix
      bind C-a send-prefix -2

      set -q -g status-utf8 on                  # expect UTF-8 (tmux < 2.2)
      setw -q -g utf8 on

      set -g history-limit 5000                 # boost history

      # edit configuration
      bind e new-window -n '~/.tmux.conf.local' "sh -c '\${EDITOR:-vim} ~/.tmux.conf.local && tmux source ~/.tmux.conf && tmux display \"~/.tmux.conf sourced\"'"

      # reload configuration
      bind r source-file ~/.tmux.conf \; display '~/.tmux.conf sourced'


      # -- display -------------------------------------------------------------------

      set -g base-index 1         # start windows numbering at 1
      setw -g pane-base-index 1   # make pane numbering consistent with windows

      setw -g automatic-rename on # rename window to reflect current program
      set -g renumber-windows on  # renumber windows when a window is closed

      set -g set-titles on                        # set terminal title
      set -g set-titles-string '#h ❐ #S ● #I #W'
      # pane navigation
      bind -r h select-pane -L  # move left
      bind -r j select-pane -D  # move down
      bind -r k select-pane -U  # move up
      bind -r l select-pane -R  # move right
      bind > swap-pane -D       # swap current pane with the next one
      bind < swap-pane -U       # swap current pane with the previous one

      # pane resizing
      bind -r H resize-pane -L 2
      bind -r J resize-pane -D 2
      bind -r K resize-pane -U 2
      bind -r L resize-pane -R 2

      # window navigation
      unbind n
      unbind p
      bind -r C-h previous-window # select previous window
      bind -r C-l next-window     # select next window
      bind Tab last-window        # move to last active window

    '';
  };

  # programs.nix-index.enable = true;
  # programs.command-not-found.enable = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # You should generally set this to the total number of logical cores in your system.
  # $ sysctl -n hw.ncpu
  nix.maxJobs = 4;
  nix.buildCores = 4;
  nix.extraOptions = ''
    extra-platforms = x86_64-darwin aarch64-darwin
    experimental-features = nix-command flakes
  '';

  # Allow non-free packages
  nixpkgs.config.allowUnfree = true;

  system.defaults.NSGlobalDomain.ApplePressAndHoldEnabled = false;
  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;

  # https://apple.stackexchange.com/a/288764
  system.defaults.NSGlobalDomain.InitialKeyRepeat = 15;
  system.defaults.NSGlobalDomain.KeyRepeat = 2;
  #system.defaults.NSGlobalDomain.com.apple.keyboard.fnState = true;

  #system.defaults.NSGlobalDomain.com.apple.mouse.tapBehavior = 1;
  #system.defaults.NSGlobalDomain.com.apple.trackpad.scaling = 3;

  system.defaults.dock.autohide = true;
  system.defaults.dock.mru-spaces = false;
  system.defaults.dock.orientation = "right";
  system.defaults.dock.tilesize = 16;

  system.defaults.trackpad.TrackpadThreeFingerDrag = true;

  system.keyboard.enableKeyMapping = true;
  system.keyboard.nonUS.remapTilde = true;
  system.keyboard.remapCapsLockToEscape = true;

}
