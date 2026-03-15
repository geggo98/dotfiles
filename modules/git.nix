{ ... }:
{
  flake.modules.homeManager.git = { pkgs, ... }: {
    programs.git = {
      enable = true;
      lfs.enable = true;
      settings = {
        user = {
          name = "stefan.schwetschke";
          email = "stefan@schwetschke.de";
        };
        diff."sopsdiffer".textconv = "${pkgs.sops}/bin/sops -d";
        credential = {
          credentialStore = "keychain";
          helper = "${pkgs.git-credential-manager}/bin/git-credential-manager";
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
