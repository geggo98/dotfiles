# Offline DevDocs (https://github.com/freeCodeCamp/devdocs) lookup: the
# `+devdocs` CLI plus its per-doc SQLite indices, all built at Nix BUILD
# TIME and pushed to the shared R2 cache like everything else this repo
# builds. Complements (does not replace) the `javadocs` MCP server in
# modules/mcp-servers.nix: DevDocs covers the JDK's own API plus Kotlin,
# Groovy, Scala, Spring Boot and ~830 non-JVM docs, but no arbitrary Maven
# artifact -- that stays the MCP server's job.
#
# Standalone aspect on its OWN namespace (`my.devdocs`, not `my.ai.devdocs`):
# ai-options.nix's `key = "nix-darwin-ai-options"` exists because four AI
# aspects read each other's settings (agent-integration reads
# my.ai.content.artifacts and my.ai.mcp.rendered). devdocs reads none of
# theirs and none of them reads devdocs -- it only sits next to the AI
# tooling because the SKILL it ships happens to live under
# modules/ai/_files/skills/devdocs/, which agent-content.nix already picks
# up with no registration needed. Precedent: modules/worktrunk.nix imports
# ai-options read-only without contributing to it; this module does not even
# need that much.
{ inputs, lib, ... }:
let
  families = import ./_files/devdocs/families.nix;
  lock = lib.importJSON ./_files/devdocs/docs.lock.json;
in
{
  flake.modules.homeManager.devdocs = { config, pkgs, lib, ... }:
    let
      cfg = config.my.devdocs;

      # Declared, not locked -- a family with no lock entry is a build
      # failure (see assertions below), never a silent skip. `resolved` is
      # the INTERSECTION on purpose: every `lock.docs.${name}` indexing
      # below assumes membership, and a lookup on a missing key throws
      # "attribute missing", a message naming neither the family nor the fix.
      # Taking the intersection keeps evaluation of the option itself
      # working (so `just devdocs-lock` can run and repair the lock) even
      # while `missing` is non-empty.
      declared = cfg.docs;
      lockedNames = lib.attrNames lock.docs;
      missing = lib.subtractLists lockedNames declared;
      stale = lib.subtractLists declared lockedNames;
      resolved = lib.filter (n: lock.docs ? ${n}) declared;
      badHash = lib.filter
        (n: !(lib.hasPrefix "sha256-" (lock.docs.${n}.hash or "")))
        resolved;
      # A hand-edited lock that pointed e.g. "kotlin" at a "scala~3" slug is
      # caught HERE, at eval time, rather than 80 MB into the wrong download.
      wrongFamily = lib.filter
        (n: let s = lock.docs.${n}.slug; in !(s == n || lib.hasPrefix "${n}~" s))
        resolved;

      # Store path names reject `~` (fetchurl's default `name` -- the URL
      # basename -- would otherwise fail at EVALUATION with "invalid
      # character in name"). Sanitise the NAME only; the URL keeps the
      # tilde, which is unreserved per RFC 3986. Every family in
      # families.nix uses only [a-z0-9_.~-], so this alone is sufficient.
      safeName = slug: lib.replaceStrings [ "~" ] [ "-" ] slug;

      buildIndexPy = pkgs.writeText "devdocs-build-index.py"
        (builtins.readFile ./_files/devdocs/build-index.py);
      devdocsPy = pkgs.writeText "devdocs-cli.py"
        (builtins.readFile ./_files/devdocs/devdocs-cli.py);

      mkDoc = name:
        let
          entry = lock.docs.${name};
          safe = safeName entry.slug;
          tarball = pkgs.fetchurl {
            name = "devdocs-${safe}.tar.gz";
            url = "https://downloads.devdocs.io/${entry.slug}.tar.gz";
            hash = entry.hash;
          };
        in
        pkgs.runCommand "devdocs-${safe}"
          {
            # pkgs.zstd ONLY for `zstd --train` -- a build-time CLI tool that
            # trains the zlib preset dictionary build-index.py compresses
            # with (see that file's module docstring for the measurement:
            # zlib+dict beats plain zlib/zstd/brotli without one, and very
            # nearly matches zstd+dict, for zero runtime dependencies). No
            # zstd runtime library is ever loaded, at build time or by
            # +devdocs -- decompression is stdlib zlib throughout.
            nativeBuildInputs = [ pkgs.python3 pkgs.zstd ];
            # Defaults deliberately left ALONE here -- the inverse of
            # agent-content.nix's rulesDir. A ~20 MB download plus a few
            # seconds of zlib -9 costs more than a substitution, and R2 is
            # the whole point: once one Mac has built and pushed a doc, the
            # other should never touch downloads.devdocs.io for it again --
            # see the "mtime is the only expiry signal" note in the
            # docs-lock recipe below, which is why that property matters
            # here specifically.
            passthru = { inherit (entry) slug release mtime; family = name; };
            meta.description = "Offline DevDocs index for ${entry.slug}";
          } ''
          mkdir -p "$out"
          python3 ${buildIndexPy} \
            --tarball ${tarball} \
            --slug ${lib.escapeShellArg entry.slug} \
            --family ${lib.escapeShellArg name} \
            --sqlite "$out/${safe}.sqlite"
        '';

      docs = map mkDoc resolved;

      # 39 `ln -s` (today) cost less than 39 narinfo round trips -- the same
      # trade-off as agent-content.nix's rulesDir, and the ONLY place in
      # this module that trade-off applies: the mkDoc derivations above stay
      # at the defaults (substitutable, not locally forced) on purpose.
      devdocsDir = pkgs.runCommand "devdocs-index"
        { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n"
          (d: let s = safeName d.slug; in ''ln -s ${d}/${s}.sqlite "$out/${s}.sqlite"'')
          docs}
        cp ${./_files/devdocs/catalog.json} "$out/catalog.json"
      '';

      # Same shape as mkZshScript in modules/nix-cache.nix (redefined
      # locally per module there too, e.g. modules/vscode.nix's comment
      # says so explicitly -- there is no shared helper to import).
      mkZshScript = name: text: pkgs.writeTextFile {
        inherit name;
        destination = "/bin/${name}";
        executable = true;
        text = ''
          #!${pkgs.zsh}/bin/zsh
          ${text}
        '';
      };

      devdocsCli = mkZshScript "+devdocs" ''
        # DEVDOCS_DIR is BAKED, not passed through: a launchd job or a
        # harness `Bash(...)` tool call inherits no shell environment at all
        # (AGENTS.md, "launchd jobs get no shell environment") -- a silent
        # default would report "no docs installed" while a real index sits
        # in the store. `''${VAR:-default}` still lets a caller override it
        # (used by the hermetic test below).
        export DEVDOCS_DIR="''${DEVDOCS_DIR:-${devdocsDir}}"
        export DEVDOCS_MAX_BYTES="''${DEVDOCS_MAX_BYTES:-${toString cfg.maxBytes}}"
        exec ${pkgs.python3}/bin/python3 ${devdocsPy} "$@"
      '';
    in
    {
      options.my.devdocs = {
        enable = lib.mkEnableOption "offline DevDocs index and the +devdocs CLI";

        docs = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[a-z0-9_.+-]+(~[a-z0-9_.+-]+)?");
          default = families;
          description = ''
            DevDocs families to install. A name with no `~` is a FAMILY:
            `just devdocs-lock` re-resolves it to the newest slug in
            https://devdocs.io/docs.json on every run (a bare slug if one
            exists, e.g. "node", otherwise the highest `<family>~*`,
            compared numerically). A name WITH `~` is a PIN and is never
            re-resolved. A declared family with no entry in
            modules/_files/devdocs/docs.lock.json is a build failure, never
            a silent skip.
          '';
        };

        maxBytes = lib.mkOption {
          type = lib.types.ints.positive;
          default = 32768;
          description = ''
            Byte cap on a rendered `+devdocs show`/`page` result before it is
            truncated for stdout (never applied to --output FILE/- or
            --format json). Overridable per-call via DEVDOCS_MAX_BYTES.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = (lock.schema or 0) == 1;
            message = ''
              modules/_files/devdocs/docs.lock.json has schema ${toString (lock.schema or 0)},
              this module reads schema 1. Regenerate it: just devdocs-lock
            '';
          }
          {
            assertion = missing == [ ];
            message = ''
              my.devdocs.docs declares families with no entry in
              modules/_files/devdocs/docs.lock.json: ${lib.concatStringsSep ", " missing}

              The lock is generated, never hand-written. Resolve and prefetch them:
                1. just devdocs-lock ${lib.concatStringsSep " " missing}
                2. git add -N modules/_files/devdocs/docs.lock.json   (if it is new)
                3. just build
            '';
          }
          {
            assertion = stale == [ ];
            message = ''
              modules/_files/devdocs/docs.lock.json still locks families that
              my.devdocs.docs no longer declares: ${lib.concatStringsSep ", " stale}
              A leftover entry keeps a multi-megabyte fetch alive for a doc
              nobody asked for. Drop them: just devdocs-lock --prune
            '';
          }
          {
            assertion = badHash == [ ];
            message = "modules/_files/devdocs/docs.lock.json entries without an "
              + "SRI sha256- hash: " + lib.concatStringsSep ", " badHash;
          }
          {
            assertion = wrongFamily == [ ];
            message = lib.concatMapStringsSep "\n"
              (n: "docs.lock.json: family '${n}' is locked to slug "
                + "'${lock.docs.${n}.slug}', which does not match the family "
                + "name or family+'~' prefix")
              wrongFamily;
          }
        ];

        home.packages = [ devdocsCli ];
      };
    };

  # Hermetic pipeline test (`just devdocs-check`): a synthetic tarball
  # through build-index.py, then the real 9 assertions in
  # modules/ai/_tests/test_devdocs_cli.py against the real +devdocs source.
  # NOT folded into checks.ai-composition (modules/ai-checks.nix) --
  # that check is about AI-aspect COMPOSITION, this one is a data pipeline
  # with its own, more compute-heavy build step (a real zlib pass over a
  # tarball), and the two are independent: folding them together would make
  # `just ai-check` pay for this every time with no benefit either way.
  # No network: the fixture is entirely synthetic, so `nix flake check`
  # (i.e. `just check`) never touches downloads.devdocs.io.
  #
  # Aspect independence (importing this module with `my.devdocs.enable` at
  # its default installs nothing) is NOT re-proven by an isolated check
  # here, unlike the four AI aspects in modules/ai-checks.nix. Two isolation
  # techniques were tried and both hit the same wall: a from-scratch
  # `home-manager.lib.homeManagerConfiguration` (modules/ai-checks.nix's own
  # `makeHome` helper) throws deep inside nixpkgs/home-manager's module
  # "transposition" handling on ANY sufficiently minimal config in this
  # flake's current pin -- reproduced even importing ZERO aspects, so it is
  # not specific to this module -- and a bare `lib.evalModules` bypass hit a
  # separate, unrelated parse error. The property itself is not in doubt:
  # `config = lib.mkIf cfg.enable { ... }` gates every side effect this
  # module has, exactly like the four aspects modules/ai-checks.nix does
  # check, and the real system build (`just build`) exercises this module
  # both enabled (both workstations, via home-manager-base.nix) and would
  # show the same "nothing installed" result if enable defaulted to false
  # there. Revisit if nixpkgs/home-manager's next bump fixes the underlying
  # crash -- try modules/ai-checks.nix's `makeHome (allAspects ++ [ hm.devdocs ]) { }`
  # again first; that construction is what broke, not hm.devdocs itself.
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
    in
    {
      checks.devdocs = pkgs.runCommand "devdocs-check"
        { nativeBuildInputs = [ pkgs.python3 pkgs.zstd ]; } ''
        export PYTHONDONTWRITEBYTECODE=1
        export HOME="$TMPDIR"
        cp ${./ai/_tests/devdocs_fixture.py} devdocs_fixture.py
        cp ${./ai/_tests/test_devdocs_cli.py} test_devdocs_cli.py
        cp ${./_files/devdocs/build-index.py} build-index.py
        cp ${./_files/devdocs/devdocs-cli.py} devdocs-cli.py
        # test_devdocs_cli.py locates build-index.py two directories up from
        # itself (mirroring the real repo layout, modules/ai/_tests/ ->
        # modules/_files/devdocs/); reproduce that relative shape here.
        mkdir -p modules/ai/_tests modules/_files/devdocs
        cp devdocs_fixture.py modules/ai/_tests/devdocs_fixture.py
        cp test_devdocs_cli.py modules/ai/_tests/test_devdocs_cli.py
        cp build-index.py modules/_files/devdocs/build-index.py
        python3 modules/ai/_tests/test_devdocs_cli.py devdocs-cli.py
        touch "$out"
      '';
    };
}
