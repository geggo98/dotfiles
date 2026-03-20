{ ... }:
{
  flake.modules.homeManager.git = { lib, pkgs, ... }: {
    programs.git = {
      enable = true;
      lfs.enable = true;
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
    programs.lazygit.enable = true;
  };
}
