# darwin-rebuild switch --flake ~/.config/nix-darwin
# git add . && nix --extra-experimental-features "nix-command flakes"  run nix-darwin -- switch --flake ~/.config/nix-darwin
{
  description = "Stefan's darwin system";

  inputs = {
    # Package sets
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-24.05-darwin"; # https://status.nixos.org/
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Environment/system management
    darwin.url = "github:lnl7/nix-darwin/master";
    darwin.inputs.nixpkgs.follows = "nixpkgs-unstable";
    
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs-unstable";
    
    # https://github.com/Mic92/sops-nix
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs-unstable";
    
    # https://github.com/nix-community/nix-index-database
    nix-index-database.url = "github:Mic92/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    # External dependencies
    astronvim = { url = "github:AstroNvim/AstroNvim/v3.40.1"; flake = false; };
  };

  outputs = { self, darwin, nixpkgs, nixpkgs-unstable, home-manager, sops-nix, nix-index-database, ... }@inputs:
  let 
    inherit (darwin.lib) darwinSystem;
    inherit (inputs.nixpkgs-unstable.lib) attrValues makeOverridable optionalAttrs singleton;

    # Configuration for `nixpkgs`
    nixpkgsConfig = {
      config = { allowUnfree = true; };
    }; 
  in
  {
    # My `nix-darwin` configs
      
    darwinConfigurations = {
      FCX19GT9XR = darwinSystem {
        system = "aarch64-darwin";
        modules = [ 
          # Main `nix-darwin` config
          ./configuration.nix
          ./darwin.nix
          # Host specific packages
          ./hosts/FCX19GT9XR/configuration.nix
          ./hosts/FCX19GT9XR/homebrew.nix
          # `home-manager` module
          home-manager.darwinModules.home-manager
          
          # WARNING:
          # Don't import the sops home-manager module here,
          # it's a NixOS specific plugin and tries to use SystemD.
          # You will get an error message like this:
          # `error: The option `systemd' does not exist. Definition values: ...`
          # So don't do this: `sops-nix.homeManagerModules.sops`
          # Instead, import it in the `home.nix` file.

          {
            nixpkgs = nixpkgsConfig;
            # `home-manager` config
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.stefan = import ./home.nix;
            home-manager.extraSpecialArgs = inputs;            
          }
        ];
      };
      DKL6GDJ7X1 = darwinSystem {
        system = "aarch64-darwin";
        modules = [ 
          # Main `nix-darwin` config
          ./configuration.nix
          ./darwin.nix
          # Host specific packages
          ./hosts/DKL6GDJ7X1/configuration.nix
          ./hosts/DKL6GDJ7X1/homebrew.nix
          # `home-manager` module
          home-manager.darwinModules.home-manager
          
          # WARNING:
          # Don't import the sops home-maanger module here,
          # it's a NixOS specific plugin and tries to use SystemD.
          # You will get an error message like this:
          # `error: The option `systemd' does not exist. Definition values: ...`
          # So don't do this: `sops-nix.homeManagerModules.sops`
          # Instead, import it in the `home.nix` file.

          {
            nixpkgs = nixpkgsConfig;
            # `home-manager` config
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users."stefan.schwetschke" = import ./home.nix;
            home-manager.extraSpecialArgs = inputs;            
          }
        ];
      };

    };

    # Overlays --------------------------------------------------------------- {{{

    overlays = {
      # Overlay useful on Macs with Apple Silicon
        apple-silicon = final: prev: optionalAttrs (prev.stdenv.system == "aarch64-darwin") {
          # Add access to x86 packages system is running Apple Silicon
          pkgs-x86 = import inputs.nixpkgs-unstable {
            system = "x86_64-darwin";
            inherit (nixpkgsConfig) config;
          };
        }; 
      };
 };
}
