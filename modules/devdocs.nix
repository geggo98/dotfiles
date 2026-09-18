# Offline API reference lookup: the `+devdocs` CLI plus its per-doc SQLite
# indices, all built at Nix BUILD TIME and pushed to the shared R2 cache like
# everything else this repo builds. Two source families feed the same schema
# and CLI:
#   - DevDocs (https://github.com/freeCodeCamp/devdocs) tarballs (`docs`,
#     modules/_files/devdocs/families.nix) -- the JDK's own API plus Kotlin,
#     Groovy, Scala, Spring Boot's reference guide, "Can I use" (as
#     `browser_support_tables`) and ~830 non-JVM docs in total.
#   - Doc sources built FROM UPSTREAM (`sources`, modules/_files/devdocs/
#     sources.nix): Maven Central javadoc jars for Apache Commons, JUnit 5,
#     Groovy's own Java API, and Spring Framework/Boot/Security/Data; the
#     Gradle docs archive; Valkey's command reference. Deliberately NOT
#     Zeal/Dash docsets -- see sources.nix's header comment for the licence
#     finding that ruled those out for this repo's PUBLIC R2 cache.
# Complements (does not replace) the `javadocs` MCP server in
# modules/mcp-servers.nix, which remains the only source for an arbitrary
# Maven artifact neither of the above carries.
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
  sourcesDecl = import ./_files/devdocs/sources.nix;
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

      # Same reconciliation, mirrored for my.devdocs.sources (schema 2's
      # "sources" object: Maven javadoc, the Gradle docs archive, Valkey
      # commands -- see modules/_files/devdocs/sources.nix and lock.py).
      # Kept as a SEPARATE parallel set, not merged into the `docs` set
      # above: the two populations have different shapes (a `sources` entry
      # has no `mtime`/`db_size`, and its own kind-specific fields), and
      # merging them would make every assertion message below have to
      # explain which shape it meant.
      declaredSrc = lib.attrNames cfg.sources;
      lockedSrc = lib.attrNames (lock.sources or { });
      missingSrc = lib.subtractLists lockedSrc declaredSrc;
      staleSrc = lib.subtractLists declaredSrc lockedSrc;
      resolvedSrc = lib.filter (n: (lock.sources or { }) ? ${n}) declaredSrc;
      badHashSrc = lib.filter
        (n: !(lib.hasPrefix "sha256-" (lock.sources.${n}.hash or "")))
        resolvedSrc;
      kindMismatch = lib.filter
        (n: lock.sources.${n}.kind != cfg.sources.${n}.kind)
        resolvedSrc;
      # The Maven-coordinate analogue of `wrongFamily` above: a hand-edited
      # lock pointing "commons-lang3" at some OTHER artifact's URL is caught
      # here, not 8 MB into the wrong jar.
      coordMismatch = lib.filter
        (n:
          let
            s = cfg.sources.${n};
            e = lock.sources.${n};
          in
          s.kind == "mavenJavadoc" && e.kind == "mavenJavadoc" &&
          !(lib.hasInfix "/${lib.replaceStrings [ "." ] [ "/" ] s.groupId}/${s.artifactId}/" e.url))
        resolvedSrc;
      # Third-party content needs an explicit, resolved licence before it can
      # enter this repo's PUBLIC, world-readable R2 cache (AGENTS.md, "This
      # repository is PUBLIC" and the third-party-data global rule) -- an
      # empty licence string is a build failure, not a silent "unknown".
      licenseMissing = lib.filter
        (n: cfg.sources.${n}.license == "" && !cfg.sources.${n}.licensePending)
        declaredSrc;
      # A source explicitly marked licensePending is STILL not built unless
      # its name is separately listed in allowLicensePending -- two files
      # have to agree, so a pending-licence family can never ship by editing
      # sources.nix alone. See that option's own description.
      pendingNotAllowed = lib.filter
        (n: cfg.sources.${n}.licensePending && !(lib.elem n cfg.allowLicensePending))
        declaredSrc;
      # installed_docs() in devdocs-cli.py keys every installed doc by
      # meta.slug, read from *.sqlite files globbed out of one flat
      # directory -- two docs (from either population, or one of each)
      # sharing a slug silently shadow each other with NO runtime error.
      allSlugs =
        (map (n: lock.docs.${n}.slug) resolved)
        ++ (map (n: cfg.sources.${n}.slug) resolvedSrc);
      duplicateSlugs = lib.subtractLists (lib.unique allSlugs) allSlugs;

      # Store path names reject `~` (fetchurl's default `name` -- the URL
      # basename -- would otherwise fail at EVALUATION with "invalid
      # character in name"). Sanitise the NAME only; the URL keeps the
      # tilde, which is unreserved per RFC 3986. Every family in
      # families.nix uses only [a-z0-9_.~-], so this alone is sufficient.
      safeName = slug: lib.replaceStrings [ "~" ] [ "-" ] slug;

      devdocsPy = pkgs.writeText "devdocs-cli.py"
        (builtins.readFile ./_files/devdocs/devdocs-cli.py);

      # One directory holding every builder script PLUS the two modules they
      # share (devdocs_sqlite.py's IndexWriter, javadoc_index.py's search-
      # index parser) -- `pkgs.writeText` can't do this, since a Python
      # `import` needs the sibling module to be a real file next to the
      # entry point, not a store path with an unrelated name. Every builder
      # below invokes its own script out of this one derivation.
      builders = pkgs.runCommand "devdocs-builders" { preferLocalBuild = true; } ''
        mkdir -p "$out"
        cp ${./_files/devdocs/devdocs_sqlite.py} "$out/devdocs_sqlite.py"
        cp ${./_files/devdocs/javadoc_index.py} "$out/javadoc_index.py"
        cp ${./_files/devdocs/build-index.py} "$out/build-index.py"
        cp ${./_files/devdocs/build-javadoc-index.py} "$out/build-javadoc-index.py"
        cp ${./_files/devdocs/build-redis-index.py} "$out/build-redis-index.py"
      '';

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
          python3 ${builders}/build-index.py \
            --tarball ${tarball} \
            --slug ${lib.escapeShellArg entry.slug} \
            --family ${lib.escapeShellArg name} \
            --sqlite "$out/${safe}.sqlite"
        '';

      docs = map mkDoc resolved;

      # Shared by BOTH new source kinds: mavenJavadoc and javadocUrl are both
      # a single immutable archive (a jar or a zip) at a known URL -- the
      # only difference is which Nix fetcher a caller already ran to get
      # that archive, which build-javadoc-index.py cannot see and does not
      # need to. `archive` is the fetched file; `subdir` is the path prefix
      # inside it (empty for a plain javadoc jar, "javadoc-api" for Spring
      # Framework's aggregated docs zip, etc.).
      mkJavadocDoc = name: archive: subdir:
        let
          entry = lock.sources.${name};
          src = cfg.sources.${name};
          safe = safeName src.slug;
        in
        pkgs.runCommand "javadoc-${safe}"
          {
            nativeBuildInputs = [ pkgs.python3 pkgs.zstd ];
            passthru = { inherit (src) slug license; inherit (entry) version; family = name; };
            meta.description = "Offline javadoc index for ${name} ${entry.version or "?"}";
          } ''
          mkdir -p "$out" "$out/licenses"
          python3 ${builders}/build-javadoc-index.py \
            --archive ${archive} \
            --subdir ${lib.escapeShellArg subdir} \
            --slug ${lib.escapeShellArg src.slug} \
            --family ${lib.escapeShellArg name} \
            --release ${lib.escapeShellArg (entry.version or "")} \
            --license ${lib.escapeShellArg src.license} \
            --license-url ${lib.escapeShellArg src.licenseUrl} \
            --attribution ${lib.escapeShellArg src.attribution} \
            --source-url ${lib.escapeShellArg entry.url} \
            --licenses-out "$out/licenses" \
            --sqlite "$out/${safe}.sqlite"
        '';

      mkMavenDoc = name:
        let
          entry = lock.sources.${name};
          tarball = pkgs.fetchurl {
            name = "javadoc-${safeName cfg.sources.${name}.slug}-${entry.version}.${entry.extension}";
            url = entry.url;
            hash = entry.hash;
          };
        in
        mkJavadocDoc name tarball (entry.subdir or cfg.sources.${name}.subdir or "");

      mkUrlDoc = name:
        let
          entry = lock.sources.${name};
          archive = pkgs.fetchurl {
            name = "javadoc-${safeName cfg.sources.${name}.slug}-${entry.version}-docs.zip";
            url = entry.url;
            hash = entry.hash;
          };
        in
        mkJavadocDoc name archive entry.subdir;

      # redisCommands is the one kind that needs an EXTRACTED tree rather
      # than an archive file -- build-redis-index.py walks commands/*.md and
      # topics/*.md directly, and a GitHub codeload tarball is not
      # byte-stable across requests the way Maven Central / services.gradle.
      # org are (hence hashMode="recursive" -> fetchzip, not fetchurl, in
      # lock.py's own comment on the point).
      mkRedisDoc = name:
        let
          entry = lock.sources.${name};
          src = cfg.sources.${name};
          safe = safeName src.slug;
          tree = pkgs.fetchzip {
            name = "redis-doc-${entry.commit}";
            url = entry.url;
            hash = entry.hash;
          };
        in
        pkgs.runCommand "redis-doc-${safe}"
          {
            # zstd for IndexWriter.finish()'s preset-dictionary training
            # (devdocs_sqlite.py, shared with every other builder) --
            # markdown for build-redis-index.py's Markdown->HTML conversion,
            # a build-time-only dependency the same way zstd is.
            nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.markdown ])) pkgs.zstd ];
            passthru = { inherit (src) slug license; inherit (entry) commit; family = name; };
            meta.description = "Offline command reference for ${name} (${entry.commit})";
          } ''
          mkdir -p "$out" "$out/licenses"
          python3 ${builders}/build-redis-index.py \
            --tree ${tree} \
            --slug ${lib.escapeShellArg src.slug} \
            --family ${lib.escapeShellArg name} \
            --commit ${lib.escapeShellArg entry.commit} \
            --license ${lib.escapeShellArg src.license} \
            --license-url ${lib.escapeShellArg src.licenseUrl} \
            --attribution ${lib.escapeShellArg src.attribution} \
            --source-url ${lib.escapeShellArg entry.url} \
            --licenses-out "$out/licenses" \
            --sqlite "$out/${safe}.sqlite"
        '';

      mkSourceDoc = name:
        {
          mavenJavadoc = mkMavenDoc name;
          javadocUrl = mkUrlDoc name;
          redisCommands = mkRedisDoc name;
        }.${cfg.sources.${name}.kind};

      # A source with licensePending=true and no matching
      # allowLicensePending entry never reaches here: the pendingNotAllowed
      # assertion below fails the WHOLE build first. So by the time
      # sourceDocs is forced, every name in resolvedSrc is both locked AND
      # cleared to build -- no separate "buildable" filter needed.
      sourceDocs = map mkSourceDoc resolvedSrc;

      # ~80 `ln -s` (today, across both `docs` and `sourceDocs`) cost less
      # than ~80 narinfo round trips -- the same trade-off as
      # agent-content.nix's rulesDir, and the ONLY place in this module that
      # trade-off applies: the mkDoc/mkSourceDoc derivations above stay at
      # the defaults (substitutable, not locally forced) on purpose.
      devdocsDir = pkgs.runCommand "devdocs-index"
        { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p "$out" "$out/LICENSES"
        ${lib.concatMapStringsSep "\n"
          (d: let s = safeName d.slug; in ''ln -s ${d}/${s}.sqlite "$out/${s}.sqlite"'')
          docs}
        ${lib.concatMapStringsSep "\n"
          (d: let s = safeName d.slug; in ''
            ln -s ${d}/${s}.sqlite "$out/${s}.sqlite"
            mkdir -p "$out/LICENSES/${s}"
            if [ -d ${d}/licenses ]; then ln -s ${d}/licenses/* "$out/LICENSES/${s}/" 2>/dev/null || true; fi
          '')
          sourceDocs}
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

        sources = lib.mkOption {
          default = sourcesDecl;
          description = ''
            Non-DevDocs doc sources, built FROM UPSTREAM (never from a
            Zeal/Dash docset -- see modules/_files/devdocs/sources.nix's
            header comment for why). `just devdocs-lock --kind <kind>`
            resolves each to docs.lock.json's "sources" object; a declared
            source with no lock entry is a build failure, never a silent
            skip -- exactly like `docs` above.
          '';
          type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
            options = {
              kind = lib.mkOption {
                type = lib.types.enum [ "mavenJavadoc" "javadocUrl" "redisCommands" ];
                description = "Which builder/fetcher this source uses -- see sources.nix's header comment.";
              };
              slug = lib.mkOption {
                type = lib.types.strMatching "[a-z0-9][a-z0-9_.+-]*";
                default = name;
                description = "The +devdocs doc id. Must be unique across every DevDocs slug too.";
              };
              license = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "SPDX identifier. Empty is a build failure unless licensePending is set.";
              };
              licenseUrl = lib.mkOption { type = lib.types.str; default = ""; };
              attribution = lib.mkOption { type = lib.types.str; default = ""; };
              licensePending = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  This source's licence has NOT been resolved as clearly
                  redistributable. It will not build even with this set --
                  see allowLicensePending, which additionally must name it.
                '';
              };

              # kind = "mavenJavadoc"
              groupId = lib.mkOption { type = lib.types.str; default = ""; };
              artifactId = lib.mkOption { type = lib.types.str; default = ""; };
              classifier = lib.mkOption { type = lib.types.str; default = "javadoc"; };
              extension = lib.mkOption { type = lib.types.enum [ "jar" "zip" ]; default = "jar"; };
              track = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Version-line prefix (e.g. \"5.\") that `just devdocs-lock` may not cross -- the `~pin` analogue for a Maven artifact.";
              };

              # kind = "javadocUrl"
              urlTemplate = lib.mkOption { type = lib.types.str; default = ""; };
              subdirTemplate = lib.mkOption { type = lib.types.str; default = ""; };
              versionFrom = lib.mkOption { type = lib.types.enum [ "" "gradleService" ]; default = ""; };

              # kind = "mavenJavadoc" (aggregated archive) or "javadocUrl"
              subdir = lib.mkOption { type = lib.types.str; default = ""; };

              # kind = "redisCommands"
              repo = lib.mkOption { type = lib.types.str; default = ""; };
              ref = lib.mkOption { type = lib.types.str; default = "main"; };
            };
          }));
        };

        allowLicensePending = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Source names whose `licensePending = true` is knowingly accepted
            for THIS build. Deliberately a separate list from sources.nix's
            own `licensePending` flag, so a pending-licence source can never
            start shipping by editing one file -- per this repo's own
            "third-party content needs explicit clearance every time" rule
            (AGENTS.md, "This repository is PUBLIC"), this list is the
            record that clearance was actually given, not merely declared.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = (lock.schema or 0) == 2;
            message = ''
              modules/_files/devdocs/docs.lock.json has schema ${toString (lock.schema or 0)},
              this module reads schema 2. Regenerate it: just devdocs-lock
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
          {
            assertion = missingSrc == [ ];
            message = ''
              my.devdocs.sources declares sources with no entry in
              modules/_files/devdocs/docs.lock.json: ${lib.concatStringsSep ", " missingSrc}

              Resolve and prefetch them:
                1. just devdocs-lock ${lib.concatStringsSep " " missingSrc}
                2. git add -N modules/_files/devdocs/docs.lock.json   (if it is new)
                3. just build
            '';
          }
          {
            assertion = staleSrc == [ ];
            message = ''
              modules/_files/devdocs/docs.lock.json still locks sources that
              my.devdocs.sources no longer declares: ${lib.concatStringsSep ", " staleSrc}
              Drop them: just devdocs-lock --prune
            '';
          }
          {
            assertion = badHashSrc == [ ];
            message = "modules/_files/devdocs/docs.lock.json 'sources' entries without an "
              + "SRI sha256- hash: " + lib.concatStringsSep ", " badHashSrc;
          }
          {
            assertion = kindMismatch == [ ];
            message = lib.concatMapStringsSep "\n"
              (n: "docs.lock.json: source '${n}' is locked as kind "
                + "'${lock.sources.${n}.kind}', but sources.nix now declares kind "
                + "'${cfg.sources.${n}.kind}' -- re-lock: just devdocs-lock ${n}")
              kindMismatch;
          }
          {
            assertion = coordMismatch == [ ];
            message = lib.concatMapStringsSep "\n"
              (n: "docs.lock.json: source '${n}' is locked to a URL that does not "
                + "contain the Maven coordinate "
                + "'${cfg.sources.${n}.groupId}:${cfg.sources.${n}.artifactId}' declared in "
                + "sources.nix -- re-lock: just devdocs-lock ${n}")
              coordMismatch;
          }
          {
            assertion = licenseMissing == [ ];
            message = ''
              modules/_files/devdocs/sources.nix declares sources with no
              licence and licensePending is not set:
              ${lib.concatStringsSep ", " licenseMissing}

              Every non-DevDocs source needs an explicit SPDX `license`
              before it can enter this repo's PUBLIC R2 cache. If the
              licence is genuinely unresolved, set `licensePending = true`
              and add the name to my.devdocs.allowLicensePending once it has
              been explicitly cleared -- it still will not build without that.
            '';
          }
          {
            assertion = pendingNotAllowed == [ ];
            message = ''
              These sources.nix entries have `licensePending = true` but are
              not in my.devdocs.allowLicensePending, so they are declared but
              cannot build: ${lib.concatStringsSep ", " pendingNotAllowed}

              This repository is PUBLIC and its R2 cache is world-readable
              (AGENTS.md). Third-party content needs EXPLICIT clearance,
              re-asked every time -- get that clearance, then add the name to
              my.devdocs.allowLicensePending. Until then this is not a bug,
              it is the gate working.
            '';
          }
          {
            assertion = duplicateSlugs == [ ];
            message = ''
              These doc slugs would be installed by more than one source
              (DevDocs family or my.devdocs.sources entry):
              ${lib.concatStringsSep ", " duplicateSlugs}
              +devdocs keys every installed doc by its slug and would
              silently serve only one of them -- rename one side's `slug`.
            '';
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
      # withPackages markdown -- build-redis-index.py's one runtime
      # dependency (see that file's module docstring: a build-time-only
      # tool, the same "not a +devdocs runtime dependency" shape as zstd for
      # the preset-dictionary trainer). The test invokes every builder via
      # `sys.executable`, so the interpreter running the test suite itself
      # must be the one carrying it.
      checkPython = pkgs.python3.withPackages (ps: [ ps.markdown ]);
    in
    {
      checks.devdocs = pkgs.runCommand "devdocs-check"
        { nativeBuildInputs = [ checkPython pkgs.zstd ]; } ''
        export PYTHONDONTWRITEBYTECODE=1
        export HOME="$TMPDIR"
        cp ${./ai/_tests/devdocs_fixture.py} devdocs_fixture.py
        cp ${./ai/_tests/javadoc_fixture.py} javadoc_fixture.py
        cp ${./ai/_tests/redis_fixture.py} redis_fixture.py
        cp ${./ai/_tests/test_devdocs_cli.py} test_devdocs_cli.py
        cp ${./_files/devdocs/devdocs_sqlite.py} devdocs_sqlite.py
        cp ${./_files/devdocs/javadoc_index.py} javadoc_index.py
        cp ${./_files/devdocs/build-index.py} build-index.py
        cp ${./_files/devdocs/build-javadoc-index.py} build-javadoc-index.py
        cp ${./_files/devdocs/build-redis-index.py} build-redis-index.py
        cp ${./_files/devdocs/devdocs-cli.py} devdocs-cli.py
        # test_devdocs_cli.py locates the builders two directories up from
        # itself (mirroring the real repo layout, modules/ai/_tests/ ->
        # modules/_files/devdocs/); reproduce that relative shape here. Every
        # builder needs devdocs_sqlite.py/javadoc_index.py as a SIBLING file
        # (a plain `import`, not a package), hence the same directory.
        mkdir -p modules/ai/_tests modules/_files/devdocs
        cp devdocs_fixture.py javadoc_fixture.py redis_fixture.py test_devdocs_cli.py modules/ai/_tests/
        cp devdocs_sqlite.py javadoc_index.py build-index.py build-javadoc-index.py \
           build-redis-index.py modules/_files/devdocs/
        python3 modules/ai/_tests/test_devdocs_cli.py devdocs-cli.py
        touch "$out"
      '';
    };
}
