{ inputs, config, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
in
{
  flake.modules.homeManager.worktrunk = { config, pkgs, lib, ... }:
    let
      enabled = name: config.my.ai.agents.enable && config.my.ai.agents.${name}.enable;
      system = pkgs.stdenv.hostPlatform.system;
      wtPackage = inputs.worktrunk.packages.${system}.default;
      # Same devenv as modules/packages.nix. The first `devenv` on an agent's PATH can be
      # the flake-compat wrapper of a devenv shell, which has no `allow` subcommand.
      devenvPackage = inputs.devenv.packages.${system}.devenv;

      # `+wt-inherit-trust PRIMARY WORKTREE`: see the docstring of the script. Wrapped so the
      # pinned direnv and devenv come first on PATH, whatever PATH the caller has.
      wt-inherit-trust = pkgs.runCommand "wt-inherit-trust" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p $out/bin $out/libexec
        { echo '#!${pkgs.python3}/bin/python3'; cat ${./_files/worktrunk/wt-inherit-trust.py}; } > $out/libexec/wt-inherit-trust.py
        chmod +x $out/libexec/wt-inherit-trust.py
        makeWrapper $out/libexec/wt-inherit-trust.py "$out/bin/+wt-inherit-trust" \
          --prefix PATH : ${lib.makeBinPath [ pkgs.direnv devenvPackage ]}
      '';

      # IntelliJ creates worktrees itself (`git worktree add`), so no `wt switch` runs and no
      # worktrunk hook fires. IntelliJ's "Run setup script" (New Worktree dialog, "Copy local
      # project setup") calls this script with the new worktree as argument, and it runs the
      # hooks that `wt switch --create` would have run.
      #
      # Laut JetBrains-Doku (IDEA 2026.3, nicht selbst gemessen): das Skript laeuft im Worktree-
      # Verzeichnis, bekommt den Worktree-Pfad als Argument, IntelliJ wartet maximal 5 Minuten
      # und zeigt bei Fehler eine Notification; von Ausgabe steht dort nichts. Deshalb das Logfile.
      # Nicht dokumentiert: PATH und Argumentposition. Daher PATH selbst setzen und `$1` nutzen.
      wt-intellij-setup = pkgs.writeShellApplication {
        name = "+wt-intellij-setup";
        runtimeInputs = [ wtPackage devenvPackage pkgs.direnv pkgs.git pkgs.coreutils ];
        text = ''
          # usage: +wt-intellij-setup WORKTREE-PATH
          arg=''${1-}

          # IntelliJ started from the Dock has only the launchd PATH. Project hooks need nix,
          # the home-manager profile and homebrew. The pinned tools above stay in front.
          export PATH="$PATH:/etc/profiles/per-user/''${USER:-$(id -un)}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin"

          # Open the log before anything can fail, so a wrong argument leaves a trace too.
          log_dir="$HOME/Library/Logs/wt-intellij-setup"
          mkdir -p "$log_dir"
          log="$log_dir/$(date +%Y%m%dT%H%M%S)-$(basename "''${arg:-no-argument}").log"
          echo "wt-intellij-setup: log $log" >&2
          exec >>"$log" 2>&1

          echo "start $(date '+%F %T') argument=$arg cwd=$PWD"
          if [ -z "$arg" ]; then
            echo "usage: +wt-intellij-setup WORKTREE-PATH"
            exit 2
          fi
          worktree=$(git -C "$arg" rev-parse --show-toplevel)
          echo "worktree=$worktree"
          cd -- "$worktree"

          # Blocking: user and project initialisation. A failure here aborts, as in `wt switch`.
          status=0
          wt hook pre-start || status=$?
          if [ "$status" -ne 0 ]; then
            echo "pre-start failed with exit $status; post-start and post-switch skipped."
            echo "If wt asked for approval: run 'wt config approvals add' once in this repository."
            exit "$status"
          fi

          # Worktrunk starts these in the background and returns. Their logs: `wt config state logs`.
          wt hook post-start
          wt hook post-switch
          echo "done $(date '+%F %T')"
        '';
      };
    in
    {
      imports = [ aiOptions inputs.worktrunk.homeModules.default ];

      programs.worktrunk = {
        enable = true;
        package = wtPackage;
        enableFishIntegration = true;
        enableZshIntegration = true;
        enableBashIntegration = true;
      };

      xdg.configFile."worktrunk/config.toml".source =
        (pkgs.formats.toml { }).generate "worktrunk-config.toml" {
          worktree-path = ".worktrees/{{ branch | sanitize }}";
          commit = lib.optionalAttrs (enabled "claude") {
            generation.command =
              "CLAUDECODE= MAX_THINKING_TOKENS=0 ${config.home.profileDirectory}/bin/+agent-claude"
              + " -p --no-session-persistence --model=haiku --tools=''"
              + " --disable-slash-commands --setting-sources='' --system-prompt=''";
          };
          # Den von git-hooks.nix erzeugten .pre-commit-config.yaml-Symlink (gitignored,
          # zeigt auf einen store-stabilen /nix/store/...-Pfad) in jeden neuen Worktree
          # spiegeln. Ohne das scheitert der erste `git commit` im Worktree mit
          # "config file not found: .pre-commit-config.yaml". `cp -P` kopiert den Symlink
          # selbst (nicht dereferenziert); `|| true` macht den Hook zum No-op fuer Repos
          # ohne git-hooks-Symlink, sodass er nie blockiert.
          #
          # Bewusst pre-start (blockierend), NICHT post-start (Hintergrund): nur so ist
          # der Symlink garantiert da, bevor `wt switch` zurueckkehrt und bevor der erste
          # Commit laeuft. Post-start liefe asynchron und ein sofortiger Commit (so wie
          # ihn die Fix-Agenten machen) gewaenne das Rennen gegen das Kopieren.
          #
          # copy-ignored und die Freigabe von direnv/devenv liegen ebenfalls in pre-start
          # (Pipeline, jeder Schritt wartet auf den vorigen). Grund: User- und Projekt-
          # post-start-Hooks laufen laut worktrunk-Doku gleichzeitig. Stuende die Freigabe in
          # post-start, koennte ein Projekt-post-start (z.B. `devenv shell -- ...`) vor ihr
          # starten. copy-ignored klont per APFS und kostet ~0 s (worktrunk step.md).
          # Der Build selbst bleibt im Projekt-post-start; dieses Rennen ist gewollt.
          #
          # Ein pre-start-Fehler bricht das Anlegen ab und ueberspringt die Projekt-Hooks.
          # Deshalb endet jeder Schritt mit exit 0 und meldet Fehler auf stderr. Die Freigabe
          # erledigt +wt-inherit-trust: direnv nur bei inhaltsgleicher, im Primaer-Worktree
          # freigegebener .envrc, devenv nur bei freigegebenem Primaer-Worktree. Ein blindes
          # `allow` fuehrte Code aus einem fremden Branch (z.B. PR) ohne Rueckfrage aus, denn
          # .envrc und devenv.nix sind getrackt. User-Hooks brauchen keine Approval, anders
          # als die Projekt-Hooks aus .config/wt.toml.
          pre-start = [
            { precommit = "cp -P {{ primary_worktree_path }}/.pre-commit-config.yaml {{ worktree_path }}/.pre-commit-config.yaml 2>/dev/null || true"; }
            { copy = "wt step copy-ignored || echo \"copy-ignored failed (exit $?)\" >&2"; }
            { trust = "${wt-inherit-trust}/bin/+wt-inherit-trust \"{{ primary_worktree_path }}\" \"{{ worktree_path }}\""; }
          ];
        };

      home.packages = [ wt-inherit-trust wt-intellij-setup ];

      # ── Worktrunk plugins for the agent CLIs (all from the worktrunk flake input) ──
      # Merges with the programs.{claude-code,codex,opencode} blocks in
      # modules/agents.nix (home-manager combines definitions across modules).
      # Every artifact is sourced from the whole-repo worktrunk store path.

      # Claude Code: full plugin — config skill, activity markers (🤖/💬 in
      # `wt list`), worktree-isolation hooks (routes Claude's isolation:"worktree"
      # through `wt switch --create`), and the /wt-switch-create skill. Loaded via
      # the claude-code module's --plugin-dir mechanism.
      # NB: reference the flake-input subpath, not a repackaged subdir — the
      # plugin's ./skills is a symlink to ../../skills that only resolves inside the
      # whole-repo store path.
      programs.claude-code.plugins = lib.mkIf (enabled "claude") [ "${inputs.worktrunk}/plugins/worktrunk" ];

      # Codex: only the config skill is meaningful (Codex exposes no activity/
      # isolation hooks). Feed the skill dir directly, bypassing the interactive
      # `/plugins` marketplace step. Symlinks ~/.codex/skills/worktrunk -> store dir.
      programs.codex.skills.worktrunk = lib.mkIf (enabled "codex") "${inputs.worktrunk}/skills/worktrunk";

      # OpenCode: activity-tracking plugin (single .ts). Identical to the file
      # `wt config plugins opencode install` writes, but store-pinned & declarative.
      xdg.configFile."opencode/plugins/worktrunk.ts" = lib.mkIf (enabled "opencode") {
        source = "${inputs.worktrunk}/dev/opencode-plugin.ts";
      };
    };

  # Same python3 as the shipped helper. The tests use fake direnv/devenv programs, so the
  # real tools are not needed in the sandbox.
  perSystem = { pkgs, ... }: {
    checks.wt-inherit-trust = pkgs.runCommand "wt-inherit-trust-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      export PYTHONDONTWRITEBYTECODE=1
      cp ${./_files/worktrunk/wt-inherit-trust.py} wt-inherit-trust.py
      cp ${./_files/worktrunk/test_wt_inherit_trust.py} test_wt_inherit_trust.py
      python3 test_wt_inherit_trust.py
      touch $out
    '';
  };
}
