{ ... }:
{
  flake.modules.homeManager.supply-chain-hardening = { ... }:
    let
      cooldownDays = 14;
      cooldownMinutes = cooldownDays * 24 * 60;
      cooldownSeconds = cooldownMinutes * 60;
    in
    {
      # Two independent policies per ecosystem: a release cooldown (never resolve
      # a version younger than N, so a compromised release has usually been pulled
      # before we can reach it) and, where installing can execute code, a
      # lifecycle-script policy. The mechanisms are NOT equivalent between tools,
      # so each block states what it actually covers.

      # uv: exclude-newer accepts duration strings. Python wheels have no
      # install-time script hook, so the cooldown is the entire policy here.
      xdg.configFile."uv/uv.toml".text = ''
        exclude-newer = "${toString cooldownDays} days"
      '';

      # npm: min-release-age in days. ignore-scripts blocks lifecycle hooks of
      # dependencies and of the project itself; npm has no per-package allowlist,
      # so it is all-or-nothing. Note this file reaches further than npm -- bun
      # reads it too (see the bun block).
      home.file.".npmrc".text = ''
        min-release-age=${toString cooldownDays}
        ignore-scripts=true
      '';

      # pnpm: settings live in YAML, NOT in the ini-style `rc` next to it. Since
      # v10 pnpm reads only registry/auth from ini files, so the previous version
      # of this block -- `rc` containing `minimum-release-age` -- was silently
      # ignored and the global cooldown had never applied to a single pnpm
      # project (measured 04.08.2026: `pnpm config get minimum-release-age` in
      # $HOME returned undefined; infra/ was covered only by its own
      # pnpm-workspace.yaml). Per-project pnpm-workspace.yaml still overrides.
      #
      # Deliberately no ignoreScripts here. pnpm already denies every dependency
      # build script that pnpm-workspace.yaml does not list in allowBuilds, and
      # strictDepBuilds fails the install on an unreviewed script rather than
      # skipping it silently -- stricter than npm's ignore-scripts. Adding
      # ignoreScripts on top would also void the reviewed allowBuilds entries
      # (infra/pnpm-workspace.yaml) and break `just pulumi-install`. Both booleans
      # are today's defaults, pinned so a future default cannot loosen them
      # unnoticed.
      home.file."Library/Preferences/pnpm/config.yaml".text = ''
        minimumReleaseAge: ${toString cooldownMinutes}
        strictDepBuilds: true
        dangerouslyAllowAllBuilds: false
      '';

      # bun: minimumReleaseAge in seconds. ignoreScripts is what closes bun's
      # curated default-trusted list -- 367 packages (`bun pm default-trusted`)
      # whose lifecycle scripts run unasked, including nx, esbuild, electron,
      # puppeteer, sharp and playwright-chromium. It also overrides an explicit
      # trustedDependencies entry (measured 04.08.2026 against a packed tarball
      # dependency). bun honours ~/.npmrc's ignore-scripts as well, so this is
      # already in force via the npm block above -- stated here so the policy
      # does not rest on bun continuing to read another tool's config file.
      # Opting out is per project, and only through a local .npmrc holding
      # `ignore-scripts=false`. A local bunfig.toml saying the same thing does
      # NOT win: the ~/.npmrc above still applies to bun and outranks it. Both
      # measured 04.08.2026 against a packed tarball dependency. See the slidev
      # skill for the case that needs the opt-out.
      home.file.".bunfig.toml".text = ''
        [install]
        minimumReleaseAge = ${toString cooldownSeconds}
        ignoreScripts = true
      '';
    };
}
