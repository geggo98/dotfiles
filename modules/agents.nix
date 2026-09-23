{ inputs, config, lib, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
  llm-agents-pkgs = system: inputs.nixpkgs-llm-agents.packages.${system};

  # TEMPORARY claude-code pin, 2.1.280 — the full reasoning is at the
  # llm-agents-claude-code-pin input in flake.nix. Only claude-code comes from
  # that input; opencode below stays on nixpkgs-llm-agents (codex has a pin of
  # its own, next block).
  #
  # The version string and the rev in flake.nix belong together; the first
  # assertion below is what keeps them together.
  claude-code-pin-version = "2.1.280";
  claude-code-pinned = system:
    inputs.llm-agents-claude-code-pin.packages.${system}.claude-code;

  # TEMPORARY codex pin, 0.156.1 — for GPT-6 Sol and GPT-6 Luna, which only
  # appear in the bundled model catalog (codex-rs/models-manager/models.json)
  # from this version on (openai/codex, tag rust-v0.156.1, GitHub release
  # 2026-09-23T02:41:36Z, hotfix openai/codex#47405 backporting #47332).
  #
  # THIS IS NOT A CLEAN REV BUMP. nixpkgs-llm-agents (numtide/llm-agents.nix)
  # cannot build 0.156.1 yet: its automated bump PR #9696 fails compiling
  # codex-chatgpt with "queries overflow the depth limit" (rustc's query-depth
  # limit, tripped by new code in connectors::list_connectors). A fix exists
  # (PR #9748, one-line `#![recursion_limit = "256"]`) but comes from an
  # external contributor's fork, unmerged as of 2026-09-23 — and per this
  # repo's own third-party-data / supply-chain rules that fork is NOT a
  # source this repo pulls from, however small the diff looks. So instead of
  # a new llm-agents-codex-pin rev (which would require exactly that fork or
  # the equally unmerged bot branch), this overrides `version`/`hash`/
  # `cargoHash` on the EXISTING, already-vetted package recipe from the
  # current llm-agents-codex-pin input (rev 6d96d0808, see below) — same
  # recipe, no new source, only the three data values that differ for
  # 0.156.1. `librusty_v8` is untouched: rust-toolchain.toml pins
  # `v8 = "=150.4.0"` identically in rust-v0.155.1 and rust-v0.156.1.
  #
  # THE COOLDOWN UNDERCUT (0.156.1 was ~10 h old when checked against the
  # 14-day bar, 2026-09-23 ~13:00 UTC), researched from metadata only, no
  # binary fetched, per AGENTS.md "Undercutting a cooldown: research first,
  # fetch second":
  #   npm: published 2026-09-23T02:45:25Z by the same trusted GitHub-Actions
  #     OIDC publisher and the same 18 maintainers as every prior version, no
  #     `deprecated`, no `unpublished`. SLSA + npm-publish attestations
  #     present, Rekor log entries match the release workflow run.
  #   OSV: {} for 0.156.1 -- no advisories. GitHub Security Advisories: only
  #     two historical GHSAs, neither affects 0.156.1.
  #   No report of a live campaign against @openai/codex or its maintainers
  #     in September 2026; known incidents (codexui-android, a May-2026 npm
  #     campaign, a Shai-Hulud note naming `keyv`) are all third-party
  #     packages, not this one.
  #   Diff 0.156.0 -> 0.156.1 confirmed (via the GitHub compare API) to be
  #     only models.json (+367/-11, the new catalog entries) plus two real
  #     code lines (a migration target and a catalog constant) plus
  #     snapshots/tests. Nothing touches build, update or network code.
  #     Cargo.lock is byte-identical to 0.156.0.
  #   ONE ANOMALY, NAMED RATHER THAN OMITTED: the tag sits two commits above
  #     the `release/0.156` branch head, on an independent hotfix branch; its
  #     PR #47405 was closed UNMERGED, without review, 34 minutes before
  #     publish (as was its predecessor #47385). Every prior codex tag
  #     (0.153.4, 0.155.1) sat exactly on its release branch's head. Content,
  #     publisher identity and provenance still match the reviewed `main` PR
  #     #47332, and the release workflow run / Rekor entry binds the
  #     published artifact to that exact commit -- so this is a process
  #     deviation on OpenAI's side, not evidence of tampering.
  #
  # SELF-BUILD BEHAVIOUR CHECKED FROM SOURCE (openai/codex on GitHub, no
  # build/run): a /nix/store path is classified InstallMethod::Other, for
  # which there is no code path that downloads or replaces a binary -- only
  # a banner. The hourly daemon updater only acts on a "managed package"
  # with a codex-package.json, which this Nix build never produces;
  # prepare_install.rs explicitly refuses a bare executable. Voice
  # (realtime_conversation, default-on since 0.156.0) needs the same
  # "package layout" and fetches nothing at runtime when it is absent -- it
  # is simply inactive here. `reasoningEffortOverride = false`
  # (my.ai.agents.codex.reasoningEffortOverride, for openai/codex#44751)
  # stays inert for a second reason on 0.156.1: the `configuration_update`
  # problem now additionally gates on a per-model flag
  # (`supports_reasoning_effort_updates`) that no bundled model in 0.156.1
  # sets, not even gpt-6-astra.
  #
  # BUILD OUTCOME, MEASURED RATHER THAN ASSUMED: a full local build of this
  # override (2026-09-23, aarch64-darwin, `nix build --impure` against this
  # override directly) did NOT hit the "queries overflow the depth limit"
  # error above -- codex-chatgpt compiled cleanly, the whole workspace
  # finished in 28m44s, and `codex --version` reports `codex-cli 0.156.1`
  # with both `"gpt-6-sol"` and `"gpt-6-luna"` present in the binary's
  # embedded model catalog. This was NOT expected going in; the working
  # theory (not independently confirmed) is that this override still builds
  # against the OLDER rustc pulled in by the existing llm-agents-codex-pin
  # input's own locked nixpkgs (rev 6d96d0808, 2026-09-05) rather than
  # whatever newer rustc numtide's current CI resolves on `main` -- the
  # recursion-limit diagnostic is a compiler query-depth count, which can
  # genuinely shift between rustc releases for code sitting right at the
  # edge of the default 128 limit. Nothing here reintroduces or relies on
  # PR #9748's patch; no such patch was needed for this exact toolchain.
  # Re-verify this on the next `just update` of nixpkgs-llm-agents, since a
  # newer rustc reaching this pin's own nixpkgs could reintroduce the error.
  #
  # The version string and (eventually, once main catches up) the rev in
  # flake.nix belong together; the first assertion below enforces the
  # version half now. codex-acp stays on nixpkgs-llm-agents and is
  # overridden to use this codex in +agent-codex, same as before.
  codex-pin-version = "0.156.1";
  codex-pinned = system:
    inputs.llm-agents-codex-pin.packages.${system}.codex.override {
      version = codex-pin-version;
      # openai/codex, tag rust-v0.156.1, fetchFromGitHub source archive.
      # Self-computed 2026-09-23 via the lib.fakeHash-then-correct idiom,
      # fetching directly from https://github.com/openai/codex/archive/
      # refs/tags/rust-v0.156.1.tar.gz -- no third-party repackaging
      # involved. (It happens to equal the value PR #9748 also carries,
      # which is expected: both are the same official tarball's hash,
      # computed independently rather than copied from that PR.)
      hash = "sha256-H53f57hmnyCtn5yPxtBe/A92qyQyzQBeU/vK2qSBrvI=";
      # FOD of `cargo vendor` for that tag's Cargo.lock (codex-rs/Cargo.lock).
      # Self-computed the same way and on the same date as `hash` above, by
      # letting the real vendor step run and reading its reported hash --
      # again independently equal to what PR #9748 carries, not copied
      # from it.
      cargoVendor.cargoHash = "sha256-W87rX/W2J1pwqNrihX+Rj6DfagoZYuB6C+l/S4BhyJM=";
    };

in
{
  flake.modules.homeManager.agents = { config, pkgs, lib, ... }:
    let
      enabled = name: config.my.ai.agents.enable && config.my.ai.agents.${name}.enable;
      llm-agents = llm-agents-pkgs pkgs.stdenv.hostPlatform.system;
      claude-code = claude-code-pinned pkgs.stdenv.hostPlatform.system;
      codex = codex-pinned pkgs.stdenv.hostPlatform.system;
      loadSecretsLib = builtins.readFile ./_files/shell/load-secrets.sh;
      wrappers = {
        claude = pkgs.writeShellApplication {
          name = "+agent-claude";
          # The override is about the CLOSURE, not about behaviour. Both branches
          # below already point at /etc/profiles/…/bin/claude — the ACP branch by
          # exporting CLAUDE_CODE_EXECUTABLE over the `--set-default` baked into
          # claude-agent-acp, the interactive one by exec'ing it directly — so at
          # runtime the pinned binary was reached either way. But the store
          # REFERENCE survives that, and without this override it drags the old
          # claude-code into every generation: measured 2026-09-02, when the pin
          # was still 2.1.247, `nix store diff-closures` reported "claude-code:
          # 2.1.247 added" rather than an upgrade, and `nix why-depends` traced
          # the leftover through home-manager-path -> +agent-claude ->
          # claude-agent-acp -> claude-code-2.1.234. That is ~222 MB of second
          # copy per generation. The version numbers are the measurement's, not
          # today's; the mechanism is what the override addresses.
          runtimeInputs = [ (llm-agents.claude-agent-acp.override { claude-code = claude-code; }) ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              export CLAUDE_CODE_EXECUTABLE="/etc/profiles/per-user/''${USER}/bin/claude"
              shift
              exec claude-agent-acp --thinking-display summarized "$@"
            fi
            # Enables Claude Code's full-screen TUI mode
            # (https://code.claude.com/docs/en/fullscreen). The name CLAUDE_CODE_NO_FLICKER
            # is misleading: it unlocks the full-screen TUI, not merely "no flicker".
            # Interactive mode only — intentionally NOT set for ACP.
            export CLAUDE_CODE_NO_FLICKER=1
            exec "/etc/profiles/per-user/''${USER}/bin/claude" --thinking-display summarized "$@"
          '';
        };
        opencode = pkgs.writeShellApplication {
          name = "+agent-opencode";
          runtimeInputs = [ ];
          text = ''
            export DISABLE_AUTOUPDATER='1'
            ${loadSecretsLib}
            load_from_secret GEMINI_API_KEY      gemini_api_key
            load_from_secret OPENAI_API_KEY      openai_api_key
            load_from_secret OPENROUTER_API_KEY  openrouter_api_key
            load_from_secret Z_AI_API_KEY        z_ai_api_key
            require_secrets GEMINI_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY Z_AI_API_KEY
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              shift
              exec "/etc/profiles/per-user/''${USER}/bin/opencode" acp "$@"
            fi
            exec "/etc/profiles/per-user/''${USER}/bin/opencode" "$@"
          '';
        };
        codex = pkgs.writeShellApplication {
          name = "+agent-codex";
          # Same closure argument as the claude-agent-acp override above:
          # codex-acp bakes `CODEX_PATH ${lib.getExe codex}` into its wrapper, so
          # without the override the main input's codex (0.150.1 at the time of
          # the pin) would ride along as a second copy in every generation.
          # `exec codex` below reaches the pinned one through the profile.
          runtimeInputs = [ (llm-agents.codex-acp.override { inherit codex; }) ];
          text = ''
            ${loadSecretsLib}
            load_from_secret OPENAI_API_KEY openai_api_key
            require_secrets OPENAI_API_KEY
            ${config.my.ai.agents.codex.environmentScript}
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              shift
              exec codex-acp "$@"
            fi
            exec codex "$@"
          '';
        };
        gemini = pkgs.writeShellApplication {
          name = "+agent-gemini";
          runtimeInputs = [ llm-agents.gemini-cli ];
          text = ''
            ${loadSecretsLib}
            load_from_secret GEMINI_API_KEY gemini_api_key
            require_secrets GEMINI_API_KEY
            if (( $# > 0 )) && [[ "''${1}" == "--acp" ]]; then
              shift
              exec gemini --experimental-acp "$@"
            fi
            exec gemini "$@"
          '';
        };
        antigravity = pkgs.writeShellApplication {
          name = "+agent-antigravity";
          # Google's Antigravity CLI (`agy`), from llm-agents.nix. A prebuilt
          # binary off Google Cloud Storage, not npm -- which is why it is dated
          # against its GitHub releases in scripts/supply-chain.toml rather than
          # a registry. Licence is `unfree` there; like every other closure it
          # ends up in the R2 cache, see "The public cache mirrors system
          # closures" in AGENTS.md.
          runtimeInputs = [ llm-agents.antigravity-cli ];
          text = ''
            # The binary carries a statically linked self-updater that runs in
            # the background on ordinary invocations. It cannot write into
            # /nix/store and must not try; this is the documented opt-out
            # (antigravity.google/docs/cli/troubleshooting). Should an old run
            # ever leave the updater wedged, the lock it holds is
            # ~/.gemini/antigravity-cli/updater/update.lock.
            export AGY_CLI_DISABLE_AUTO_UPDATE=true
            ${loadSecretsLib}
            # Deliberately NOT require_secrets, unlike +agent-gemini: the default
            # sign-in is the Google account held in the macOS keychain, and per
            # the docs GEMINI_API_KEY is only consulted once
            # ~/.gemini/antigravity-cli/settings.json carries
            # `"modelProvider": "gemini"`. Loading it keeps that headless route
            # one settings key away without forcing the key on interactive use.
            # settings.json stays unmanaged -- agy writes to it.
            #
            # What IS managed lives elsewhere, at agy's global customization
            # root ~/.gemini/config/ (not ~/.gemini/antigravity-cli/, which is
            # the pre-migration layout the online docs still show): the skills
            # and MCP servers as the plugin ~/.gemini/config/plugins/nix-darwin
            # (modules/agent-integration.nix), the global rules as a managed block
            # in ~/.gemini/GEMINI.md (modules/agent-content.nix), which
            # +agent-gemini reads as well.
            load_from_secret GEMINI_API_KEY gemini_api_key
            # No `--acp` branch: neither the docs, the changelog nor llm-agents
            # know an ACP mode or an antigravity-acp shim (checked 2026-09-11).
            exec agy "$@"
          '';
        };
      };
    in
    {
      imports = [ aiOptions ];
      # These exist so the TEMPORARY pins (flake.nix, inputs
      # llm-agents-claude-code-pin and llm-agents-codex-pin) cannot fail quietly.
      # A pin that outlives its reason, or drifts away from the version everything
      # documents, is the failure class this repo keeps paying for elsewhere.
      # One pair per pin: rev matches the documented version, and the pin
      # removes itself once the main input catches up.
      assertions = lib.optionals (enabled "claude") [
        {
          # Tripwire against silent drift: bump the rev in flake.nix without
          # bumping the version here and you would get a different version than
          # the one flake.nix, this file and scripts/supply-chain.toml all name.
          assertion = claude-code.version == claude-code-pin-version;
          message = ''
            llm-agents-claude-code-pin ships claude-code ${claude-code.version},
            expected ${claude-code-pin-version}. The rev in flake.nix and this
            version string belong together -- one was moved without the other.
          '';
        }
        {
          # The pin removes itself instead of standing there forever.
          assertion = lib.versionOlder
            llm-agents.claude-code.version
            claude-code-pin-version;
          message = ''
            nixpkgs-llm-agents now ships claude-code
            ${llm-agents.claude-code.version} >= ${claude-code-pin-version}, so the
            pin has served its purpose. Remove it:
              1. drop the llm-agents-claude-code-pin input from flake.nix
              2. set `package = llm-agents.claude-code;` again below
              3. drop the "claude-code (pinned)" [[packages]] entry from
                 scripts/supply-chain.toml
              4. drop these two assertions and the claude-code-pin-version /
                 claude-code-pinned bindings at the top of this file
          '';
        }
      ] ++ lib.optionals (enabled "codex") [
        {
          assertion = codex.version == codex-pin-version;
          message = ''
            llm-agents-codex-pin ships codex ${codex.version}, expected
            ${codex-pin-version}. The rev in flake.nix and this version string
            belong together -- one was moved without the other.
          '';
        }
        {
          assertion = lib.versionOlder
            llm-agents.codex.version
            codex-pin-version;
          message = ''
            nixpkgs-llm-agents now ships codex ${llm-agents.codex.version} >=
            ${codex-pin-version}, so the pin has served its purpose. Remove it:
              1. drop the llm-agents-codex-pin input from flake.nix
              2. set `package = llm-agents.codex;` again below
              3. in this file, drop the codex-pinned binding and the
                 `.override { codex = … }` on codex-acp in +agent-codex
              4. drop the "codex (pinned)" [[packages]] entry from
                 scripts/supply-chain.toml
              5. drop these two assertions and the codex-pin-version /
                 codex-pinned bindings at the top of this file
          '';
        }
      ];

      programs.claude-code = lib.mkIf (enabled "claude") {
        enable = true;
        package = claude-code;
        settings = {
          # Opus for planning, Sonnet for execution.
          model = "opusplan";
          # No automatic attribution in commits or PRs.
          #
          # `attribution.commit = ""` replaces the deprecated `includeCoAuthoredBy`
          # ("Deprecated: Use attribution instead" in the settings schema). The two
          # are not additive: once `attribution` carries a `commit` or `pr` key,
          # MkS() stops consulting `includeCoAuthoredBy` altogether, because
          # pCs(e) = e.commit !== undefined || e.pr !== undefined. Leaving the old
          # key beside this block would be dead config that still reads as if it did
          # something. Same outcome either way: fCs(...) === "disabled".
          #
          # `sessionUrl = false` drops the "Claude-Session: https://claude.ai/code/..."
          # trailer and the matching link in PR bodies (anthropics/claude-code#77830).
          # That URL points straight at the account's session, so it is personal data
          # and has no business in the history of a public repository.
          #
          # Measured against claude-code 2.1.233, read out of the bundle:
          #   qMa(): if (env.CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION) return null;
          #          if (settings().attribution?.sessionUrl === false) return null;
          #   Ipt(): let e = MkS(), t = qMa(); if (!t) return e; return DkS(e, t.url)
          # One function feeds both the trailer and the "End git commit messages with"
          # line in the Bash tool's system prompt, so this removes the instruction as
          # well -- but only in sessions started after the switch. The issue reports
          # the key as ineffective; that was measured against an older version.
          #
          # The env var above is the equivalent gate and would work too. Deliberately
          # not set: one source per setting, as with every other credential path here.
          attribution = {
            commit = "";
            pr = "";
            sessionUrl = false;
          };
          # Default every session to "ultracode": xhigh reasoning effort + standing
          # dynamic-workflow orchestration. `ultracode` is a real persisted settings
          # key in claude-code (the resolver maps `settings.ultracode === true` to
          # xhigh effort and turns on standing workflow orchestration). It requires
          # workflows enabled and an xhigh-capable model (Opus 4.8 etc.). The
          # interactive `/effort` slider never writes this; a settings file does.
          # Set `enableWorkflows` explicitly since ultracode depends on it.
          ultracode = true;
          enableWorkflows = true;
          enabledPlugins = {
            "jdtls-lsp@claude-plugins-official" = true;
            "lua-lsp@claude-plugins-official" = true;
            "pyright-lsp@claude-plugins-official" = true;
            "rust-analyzer-lsp@claude-plugins-official" = true;
            "gopls-lsp@claude-plugins-official" = true;
            "pr-review-toolkit@claude-plugins-official" = true;
            "typescript-lsp@claude-plugins-official" = true;
            "frontend-design@claude-plugins-official" = true;
            "code-review@claude-plugins-official" = true;
            "commit-commands@claude-plugins-official" = true;
          };
          permissions = {
            defaultMode = "auto";
          };
          skipAutoPermissionPrompt = true;
          skipDangerousModePermissionPrompt = true;
          statusLine = {
            type = "command";
            command = "sh ~/.claude/statusline-command.sh";
          };
        };
      };

      programs.opencode = lib.mkIf (enabled "opencode") {
        enable = true;
        package = llm-agents.opencode;
        settings = {
          autoupdate = false;
        };
      };

      # No `programs.codex.settings` here: that would materialize
      # ~/.codex/config.toml as a read-only nix-store symlink, but Codex
      # must write to it (directory trust, model choice via
      # config/batchWrite). The managed part is merged into a regular
      # writable file by the integration aspect.
      programs.codex = lib.mkIf (enabled "codex") {
        enable = true;
        package = codex;
      };

      home.packages = lib.attrValues (lib.filterAttrs (name: _: enabled name) wrappers);
      home.file.".claude/statusline-command.sh" = lib.mkIf (enabled "claude") {
        source = ./ai/_files/statusline-command.sh;
      };
    };
}
