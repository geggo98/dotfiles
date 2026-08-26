{ config, inputs, lib, ... }:
{
  flake.overlays = {
    # `prev ? stdenv` guards against flake-schemas calling the overlay
    # with empty args (`overlay {} {}`) to verify it returns an attrset —
    # without the guard, `nix flake check` errors on `attribute 'stdenv'
    # missing` before reaching any real build.
    apple-silicon = final: prev: lib.optionalAttrs (prev ? stdenv && prev.stdenv.hostPlatform.system == "aarch64-darwin") {
      pkgs-x86 = import inputs.nixpkgs {
        system = "x86_64-darwin";
        config = { allowUnfree = true; };
      };
    };

    # VS Code extensions from the Open VSX and VS Code Marketplace registries,
    # regenerated daily upstream. Consumed by modules/vscode.nix.
    #
    # The overlay form rather than reading inputs.nix-vscode-extensions directly:
    # it applies THIS repo's nixpkgs fixes to the generated set (upstream README),
    # and home-manager-darwin.nix sets useGlobalPkgs = true, so it is visible in
    # the home-manager modules without a second nixpkgs.overlays assignment.
    #
    # Cooldown note: this input carries no version numbers of its own — it pins
    # whatever was newest on the day its revision was generated. A revision that is
    # N days old therefore pins extension versions that are at least N days old,
    # which is why scripts/supply-chain.toml gives it the 14-day extension bar
    # rather than the 5-day input default.
    nix-vscode-extensions = inputs.nix-vscode-extensions.overlays.default;

    fix-gcm = final: prev: {
      git-credential-manager = prev.symlinkJoin {
        name = "git-credential-manager-wrapped";
        paths = [ prev.git-credential-manager ];
        nativeBuildInputs = [ prev.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/git-credential-manager \
            --set DOTNET_SYSTEM_GLOBALIZATION_INVARIANT 1
        '';
      };
    };
  };

  flake.modules.darwin.overlays = {
    nixpkgs.overlays = lib.attrValues config.flake.overlays;
  };
}
