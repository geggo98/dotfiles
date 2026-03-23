# darwin-rebuild build --flake ~/.config/nix-darwin
# sudo darwin-rebuild switch --flake ~/.config/nix-darwin
# sudo determinate-nixd upgrade
# determinate-nixd version # Shows features, see https://dtr.mn/features
{
  description = "Stefan's darwin system";

  # Update all with: `nix flake update`
  # Update single input with `nix flake lock --update-input <input-name>`
  inputs = {
    # Package sets
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11"; # https://status.nixos.org/
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Flake structure
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    # Environment/system management
    darwin.url = "github:lnl7/nix-darwin/nix-darwin-25.11";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    # Determinate Nix module for Nix Darwin
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/Mic92/sops-nix
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/nix-community/nix-index-database
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/numtide/llm-agents.nix
    nixpkgs-llm-agents.url = "github:numtide/llm-agents.nix";

    # External dependencies
    nvf = {
      url = "github:NotAShelf/nvf";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    # https://github.com/numtide/llm-agents.nix/blob/main/flake.nix
    extra-substituters = [ "https://numtide.cachix.org" "https://devenv.cachix.org" ];
    extra-trusted-public-keys = [ "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE=" "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ (inputs.import-tree ./modules) ];
    };
}
