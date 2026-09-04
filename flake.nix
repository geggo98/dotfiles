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
      url = "github:yt-dlp/yt-dlp/2026.08.19";
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
      url = "github:Homebrew/brew/6.0.20";
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
    # on its own, for good reasons written up in AGENTS.md; this was a decision
    # by hand, and the two weeks of unreleased main are exactly what was given
    # up.
    devenv.url = "github:cachix/devenv/v2.2.2";

    # https://github.com/numtide/llm-agents.nix
    # Tracks main. Source for claude-code, codex, opencode, gemini-cli, ccusage
    # and the ACP shims. Deliberately *not* the source for agent-browser — see
    # modules/agent-browser.nix for why that one comes from release binaries.
    nixpkgs-llm-agents.url = "github:numtide/llm-agents.nix";

    # TEMPORARY PIN — claude-code 2.1.247. Consumed by modules/mcp-servers.nix.
    #
    # Why: an open heap-growth bug. The fix chain is 2.1.238 (subagent tool results
    # were never released in long sessions), 2.1.243 (the runtime collects sooner as
    # the heap grows; 40-70 MB less per session), 2.1.246 (memory grew with session
    # length in the fullscreen/Ctrl+O transcript — every rendered row held a copy of
    # the transcript-wide tool lookups) and 2.1.247 (unbounded growth when a hook's
    # or background task's output file could not be written). nixpkgs-llm-agents
    # sits on 2.1.234 and carries NONE of them.
    #
    # 2.1.247 was published 2026-08-26 18:02Z — 6.5 days old against the 14-day bar
    # scripts/supply-chain.toml gives this ecosystem. So this is a deliberate
    # undercut under AGENTS.md "Undercutting a cooldown: research first, fetch
    # second", and the research was done while fetching nothing: the three SRI
    # hashes in llm-agents' packages/claude-code/hashes.json at this rev match
    # Anthropic's own manifest.json for 2.1.247 exactly (darwin-arm64, linux-arm64,
    # linux-x64) — two independent sources; the artifact is still served (HTTP 200,
    # 233 MB, last-modified agreeing with the npm publish time); and `latest` points
    # at 2.1.258, i.e. 2.1.247 was superseded normally rather than withdrawn.
    # Withdrawal here means Anthropic repointing `latest`, which llm-agents' own
    # `versionPolicy = "follow_pointer"` really did act on for 2.1.243 on 2026-08-25.
    # It has not happened to 2.1.247 in 6.5 days.
    #
    # The blast radius is deliberately ONE package: the rev sits exactly on the bump
    # commit "claude-code: 2.1.246 -> 2.1.247" (2026-08-27 01:43Z), and only
    # claude-code is taken from it. codex, opencode, gemini-cli, ccusage and the ACP
    # shims stay on nixpkgs-llm-agents and stay soaked. Moving the main input
    # instead would have pulled all of them out of the 14-day window for a bug that
    # only affects the CLI.
    #
    # No `inputs.nixpkgs.follows` on purpose, and it is load-bearing. Without it the
    # derivation is bit-identical to upstream CI's, and upstream publishes it.
    # Measured 2026-09-02: https://cache.numtide.com serves this exact out path,
    # hf25qcvb4a9s6lkn7gi8l38x33jxxv1g-claude-code-2.1.247 (NarSize 233074048),
    # with Deriver xjqns9sr…-claude-code-2.1.247.drv and an niks3.numtide.com-1
    # signature. Adding the follows moves the path to in0gm0gc…, which is 404
    # there — it would have to be built here. Five inputDrvs change (stdenv-darwin,
    # bash 5.3p15 -> 5.3p9, make-shell-wrapper-hook, version-check-hook and the
    # fetchurl drv); the recipe does not, and the 233 MB fetchurl OUTPUT is
    # content-addressed and identical either way, so the cost is the build, not the
    # download. It also evaluates fine against nixpkgs 26.05 — the "llm-agents needs
    # unstable" worry does not apply to this package.
    #
    # This only started paying off once nixConfig.extra-substituters below was
    # corrected: it named numtide.cachix.org, which upstream has left, so the
    # identical, publicly cached artifact was rebuilt here on every bump.
    #
    # What that fix does NOT change is what the R2 cache ends up mirroring, and it
    # is worth writing down so nobody re-derives the wrong conclusion from it.
    # home-manager's generated wrapper for this package carries allowSubstitutes=""
    # and preferLocalBuild=1, so it is always built locally, and nix-cache-push
    # copies CLOSURES (it must — a binary cache has to be referentially complete),
    # so the wrapper's reference travels with it either way. Measured 2026-09-02:
    # bash-5.3p15 sits in R2 with ultimate=false and its two cache.nixos.org
    # signatures, i.e. purely substituted here and re-published by a closure push.
    # The general case and its licence consequences: see "The public cache mirrors
    # system closures" in AGENTS.md.
    #
    # REMOVE once nixpkgs-llm-agents itself ships >= 2.1.247 — at the earliest on
    # 2026-09-10, when `just update` with the 14-day bar lands on a rev from
    # 2026-08-27 or later. An assertion in modules/mcp-servers.nix breaks the build
    # at that point and spells out the four steps, so the pin cannot go stale
    # silently.
    llm-agents-claude-code-pin.url =
      "github:numtide/llm-agents.nix/aebe6cb75261fa098939e4e5b24fc5a545478dc4";

    # agent-browser: source of truth for both the version and the skill bodies
    # consumed by modules/agent-browser.nix. That module reads the version from
    # this input's package.json and fetches the matching prebuilt release binary,
    # so binary and skill-data can never drift apart.
    # Upgrade: bump the tag -> `just agent-browser-hashes <version>` -> paste the
    # printed hashes into modules/agent-browser.nix -> `just build`.
    # Pinned by tag, not rev: github archive URLs are ambiguous when a repo has a
    # branch and tag of the same name (llm-agents hit this in 62903bf).
    #
    # HELD AT 0.33.2 (2026-08-02), NOT 0.34.0 (2026-08-11) — deliberate. This is a tag
    # pin, so `just update`'s cooldown does not move it and the choice is made here by
    # hand. 0.34.0 is 11 days old and would clear the repo's 5-day bar; 0.33.2 is 20
    # days old, is patch-level on the 0.33 minor already trusted here, and carries the
    # identical asset names — so the bump needs only the four hashes below, no
    # structural change to modules/agent-browser.nix.
    #
    # THE OPEN ISSUE, and why bumping further would not address it:
    # vercel-labs/agent-browser#1679 — the CLI auto-discovers a project-local
    # `agent-browser.json` from its working directory and honours `executablePath` and
    # `plugins` from it. A repository that merely *contains* such a file therefore runs
    # code as you the moment you invoke agent-browser inside that checkout. The fix,
    # PR #1702, is unmerged and is NOT in 0.34.0 either, so this is not a reason to
    # prefer the newer tag. It is also not a regression: the same exposure exists at
    # 0.33.0, which this repo shipped before.
    #   -> Until #1702 lands, do not run agent-browser with cwd inside an untrusted
    #      checkout. Re-read the issue before the next bump.
    #
    # BEHAVIOUR CHANGE that arrives with this bump: 0.33.1 gave the daemon a default
    # 1-hour idle timeout (#1605), after which it closes the browser and exits. Set
    # AGENT_BROWSER_IDLE_TIMEOUT_MS=0 to restore the old always-persist daemon if a
    # long-running skill workflow depends on it.
    agent-browser-src = {
      url = "github:vercel-labs/agent-browser/v0.33.2";
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
    # NEEDS ONE INTERACTIVE ACCEPTANCE. ~/.local/share/nix/trusted-settings.json
    # keys consent on the EXACT string of the whole list, so changing one host
    # invalidates the stored "yes" and a non-interactive run silently ignores the
    # setting again ("warning: ignoring untrusted flake configuration setting").
    # Answer the prompt once per machine, e.g. during `just build`, then check:
    #   nix config show | grep '^substituters'   # cache.numtide.com must appear
    extra-substituters = [ "https://cache.numtide.com" "https://devenv.cachix.org" "https://nix-cache.pub.schwetschke.dev" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" "nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=" ];
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ (inputs.import-tree ./modules) ];
    };
}
