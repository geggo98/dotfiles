{ inputs, ... }:
{
  flake.modules.homeManager.shell = { config, pkgs, lib, ... }: {
    imports = [ inputs.nix-index-database.homeModules.nix-index ];

    home.sessionVariables.SOPS_AGE_SSH_PRIVATE_KEY_FILE =
      "${config.home.homeDirectory}/.ssh/id_ed25519_sops_nopw";

    programs.nix-index-database.comma.enable = true;
    programs.nix-index.enable = true;

    programs.direnv.enable = true;
    programs.direnv.nix-direnv.enable = true;

    programs.z-lua.enable = true;

    programs.zsh.enable = true;
    programs.fish = {
      enable = true;
      interactiveShellInit = (builtins.readFile ./_files/shell/promptInit.fish)
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
        "+yt-dlp-transcript" = {
          body = ''
            argparse 'q/stdout' -- $argv
            or return $status

            if test (count $argv) -eq 0
              echo "Usage: +yt-dlp-transcript [-q|--stdout] <url> [sub-langs]"
              echo ""
              echo "Download subtitles (VTT) and write a cleaned plain-text"
              echo "transcript into \$TMPDIR/yt-dlp-transcript/<id>.<lang>.{vtt,txt}."
              echo ""
              echo "Uses --ignore-config so the global 'sub-langs = all' setting"
              echo "in ~/.config/yt-dlp/config does not force every language."
              echo ""
              echo "Default sub-langs: '.*-orig' (regex: only original-language auto-caption"
              echo "tracks; translate locally instead of pulling YouTube's dubbed tracks,"
              echo "which quickly triggers HTTP 429 rate limits)."
              echo ""
              echo "Example overrides: +yt-dlp-transcript <url> de,en"
              echo "                   +yt-dlp-transcript <url> 'en.*'"
              echo ""
              echo "-q, --stdout   Pipe mode: transcripts to stdout, info lines"
              echo "               suppressed, errors on stderr only."
              return 1
            end
            set --local url $argv[1]
            set --local langs '.*-orig'
            if test (count $argv) -ge 2
              set langs $argv[2]
            end
            set --local tmproot /tmp
            if test -n "$TMPDIR"
              set tmproot $TMPDIR
            end
            set --local outdir $tmproot/yt-dlp-transcript
            mkdir -p $outdir

            set --local marker (mktemp)

            set --local quiet_args
            if set --query _flag_stdout
              set quiet_args --quiet --no-warnings --no-progress
            end

            yt-dlp --ignore-config \
              --no-playlist \
              --skip-download \
              --write-subs \
              --write-auto-subs \
              --sub-langs "$langs" \
              --sub-format "vtt/best" \
              --convert-subs vtt \
              --sleep-subtitles 2 \
              $quiet_args \
              --output "$outdir/%(id)s.%(ext)s" \
              $url
            or begin
              set --local rc $status
              rm -f $marker
              return $rc
            end

            for vtt in $outdir/*.vtt
              set --local txt (string replace -r '\.vtt$' '.txt' $vtt)
              if not test -e $txt; or test $vtt -nt $txt
                sed -E \
                  -e '/^WEBVTT/d' \
                  -e '/^Kind:/d' \
                  -e '/^Language:/d' \
                  -e '/^NOTE/d' \
                  -e '/^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} --> /d' \
                  -e 's/<[^>]+>//g' \
                  -e '/^[[:space:]]*$/d' \
                  $vtt | awk '!seen[$0]++' > $txt
                if not set --query _flag_stdout
                  echo "VTT:        $vtt"
                  echo "Transkript: $txt"
                end
              end
              if set --query _flag_stdout; and test $vtt -nt $marker
                cat $txt
              end
            end

            rm -f $marker
          '';
          description = "Download subtitles (VTT) and write a cleaned transcript .txt into $TMPDIR/yt-dlp-transcript (ignores global yt-dlp config; -q/--stdout for pipe use)";
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

        "+pmset-standby-ram" = "sudo pmset -a hibernatemode 3";
        "+pmset-hibernate-disk" = "sudo pmset -a hibernatemode 25";

        "+ssh-add-yubikey" = "env SSH_AUTH_SOCK={$HOME}.ssh/agent ssh-add {$HOME}/.ssh/id_es255519_sk";

        "+yt-dlp" = "yt-dlp -i --format 'bestvideo[ext=mp4]+bestaudio/best[ext=m4a]/best' --merge-output-format mp4 --no-post-overwrites --output ~/Downloads/yt-dlp/'%(title)s.%(ext)s'";
        "+yt-dlp-info" = ''yt-dlp --ignore-config --skip-download --no-playlist --print "Title:       %(title)s" --print "Uploader:    %(uploader)s" --print "Upload Date: %(upload_date)s" --print "Duration:    %(duration_string)s" --print "Views:       %(view_count)s" --print "URL:         %(webpage_url)s" --print "" --print "%(description)s"'';

        "+darwin-rebuild-switch" = "sudo darwin-rebuild switch --flake ~/.config/nix-darwin";

        "+grep" = "ug";
        "+grep-tui" = "ug -Q";

        "+agent-codex-sandbox" = "+agent-codex --full-auto";
        "+agent-codex-danger-delete-all-my-files-and-trash-my-computer" = "+agent-codex --dangerously-bypass-approvals-and-sandbox";

        "+tar-zstd" = "tar \"-Izstd -10 -T0\"";
        "+tar-zstd-max" = "tar \"-Izstd -19 -T0\"";

        "+sops-edit-keys" = "env SOPS_AGE_SSH_PRIVATE_KEY_FILE={$HOME}/.ssh/id_ed25519_sops_nopw sops edit -s";
        "+sops-edit-secrets" = "env SOPS_AGE_SSH_PRIVATE_KEY_FILE={$HOME}/.ssh/id_ed25519_sops_nopw sops edit";
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
