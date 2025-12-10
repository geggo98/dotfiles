{ config, pkgs, nixpkgs-unstable, lib, astronvim, sops-nix, nix-index-database, ... }:
let
    moreutilsWithoutParallel = pkgs.moreutils.overrideAttrs (oldAttrs: {
      preBuild = (oldAttrs.preBuild or "") + ''
        substituteInPlace Makefile --replace " parallel " " " --replace " parallel.1 " " "
      '';
    });
    unstable = nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
    # Prefer docker-client if available in this nixpkgs, else fallback to docker
    dockerPkg = if builtins.hasAttr "docker-client" pkgs then pkgs."docker-client" else pkgs.docker;
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
  home.stateVersion = "25.11";

  # Import home-manager modules
  # Import them here instead of in the flake input to avoid importing NixOS modules not compatible with macOS Darwin
  imports = [
    nix-index-database.homeModules.nix-index
    sops-nix.homeManagerModules.sops
    ./modules/aichat.nix
  ];

  sops = {
    # age.keyFile = "~/.config/sops/keys/age";
    # SSH keys must be passwordless and in Ed25519 format
    # `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_sops_nopw -N ""`
    # Convert them with the ssh-to=age command: `ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw`
    # Edit secrets in the file with: `env SOPS_AGE_KEY=(, ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key ) sops edit secrets/secrets.enc.yaml`
    # Edit keys in the file: `env SOPS_AGE_KEY=(, ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key ) sops -s edit secrets/secrets.enc.yaml`
    # Add key with: `env SOPS_AGE_KEY=(, ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key ) sops --add-age age1... -r -i secrets/secrets.enc.yaml
    age.sshKeyPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519_sops_nopw" ];
    defaultSopsFile = ./secrets/secrets.enc.yaml;
    secrets = {
      "aws/credentials".path = "${config.home.homeDirectory}/.aws/credentials";
      "aws/credentials".mode = "0600";
      "aws/config".path = "${config.home.homeDirectory}/.aws/config";
      "aws/config".mode = "0600";
      openai_api_key = {};
      anthropic_api_key = {};
      openrouter_api_key = {};
      groq_api_key = {};
      gemini_api_key = {};
      context7_api_key = {};
      ollama_api_key = {};
      travily_api_key = {};
      z_ai_api_key = {};
      slack_c24_api_key = {};
      atlassian_c24_bitbucket_api_token = {};
      confluence_url = {};
      confluence_username = {};
      confluence_personal_token = {};
      jira_url = {};
      jira_username = {};
      jira_api_token = {};
      absence_io_api_id = {};
      absence_io_api_key = {};
      "c24_bi_kfz_test_stefan_schwetschke.json" = {};
      "c24_bi_kfz_prod_stefan_schwetschke.json" = {};
      "c24_bi_kfz_test_liquibase.json" = {};
      "c24_bi_kfz_prod_liquibase.json" = {};
    };
  };

  # Needs newer home manager to work properly
#  programs.claude-code = {
#      enable = true;
#
#      # MCP servers -> written by HM into Claude Code's MCP config
#      mcpServers = {
#        # 1) GitHub (containerized stdio)
#        github = {
#          type = "stdio";
#          command = "docker";
#          args = [
#            "run" "-i" "--rm"
#            "-e" "GITHUB_PERSONAL_ACCESS_TOKEN"
#            "ghcr.io/github/github-mcp-server"
#          ];
#          # No secrets here; docker -e forwards from your shell env.
#        };
#
#        # 2) Atlassian (remote SSE) — use HTTP if they offer it; SSE is second-class
#        atlassian = {
#          type = "sse";
#          url = "https://mcp.atlassian.com/v1/sse";
#        };
#
#        # 3) javadocs.dev (remote HTTP)
#        javadocs = {
#          type = "http";
#          url = "https://www.javadocs.dev/mcp";
#        };
#
#        # 4) Upstash Context7 (local stdio via npx)
#        context7 = {
#          type = "stdio";
#          command = "npx";
#          args = [ "-y" "@upstash/context7-mcp" ];
#          env = {
#            # expanded at runtime by Claude Code
#            CONTEXT7_API_KEY = "\${CONTEXT7_API_KEY}";
#          };
#        };
#
#        # 5) NixOS (local stdio via uvx)
#        nixos = {
#          type = "stdio";
#          command = "uvx";
#          args = [ "mcp-nixos" ];
#        };
#
#        # 6) Tavily (remote HTTP) — prefer header if supported; else query param
#        tavily = {
#          type = "http";
#          # If Tavily supports headers for you, use the headers block below and set url without query:
#          # url = "https://mcp.tavily.com/mcp/";
#          # headers = { Authorization = "Bearer ${TAVILY_API_KEY}"; };
#          # Otherwise keep query-param style:
#          url = "https://mcp.tavily.com/mcp/?tavilyApiKey=\${TAVILY_API_KEY}";
#        };
#
#        # 7) Google Programmable Search (local stdio via npx)
#        google-pse = {
#          type = "stdio";
#          command = "npx";
#          args = [
#            "-y" "google-pse-mcp"
#            "https://www.googleapis.com/customsearch"
#            "\${GOOGLE_CSE_ID}"    # engine ID (cx)
#            # If the tool needs the API key as an arg, add: "${GOOGLE_API_KEY}"
#          ];
#          env = {
#            GOOGLE_API_KEY = "\${GOOGLE_API_KEY}";
#            GOOGLE_CSE_ID  = "\${GOOGLE_CSE_ID}";
#          };
#        };
#      };
#  };

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

        export_nix_sops_secret_path OPENROUTER_API_KEY_PATH "${config.sops.secrets.openrouter_api_key.path}"
        export_nix_sops_secret_value OPENROUTER_API_KEY "${config.sops.secrets.openrouter_api_key.path}"
        # llm-openrouter expects the key in the environment variables LLM_OPENROUTER_KEY and OPENROUTER_KEY.
        export_nix_sops_secret_value LLM_OPENROUTER_KEY "${config.sops.secrets.openrouter_api_key.path}"
        export_nix_sops_secret_value OPENROUTER_KEY "${config.sops.secrets.openrouter_api_key.path}"

        export_nix_sops_secret_path GROQ_API_KEY_PATH "${config.sops.secrets.groq_api_key.path}"
        export_nix_sops_secret_value GROQ_API_KEY "${config.sops.secrets.groq_api_key.path}"

        # llm-openrouter expects the key in the environment variables LLM_GEMINI_KEY
        export_nix_sops_secret_value LLM_GEMINI_KEY "${config.sops.secrets.gemini_api_key.path}"
        export_nix_sops_secret_value GEMINI_API_KEY "${config.sops.secrets.gemini_api_key.path}"
        export_nix_sops_secret_path GEMINI_API_KEY_PATH "${config.sops.secrets.gemini_api_key.path}"

        export_nix_sops_secret_path CONTEXT7_API_KEY_PATH "${config.sops.secrets.context7_api_key.path}"
        export_nix_sops_secret_value CONTEXT7_API_KEY "${config.sops.secrets.context7_api_key.path}"

        export_nix_sops_secret_path OLLAMA_API_KEY_PATH "${config.sops.secrets.ollama_api_key.path}"
        export_nix_sops_secret_value OLLAMA_API_KEY "${config.sops.secrets.ollama_api_key.path}"

        export_nix_sops_secret_path TRAVILY_API_KEY_PATH "${config.sops.secrets.travily_api_key.path}"
        export_nix_sops_secret_value TRAVILY_API_KEY "${config.sops.secrets.travily_api_key.path}"

        export_nix_sops_secret_path Z_AI_API_KEY_PATH "${config.sops.secrets.z_ai_api_key.path}"
        export_nix_sops_secret_value Z_AI_API_KEY "${config.sops.secrets.z_ai_api_key.path}"

        export_nix_sops_secret_path ABSENCE_IO_API_ID_PATH "${config.sops.secrets.absence_io_api_id.path}"
        export_nix_sops_secret_value ABSENCE_IO_API_ID "${config.sops.secrets.absence_io_api_id.path}"

        export_nix_sops_secret_path ABSENCE_IO_API_KEY_PATH "${config.sops.secrets.absence_io_api_key.path}"
        export_nix_sops_secret_value ABSENCE_IO_API_KEY "${config.sops.secrets.absence_io_api_key.path}"

        export_nix_sops_secret_value SLACK_C24_API_KEY "${config.sops.secrets.slack_c24_api_key.path}"

        export_nix_sops_secret_value ATLASSIAN_C24_BITBUCKET_API_TOKEN "${config.sops.secrets.atlassian_c24_bitbucket_api_token.path}"
        export_nix_sops_secret_value ATLASSIAN_API_TOKEN "${config.sops.secrets.atlassian_c24_bitbucket_api_token.path}"
        '';
    plugins = [
      { name = "z"; src = pkgs.fishPlugins.z.src; }
      { name = "fzf"; src = pkgs.fishPlugins.fzf-fish.src; }
      { name = "forgit"; src = pkgs.fishPlugins.forgit.src; }

      { name = "bass"; src = pkgs.fishPlugins.bass.src; }
    ];

    functions = {
      "+git-ignore-generator" = {
        body = ''
          # Generate .gitignore files for multiple frameworks/languages
          # Usage: +git-ignore-generator <technology1> [technology2] [technology3]...
          # Example: +git-ignore-generator gradle java
          #          +git-ignore-generator node typescript react
          #
          # This function:
          # 1. Takes one or more technology names as arguments
          # 2. Joins them with commas
          # 3. URL encodes the result
          # 4. Makes a curl request to gitignore.io API
          # 5. Prints the resulting .gitignore content

          # Check if we have arguments
          if test (count $argv) -eq 0
            echo "Error: At least one technology name required"
            echo ""
            echo "Usage: +git-ignore-generator <technology1> [technology2] [technology3]..."
            echo ""
            echo "Examples:"
            echo "  +git-ignore-generator gradle java"
            echo "  +git-ignore-generator node typescript react"
            echo "  +git-ignore-generator python go"
            echo ""
            echo "See https://www.toptal.com/developers/gitignore for available technologies"
            return 1
          end

          # Join all arguments with commas
          set --local joined_args (string join "," $argv)

          # Make the curl request to gitignore.io API
          # Note: Fish shell handles URL encoding automatically when passing arguments
          curl -L -s "https://www.toptal.com/developers/gitignore/api/$joined_args"
        '';
        description = "Generate .gitignore files for multiple technologies via gitignore.io API";
      };
    };
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
      # "+git-ignore-generator" = "gi"; # Replaced with Fish function
      "+git-log-viewer" = "glo";
      "+git-reset-head" = "grh";
      "+git-revert-commit" = "grc";
      "+git-stash-push" = "gsp";
      "+git-stash-viewer" = "gss";

      # Use `lsd` for dir colors. Alternative: `eza`, the successor of `exa`. `eza` has more features, `lsd` better compatibility with `ls`.
      "+l" = "lsd";
      "+la" = "lsd -a";
      "+ll" = "lsd -l --git";
      "+lla" = "lsd -la --git";
      "+llt" = "lsd --long --tree --git --ignore-glob .git --ignore-glob node_modules --ignore-glob __pycache__";
      "+lt" = "lsd --tree --ignore-glob .git --ignore-glob node_modules --ignore-glob __pycache__";

      #Utils
      "+rm" = "trash";
      "+lsusb" = "system_profiler SPUSBDataType";
      "+bus-pirate" = ", tio -b 115200 -d 8 -p none -s 1 -f none (find /dev -maxdepth 2 -path '/dev/cu.usbmodem*' -o -path '/dev/serial/by-id/*' 2>/dev/null | fzf --prompt='Select Bus Pirate device > ')";
      "+usb-serial-autoconnect-latest" = ", tio -a latest";
      "+usb-serial-list" = ", tio --list";

      # YubiKey
      "+ssh-add-yubikey" = "env SSH_AUTH_SOCK={$HOME}.ssh/agent ssh-add {$HOME}/.ssh/id_es255519_sk";

      # yt-dlp
      "+yt-dlp" = "yt-dlp -i --format 'bestvideo[ext=mp4]+bestaudio/best[ext=m4a]/best' --merge-output-format mp4 --no-post-overwrites --output ~/Downloads/yt-dlp/'%(title)s.%(ext)s'";

      # Nix
      "+darwin-rebuild-switch" = "sudo darwin-rebuild switch --flake ~/.config/nix-darwin";

      # Grep
      "+grep" = "ug";
      "+grep-tui" = "ug -Q";

      # AI Agents
      "+agent-codex" = ", codex";
      "+agent-codex-sandbox" = ", codex --full-auto";
      "+agent-codex-danger-delete-all-my-files-and-trash-my-computer" = ", codex --dangerously-bypass-approvals-and-sandbox";
      "+agent-claude" = ", claude";
      "+agent-cline" = "npx -y cline";
      "+agent-opencode" = ", opencode";

      # SOPS Encryption
      "+sops-edit-keys" = "env SOPS_AGE_KEY=(, ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key ) sops -s edit";
      "+sops-edit-secrets" = "env SOPS_AGE_KEY=(, ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key ) sops edit";
    };
  };
  programs.nix-index.enable = true;
  programs.nnn.enable = true;
  programs.starship= {
    enable = true;
    enableTransience = true;
  };
  programs.yazi = {
    enable = true; # TUI file manager, start with `ya`. https://yazi-rs.github.io/docs/quick-start
    enableFishIntegration = true;
    enableZshIntegration = true;
    # Plugins don't work at the moment: Home manager expects them to have an `init.lua`, but they have a `main.lua`.
    package = pkgs.yazi;
    plugins = {
        git = pkgs.yaziPlugins.git; # see https://github.com/yazi-rs/plugins/tree/main/git.yazi
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

  programs.helix = {
    enable = true;
    settings = {
      editor = {
        bufferline = "multiple";
      };
    };
  };

  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      user = {
        name = "stefan.schwetschke";
        email = "stefan@schwetschke.de";
      };
      # `echo '*.enc.yaml diff=sopsdiffer' >> .gitattributes`
      diff."sopsdiffer".textconv = "${pkgs.sops}/bin/sops -d";
      credential = {
        credentialStore = "keychain"; # See https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/credstores.md
        helper = "${pkgs.git-credential-manager}/bin/git-credential-manager";
      };
    };
  };
  programs.difftastic = {
    # Note: For big files, use "delta" instead. 
    # It's faster, also has syntax highlightning, but doesn't interpret structure.
    enable = true;
    git.enable = true;
  };
  # programs.git-credential-oauth.enable = true;
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
  programs.eza = {
    enable = true;
    # Shell integration sets aliases for `ls`, `ll`, `la`, `lt`, `lla`.
    enableBashIntegration = false;
    enableZshIntegration = false;
    enableFishIntegration = false;
  };
  programs.ripgrep.enable = true;

  # Htop
  # https://rycee.gitlab.io/home-manager/options.html#opt-programs.htop.enable
  programs.htop.enable = true;
  programs.htop.settings.show_program_path = true;

  programs.aria2.enable = true;
  programs.yt-dlp = {
    enable = true;
    package = unstable.yt-dlp;
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
    git-absorb # https://github.com/tummychow/git-absorb
    # git-branchless # https://github.com/arxanas/git-branchless # Provides `git undo` and `git sync` for updating all non-conflicting branches
    git-crypt # https://github.com/AGWA/git-crypt
    git-machete
    git-trim # https://github.com/foriequal0/git-trim
    git-credential-manager # Manages HTTPS tokens for Azure DevOps, Bitbucket, GitHub, and GitLab. `git credential-manager configure`. Alternative: https://github.com/hickford/git-credential-oauth
    graphviz
    # dotnet-runtime_7 # git-credential-manager needs this.
    lazygit
    # gitu # https://github.com/altsem/gitu - GIT TUI client
    # tig # https://jonas.github.io/tig/
    nodePackages.typescript
    nodejs
    neovim
    pandoc
    plantuml-c4
    pixi # Python venv manager, https://github.com/prefix-dev/pixi
    rustup
    uv # Python package manager, https://docs.astral.sh/uv/guides/tools/
    vale # Linter for prose

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
    krew # Package manager for kubectl
    mkcert
    # mosh
    netcat
    # ngrok
    pssh
    shellcheck
    step-ca
    step-cli # https://github.com/smallstep/cli
    socat
    sops
    telepresence2
    # tor
    # torsocks # https://www.jamieweb.net/blog/tor-is-a-great-sysadmin-tool/
    xxh # ssh with better shell supporton the remote site

    # CSV processing
    jless
    miller
    q-text-as-data
    # sc-im # Has open CVE in libxls-1.6.2
    visidata
    xan # alternative to xsv and csvkit

    # Password management
    # pkgs._1password
    #pass
    #passExtensions.pass-audit
    #passExtensions.pass-checkup
    #passExtensions.pass-genphrase
    #passExtensions.pass-import
    #passExtensions.pass-otp
    #passExtensions.pass-update

    # Command line helper
    btop
    bottom # Was "ytop", now "btm": https://github.com/ClementTsang/bottom
    edir # edit directories https://github.com/bulletmark/edir , see also https://github.com/trapd00r/vidir
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
    python312Packages.ftfy # Fix broken unicode encoding
    rename
    tmuxp # Tmuxinator like session manager
    tldr-hs # TLDR client with local cache
    trash-cli # move files to trash https://github.com/andreafrancia/trash-cli
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
    # broot
    # nnn
    edir # https://github.com/bulletmark/edir
    ranger
    trash-cli # https://github.com/andreafrancia/trash-cli
    vifm

    # Useful nix related tools
    any-nix-shell
    cachix # adding/managing alternative binary caches hosted by Cachix
    unstable.devbox # https://www.jetpack.io/devbox/docs/cli_reference/devbox/
    nil # Nix LSP https://github.com/oxalica/nil
    nixd # Nix language server https://github.com/nix-community/nixd
    nixpkgs-fmt # Nix formatter
    nodePackages.node2nix # Convert node packages to Nix


    # AI Tools
    unstable.aichat
    unstable.ollama

    # Utility scripts -----------------------------------------------------------------------------{{{
    (pkgs.writeShellApplication {
      name = "+mcp-atlassian";
      # Use Docker client from Nix; still requires a running Docker daemon.
      runtimeInputs = [ dockerPkg ];

      # Hint: Escape `${` with the sequence `''${`, don't use `\${` or `\\$}`.
      text = ''
        # Secrets directory (respects XDG_CONFIG_HOME if set)
        SECRETS_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"

        # Helper: if VAR is empty, try loading it from $SECRETS_DIR/<file>
        load_from_secret() {
          local var_name="$1" file_name="$2"
          # Bash indirect expansion: ''${!var_name}
          local current_val="''${!var_name-}"
          if [[ -z "''${current_val}" && -r "''${SECRETS_DIR}/''${file_name}" ]]; then
            local val
            val="$(<"''${SECRETS_DIR}/''${file_name}")"
            if [[ -n "''${val}" ]]; then
              export "''${var_name}=''${val}"
            fi
          fi
        }

        # Load Atlassian credentials (only if not already set in env)
        load_from_secret CONFLUENCE_URL       confluence_url
        load_from_secret CONFLUENCE_USERNAME  confluence_username
        load_from_secret CONFLUENCE_PERSONAL_TOKEN confluence_personal_token
        load_from_secret JIRA_URL             jira_url
        load_from_secret JIRA_USERNAME        jira_username
        load_from_secret JIRA_API_TOKEN       jira_api_token

        # Validate required variables
        missing=()
        for k in CONFLUENCE_URL CONFLUENCE_USERNAME CONFLUENCE_PERSONAL_TOKEN \
                 JIRA_URL JIRA_USERNAME JIRA_API_TOKEN; do
          if [[ -z "''${!k-}" ]]; then
            missing+=("$k")
          fi
        done

        if (( ''${#missing[@]} > 0 )); then
          echo "[mcp-atlassian] Missing required env vars: ''${missing[*]}" >&2
          echo "[mcp-atlassian] Provide them via environment or secrets in: $SECRETS_DIR" >&2
          exit 1
        fi

        # Allow image override; default to the official image
        IMAGE="''${MCP_ATLASSIAN_IMAGE:-ghcr.io/sooperset/mcp-atlassian:latest}"

        # Build docker args (keep -i like the original command)
        # See https://github.com/sooperset/mcp-atlassian
        args=(
          run -i --rm
          -e CONFLUENCE_URL
          -e CONFLUENCE_USERNAME
          -e CONFLUENCE_PERSONAL_TOKEN
          # -e "CONFLUENCE_SSL_VERIFY=false"
          -e JIRA_URL
          -e JIRA_USERNAME
          -e JIRA_API_TOKEN
          -e "ENABLED_TOOLS=jira_get_issue,jira_get_sprint_issues,jira_search,jira_transition_issue,jira_add_comment,confluence_get_page,confluence_get_page_children,confluence_get_labels,confluence_search"
          # -e "CONFLUENCE_SPACES_FILTER=KFZ,WDSSO,C24OITSUPPORT,HSM,MESA,C24HRPE,C24APPS,VSPROD"
          -e "JIRA_PROJECTS_FILTER=VUKFZIF,VUKFZOPS,VUKFZCORE"
          # -e MCP_VERBOSE=true
          # -e MCP_VERY_VERBOSE=true
          "$IMAGE"
        )

        # Exec docker; forward any extra args provided to the script
        exec docker "''${args[@]}" "$@"
      '';

      # Optional: adjust shellcheck if needed
      # excludeShellChecks = [ "SC2154" ];
    })
    (pkgs.writeShellApplication {
      name = "+agent-gemini";
      runtimeInputs = [ nodejs_24 ]; # TODO: Add `unstable.gemini` after switch to Nix 25.11

      # Hint: Escape `${` with the sequence `''${`, don't use `\${` or `\\$}`.
      text = ''
        # Secrets directory (respects XDG_CONFIG_HOME if set)
        SECRETS_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"

        # Helper: if VAR is empty, try loading it from $SECRETS_DIR/<file>
        load_from_secret() {
          local var_name="$1" file_name="$2"
          # Bash indirect expansion: ''${!var_name}
          local current_val="''${!var_name-}"
          if [[ -z "''${current_val}" && -r "''${SECRETS_DIR}/''${file_name}" ]]; then
            local val
            val="$(<"''${SECRETS_DIR}/''${file_name}")"
            if [[ -n "''${val}" ]]; then
              export "''${var_name}=''${val}"
            fi
          fi
          if [[ -z "''${var_name}" ]]; then
            echo "ERROR: Secret ''${var_name} not found" >&2
            exit 1
          fi
        }

        # Load Gemini API key secrets
        load_from_secret GEMINI_API_KEY  gemini_api_key
        # To use a specific version, run: npx -y github:google-gemini/gemini-cli@v0.5.0
        exec npx -y "github:google-gemini/gemini-cli" "$@"
        # exec comma gemini "$@"
      '';

      # Optional: adjust shellcheck if needed
      # excludeShellChecks = [ "SC2154" ];
    })
    (pkgs.writeShellApplication {
      name = "+agent-claude-apiKeyHelper";
      runtimeInputs = [  ];

      # Hint: Escape `${` with the sequence `''${`, don't use `\${` or `\\$}`.
      text = ''
        # Secrets directory (respects XDG_CONFIG_HOME if set)
        SECRETS_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets"

        # Helper: if VAR is empty, try loading it from $SECRETS_DIR/<file>
        load_from_secret() {
          local var_name="$1" file_name="$2"
          # Bash indirect expansion: ''${!var_name}
          local current_val="''${!var_name-}"
          if [[ -z "''${current_val}" && -r "''${SECRETS_DIR}/''${file_name}" ]]; then
            local val
            val="$(<"''${SECRETS_DIR}/''${file_name}")"
            if [[ -n "''${val}" ]]; then
              export "''${var_name}=''${val}"
            fi
          fi
          if [[ -z "''${var_name}" ]]; then
            echo "ERROR: Secret ''${var_name} not found" >&2
            exit 1
          fi
        }

        # Load Claude or GLM API key secrets
        load_from_secret CLAUDE_API_KEY z_ai_api_key
        echo -n "''${CLAUDE_API_KEY}"
      '';

      # Optional: adjust shellcheck if needed
      # excludeShellChecks = [ "SC2154" ];
    })
  ] ++ lib.optionals stdenv.isDarwin [
    mas # CLI for the macOS app store
    m-cli # useful macOS CLI commands
  ];
  # ~/Library/LaunchAgents/
  launchd.agents = {
    ollama = {
      enable = true;
      config = {
        # Program = unstable.ollama/bin/ollama;
        EnvironmentVariables = {
            OLLAMA_ORIGINS = "app://obsidian.md*"; # See https://github.com/logancyang/obsidian-copilot/blob/master/local_copilot.md
            OLLAMA_CONTEXT_LENGTH="8192"; # Set default context length, see https://github.com/ollama/ollama/blob/main/docs/faq.md#how-can-i-specify-the-context-window-size
        };
        ProgramArguments = [ "${unstable.ollama}/bin/ollama" "serve" ];
        RunAtLoad = true;
        KeepAlive = true;
        # Get logs with:
        # sudo launchctl debug <service-target> --stdout --stderr
        # Or redirect stdout/stderr at /Users/stefan/Library/Logs/
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ollama.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ollama.err.log";
      };
    };
    "hidutil-key-remapping" = {
        enable = true;
        config = {
          ProgramArguments = [
            "/usr/bin/hidutil"
            "property"
            "--set"
            # Verify: hidutil property --get "UserKeyMapping"
            # https://hidutil-generator.netlify.app/
            # caps_lock -> f19
            "{\"UserKeyMapping\": [
                    {
                        \"HIDKeyboardModifierMappingSrc\":0x700000039,
                        \"HIDKeyboardModifierMappingDst\":0x70000006E
                    }
                ]}"
          ];
          RunAtLoad = true;
          KeepAlive = false;
        };
    };
  };

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
    "raycast/script_commands" = {
      source = ./config/raycast/script_commands;
      recursive = true;
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
        github-username = "geggo98";
      };
    };
    nix.enable = true;
  };

  home.file."Library/Application Support/iTerm2/DynamicProfiles/50_Nix.json" = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
    source = ./config/iTerm2/DynamicProfiles/50_Nix.json;
  };

  home.file.".hammerspoon/nix.lua"  = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
    source = ./config/hammerspoon/nix.lua;
  };
  home.file.".hammerspoon/nix_f19.lua"  = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
    source = ./config/hammerspoon/nix_f19.lua;
  };
  home.file.".hammerspoon/nix_display_monitor.lua"  = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
    source = ./config/hammerspoon/nix_display_monitor.lua;
  };

  home.sessionVariables = {
    # Comma separated list of age recipients.
    # Convert from ssh key with `ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw.pub`
    SOPS_AGE_RECIPIENTS = "age1vygfenpy584kvfdge57ep2vwqqe33zd4auanwu7frmf0tht5jq0q5ugmgd," # FCX19GT9XR
      + "age1ae3vaq0cwzd8y0eatczdz7dz26m3mpxfnelwfxle9mqdachftd7q96fvaz"; # DKL6GDJ7X1
    EDITOR = "${pkgs.neovim}/bin/nvim";
    # Doesn't work, because it contains the `%r` placeholder for the sops secrets directory.
    # OPENAI_API_KEY_FILE = config.sops.secrets."openai_api_key".path;
  };
  # See https://nix-community.github.io/home-manager/options.xhtml#opt-home.activation
  # Uset the `run` helper to support dry run functionality
  home.activation.llm = lib.hm.dag.entryAfter [ "installPackages" ] ''
      # Install or update LLM plugins
      original_path_B541A0A9="$PATH"
      export PATH="$PATH:/opt/homebrew/bin"
      if command -v llm > /dev/null 2>&1
      then
        echo "Installing or updating LLM plugins"
        run  --quiet llm install -U llm-openrouter llm-groq llm-ollama llm-claude-3 llm-gemini llm-cmd
        # Fix for llm-cmd on macOS: Should be fixed: https://github.com/simonw/llm-cmd/issues/11
        # run --quiet llm install https://github.com/nkkko/llm-cmd/archive/b5ff9c2a970720d57ecd3622bd86d2d99591838b.zip
        # See ~/Library/Application\ Support/io.datasette.llm/aliases.json
        run --quiet llm aliases set gemini gemini-2.0-pro-exp-02-05
        run --quiet llm aliases set deepseek openrouter/deepseek/deepseek-r1
        run --quiet llm aliases set auto openrouter/openrouter/auto
        run llm models default gpt-5-mini
      fi
      export PATH="$original_path_B541A0A9"
      unset original_path_B541A0A9
    '';
  home.activation.orbstack = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if test -e ~/.orbstack/run/docker.sock -a ! -e /var/run/docker.sock
      then
        echo "Updating Docker socket"
        run sudo ln -s ~/.orbstack/run/docker.sock /var/run/docker.sock
      fi
      if test -e /var/run/docker.sock
      then
        echo "The Docker socket at /var/run/docker.sock is up to date"
        ls -l /var/run/docker.sock
      else
        echo "The Docker socket at /var/run/docker.sock is missing"
      fi
    '';
    home.activation.hammerspoon = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if test -e ~/.hammerspoon/init.lua
        then
            if ! grep 'require("nix")' ~/.hammerspoon/init.lua > /dev/null
            then
                echo 'Add nix to Hammerspoon config\n'
                echo "" >> ~/.hammerspoon/init.lua
                echo "-- Load Nix home manager provided packages" >> ~/.hammerspoon/init.lua
                echo "require(\"nix\")" >> ~/.hammerspoon/init.lua
                echo "" >> ~/.hammerspoon/init.lua
            fi
        fi
    '';
}
