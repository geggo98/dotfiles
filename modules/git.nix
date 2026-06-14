{ ... }:
{
  flake.modules.homeManager.git = { lib, pkgs, ... }:
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
          diff."sopsdiffer".textconv = "${pkgs.sops}/bin/sops -d";
          credential = {
            credentialStore = "keychain";
            helper = "${pkgs.git-credential-manager}/bin/git-credential-manager";
          };
          rerere = {
            enabled = true;
            autoUpdate = true;
          };
        };
      };
      programs.difftastic = {
        enable = true;
        git.enable = true;
      };
      programs.gh.enable = true;
      programs.lazygit = {
        enable = true;
        settings = {
          git.pagers = [
            { externalDiffCommand = "${pkgs.difftastic}/bin/difft --color=always"; }
            { pager = "${pkgs.delta}/bin/delta --dark --paging=never"; }
          ];
        };
      };
    };
}
