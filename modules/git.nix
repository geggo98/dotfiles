{ ... }:
{
  flake.modules.homeManager.git = { lib, pkgs, ... }:
    let
      # Chain to repo-local hook if it exists (needed because core.hooksPath overrides .git/hooks/)
      chainLocalHook = name: ''
        REPO_HOOK="$(${pkgs.git}/bin/git rev-parse --git-dir 2>/dev/null)/hooks/${name}"
        if [ -x "$REPO_HOOK" ]; then
          "$REPO_HOOK" "$@" || exit $?
        fi
      '';

      configFlag = key: ''[ "$(${pkgs.git}/bin/git config --bool --get ${key} 2>/dev/null)" = "true" ]'';

      # Per-repo opt-out for the hooks below. Set a flag with:
      #   git config --local hooks.skipPreCommit true        # disable pre-commit entirely (also skips chained local hook)
      #   git config --local hooks.skipGitleaksCommit true   # disable only the gitleaks scan; local hook still runs
      #   git config --local hooks.skipPrePush true          # disable pre-push entirely (also skips chained local hook)
      #   git config --local hooks.skipGitleaksPush true     # disable only the gitleaks scan; local hook still runs
      # Re-enable by unsetting: git config --local --unset hooks.<flag>
      gitleaksPreCommit = pkgs.writeShellScript "pre-commit" ''
        if ${configFlag "hooks.skipPreCommit"}; then
          echo "pre-commit: skipped (hooks.skipPreCommit=true)"
          exit 0
        fi
        ${chainLocalHook "pre-commit"}
        if ${configFlag "hooks.skipGitleaksCommit"}; then
          echo "pre-commit: gitleaks skipped (hooks.skipGitleaksCommit=true)"
          exit 0
        fi
        ${pkgs.gitleaks}/bin/gitleaks protect --staged --verbose --redact
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
          echo ""
          echo "ERROR: gitleaks detected secrets in staged changes."
          echo "To bypass (false positive): git commit --no-verify"
          echo "To disable permanently for this repo: git config --local hooks.skipGitleaksCommit true"
          exit $exit_code
        fi
      '';

      gitleaksPrePush = pkgs.writeShellScript "pre-push" ''
        if ${configFlag "hooks.skipPrePush"}; then
          echo "pre-push: skipped (hooks.skipPrePush=true)"
          exit 0
        fi
        ${chainLocalHook "pre-push"}
        if ${configFlag "hooks.skipGitleaksPush"}; then
          echo "pre-push: gitleaks skipped (hooks.skipGitleaksPush=true)"
          exit 0
        fi
        while read -r local_ref local_sha remote_ref remote_sha; do
          if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
            continue
          fi
          if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
            ${pkgs.gitleaks}/bin/gitleaks detect --verbose --redact --log-opts="$local_sha"
          else
            ${pkgs.gitleaks}/bin/gitleaks detect --verbose --redact --log-opts="$remote_sha..$local_sha"
          fi
          exit_code=$?
          if [ $exit_code -ne 0 ]; then
            echo ""
            echo "ERROR: gitleaks detected secrets in commits being pushed."
            echo "To bypass (false positive): git push --no-verify"
            echo "To disable permanently for this repo: git config --local hooks.skipGitleaksPush true"
            exit $exit_code
          fi
        done
      '';
    in
    {
      programs.git = {
        enable = true;
        lfs.enable = true;
        hooks = {
          pre-commit = gitleaksPreCommit;
          pre-push = gitleaksPrePush;
        };
        settings = {
          init.defaultBranch = "main";
          core.autocrlf = "input";
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
