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

      gitleaksPreCommit = pkgs.writeShellScript "pre-commit" ''
        ${chainLocalHook "pre-commit"}
        ${pkgs.gitleaks}/bin/gitleaks protect --staged --verbose --redact
        exit_code=$?
        if [ $exit_code -ne 0 ]; then
          echo ""
          echo "ERROR: gitleaks detected secrets in staged changes."
          echo "To bypass (false positive): git commit --no-verify"
          exit $exit_code
        fi
      '';

      gitleaksPrePush = pkgs.writeShellScript "pre-push" ''
        ${chainLocalHook "pre-push"}
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
