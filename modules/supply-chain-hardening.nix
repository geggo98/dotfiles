{ ... }:
{
  flake.modules.homeManager.supply-chain-hardening = { ... }:
    let
      cooldownDays = 14;
      cooldownMinutes = cooldownDays * 24 * 60;
      cooldownSeconds = cooldownMinutes * 60;
    in
    {
      # uv: exclude-newer accepts duration strings
      xdg.configFile."uv/uv.toml".text = ''
        exclude-newer = "${toString cooldownDays} days"
      '';

      # npm: min-release-age in days, ignore-scripts blocks lifecycle hooks
      home.file.".npmrc".text = ''
        min-release-age=${toString cooldownDays}
        ignore-scripts=true
      '';

      # pnpm: minimum-release-age in minutes (macOS global config path)
      home.file."Library/Preferences/pnpm/rc".text = ''
        minimum-release-age=${toString cooldownMinutes}
      '';

      # bun: minimumReleaseAge in seconds
      home.file.".bunfig.toml".text = ''
        [install]
        minimumReleaseAge = ${toString cooldownSeconds}
      '';
    };
}
