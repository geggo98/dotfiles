Applies to: all (any OS, any JDK from 12; the dynamic archive from JDK 13, `AutoCreateSharedArchive` from JDK 19)

# Class Data Sharing (CDS) and AppCDS

TL;DR: CDS stores parsed classes in an archive file that the JVM maps at start. The JDK ships a
default archive for its own classes, and it is on by default. A dynamic AppCDS archive adds the
application's classes. On the reference app (a Spring Boot demo, setup in
[measuring.md](measuring.md), section 9), a dynamic archive on the fat JAR cut the start by 13 %,
about the same as extracting the fat JAR; on the extracted JAR it cut 32 % in a second session. On JDK
25 and later (**open inconsistency:** [SKILL.md](../SKILL.md) and the bullet "The JDK is older than 24" below use JDK 24 as the boundary), prefer the AOT cache ([leyden-aot.md](leyden-aot.md)): it cut the start by 52 % on the
same app. A stale archive is skipped without an error, and `AutoCreateSharedArchive` did not refresh it
in the measurement, so verify that it is used.

## Contents

- [1. What CDS stores](#1-what-cds-stores)
- [2. Default CDS](#2-default-cds)
- [3. Dynamic AppCDS archive](#3-dynamic-appcds-archive)
- [4. AutoCreateSharedArchive](#4-autocreatesharedarchive)
- [5. Stale archives fall back silently](#5-stale-archives-fall-back-silently)
- [6. Verify that the archive is used](#6-verify-that-the-archive-is-used)
- [7. Numbers](#7-numbers)
- [8. When to use CDS instead of the AOT cache](#8-when-to-use-cds-instead-of-the-aot-cache)

## 1. What CDS stores

A CDS archive holds class metadata in the form the JVM uses in memory. At start, the JVM maps the
archive instead of reading, parsing and verifying each class file. The archive does not hold
compiled code. It does not hold the application's heap state.

The AOT cache of JDK 24 and later ([leyden-aot.md](leyden-aot.md)) is built on the same format. It
adds linked classes, method profiles and, from JDK 28, compiled code.

## 2. Default CDS

The JDK ships an archive of its own core classes, and `-Xshare:auto` (the default) uses it since
JDK 12 (reported, docs). You get it without any flag. Which docs page each "(reported, docs)" in
this file refers to was not recorded.

`-Xshare` has three values (reported, docs):

| Value | Behaviour |
|---|---|
| `auto` (default) | uses the archive if it can be mapped, otherwise starts without it |
| `on` | fails the start if the archive cannot be used; documented "for testing only" |
| `off` | no archive |

Do not set `-Xshare:off` in production: it gives up the default archive.

## 3. Dynamic AppCDS archive

A dynamic archive adds the classes the application loaded during one run. Create it at the end of a
training run, then use it:

```bash
# training: the archive is written when the JVM exits
java -XX:ArchiveClassesAtExit=app.jsa -Dspring.context.exit=onRefresh -jar app.jar
# production
java -XX:SharedArchiveFile=app.jsa -jar app.jar
```

`-Dspring.context.exit=onRefresh` makes Spring Framework 7 exit after the context refresh: all
non-lazy singletons exist, but no lifecycle bean has started (reported, Spring docs). Without a
framework flag, end the training run yourself after the app is ready, for example with SIGTERM.

The Spring Boot recipe extracts the fat JAR first (reported, Spring Boot docs):

```bash
java -Djarmode=tools -jar my-app.jar extract --destination application
cd application
java -XX:ArchiveClassesAtExit=application.jsa -Dspring.context.exit=onRefresh -jar my-app.jar
java -XX:SharedArchiveFile=application.jsa -jar my-app.jar
```

**Conflict:** the Spring Boot docs say the archive has no effect with an unextracted fat JAR. On the
reference app, a dynamic archive with the fat JAR cut the start from 1212 to 1050 ms, 13 % (fresh
measurement, setup in [measuring.md §9](measuring.md#9-reference-setup-of-the-fresh-measurement); see
§7). On the extracted JAR, a dynamic archive cut the start by 32 % in a second session: a separate
series on the same Mac, JDK and day (§7, second table).

The dynamic archive builds on top of the JDK's default archive. A JDK built without a default
archive, or a different JDK build, cannot use it (reported, docs).

## 4. AutoCreateSharedArchive

From JDK 19, the JVM can create and refresh the dynamic archive itself:

```bash
java -XX:+AutoCreateSharedArchive -XX:SharedArchiveFile=app.jsa -jar app.jar
```

The first run writes `app.jsa` at exit. Later runs use it. If the archive is missing, stale or
damaged, the JVM writes a new one at exit (reported, docs). The flag works only together with
`-XX:SharedArchiveFile` and only with `-Xshare:auto`.

Two costs follow from the mechanism:

- The first start after each deployment runs without the archive, and pays for the dump at exit.
- The archive file must be writable at run time. In a container with a read-only root file system,
  put it on a writable volume, or create it at build time instead.

On the reference app, the first run took 1.6 s including the dump; the second run with the archive
took 1100 ms (fresh measurement).

**Do not rely on the refresh.** After a `touch` on `app.jar`, the JVM did not rewrite the stale archive
in six further runs, five normal ones and one that exited cleanly through
`-Dspring.context.exit=onRefresh`: the `.jsa` kept its modification time, and every start stayed at
the cold level of about 1160 ms (fresh Mac, second session, §7). The documented behaviour says it
should refresh; the reason was not found. Rule: rebuild the archive explicitly whenever the JARs or
the JDK change. Limit: one JDK build (Temurin 25.0.5) on macOS; other builds or Linux can behave
differently.

## 5. Stale archives fall back silently

**Rule:** treat an archive like a build artifact that belongs to exactly one JDK build and one
class path. Rebuild it when either changes.

**Reason:** the JVM checks the JDK build and the class path recorded in the archive. When they do not
match, `-Xshare:auto` starts without the archive. For the dynamic archive, the JVM falls back to the
default archive (reported, JEP 350). The start succeeds, the exit code is 0, and the app is just
slower.

The AOT cache behaves the same way, and there it is measured: after `touch` on one JAR the JVM printed
a warning, ignored the cache and started cold, at 1141 ms instead of 571 to 593 ms (fresh measurement;
details in [leyden-aot.md](leyden-aot.md), section 7). A stale `.jsa` behaves the same: after a
`touch` on `app.jar`, the app started and exited 0, at 1183 ms instead of 778 ms with the valid
archive, and the log showed `[warning][cds] This file is not the one used while building the shared
archive file: 'app.jar', timestamp has changed` and `[error][cds] shared class paths mismatch` (fresh
Mac, second session, §7).

**Limit:** the JVM compares the modification time and size of each JAR, not its path. Copying the
JAR directory with preserved times (`cp -p`, `cp -Rp`) kept the AOT cache valid (fresh measurement). **Open inconsistency:** this is evidence for the AOT cache, not for a CDS archive, and [struck-claims.md](struck-claims.md) lists path binding of the AOT cache as contested.
A build step that rewrites the JARs with new times invalidates the archive although the content is
the same.

## 6. Verify that the archive is used

Never rely on the absence of an error. Use one of these checks in CI:

- **Strict mode:** run once with `-Xshare:on`. A start that cannot use the archive fails instead of
  falling back. Use it as a test, not in production (the docs call it "for testing only"). For a
  dynamic archive this was not measured. It cannot be combined with `-XX:+AutoCreateSharedArchive`,
  which needs `-Xshare:auto`; test the strict start with `-XX:SharedArchiveFile` alone.
- **Class source count:** start with `-Xlog:class+load` and count the lines that end in
  `source: shared objects file`. A count near the total number of loaded classes means the archive
  works. A count that equals the cold-start count means it does not.

```bash
java -Xlog:class+load -XX:SharedArchiveFile=app.jsa -jar app.jar > classload.log &
# stop the app after it is ready, then:
grep -c 'source: shared objects file' classload.log
wc -l < classload.log
```

## 7. Numbers

Each table is one setup. Do not compare numbers across tables.

**Fresh measurement** (measured 2026-11-16, Temurin 25.0.5, macOS 26, Apple M2 Max 12 cores, no CPU
limit, Spring Boot 4.1.2 demo app with web and actuator, 7,958 loaded classes; metric: launch until
first health 200; n = 5, median; setup in [measuring.md](measuring.md), section 9):

| Configuration | Median ms | Min to max ms | Change | RSS MB | CPU s |
|---|---|---|---|---|---|
| fat JAR, default CDS only | 1212 | 1205 to 1245 | baseline | 249 | 4.92 |
| extracted JAR, default CDS only | 1053 | 1036 to 1089 | -13 % | 234 | 3.84 |
| fat JAR + dynamic archive (`-XX:SharedArchiveFile`) | 1050 | 1034 to 1068 | -13 % | 411 | 4.44 |
| fat JAR + `AutoCreateSharedArchive`, second run | 1100 | 1072 to 1106 | -9 % | 403 | 4.53 |
| extracted JAR + AOT cache (two-step), for scale | 575 | 570 to 594 | -52 % | 261 | 3.19 |

The three middle rows are equal within the noise of about 7 % ([measuring.md](measuring.md), section
2). The dynamic archive gave no more than extraction alone. RSS includes mapped archive pages as macOS
`ps` reports them; see [gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md) before you read anything
into the 411 MB.

**Fresh Mac, second session** (a second series of the fresh measurement, measured 2026-11-16 on the same machine and JDK as above, extracted JAR,
n = 5, median; a separate session, so compare only inside this table: its cold start was 1143 ms
against 1053 ms above):

| Configuration | Median ms | Min to max ms | RSS MB | CPU s |
|---|---|---|---|---|
| extracted JAR, cold | 1143 | 1129 to 1219 | 231 | 4.09 |
| + dynamic archive (`-XX:ArchiveClassesAtExit`, 36 MB) | 778 (-32 %) | 766 to 861 | 224 | 2.83 |
| the same archive, `app.jar` touched afterwards | 1183 | 1171 to 1216 | 263 | 4.25 |
| `AutoCreateSharedArchive`, second run | 844 (-26 %) | 780 to 885 | 239 | 3.04 |
| `AutoCreateSharedArchive`, `app.jar` touched afterwards, first five runs | 1162 | 1119 to 1352 | 259 | 4.14 |
| the same after one more clean exit (`-Dspring.context.exit=onRefresh`) | 1164 | 1126 to 1217 | 257 | 4.10 |

On the extracted JAR the dynamic archive gave a clear gain (-32 %), unlike on the fat JAR above, where
it was equal to extraction alone. The last three rows are the silent fallback of §5 and the missing
refresh of §4.

Creating the archives (fresh measurement, one run each):

| Archive | Wall time | Size |
|---|---|---|
| `-XX:ArchiveClassesAtExit` training run | 1.9 s | 33.7 MB |
| `AutoCreateSharedArchive`, first run | 1.6 s | 33.7 MB |

**Team measurement** (earlier runs by this skill's author on Linux, see
[measuring.md](measuring.md), section 10; measured 2026-09, Zulu 25.0.4.1, Linux container on arm64, PetClinic-class
app on Spring Boot 4.0.3, class count not recorded, CPU limit not recorded; metric: launch until
`/actuator/health` 200; median of 5):

| Configuration | Median s |
|---|---|
| fat JAR, cold | 2.925 |
| fat JAR + AppCDS | 2.26 |

## 8. When to use CDS instead of the AOT cache

Use a CDS archive when one of these holds:

- The JDK is older than 24. The AOT cache does not exist there.
- A debugger (JDWP) must attach to production-like starts. The AOT cache with linked classes is
  discarded under JDWP ([leyden-aot.md](leyden-aot.md), section 9). A CDS archive is not affected
  (reported, docs; not measured here). **Open inconsistency:** [debug-agents.md](debug-agents.md) cites a blog, not docs, for the same claim.
- A Java agent rewrites classes at load time. CDS still works; the agent's transformed classes simply
  do not come from the archive (reported, blog, URL not recorded; not measured here).

Otherwise, on JDK 25 and later, the AOT cache gives more for the same training run.

Rollback: remove `-XX:SharedArchiveFile` (and `-XX:+AutoCreateSharedArchive`). Nothing else depends
on the archive.
