# Non-DevDocs doc sources for `modules/devdocs.nix` (`my.devdocs.sources`),
# built FROM UPSTREAM at Nix build time -- the same pattern
# modules/_files/devdocs/families.nix already uses for DevDocs itself.
# Resolved/hashed by `just devdocs-lock --kind <kind>` into docs.lock.json's
# "sources" object (schema 2); never hand-edit a hash or version here.
#
# Zeal/Dash docsets are NOT a source here, by licence. Kapeli's feeds
# repository (github.com/Kapeli/feeds, README.md) states that the docsets may
# be used "for personal reasons or while using Dash or Zeal" and NOT in "any
# third-party application, online or offline". This repo's builds land in a
# PUBLIC, world-readable R2 bucket (modules/nix-cache.nix), which is squarely
# outside that. Every family below is therefore built from each project's OWN
# upstream instead -- Maven Central javadoc jars (immutable once published,
# sha1-checked, better pinning than DevDocs' own tarballs), the Gradle docs
# archive, and the Valkey documentation repository.
#
# The `# Zeal:` comments below are informational cross-references ONLY, for a
# human browsing this file who has the corresponding docset open in Zeal and
# wants to know whether an offline equivalent exists here -- no byte of
# content is taken from them.
#
# `kind = "mavenJavadoc"`: a plain javadoc jar (classifier "javadoc",
# extension "jar" -- the defaults, so most entries omit both) or an
# aggregated "docs" archive (Spring Framework/Boot, classifier/extension/
# subdir given explicitly). `track` pins a version-line PREFIX so
# `just devdocs-lock` cannot silently jump a family across a major version
# nobody asked for (see the junit-jupiter-api/junit-platform-launcher
# entries below for why this matters).
#
# `kind = "javadocUrl"`: a live, VERSIONED archive URL with no Maven
# coordinates (Gradle only -- services.gradle.org is not a Maven repository).
#
# `kind = "redisCommands"`: a valkey-doc-shaped source tree (commands/*.md +
# topics/*.md). See build-redis-index.py's module docstring for exactly what
# this parses and what it deliberately does NOT attempt to replicate
# (per-command group metadata, which valkey-doc no longer ships as its own
# commands.json).
{
  # --- Apache Commons (Apache-2.0), the actively-maintained components ---
  # Zeal: "Apache Commons" (user-contributed) covers only 5 of these (Lang,
  # Collections, Math, CSV, Text), each version-behind, and has NO docset at
  # all for Commons IO or Codec -- the two most used. commons-math3 and
  # commons-digester3 are excluded here: their current released javadoc
  # predates JEP 225 (2016 and 2011 respectively) and carries no
  # member-search-index.js, which build-javadoc-index.py refuses to build an
  # index from silently.
  commons-lang3 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-lang3";
    track = "3.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Lang, The Apache Software Foundation";
  }; # Zeal: "Apache Commons Lang" (user-contributed, stale)
  commons-io = {
    kind = "mavenJavadoc";
    groupId = "commons-io";
    artifactId = "commons-io";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons IO, The Apache Software Foundation";
  };
  commons-collections4 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-collections4";
    track = "4.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Collections, The Apache Software Foundation";
  }; # Zeal: "Apache Commons Collections" (user-contributed, stale)
  commons-text = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-text";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Text, The Apache Software Foundation";
  }; # Zeal: "Apache Commons Text" (user-contributed, stale)
  commons-codec = {
    kind = "mavenJavadoc";
    groupId = "commons-codec";
    artifactId = "commons-codec";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Codec, The Apache Software Foundation";
  };
  commons-csv = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-csv";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons CSV, The Apache Software Foundation";
  }; # Zeal: "Apache Commons CSV" (user-contributed, stale)
  commons-compress = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-compress";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Compress, The Apache Software Foundation";
  };
  commons-cli = {
    kind = "mavenJavadoc";
    groupId = "commons-cli";
    artifactId = "commons-cli";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons CLI, The Apache Software Foundation";
  };
  commons-net = {
    kind = "mavenJavadoc";
    groupId = "commons-net";
    artifactId = "commons-net";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Net, The Apache Software Foundation";
  };
  commons-pool2 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-pool2";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Pool, The Apache Software Foundation";
  };
  commons-dbcp2 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-dbcp2";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons DBCP, The Apache Software Foundation";
  };
  commons-configuration2 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-configuration2";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Configuration, The Apache Software Foundation";
  };
  commons-validator = {
    kind = "mavenJavadoc";
    groupId = "commons-validator";
    artifactId = "commons-validator";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Validator, The Apache Software Foundation";
  };
  commons-beanutils = {
    kind = "mavenJavadoc";
    groupId = "commons-beanutils";
    artifactId = "commons-beanutils";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons BeanUtils, The Apache Software Foundation";
  };
  commons-exec = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-exec";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons Exec, The Apache Software Foundation";
  };
  commons-vfs2 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-vfs2";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons VFS, The Apache Software Foundation";
  };
  commons-jexl3 = {
    kind = "mavenJavadoc";
    groupId = "org.apache.commons";
    artifactId = "commons-jexl3";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons JEXL, The Apache Software Foundation";
  };
  commons-fileupload = {
    kind = "mavenJavadoc";
    groupId = "commons-fileupload";
    artifactId = "commons-fileupload";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Commons FileUpload, The Apache Software Foundation";
  };
  # commons-numbers-core, commons-rng-client-api and commons-statistics-
  # distribution are EXCLUDED, for the same underlying reason as
  # commons-math3/commons-digester3 above, one generation further back:
  # their current released javadoc (commons-numbers-core:1.3, measured
  # 2026-09) already carries a JEP-225 search index, but its HTML predates
  # javadoc's semantic <section class="detail" id="..."> markup -- members
  # are marked by a bare, essentially empty `<a id="EPSILON">` immediately
  # followed by SIBLING content, not a container the id itself wraps.
  # javadoc_index.py's kind-detection now understands this shape (see
  # LEGACY_DETAIL_MARKERS), but devdocs-cli.py's `_AnchorExtractor` --
  # deliberately conservative, shared with every other doc in this index --
  # does not yet have a third extraction mode for it, so a member-scoped
  # `show` would resolve the anchor and kind correctly and then render an
  # EMPTY body. Building these would ship docs that look installed and
  # correct until the exact member lookup someone actually wants.

  # --- JUnit 5 (EPL-2.0) ---
  # Zeal: "JUnit5" (user-contributed) is frozen at 5.5.2 (2019); upstream has
  # since unified Jupiter/Platform onto a shared 6.x version line, which
  # `track` deliberately holds back from -- the user asked for JUnit 5.
  junit-jupiter-api = {
    kind = "mavenJavadoc";
    groupId = "org.junit.jupiter";
    artifactId = "junit-jupiter-api";
    track = "5.";
    license = "EPL-2.0";
    licenseUrl = "https://www.eclipse.org/legal/epl-2.0/";
    attribution = "JUnit 5, JUnit Team";
  }; # Zeal: "JUnit5" (user-contributed, stale)
  junit-jupiter-params = {
    kind = "mavenJavadoc";
    groupId = "org.junit.jupiter";
    artifactId = "junit-jupiter-params";
    track = "5.";
    license = "EPL-2.0";
    licenseUrl = "https://www.eclipse.org/legal/epl-2.0/";
    attribution = "JUnit 5, JUnit Team";
  };
  junit-platform-launcher = {
    kind = "mavenJavadoc";
    groupId = "org.junit.platform";
    artifactId = "junit-platform-launcher";
    track = "1.";
    license = "EPL-2.0";
    licenseUrl = "https://www.eclipse.org/legal/epl-2.0/";
    attribution = "JUnit 5, JUnit Team";
  };
  junit-platform-suite-api = {
    kind = "mavenJavadoc";
    groupId = "org.junit.platform";
    artifactId = "junit-platform-suite-api";
    track = "1.";
    license = "EPL-2.0";
    licenseUrl = "https://www.eclipse.org/legal/epl-2.0/";
    attribution = "JUnit 5, JUnit Team";
  };

  # --- Groovy (Apache-2.0) ---
  # Distinct slug from the existing DevDocs `groovy` family (GroovyDoc/GDK
  # docs, frozen at 4.0.0) -- this is the plain Java API javadoc at a current
  # 5.x, complementary rather than a duplicate.
  groovy-api = {
    kind = "mavenJavadoc";
    groupId = "org.apache.groovy";
    artifactId = "groovy";
    track = "5.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Apache Groovy, The Apache Software Foundation";
  };

  # --- Spring (Apache-2.0) ---
  # Zeal's official feed has "Spring_Framework" fresh (it is one of the few
  # official docsets relevant here) -- still not used, per the licence
  # finding above. Spring Framework and Spring Boot each publish ONE
  # aggregated javadoc archive on Maven Central covering every module, so
  # each is a single family here, not one per module. Spring Security and
  # Spring Data publish no such aggregate, so those go per-module.
  spring-framework-api = {
    kind = "mavenJavadoc";
    groupId = "org.springframework";
    artifactId = "framework-api";
    classifier = "docs";
    extension = "zip";
    subdir = "javadoc-api";
    track = "7.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Framework, VMware/Broadcom and contributors";
  }; # Zeal: "Spring_Framework" (official feed, fresh -- see modules/devdocs.nix comment on why not used anyway)
  spring-boot-api = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.boot";
    artifactId = "spring-boot-docs";
    classifier = "api-catalog-content";
    extension = "zip";
    subdir = "java";
    track = "4.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Boot, VMware/Broadcom and contributors";
  }; # Zeal: "Spring_Boot" (user-contributed, stale). The existing DevDocs
  # `spring_boot` family (frozen at 3.1.3, the REFERENCE GUIDE not javadoc)
  # stays as the 3.x fallback -- spring-boot-docs's api-catalog-content
  # classifier only exists from Boot 4.0.8 onward. Different slugs, no clash.
  spring-security-core = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.security";
    artifactId = "spring-security-core";
    track = "7.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Security, VMware/Broadcom and contributors";
  };
  spring-security-web = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.security";
    artifactId = "spring-security-web";
    track = "7.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Security, VMware/Broadcom and contributors";
  };
  spring-security-config = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.security";
    artifactId = "spring-security-config";
    track = "7.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Security, VMware/Broadcom and contributors";
  };
  spring-security-oauth2-client = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.security";
    artifactId = "spring-security-oauth2-client";
    track = "7.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Security, VMware/Broadcom and contributors";
  };
  spring-security-test = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.security";
    artifactId = "spring-security-test";
    track = "7.";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Security, VMware/Broadcom and contributors";
  };
  spring-data-commons = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.data";
    artifactId = "spring-data-commons";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Data, VMware/Broadcom and contributors";
  };
  spring-data-jpa = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.data";
    artifactId = "spring-data-jpa";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Data, VMware/Broadcom and contributors";
  };
  spring-data-mongodb = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.data";
    artifactId = "spring-data-mongodb";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Data, VMware/Broadcom and contributors";
  };
  spring-data-redis = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.data";
    artifactId = "spring-data-redis";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Data, VMware/Broadcom and contributors";
  };
  spring-data-jdbc = {
    kind = "mavenJavadoc";
    groupId = "org.springframework.data";
    artifactId = "spring-data-jdbc";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Spring Data, VMware/Broadcom and contributors";
  };

  # --- Gradle (Apache-2.0) ---
  # Fills a gap DevDocs never had at all, despite this repo carrying
  # Gradle-specific agent rules. services.gradle.org is not a Maven
  # repository, hence `javadocUrl` rather than `mavenJavadoc`.
  gradle = {
    kind = "javadocUrl";
    urlTemplate = "https://services.gradle.org/distributions/gradle-@version@-docs.zip";
    subdirTemplate = "gradle-@version@/docs/javadoc";
    versionFrom = "gradleService";
    license = "Apache-2.0";
    licenseUrl = "https://www.apache.org/licenses/LICENSE-2.0";
    attribution = "Gradle, Gradle Inc.";
  }; # Zeal: "Gradle_Java_API" / "Gradle_DSL" / "Gradle_User_Guide" (official feed)

  # --- Valkey (CC-BY-SA-4.0) ---
  # The user's chosen replacement for MySQL-via-Zeal (blocked: Zeal has no
  # usable MySQL docset either, and Oracle's own MySQL Reference Manual is
  # explicitly "NOT distributed under a GPL license") AND for the stale
  # DevDocs `redis` family (7.0.10, 2023): redis-doc's CC-BY-SA-4.0 content
  # is frozen since the repo was archived (2025-06-23), and its successor
  # (redis/docs) switched to CC-BY-NC-SA-4.0 -- NonCommercial, blocked for a
  # repo carrying work config. valkey-io/valkey-doc is CC-BY-SA-4.0, actively
  # maintained, and Valkey is a drop-in Redis command-set fork.
  #
  # licensePending is NOT set -- CC-BY-SA-4.0 is a resolved, redistributable
  # licence (verbatim in the repo's own LICENSE file; GitHub's own metadata
  # reports NOASSERTION only because it lacks an SPDX header, not because
  # the terms are unclear).
  valkey-commands = {
    kind = "redisCommands";
    repo = "valkey-io/valkey-doc";
    ref = "main";
    license = "CC-BY-SA-4.0";
    licenseUrl = "https://creativecommons.org/licenses/by-sa/4.0/";
    attribution = "Valkey documentation contributors";
  };
}
