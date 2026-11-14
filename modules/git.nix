{ ... }:
{
  flake.modules.homeManager.git = { lib, pkgs, ... }:
    let
      difft = lib.getExe pkgs.difftastic;
      sopsDecrypt = "${pkgs.sops}/bin/sops -d";
      # difftastic and SOPS decryption are for people only. Neither is in the
      # global git config, so agents, scripts and `git diff | grep` get the plain
      # unified diff of the encrypted file. Measured 2026-11-14: git applies
      # textconv only to its internal diff, never together with diff.external,
      # so difftastic shows the encrypted text and `dsops` shows the decrypted one.
      difftOpts = "-c diff.external=${difft}";
    in
    {
      programs.git = {
        enable = true;
        lfs.enable = true;
        ignores = [
          # Worktrees, dev shells, macOS, pre-commit
          "/.worktrees/"
          "/.devenv/"
          "/.direnv/"
          "/.devbox/"
          ".DS_Store"
          "/.pre-commit-config.yaml"

          # Nix build symlinks
          "/result"
          "/result-*"

          # Clojure / Leiningen / clj / clojure-lsp / clj-kondo / Calva / shadow-cljs
          ".calva/"
          ".cpcache/"
          ".nrepl-port"
          ".lsp/.cache/"
          ".clj-kondo/.cache/"
          ".shadow-cljs/"
          ".lein-deps-sum"
          ".lein-repl-history"
          ".lein-plugins/"
          ".lein-failures"

          # Scala / Metals / Bloop / BSP / scala-cli
          ".metals/"
          ".bloop/"
          ".bsp/"
          ".scala-build/"

          # JVM crash logs
          "hs_err_pid*"
          "replay_pid*.log"

          # Node / JS / TS
          "node_modules/"
          "jspm_packages/"
          "*.tsbuildinfo"
        ];
        settings = {
          init.defaultBranch = "main";
          core.autocrlf = "input";
          push.default = "current";
          user = {
            name = "stefan.schwetschke";
            email = lib.mkDefault "stefan@schwetschke.de";
          };
          alias = {
            dft = "${difftOpts} diff";
            dshow = "${difftOpts} show --ext-diff";
            dlog = "${difftOpts} log -p --ext-diff";
            # Decrypted diff of SOPS files (git textconv, internal diff only).
            dsops = "-c 'diff.sopsdiffer.textconv=${sopsDecrypt}' diff";
          };
          credential = {
            credentialStore = "keychain";
            helper = "${pkgs.git-credential-manager}/bin/git-credential-manager";
          };
          rerere = {
            enabled = true;
            autoUpdate = true;
          };
          # Bitbucket Cloud nimmt SSH ab 12.11.2026 nur noch an ssh.bitbucket.org an.
          # Fängt .gitmodules, den Clone-Dialog mit der alten Adresse und Tools mit Git-Deps ab.
          url."git@ssh.bitbucket.org:".insteadOf = [
            "git@bitbucket.org:"
            "ssh://git@bitbucket.org/"
          ];
        };
      };
      programs.difftastic.enable = true;

      # Interactive fish only: functions do not exist in zsh, bash or child
      # processes. difftastic runs only when stdout is a terminal, so
      # `git diff | grep` still sees the unified diff.
      programs.fish.functions.git = {
        wraps = "git";
        description = "git, with difftastic for diff, show and log on a terminal";
        body = ''
          if not isatty stdout
            command git $argv
            return
          end
          # Find the subcommand: skip global options such as -C <dir> and -c <k=v>.
          set -l n (count $argv)
          set -l i 1
          while test $i -le $n
            switch $argv[$i]
              case -C -c --git-dir --work-tree --namespace --exec-path --super-prefix --config-env
                set i (math $i + 2)
              case '-*'
                set i (math $i + 1)
              case '*'
                break
            end
          end
          if test $i -gt $n
            command git $argv
            return
          end
          switch $argv[$i]
            case diff show log
              set -l pre
              test $i -gt 1; and set pre $argv[1..(math $i - 1)]
              set -l rest
              test $i -lt $n; and set rest $argv[(math $i + 1)..-1]
              command git $pre ${difftOpts} $argv[$i] --ext-diff $rest
            case '*'
              command git $argv
          end
        '';
      };
      programs.gh.enable = true;
      programs.lazygit = {
        enable = true;
        # lazygit is interactive, so it decrypts SOPS diffs for its delta pager.
        # The textconv comes in through the environment, not the git config, and
        # only when no GIT_CONFIG_COUNT is set. Processes that lazygit starts
        # inherit it.
        package = pkgs.symlinkJoin {
          name = "lazygit-sops-textconv";
          paths = [ pkgs.lazygit ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/lazygit --run '
              if [ -z "''${GIT_CONFIG_COUNT-}" ]; then
                export GIT_CONFIG_COUNT=1
                export GIT_CONFIG_KEY_0=diff.sopsdiffer.textconv
                export GIT_CONFIG_VALUE_0="${sopsDecrypt}"
              fi'
          '';
        };
        settings = {
          git.pagers = [
            { externalDiffCommand = "${pkgs.difftastic}/bin/difft --color=always"; }
            { pager = "${pkgs.delta}/bin/delta --dark --paging=never"; }
          ];
        };
      };
    };
}
