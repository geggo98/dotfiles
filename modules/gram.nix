{ ... }:
{
  # Gram replaces the `zed` cask. The app itself comes from the `gram` homebrew
  # cask (see modules/homebrew-common.nix), not from nixpkgs: the nixpkgs build
  # symlinks a full `git` into the app bundle, and on darwin that drags
  # python3 -> clang -> llvm -> apple-sdk along, for a 1.8 GiB closure against a
  # ~130 MiB app. Overriding `git` to gitMinimal would cut ~1.3 GiB of that, but
  # changes the store path and so forces a source build of a Zed-sized Rust tree
  # (hours). The cask ships the same upstream release.
  flake.modules.homeManager.gram = {
    # Gram is a Zed fork and reads Zed themes verbatim (same
    # zed.dev/schema/themes/v0.2.0.json its own bundled themes declare).
    # Same palette as modules/_files/vscode/turbo-vision-color-theme.json and
    # the IntelliJ scheme "Gerry Cyberpunk Plus Cursive Font".
    #
    # One mapping decision worth recording: VS Code colours HTML attributes
    # (#fff067) differently from annotations/decorators (#bbb529), but Zed
    # routes both through the `attribute` capture. The theme gives `attribute`
    # the attribute colour — which also matches IntelliJ's DEFAULT_ATTRIBUTE —
    # and puts the annotation yellow on `preproc`.
    #
    # settings.jsonc is deliberately NOT managed: Gram writes UI settings back
    # to it, which a read-only nix store symlink would break. Select the theme
    # once in Gram, or hand-edit ~/.config/gram/settings.jsonc.
    xdg.configFile."gram/themes/turbo-vision.json".source =
      ./_files/gram/turbo-vision.json;
  };
}
