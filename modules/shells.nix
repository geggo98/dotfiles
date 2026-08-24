{ inputs, ... }:
{
  # Split out of `shell` so that aspect stays evaluable on hosts without
  # sops-nix. Every line below dereferences `config.sops.secrets.<name>.path`,
  # which is an eval-time error — not a runtime one — if the secret is not
  # declared, so a server that has no business holding these API keys could not
  # import `shell` at all while they lived in it.
  #
  # mkAfter is load-bearing: `export_nix_sops_secret_*` are fish functions
  # defined in _files/shell/promptInit.fish, which `shell` prepends. Plain
  # `types.lines` merging gives no order guarantee between two modules, so
  # without this the exports could be emitted before the functions exist.
  flake.modules.homeManager.shell-secrets = { config, lib, ... }: {
    # NOTE: *_PATH only — this block deliberately exports no secret VALUES.
    #
    # Files are the default source; an environment variable is a manual
    # override. Every consumer in this repo reads its sops-nix file (the
    # `load_from_secret` helper in _files/shell/load-secrets.sh, used by the
    # +agent-* and +mcp-* wrappers), so an ambient copy in the shell bought
    # nothing and cost plenty: a globally exported secret lands in every child
    # process, `env` dump, crash report and agent transcript.
    #
    # It also caused a real outage. ATLASSIAN_API_TOKEN was exported here
    # holding the *Bitbucket* token, and the jira / bitbucket-pr skills checked
    # every env name before any file — so the dead alias outranked the correct
    # jira_api_token file and every Jira call failed, as a 404 that read like a
    # missing ticket. Both the alias tier and the value exports are gone.
    #
    # Adding a secret VALUE here needs a reason that a per-invocation wrapper
    # cannot serve. `llm` and `ollama` are the tools that needed one; they are
    # wrapped in modules/ai-tools.nix instead.
    #
    # ONLY SECRETS EVERY HOST DECLARES belong in this list. `shell-secrets`
    # hangs on both workstations via homeManager.base, and each line below
    # dereferences `config.sops.secrets.<name>.path`, which is an EVAL error —
    # not a runtime one — where the secret is not declared. So a host-specific
    # secret referenced here breaks the *other* host's build. That is why the
    # two ABSENCE_IO_*_PATH lines left with the absence.io credentials when
    # they moved to hosts/DKL6GDJ7X1 on 2026-08-24; nothing read them anyway,
    # and consumers find the file under its plain name in $SOPS_SECRETS_DIR.
    programs.fish.interactiveShellInit = lib.mkAfter ''
      export_nix_sops_secret_path OPENAI_API_KEY_PATH "${config.sops.secrets.openai_api_key.path}"

      export_nix_sops_secret_path OPENROUTER_API_KEY_PATH "${config.sops.secrets.openrouter_api_key.path}"

      export_nix_sops_secret_path GROQ_API_KEY_PATH "${config.sops.secrets.groq_api_key.path}"

      export_nix_sops_secret_path GEMINI_API_KEY_PATH "${config.sops.secrets.gemini_api_key.path}"

      export_nix_sops_secret_path CONTEXT7_API_KEY_PATH "${config.sops.secrets.context7_api_key.path}"

      export_nix_sops_secret_path OLLAMA_API_KEY_PATH "${config.sops.secrets.ollama_api_key.path}"

      export_nix_sops_secret_path TRAVILY_API_KEY_PATH "${config.sops.secrets.travily_api_key.path}"

      export_nix_sops_secret_path Z_AI_API_KEY_PATH "${config.sops.secrets.z_ai_api_key.path}"

      export_nix_sops_secret_path HF_TOKEN_PATH "${config.sops.secrets.huggingface_ro_token.path}"

      export_nix_sops_secret_path SLACK_C24_API_KEY_PATH "${config.sops.secrets.slack_c24_api_key.path}"
    '';
  };

  flake.modules.homeManager.shell = { config, pkgs, lib, ... }: {
    imports = [ inputs.nix-index-database.homeModules.nix-index ];

    home.sessionVariables.SOPS_AGE_SSH_PRIVATE_KEY_FILE =
      "${config.home.homeDirectory}/.ssh/id_ed25519_sops_nopw";

    programs.nix-index-database.comma.enable = true;
    programs.nix-index.enable = true;

    programs.direnv.enable = true;
    programs.direnv.nix-direnv.enable = true;

    programs.z-lua.enable = true;

    programs.zsh = {
      enable = true;
      initContent = ''
        if command -v devenv > /dev/null; then
          eval "$(devenv hook zsh)"
        fi
      '';
    };
    programs.fish = {
      enable = true;
      interactiveShellInit = (builtins.readFile ./_files/shell/promptInit.fish)
        + ''
        # set theme for current session https://fishshell.com/docs/current/cmds/fish_config.html
        fish_config theme choose "Dracula" # --color-theme=dark
      '';
      plugins = [
        { name = "z"; src = pkgs.fishPlugins.z.src; }
        { name = "fzf"; src = pkgs.fishPlugins.fzf-fish.src; }
        { name = "forgit"; src = pkgs.fishPlugins.forgit.src; }
        { name = "bass"; src = pkgs.fishPlugins.bass.src; }
      ];

      functions = {
        "+cd-groot" = {
          body = ''
            set -l toplevel (git rev-parse --show-toplevel 2>/dev/null)
            if test $status -ne 0
              echo "Error: Not inside a git repository"
              return 1
            end
            cd $toplevel
          '';
          description = "Change to the root directory of the current git repository";
        };
        "+git-ignore-generator2" = {
          body = ''
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
            set --local joined_args (string join "," $argv)
            curl -L -s "https://www.toptal.com/developers/gitignore/api/$joined_args"
          '';
          description = "Generate .gitignore files for multiple technologies via gitignore.io API";
        };
        "+wait-and-exec" = {
          body = builtins.readFile ./_files/shell/wait-and-exec.fish;
          description = "Block until stdin has data, then exec the given command (passes stdin through). --timeout N for hard abort, --wait-eof to buffer via sponge.";
        };
        "+darwin-rebuild-switch" = {
          body = ''
            # Select the flake attr by hardware serial (IOPlatformSerialNumber) so a
            # transiently drifted LocalHostName — macOS's "-2" Bonjour suffix on a name
            # collision — can't break attr selection the way a bare `--flake <dir>` does.
            set -l serial (ioreg -c IOPlatformExpertDevice -d 2 | string match -rg 'IOPlatformSerialNumber" = "([^"]+)"')
            if test -z "$serial"
              echo "Error: could not determine hardware serial" >&2
              return 1
            end
            echo "→ sudo darwin-rebuild switch --flake ~/.config/nix-darwin#$serial $argv" >&2
            sudo darwin-rebuild switch --flake "$HOME/.config/nix-darwin#$serial" $argv
          '';
          description = "Apply this host's nix-darwin config, selecting the flake attr by hardware serial (drift-safe against the macOS -2 hostname bump).";
        };
      };
      shellAbbrs = {
        # forgit abbreviations
        "+git-add-interactive" = "git forgit add";
        "+git-checkout-branch" = "git forgit checkout_branch";
        "+git-checkout-commit" = "git forgit checkout_commit";
        "+git-checkout-file" = "git forgit checkout_file";
        "+git-checkout-tag" = "git forgit checkout_tag";
        "+git-commit-fixup" = "git forgit fixup";
        "+git-delete-branch-interactive" = "git forgit branch_delete";
        "+git-diff-interactive" = "git forgit diff";
        "+git-ignore-generator" = "git forgit ignore";
        "+git-log-viewer" = "git forgit log";
        "+git-reset-head" = "git forgit reset_head";
        "+git-revert-commit" = "git forgit revert_commit";
        "+git-stash-push" = "git forgit stash_push";
        "+git-stash-viewer" = "git forgit stash_show";

        "+l" = "lsd";
        "+la" = "lsd -a";
        "+ll" = "lsd -l --git";
        "+lla" = "lsd -la --git";
        "+llt" = "lsd --long --tree --git --ignore-glob .git --ignore-glob node_modules --ignore-glob __pycache__";
        "+lt" = "lsd --tree --ignore-glob .git --ignore-glob node_modules --ignore-glob __pycache__";

        "+rm" = "trash";
        "+lsusb" = "system_profiler SPUSBDataType";
        "+bus-pirate" = ", tio -b 115200 -d 8 -p none -s 1 -f none (find /dev -maxdepth 2 -path '/dev/cu.usbmodem*' -o -path '/dev/serial/by-id/*' 2>/dev/null | fzf --prompt='Select Bus Pirate device > ')";
        "+usb-serial-autoconnect-latest" = ", tio -a latest";
        "+usb-serial-list" = ", tio --list";

        "+pmset-standby-ram" = "sudo pmset-hibernatemode standby-ram";
        "+pmset-hibernate-disk" = "sudo pmset-hibernatemode disk";

        # NB: $HOME, not {$HOME} — fish does not strip braces around a single element,
        # so "{$HOME}/.ssh/x" expands to the literal "{/Users/stefan}/.ssh/x".
        "+ssh-add-yubikey" = "env SSH_AUTH_SOCK=$HOME/.ssh/agent ssh-add $HOME/.ssh/id_ed25519_sk";

        "+grep" = "ug";
        "+grep-tui" = "ug -Q";

        "+agent-codex-sandbox" = "+agent-codex --full-auto";
        "+agent-codex-danger-delete-all-my-files-and-trash-my-computer" = "+agent-codex --dangerously-bypass-approvals-and-sandbox";

        "+tar-zstd" = "tar \"-Izstd -10 -T0\"";
        "+tar-zstd-max" = "tar \"-Izstd -19 -T0\"";

        # No env prefix needed: SOPS_AGE_SSH_PRIVATE_KEY_FILE is already exported from
        # home.sessionVariables at the top of this file. The prefix these used to carry
        # was doubly broken anyway — it passed the literal "{/Users/stefan}/.ssh/..."
        # (see the $HOME note above), so sops fell back to whatever it could find.
        "+sops-edit-keys" = "sops edit -s";
        "+sops-edit-secrets" = "sops edit";
      };
    };

    programs.starship = {
      enable = true;
      enableTransience = true;
    };

    programs.atuin = {
      enable = true;
      settings = {
        dialect = "uk";
        workspaces = true;
        enter_accept = true;
      };
    };

    programs.bat.enable = true;
    programs.fzf.enable = true;
    programs.nnn.enable = true;
  };
}
