{ ... }:
{
  flake.modules.homeManager.misc = { config, pkgs, lib, ... }: {
    # Key remapping: caps_lock → f19
    launchd.agents."hidutil-key-remapping" = {
      enable = true;
      config = {
        ProgramArguments = [
          "/usr/bin/hidutil"
          "property"
          "--set"
          "{\"UserKeyMapping\": [
                    {
                        \"HIDKeyboardModifierMappingSrc\":0x700000039,
                        \"HIDKeyboardModifierMappingDst\":0x70000006E
                    }
                ]}"
        ];
        RunAtLoad = true;
        KeepAlive = false;
      };
    };

    # Hammerspoon
    home.file.".hammerspoon/nix.lua" = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
      source = ./_files/darwin/hammerspoon/nix.lua;
    };
    home.file.".hammerspoon/nix_f19.lua" = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
      source = ./_files/darwin/hammerspoon/nix_f19.lua;
    };
    home.file.".hammerspoon/nix_display_monitor.lua" = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
      source = ./_files/darwin/hammerspoon/nix_display_monitor.lua;
    };

    # iTerm2 Dynamic Profiles
    home.file."Library/Application Support/iTerm2/DynamicProfiles/50_Nix.json" = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin" || pkgs.stdenv.hostPlatform.system == "x86_64-darwin") {
      source = ./_files/darwin/iTerm2/DynamicProfiles/50_Nix.json;
    };

    # XDG config files
    xdg.configFile = {
      "starship.toml" = {
        source = ./_files/darwin/starship-preset-bracketed-segments.toml;
      };
      "raycast/script_commands" = {
        source = ./_files/darwin/raycast/script_commands;
        recursive = true;
      };
      "topgrade.toml" = {
        source = ./_files/tools/topgrade.toml;
      };
    };

    # Session variables
    home.sessionVariables = {
      SOPS_AGE_RECIPIENTS = "age1vygfenpy584kvfdge57ep2vwqqe33zd4auanwu7frmf0tht5jq0q5ugmgd,"
        + "age1ae3vaq0cwzd8y0eatczdz7dz26m3mpxfnelwfxle9mqdachftd7q96fvaz";
      EDITOR = "${pkgs.neovim}/bin/nvim";
      VISUAL = "${pkgs.neovim}/bin/nvim";
    };

    # Haskell Stack config
    home.file.".stack/config.yaml".text = lib.generators.toYAML { } {
      templates = {
        scm-init = "git";
        params = {
          author-name = "Stefan Schwetschke";
          author-email = "stefan@schwetschke.de";
          github-username = "geggo98";
        };
      };
      nix.enable = true;
    };

    # OrbStack Docker socket activation
    home.activation.orbstack = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if test -e ~/.orbstack/run/docker.sock -a ! -e /var/run/docker.sock
      then
        echo "Updating Docker socket"
        run sudo ln -s ~/.orbstack/run/docker.sock /var/run/docker.sock
      fi
      if test -e /var/run/docker.sock
      then
        echo "The Docker socket at /var/run/docker.sock is up to date"
        ls -l /var/run/docker.sock
      else
        echo "The Docker socket at /var/run/docker.sock is missing"
      fi
    '';

    # Hammerspoon init.lua injection
    home.activation.hammerspoon = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if test -e ~/.hammerspoon/init.lua
      then
          if ! grep 'require("nix")' ~/.hammerspoon/init.lua > /dev/null
          then
              echo 'Add nix to Hammerspoon config\n'
              echo "" >> ~/.hammerspoon/init.lua
              echo "-- Load Nix home manager provided packages" >> ~/.hammerspoon/init.lua
              echo "require(\"nix\")" >> ~/.hammerspoon/init.lua
              echo "" >> ~/.hammerspoon/init.lua
          fi
      fi
    '';
  };
}
