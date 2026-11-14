{ ... }:
let
  # Release pins. The sha256 values are the GitHub asset digests, re-computed
  # locally with `shasum -a 256` on the downloaded files.
  releases = {
    home-weather-station = {
      owner = "geggo98";
      repo = "stream-deck-home-weather-station";
      tag = "v0.1.4";
      uuid = "de.schwetschke.sd.home-weather-station";
      sha256 = "e75a5f1da55fe536623896fbf0132e01b0a04a25aaceb70315ea1e4461f00dce";
    };
    eiscp-avr-remote = {
      owner = "geggo98";
      repo = "stream-deck-eiscp-avr-remote-plugin";
      tag = "v1.4.0";
      uuid = "de.schwetschke.sd.eiscp-avr-remote";
      sha256 = "e19d8de3651e7d3a6acdbe6917dbfedb91d860e1f6e5aebd9976a0a9e5144c42";
    };
  };
in
{
  flake.modules.homeManager.stream-deck = { config, lib, pkgs, ... }:
    let
      cfg = config.my.streamDeck;

      # The release asset is a zip holding exactly one `<uuid>.sdPlugin/` directory,
      # already bundled by rollup (no node_modules). Unpack it and fail the build
      # if the directory name or the manifest UUID disagree with the pin.
      mkReleasePlugin = { owner, repo, tag, uuid, sha256 }:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "stream-deck-plugin-${uuid}";
          version = tag;
          src = pkgs.fetchurl {
            url = "https://github.com/${owner}/${repo}/releases/download/${tag}/${uuid}.streamDeckPlugin";
            inherit sha256;
            name = "${uuid}-${tag}.zip";
          };
          nativeBuildInputs = [ pkgs.unzip ];
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            unzip -q "$src" -d unpacked
            [ -d "unpacked/${uuid}.sdPlugin" ] || { echo >&2 "archive lacks ${uuid}.sdPlugin/"; exit 1; }
            [ "$(ls -A unpacked | wc -l)" = 1 ] || { echo >&2 "archive holds more than ${uuid}.sdPlugin/"; exit 1; }
            grep -q '"UUID": "${uuid}"' "unpacked/${uuid}.sdPlugin/manifest.json" \
              || { echo >&2 "manifest UUID differs from ${uuid}"; exit 1; }
            cp -r "unpacked/${uuid}.sdPlugin" "$out"
            runHook postInstall
          '';
          passthru = { inherit uuid; };
        };

      pluginsDir = "$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins";
      stateFile = "${config.xdg.stateHome}/stream-deck/managed-plugins";
      rsync = "${pkgs.rsync}/bin/rsync";
    in
    {
      options.my.streamDeck.enable = lib.mkEnableOption "the pinned Stream Deck plugins";

      options.my.streamDeck.plugins = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = lib.mapAttrsToList (_: mkReleasePlugin) releases;
        description = ''
          Stream Deck plugins (derivations whose output is the `<uuid>.sdPlugin`
          directory and which carry `passthru.uuid`). They are copied, not
          symlinked: the SDK writes `logs/` inside the plugin directory, which a
          read-only /nix/store symlink would break.
        '';
      };

      config = lib.mkIf cfg.enable {
        home.activation.streamDeckPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          sd_dir="${pluginsDir}"
          sd_state="${stateFile}"
          sd_changed=0
          sd_wanted=""

          run mkdir -p "$sd_dir" "$(dirname "$sd_state")"

          ${lib.concatMapStringsSep "\n" (p: ''
            sd_target="$sd_dir/${p.passthru.uuid}.sdPlugin"
            sd_wanted="$sd_wanted ${p.passthru.uuid}"
            if [ -L "$sd_target" ]; then
              echo >&2 "stream-deck: ${p.passthru.uuid} is a symlink (dev link?), leaving it alone"
            else
              sd_out=$(${rsync} -rltpO --delete --chmod=u+w,Du+w --exclude=/logs/ \
                --itemize-changes ''${DRY_RUN:+--dry-run} "${p}/" "$sd_target/")
              if [ -n "$sd_out" ]; then
                echo "stream-deck: updated ${p.passthru.uuid} (${p.version})"
                sd_changed=1
              fi
            fi
          '') cfg.plugins}

          # Plugins that were managed before but are gone from the configuration.
          if [ -f "$sd_state" ]; then
            while read -r sd_old; do
              [ -n "$sd_old" ] || continue
              case " $sd_wanted " in *" $sd_old "*) continue ;; esac
              if [ -d "$sd_dir/$sd_old.sdPlugin" ] && [ ! -L "$sd_dir/$sd_old.sdPlugin" ]; then
                echo "stream-deck: removing $sd_old"
                run rm -rf "$sd_dir/$sd_old.sdPlugin"
                sd_changed=1
              fi
            done < "$sd_state"
          fi
          if [ -z "''${DRY_RUN:-}" ]; then
            for sd_id in $sd_wanted; do echo "$sd_id"; done > "$sd_state"
          fi

          if [ "$sd_changed" = 1 ]; then
            echo "stream-deck: plugins changed, restart the Stream Deck app to load them"
          fi
        '';
      };
    };
}
