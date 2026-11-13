# just build   # build without applying
# just switch  # apply — selects the flake attr by hardware serial, so a drifted
#              # LocalHostName (macOS's "-2" suffix) can't break attr selection
#              # the way a bare `darwin-rebuild switch --flake .` does
# sudo determinate-nixd upgrade
# determinate-nixd version # Shows features, see https://dtr.mn/features
{
  description = "Stefan's darwin system";

  # Update all with: `nix flake update`
  # Update single input with `nix flake lock --update-input <input-name>`
  inputs = {
    # Package sets
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05"; # https://status.nixos.org/
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-yt-dlp.url = "github:nixos/nixpkgs/nixos-unstable"; # yt-dlp build recipe (deps/patches)
    # yt-dlp source straight from upstream, pinned to a stable release tag — so
    # the installed yt-dlp is the newest *released* version regardless of how
    # stale the nixpkgs packaging is (nixos-unstable can lag releases by months).
    # Not a flake, so flake = false; Nix hashes the source automatically. To
    # upgrade, bump the tag below to the latest release from
    # https://github.com/yt-dlp/yt-dlp/releases (then `just build`).
    yt-dlp-src = {
      url = "github:yt-dlp/yt-dlp/2026.10.26";
      flake = false;
    };

    # Flake structure
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    # Environment/system management
    darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    # Determinate Nix module for Nix Darwin
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Homebrew installation manager for nix-darwin — makes the `brew` binary
    # Nix-managed and version-pinned (via brew-src below), so `brew trust`
    # (Homebrew 6.0+) is always present and the version is deterministic
    # across hosts. https://github.com/zhaofengli/nix-homebrew
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    nix-homebrew.inputs.brew-src.follows = "brew-src";

    # Pinned Homebrew source. Overrides nix-homebrew's bundled default so we
    # control the exact brew version; bump the tag to upgrade (then `just build`).
    # https://github.com/Homebrew/brew/releases
    #
    # KNOWN FAILURE MODE — this pin cannot be left to rot. Homebrew 6 no longer
    # taps homebrew/core and homebrew/cask; it reads them from Homebrew's JSON
    # API, which is a rolling service and therefore NOT pinnable. When upstream
    # adds a new cask DSL artifact, the API starts serving it to everyone while
    # this pinned brew still lacks the Ruby class for it, and `brew bundle` dies
    # mid-activation:
    #
    #   Error: Cask 'firefox' definition is invalid:
    #          undefined method 'command_wrapper' for Cask 'firefox'
    #
    # That aborts `darwin-rebuild switch` *after* /etc is written but *before*
    # home-manager activates, so the system is left half-applied.
    #
    # Seen 2026-08-16: pinned 6.0.9 (2026-07-07) vs. the `command_wrapper`
    # artifact added upstream 2026-07-21..26 (Homebrew/brew#23183, #23296,
    # #23308). First brew tag carrying
    # Library/Homebrew/cask/artifact/command_wrapper.rb is 6.0.13 (2026-07-27);
    # homebrew-cask migrated firefox, keka, betterdisplay and vlc to the new
    # stanza on 2026-07-29 (Homebrew/homebrew-cask#275991). This host only
    # tripped over it on 2026-08-11, when its local cask.jws.json cache refreshed.
    #
    # Mind that margin: the brew release able to parse the new stanza preceded the
    # API serving it by TWO DAYS. This pin must not lag more than a release or two.
    #
    # Fix, and the routine cure whenever this recurs: `just brew-bump`.
    #
    # DO NOT SANITY-CHECK THIS PIN AGAINST THE VERSION NUMBER NIX REPORTS — it lies,
    # and it lies in the alarming direction. `nix store diff-closures` prints e.g.
    # `brew: 6.0.12 -> 6.0.16` and the store path is `brew-6.0.16-patched`, both while
    # this input was pinned to 6.0.17. That label comes from nix-homebrew's OWN default
    # brew-src, not from ours; `nix-homebrew.inputs.brew-src.follows` redirects the
    # source but not the version string. Verified 2026-08-22: the built derivation's
    # only `-source` input is our tree, `gh api repos/Homebrew/brew/git/ref/tags/6.0.17`
    # returned exactly the rev 4dacfe77a… locked at the time, and that tree does contain
    # Library/Homebrew/cask/artifact/command_wrapper.rb — the class whose absence caused
    # the 6.0.9 breakage above. `brew --version` is no help either; it prints
    # "Homebrew >=4.3.0 (shallow or no git repository)".
    #
    # So the authoritative check is the flake.lock rev, not the closure diff:
    #   nix eval --raw .#inputs.brew-src.rev   (or read flake.lock)
    # Reading the label instead invites "fixing" a pin that was never wrong.
    brew-src = {
      url = "github:Homebrew/brew/7.0.12";
      flake = false;
    };

    # https://github.com/Mic92/sops-nix
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Declarative disk partitioning for the NixOS hosts. Consumed by
    # modules/hosts/p-ion-berlin-xs56r6.nix and by `nixos-anywhere`, which reads the
    # disko config out of the flake to partition the target before installing.
    # https://github.com/nix-community/disko
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/nix-community/nix-index-database
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/cachix/devenv
    #
    # PINNED TO A RELEASE TAG, not to main, and the tag is the whole point.
    # Without a ref this input tracked the default branch, and main carries a
    # Cargo version that has not been released: measured 2026-09-03, the
    # deployed path was
    #   /etc/profiles/per-user/<user>/bin/devenv -> home-manager-path
    #     -> /nix/store/f2vgfk2j...-devenv-wrapped-2.2.3
    # while cachix/devenv's releases end at v2.2.2 (2026-08-13). So the machines
    # ran a "2.2.3" that exists nowhere upstream -- nothing to read release
    # notes for, nothing to report a bug against.
    #
    # The cooldown cannot fix that, because it picks an AGE, not a publication.
    # `just update-preview` on the same day:
    #     devenv   ed3d140a9 (6.9d) -> eeced8155 (2026-08-28, 5.8d, 5d bar)
    # -- again an arbitrary main commit, merely an older one.
    #
    # Cost of the pin, stated plainly: `just update` no longer moves this input
    # at all; it lands in the "skipped -- immutable pin" class. `just devenv-bump`
    # is the replacement and keeps the bar, because it asks
    # `supply-chain.py release cachix/devenv` for the newest release that clears
    # `[cooldown] inputs` instead of taking whatever is newest.
    #
    # Adopting v2.2.2 moved this input BACKWARDS, from a main commit of
    # 2026-08-27 to the release of 2026-08-13. `just update` refuses to do that
    # on its own, for good reasons written up in docs/supply-chain.md; this was a decision
    # by hand, and the two weeks of unreleased main are exactly what was given
    # up.
    devenv.url = "github:cachix/devenv/v2.4.0";

    # https://github.com/numtide/llm-agents.nix
    # Tracks main. Source for claude-code, codex, opencode, gemini-cli,
    # antigravity-cli, ccusage and the ACP shims. Deliberately *not* the source
    # for agent-browser — see modules/agent-browser.nix for why that one comes
    # from release binaries.
    nixpkgs-llm-agents.url = "github:numtide/llm-agents.nix";

    # agent-browser: source of truth for both the version and the skill bodies
    # consumed by modules/agent-browser.nix. That module reads the version from
    # this input's package.json and fetches the matching prebuilt release binary,
    # so binary and skill-data can never drift apart.
    # Upgrade: bump the tag -> `just agent-browser-hashes <version>` -> paste the
    # printed hashes into modules/agent-browser.nix -> `just build`.
    # Pinned by tag, not rev: github archive URLs are ambiguous when a repo has a
    # branch and tag of the same name (llm-agents hit this in 62903bf).
    #
    # AT 0.39.3 (2026-10-26, 12 d), 2 days short of the 14 d bar, ON PURPOSE: 0.39.3 is
    # the first release that closes vercel-labs/agent-browser#1679 (the CLI auto-
    # discovered a project-local `agent-browser.json` and honoured `executablePath`
    # and `plugins` from it, so a repository that merely contained such a file ran
    # code as you). Fixed by #2180, merged 2026-10-23, in 0.39.3 and not in 0.39.2.
    # The same release carries four more hardening fixes (MCP tool arguments can no
    # longer override access settings #2181, inspect WebSocket origin check #2182,
    # signals only after a process identity check #2183, auth key overwrite #2178).
    # Metadata checked before the fetch: the four asset sha256 digests GitHub records
    # on the release equal the hashes in modules/agent-browser.nix. This is a tag pin,
    # so `just update`'s cooldown does not move it; `supply-chain.py release
    # vercel-labs/agent-browser` still names 0.39.2 until 2026-11-09.
    #
    # Verified after the bump: with a `agent-browser.json` in the working directory
    # whose `executablePath` points at a marker script, the script does not run.
    #
    # WHAT ARRIVED between 0.33.2 and 0.36.0, in the order it matters here:
    #   0.36.0  experimental WebMCP, ON by default for locally managed Chrome: a page
    #           can advertise tools and the agent can invoke them. Left at the upstream
    #           default on purpose — those tools run in the page's own JavaScript,
    #           which the agent can already drive by clicking, so nothing new
    #           executes on this machine. Opt out per call with `--no-webmcp` or
    #           AGENT_BROWSER_NO_WEBMCP; skill-data gains `webmcp-gen`.
    #   0.35.2  dashboard origin validation hardened against DNS rebinding and
    #           cross-origin requests (#1738).
    #   0.35.0  `--ca-cert` for a private proxy CA on Linux; skill-data gains
    #           `protected-vercel-deployments`.
    #   0.34.0  named sessions on a shared Chrome remember their CDP target; the
    #           skill guidance now wants a named `--session` before the first
    #           command (#1589).
    #   0.33.1  the daemon has a default 1-hour idle timeout (#1605) after which it
    #           closes the browser and exits; AGENT_BROWSER_IDLE_TIMEOUT_MS=0 restores
    #           the always-persist daemon for a long-running skill workflow.
    agent-browser-src = {
      url = "github:vercel-labs/agent-browser/v0.39.3";
      flake = false;
    };

    # External dependencies
    # Tracks nvf main: v0.8 (the latest tag) bundles blink-cmp 1.8.0, whose
    # frizbee dep needs nightly portable_simd and fails on nixpkgs 26.05's
    # stable rustc. main ships a buildable blink-cmp against current nixpkgs.
    nvf = {
      url = "github:NotAShelf/nvf";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/nix-community/nix-vscode-extensions
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/max-sixty/worktrunk
    worktrunk = {
      url = "github:max-sixty/worktrunk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/gradle/gradle-skills (Apache-2.0): the official Gradle
    # skills, `gradle-best-practices` and `gradle-wrapper-upgrade`. Not a flake;
    # the repo root is itself a Claude Code plugin (.claude-plugin/), loaded
    # through modules/gradle.nix. Move it with `just update-input gradle-skills`
    # so the supply-chain cooldown applies.
    gradle-skills = {
      url = "github:gradle/gradle-skills";
      flake = false;
    };

    # https://github.com/iha2/superlite (MIT): an autonomous build-lifecycle
    # plugin for Claude Code. Deliberately NOT in programs.claude-code.plugins:
    # its SessionStart hook injects a skill into every session and its
    # PreToolUse hooks run on every Bash/Edit call. It is reachable only through
    # `+agent-claude-superlite` (modules/superlite.nix). Not a flake. The repo
    # is days old and moves daily; `just update-input superlite` applies the
    # cooldown, so expect the pin to trail the newest tag.
    superlite = {
      url = "github:iha2/superlite";
      flake = false;
    };
  };

  # Substituters offered to anyone building this flake (each honored only for a
  # trusted user who accepts it — accept-flake-config). numtide/devenv front the
  # llm-agents/devenv builds; nix-cache.pub.schwetschke.dev is our shared R2
  # cache (modules/nix-cache.nix). R2 is listed here — on top of the
  # nix.custom.conf substituter that covers steady-state — so a FRESH machine's
  # first build can pull the ~3.3 GiB delta (paths not on cache.nixos.org)
  # instead of compiling it, before nix.custom.conf exists. See `just bootstrap`.
  nixConfig = {
    # https://github.com/numtide/llm-agents.nix/blob/main/flake.nix
    # cache.numtide.com, NOT numtide.cachix.org. numtide moved llm-agents.nix to
    # its own niks3 cache; the cachix host is still up and answers nix-cache-info
    # with 200, but it holds nothing from this project — measured 2026-09-02, 58
    # of this store's hashes probed against it returned 0 hits, and every
    # llm-agents output tried (claude-code, codex, opencode, ccusage, gemini-cli,
    # on both aarch64-darwin and x86_64-linux, at three revs) 404s. So its answer
    # was indistinguishable from a genuine miss, and claude-code was rebuilt
    # locally for weeks while this line claimed to prevent exactly that. The
    # value below is what llm-agents.nix declares in its own nixConfig.
    #
    # Validate the same way if this is ever suspected again: probe a handful of
    # paths you KNOW the cache should have before believing a 404.
    #
    # NEEDS ONE INTERACTIVE ACCEPTANCE, PER USER.
    # ~/.local/share/nix/trusted-settings.json keys consent on the EXACT string
    # of the whole list, so changing one host invalidates the stored "yes" and a
    # non-interactive run silently ignores the setting again ("warning: ignoring
    # untrusted flake configuration setting"). Answer the prompt once per
    # machine, e.g. during `just build`; `just switch` checks for the stored yes
    # and prints the exact command when it is missing.
    #
    # DO NOT verify with `nix config show | grep '^substituters'`. That command
    # does not load the flake, so it prints the same list whether or not this
    # block was ever accepted — and cache.numtide.com is in it regardless,
    # because modules/nix-cache.nix sets it system-wide through
    # determinateNix.customSettings. Measured 05.09.2026: consent granted and
    # demonstrably effective, yet devenv.cachix.org absent from that output.
    # devenv.cachix.org is the only entry here that exists NOWHERE else, so it
    # is the one worth looking for. What actually answers the question:
    #   nix eval --raw '.#darwinConfigurations.<serial>.system.drvPath'
    #     -> effective when it prints no "untrusted flake configuration" warning
    #
    # AND `sudo darwin-rebuild` IS A DIFFERENT USER. root's consent file is
    # /var/root/.local/share/nix/trusted-settings.json, and the prompt has no
    # tty there, so `just switch` warns twice on EVERY run even when yours is in
    # order. Measured the same day: 0 warnings from a user-level eval against 2
    # from the switch beside it. Do not read the switch's warning as an
    # unanswered prompt.
    extra-substituters = [ "https://cache.numtide.com" "https://devenv.cachix.org" "https://nix-cache.pub.schwetschke.dev" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" "nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=" ];
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ (inputs.import-tree ./modules) ];
    };
}
