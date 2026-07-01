{ ... }:
{
  flake.modules.homeManager.camoufox = { pkgs, lib, ... }:
    let
      # Pinned Camoufox release. Per the supply-chain-hardening policy the
      # tagged version must be at least 14 days old at landing time. To bump:
      #   1. Pick a tag from https://github.com/daijro/camoufox/releases that
      #      is ≥14 days old.
      #   2. Update `version` — the release tag, downloaded as `v${version}`.
      #   3. The published binaries carry a build stamp ("alpha.N") that can
      #      differ from the release tag ("beta.N") and even vary per platform,
      #      so set `assetVersion` / `assetVersionLinux` to match the actual
      #      asset filenames listed on the release page.
      #   4. Set the affected hashes to `lib.fakeHash`, run `just build`, read
      #      the "got: sha256-..." lines, paste them back.
      version = "150.0.2-beta.25";
      assetVersion = "150.0.2-alpha.25"; # mac.arm64 / mac.x86_64 asset stamp
      assetVersionLinux = "150.0.2-alpha.26"; # lin.x86_64 asset stamp

      sys = pkgs.stdenv.hostPlatform.system;

      # Asset name conventions used by the Camoufox release workflow. The
      # release tag (`v${version}`) and the asset filename stamp
      # (`assetVersion`) are tracked separately — see the bump notes above.
      asset =
        if sys == "aarch64-darwin" then {
          file = "camoufox-${assetVersion}-mac.arm64.zip";
          hash = "sha256-yxAIUddk5hWtfjm4TGD0SL1NKKUjoQ/oKB7tbcBIFSE=";
          executable = "Camoufox.app/Contents/MacOS/camoufox";
        }
        else if sys == "x86_64-darwin" then {
          file = "camoufox-${assetVersion}-mac.x86_64.zip";
          hash = lib.fakeHash;
          executable = "Camoufox.app/Contents/MacOS/camoufox";
        }
        else if sys == "x86_64-linux" then {
          file = "camoufox-${assetVersionLinux}-lin.x86_64.zip";
          hash = lib.fakeHash;
          executable = "camoufox-bin/camoufox";
        }
        else null;

      # Nix-managed Camoufox binary. When the platform isn't covered by an
      # asset entry above the wrapper falls back to `python -m camoufox fetch`.
      camoufoxBinary =
        if asset == null then null
        else
          pkgs.stdenv.mkDerivation {
            pname = "camoufox-binary";
            inherit version;
            src = pkgs.fetchzip {
              url = "https://github.com/daijro/camoufox/releases/download/v${version}/${asset.file}";
              hash = asset.hash;
              stripRoot = false;
            };
            dontConfigure = true;
            dontBuild = true;
            dontPatchELF = true;
            dontFixup = true;
            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/camoufox $out/bin
              cp -R ./. $out/share/camoufox/
              # Wrap rather than symlink: Firefox-style binaries discover their
              # sibling libraries relative to /proc/self/exe; a symlink breaks
              # that lookup on Linux. exec-from-shell preserves the real path.
              cat > $out/bin/camoufox <<EOF
              #!${pkgs.runtimeShell}
              exec "$out/share/camoufox/${asset.executable}" "\$@"
              EOF
              chmod +x $out/bin/camoufox
              runHook postInstall
            '';
            meta = {
              description = "Camoufox: anti-detect Firefox fork (binary, ${version})";
              homepage = "https://github.com/daijro/camoufox";
              license = lib.licenses.mpl20;
              platforms = lib.platforms.unix;
            };
          };

      driverScript = ./ai/_files/skills/web-browser/scripts/camoufox-daemon.py;

      # Wrapper: bootstraps a uv-managed venv on first use (idempotent),
      # exports CAMOUFOX_EXECUTABLE_PATH when the Nix binary is available, and
      # execs the daemon/client script.
      camoufoxDriver = pkgs.writeShellApplication {
        name = "camoufox-driver";
        runtimeInputs = with pkgs; [ python313 uv ];
        # Pip resolves arbitrary versions; pin via the stamp file's name.
        text = ''
          set -euo pipefail

          cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/camoufox-driver"
          venv="$cache_dir/.venv"
          stamp="$cache_dir/.installed-${version}-v1"

          if [[ ! -f "$stamp" ]]; then
            mkdir -p "$cache_dir"
            rm -rf "$venv"
            uv venv -q "$venv"
            uv pip install -q --python "$venv/bin/python" \
              "camoufox[geoip]" "playwright>=1.40,<2"
            touch "$stamp"
          fi

        '' + lib.optionalString (camoufoxBinary != null) ''
          if [[ -x "${camoufoxBinary}/bin/camoufox" ]]; then
            export CAMOUFOX_EXECUTABLE_PATH="${camoufoxBinary}/bin/camoufox"
          fi
        '' + ''

          if [[ -z "''${CAMOUFOX_EXECUTABLE_PATH:-}" ]]; then
            # Lazy fetch on first use (~300 MB into ~/.cache/camoufox).
            if ! "$venv/bin/python" -c "import camoufox.utils; camoufox.utils.installed_verstr()" \
                  >/dev/null 2>&1; then
              "$venv/bin/python" -m camoufox fetch
            fi
          fi

          exec "$venv/bin/python" ${driverScript} "$@"
        '';
      };
    in
    {
      home.packages = [ camoufoxDriver ];
    };
}
