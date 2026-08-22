# agent-browser (https://github.com/vercel-labs/agent-browser) from upstream's
# prebuilt release binaries, not from nixpkgs or llm-agents.nix.
#
# Why: both of those build the observability dashboard out of agent-browser's pnpm
# workspace, and that dashboard's pnpm-deps FOD resolves *time-dependently* — pnpm's
# `minimumReleaseAge` picks "newest version released more than N days ago" for deps
# that aren't fully locked. The pinned hash therefore drifts away on its own, which
# is what took agent-browser out of modules/ai-tools.nix on 2026-07-25 (first a
# ~26 min registry scan that got SIGKILLed, then a plain hash mismatch).
#
# The release binary is a standalone Rust executable — no node, no pnpm, no cargo,
# no FOD — so that failure mode is structurally gone. What it does *not* contain is
# the skill bodies (`agent-browser skills get <name>`): the binary looks them up on
# disk and bails with "Skills directory not found" otherwise. They come from the
# tag-matched source input and are wired in via AGENT_BROWSER_SKILLS_DIR below.
{ inputs, lib, ... }:
let
  # Single source of truth for the version: the pinned agent-browser-src tag.
  # Bumping the tag in flake.nix moves the binary too, so the two can't diverge.
  version = (builtins.fromJSON
    (builtins.readFile "${inputs.agent-browser-src}/package.json")).version;

  # One release asset per system. Linux deliberately uses the *musl* builds: they
  # are statically linked, so no autoPatchelfHook and no interpreter patching —
  # which in turn keeps the "never rewrite the binary" rule below intact on Linux.
  # Recompute after a version bump with `just agent-browser-hashes <version>`.
  assets = {
    aarch64-darwin = { asset = "agent-browser-darwin-arm64"; hash = "sha256-y7UXkCvKo7emOE/Z8l3SdNo98rtqO6nD6FgG14ITwms="; };
    x86_64-darwin = { asset = "agent-browser-darwin-x64"; hash = "sha256-prscEBJPYkqbH9Duyr93RHfNtxDjVS+4Q/H39mS48yY="; };
    x86_64-linux = { asset = "agent-browser-linux-musl-x64"; hash = "sha256-yn5liRWP2Sdol+xmNnEFcEohX5Wx30xKuxkyRNAmDto="; };
    aarch64-linux = { asset = "agent-browser-linux-musl-arm64"; hash = "sha256-7sfQon4yuWpPm5+90MBw0FjltOqhvWvh//6SYyHF0Bw="; };
  };
in
{
  # Picked up automatically by modules/overlays.nix (`lib.attrValues
  # config.flake.overlays` -> nixpkgs.overlays), and reaches the home-manager
  # modules because home-manager.useGlobalPkgs = true. Overrides the (older)
  # agent-browser that nixpkgs itself ships.
  #
  # `prev ? stdenv` guard as in modules/overlays.nix: flake-schemas calls the
  # overlay with empty args (`overlay {} {}`) just to check it returns an attrset.
  flake.overlays.agent-browser = final: prev:
    lib.optionalAttrs (prev ? stdenv)
      (lib.optionalAttrs (assets ? ${prev.stdenv.hostPlatform.system})
        (
          let
            inherit (assets.${prev.stdenv.hostPlatform.system}) asset hash;
          in
          {
            agent-browser = prev.stdenvNoCC.mkDerivation {
              pname = "agent-browser";
              inherit version;

              src = prev.fetchurl {
                url = "https://github.com/vercel-labs/agent-browser/releases/download/v${version}/${asset}";
                inherit hash;
              };

              dontUnpack = true;

              # The darwin binaries are ad-hoc (linker-)signed Mach-O; macOS refuses
              # to exec an arm64 binary whose signature no longer matches. Anything
              # that rewrites bytes — strip, patchelf — invalidates it. So the binary
              # is only ever *copied*, never modified.
              dontStrip = true;
              dontPatchELF = true;

              nativeBuildInputs = [ prev.makeWrapper ];

              # makeWrapper (a shell script), deliberately not makeBinaryWrapper:
              # the latter would emit an additional, unsigned Mach-O binary.
              # --set-default, not --set, so a caller-supplied skills dir still wins.
              # `which` is in the wrapper PATH because the CLI shells out to it.
              installPhase = ''
                runHook preInstall

                install -Dm755 "$src" "$out/libexec/agent-browser"
                cp -r ${inputs.agent-browser-src}/skill-data "$out/skill-data"

                makeWrapper "$out/libexec/agent-browser" "$out/bin/agent-browser" \
                  --set-default AGENT_BROWSER_SKILLS_DIR "$out/skill-data" \
                  --prefix PATH : ${lib.makeBinPath [ prev.which ]}

                runHook postInstall
              '';

              meta = {
                description = "Browser automation CLI for AI agents";
                homepage = "https://agent-browser.dev/";
                license = lib.licenses.asl20;
                mainProgram = "agent-browser";
                platforms = lib.attrNames assets;
                sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
              };
            };
          }
        ));
}
