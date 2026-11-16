Applies to: all (any OS; JDK 24 and later; the one-step workflow from JDK 25)

# Leyden AOT Cache (JEP 483, 514, 515, 516, 544)

TL;DR: The AOT cache stores loaded and linked classes and method profiles from a training run. The
JVM maps the cache at start. On the reference app (a Spring Boot demo, setup in
[measuring.md](measuring.md), section 9), the AOT cache together with an extracted JAR cut
the start from 1212 to 575 ms (-52 %). On other apps, without Spring AOT, the cache
alone cut the start by 42 % (JEP 483, PetClinic) and by 36 % (team measurement,
[measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers); PetClinic-class app on a fat JAR,
2.925 to 1.884 s); the same team app with the cache plus an extracted JAR went from 2.925 to 0.98 s
(-66 %). The cache is bound to one JDK build, one OS, one CPU architecture and the exact class
path. When anything does not match, or when JDWP (the Java debugger protocol) or an unplanned JFR recording is active, the JVM
ignores the cache and starts cold with exit code 0. A cache trained with another collector than
production, or training with the OpenTelemetry agent, can also cost the whole gain (sections 9 and 10).
**Always verify in CI that the cache is used** (section 7).

## Contents

- [1. What the cache holds](#1-what-the-cache-holds)
- [2. JEPs and JDK versions](#2-jeps-and-jdk-versions)
- [3. Recipes](#3-recipes)
- [4. Extract the fat JAR](#4-extract-the-fat-jar)
- [5. Spring AOT processing as an extra step](#5-spring-aot-processing-as-an-extra-step)
- [6. Constraints](#6-constraints)
- [7. Verify that the cache is used (mandatory)](#7-verify-that-the-cache-is-used-mandatory)
- [8. Containers, multi-stage builds and buildpacks](#8-containers-multi-stage-builds-and-buildpacks)
- [9. Debuggers, JFR and Java agents](#9-debuggers-jfr-and-java-agents)
- [10. Garbage collectors](#10-garbage-collectors)
- [11. CPU features: the SIGILL trap](#11-cpu-features-the-sigill-trap)
- [12. Training: context refresh or real traffic](#12-training-context-refresh-or-real-traffic)
- [13. Cache sizes and build times](#13-cache-sizes-and-build-times)
- [14. What the cache file contains](#14-what-the-cache-file-contains)
- [15. Rollback](#15-rollback)
- [16. Claims not to believe](#16-claims-not-to-believe)
- [17. Numbers](#17-numbers)

## 1. What the cache holds

Project Leyden is the OpenJDK project for faster start and warm-up. Its first product is the AOT
cache ("ahead of time"). A training run records what the application does at start. An assembly step
writes the cache. Production runs map it.

| Content | From |
|---|---|
| classes, already loaded and linked | JDK 24 (JEP 483) |
| method profiles, so the JIT can compile hot methods sooner | JDK 25 (JEP 515) |
| heap objects of loaded classes (strings, and class mirrors, the `java.lang.Class` objects) in a GC-neutral format | JDK 26 (JEP 516) |
| compiled code from the C1 and C2 compilers ([gc-cpu-ram-throughput.md §5](gc-cpu-ram-throughput.md#5-rss-and-cpu-time-at-start)) | JDK 28 (JEP 544), reported |

The cache does not hold the application's live heap, such as Spring beans. The JVM still runs the
application's start code. Compare CRaC ([crac-engines.md](crac-engines.md)), which restores a whole
running JVM.

## 2. JEPs and JDK versions

All rows: reported (JEP pages and JDK project pages, read 2026-11-16).

| JEP or change | JDK | Status | Effect |
|---|---|---|---|
| JEP 483 AOT Class Loading and Linking | 24 | delivered | two-step workflow (`record`, `create`) |
| JEP 514 AOT Command-Line Ergonomics | 25 | delivered | one-step workflow `-XX:AOTCacheOutput`; `JDK_AOT_VM_OPTIONS` passes options to the assembly step only |
| JEP 515 AOT Method Profiling | 25 | delivered | profiles in the cache |
| JEP 516 AOT Object Caching with Any GC | 26 | delivered | heap objects in a streamable format; ZGC can use the cache |
| `-XX:AOTMode=on` renamed to `required` | 27 | delivered | strict mode gets a new name |
| JEP 523 G1 by default in all environments | 27 | delivered | small containers no longer get Serial GC by default |
| JEP 534 Compact Object Headers by default | 27 | delivered | object layout changes; whether old caches still match is not confirmed |
| JEP 544 AOT Code Compilation | 28 | targeted (GA planned 2027-03) | compiled code in the cache; needs the same GC and CPU features at run time |
| JEP 545 Faster Startup and Warmup with ZGC | 28 | integrated | ZGC starts with a small heap; not an AOT cache JEP |

`-XX:AOTMode` values (reported, JEP 483):

| Value | Meaning |
|---|---|
| `auto` (default) | use `-XX:AOTCache` if it fits, otherwise warn and run without it |
| `on` (JDK 24 to 26) / `required` (JDK 27 and later) | fail the start if the cache cannot be used |
| `off` | ignore the cache |
| `record` | training run; writes `-XX:AOTConfiguration` |
| `create` | assembly; reads the configuration and writes `-XX:AOTCache`; does not run the app |

`-XX:AOTMode=on` was measured on Temurin 25.0.5 (fresh measurement: macOS, reference app; setup in
[measuring.md §9](measuring.md#9-reference-setup-of-the-fresh-measurement)). On the Linux VM
([measuring.md §11](measuring.md#11-linux-vm-measurements)), `on` worked on
Temurin 25.0.5 and 26.0.2.1, `required` worked on 27.0.1.0.2, and both JDK 25 and 26 rejected
`required` (measured 2026-11-16, Linux arm64 (OrbStack VM)).

## 3. Recipes

All recipes use the same JDK build for training and production (section 6).

**One step, JDK 25 and later:**

```bash
# training + assembly in one command; the JVM starts a second JVM for the assembly
java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar app/app.jar
# production
java -XX:AOTCache=app.aot -jar app/app.jar
```

**Two steps, JDK 24 and later:**

```bash
java -XX:AOTMode=record -XX:AOTConfiguration=app.aotconf -Dspring.context.exit=onRefresh -jar app/app.jar
java -XX:AOTMode=create -XX:AOTConfiguration=app.aotconf -XX:AOTCache=app.aot -jar app/app.jar
java -XX:AOTCache=app.aot -jar app/app.jar
```

On the reference app, the one-step and two-step caches gave equal start times (597 and 575 ms
extracted, 887 and 903 ms fat JAR; all inside the noise; fresh measurement). The one-step run deletes
the `.aotconf` file after the assembly.

**Spring Boot, JDK 25 and later** (reported, Spring Boot docs; this is the recipe of the fresh
measurement):

```bash
java -Djarmode=tools -jar my-app.jar extract --destination application
cd application
java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar my-app.jar
java -XX:AOTCache=app.aot -jar my-app.jar
```

`-Dspring.context.exit=onRefresh` (Spring Framework 7) ends the training after the context refresh:
all non-lazy singletons exist, no lifecycle bean has started (reported, Spring docs). Without Spring,
stop the training run after the app is ready, for example with SIGTERM, so the JVM writes the cache
at exit.

## 4. Extract the fat JAR

**Rule:** extract the Spring Boot fat JAR before training, and run the extracted form in production.

**Reason:** a fat JAR loads classes from nested JARs through Spring Boot's own class loader. The AOT
cache supports custom class loaders only in a limited way (reported, JEP 483). On the reference app,
6,050 of 7,348 classes came from the cache with the fat JAR, and 7,685 of 7,958 with the extracted
JAR (fresh measurement, counted with `-Xlog:class+load`). The start took 887 to 903 ms with the fat
JAR and 575 to 597 ms extracted. Extraction alone, without a cache, took 1053 ms instead of 1212 ms (-13 %).

The extraction took 0.3 s and produced `app.jar` (3.4 KB) plus a `lib/` directory (fresh
measurement).

**Limit:** other packaging (a plain class path of JARs, a jlink image) has no nested JARs and does not
need this step. Whether a cache works with a jlink runtime is not confirmed.

## 5. Spring AOT processing as an extra step

Spring AOT processing is a different technique with a similar name. At build time it evaluates the
Spring configuration and generates Java code for the bean definitions. At run time it is enabled with
`-Dspring.aot.enabled=true`. It is required for GraalVM native images, and it also works on the JVM.

The two combine. Third-party numbers, each from its own setup (not comparable across rows):

| Source | Setup | AOT cache only | AOT cache + Spring AOT |
|---|---|---|---|
| reported ([blog](https://blog.rasc.ch/2026/04/spring-boot-startup.html)) | Spring Boot 4.1.1 PetClinic, Zulu 27, cloud VM, Docker, median of 15 | 2622 ms | 2356 ms |
| reported ([blog](https://ankurm.com/spring-boot-jdk-aot-cache-jep-514-515-startup-benchmarks/)) | small Spring Boot 4.1.1 app, Temurin 25.0.4.1, 2 vCPU, median of 10, traffic training | 1949 ms | 1436 ms |

**Caveat: Spring AOT freezes conditions.** Spring AOT evaluates `@Conditional...` annotations, such
as `@ConditionalOnProperty`, and profile selection at build time (reported, Spring docs). A property
that switches a bean on or off at run time no longer has that effect. Placeholders that a
`BeanFactoryPostProcessor` resolves can also be fixed at build time (reported, Spring docs). Use Spring AOT only when the
bean graph is the same in every environment, or build once per environment.

## 6. Constraints

The JVM accepts the cache only when production matches the training run in these points (reported,
JEP 483 and Spring docs, unless marked measured):

| Constraint | Detail |
|---|---|
| same JDK build | the exact build, not just the same version; a different patch release or JDK path makes the JVM ignore the cache (reported, buildpack docs; URL not recorded) |
| same OS and CPU architecture | a cache built on arm64 does not work on x86_64 |
| same class path | same JARs in the same order; extra JARs only at the end, and they are not cached; JARs only, no directories, no wildcards |
| JAR modification time and size unchanged | measured: `touch` on one JAR made the JVM ignore the cache |
| same module options | `-m`, `-p`, `--add-modules` identical; `--add-opens`, `--add-exports`, `--add-reads`, `--patch-module`, `--limit-modules`, `--upgrade-module-path` are not allowed |
| no class-rewriting agents | JVMTI (JVM Tool Interface) agents with a `ClassFileLoadHook`, the JVMTI event that lets an agent rewrite class bytes at load time, that rewrite arbitrary classes, or that add JARs to the boot or system class path, are not allowed; the OpenTelemetry agent broke the training run (measured, section 9) |
| path of the JAR directory | not checked: a copy at another path, with the same times and sizes, kept the cache in use (measured; section 16) |

A different garbage collector is allowed by the JEPs for the class and object cache, but it can cost
the whole gain: a cache trained with G1 gave no gain under ZGC, and was 19 % slower on JDK 27 (section 10). It is not allowed for
compiled code from JDK 28.

## 7. Verify that the cache is used (mandatory)

**Rule:** in CI or a test stage, start the app once with strict mode and the production flags. In
production, keep the default mode and watch the log.

**Origin:** the fresh measurement found that every rejection case started the app cold with exit code
0 (measured 2026-11-16, Temurin 25.0.5, macOS on Apple M2 Max, reference app, n = 3 per case):

| Case | Median ms | What the JVM printed |
|---|---|---|
| cache valid | 571 to 593 | `Opened AOT cache ...` |
| `touch` on `app.jar` | 1141 | `[warning][aot] This file is not the one used while building the AOT cache: '.../app.jar', timestamp has changed` then `[error][aot] shared class paths mismatch` and `[error][aot] Unable to map shared spaces` |
| `touch` on one library JAR | 1159 | the same, with the library JAR's name |
| cache file missing | 1096 | `[info][aot] Specified AOT cache not found (...)`, `[error][aot] Loading static archive failed.`, `Unable to map shared spaces` |
| JAR directory copied to another path with `cp -Rp` | 583 | nothing; the cache was used |
| run with `-XX:+UseSerialGC`, trained with G1 | 571 | nothing; the cache was used |
| `-XX:AOTMode=on` and a touched `app.jar` | no start | `Error occurred during initialization of VM` / `Unable to use AOT cache.` |

The `[warning]` and `[error]` lines appear on stdout without any logging flag, so they reach a
container log. Nothing else stops the deployment. Strict mode with a touched `app.jar` behaved the same
on Temurin 25, 26 and 27: exit code 1 after `timestamp has changed` and `shared class paths mismatch`
(measured 2026-11-16, Linux arm64 (OrbStack VM)).

**Reason:** a silent fallback looks like success. The only visible symptom is a start that is twice
as slow, and nobody compares start times after each release.

**Checks, from strongest to weakest:**

1. **Strict mode in CI:** add `-XX:AOTMode=on` (JDK 24 to 26) or `-XX:AOTMode=required` (JDK 27 and
   later) to one test start with the production flags and the production image. The JVM stops if the
   cache cannot be used. Do not use strict mode in production: JEP 483 warns that, for example, a
   cloud provider can inject an agent with a `ClassFileLoadHook`, and then the app would not start.
2. **Class source count:** start with `-Xlog:class+load` and count `source: shared objects file`.
   The reference app loaded 7,685 of 7,958 classes from the cache when it worked.
3. **Log lines:** search the start log for `[error][aot]` and `Unable to map shared spaces`.
   **Do not** treat `Opened AOT cache` as proof: in the `touch` cases, the JVM printed
   `Opened AOT cache ...` with `-Xlog:aot` and rejected the cache a few lines later (fresh
   measurement).

```bash
# CI check, JDK 25 or 26 (use AOTMode=required on JDK 27 and later)
java -XX:AOTMode=on -XX:AOTCache=app.aot -Dspring.context.exit=onRefresh -jar app/app.jar
```

`-Dspring.context.exit=onRefresh` ends the check after the context refresh, so it needs no running
service.

## 8. Containers, multi-stage builds and buildpacks

**Rule:** train inside the image that runs in production, with the same JDK build and the same paths.

**Reason:** the cache records the JDK build and the JARs' modification times and sizes. A
multi-stage build that trains in a builder stage with another JDK image, or that copies the JARs in a
way that changes their times, produces a cache that production ignores without an error.

A pattern that keeps both in one place (not measured as a container build here; verify with
section 7):

```dockerfile
# stage 1: build the fat JAR with any JDK
FROM <build-jdk-image>@sha256:<digest> AS build
WORKDIR /src
COPY . .
RUN ./mvnw -q package -DskipTests

# stage 2: the production image; extraction, training and run use this one JDK
FROM <runtime-jdk-image>@sha256:<digest>
WORKDIR /app
COPY --from=build /src/target/my-app.jar /tmp/my-app.jar
RUN java -Djarmode=tools -jar /tmp/my-app.jar extract --destination /app && rm /tmp/my-app.jar
# training: no production secrets, no JDWP, no agents, same JVM options as production
RUN java -XX:AOTCacheOutput=/app/app.aot -Dspring.context.exit=onRefresh -jar /app/my-app.jar
# fail the image build if production would not use the cache (JDK 27+: AOTMode=required)
RUN java -XX:AOTMode=on -XX:AOTCache=/app/app.aot -Dspring.context.exit=onRefresh -jar /app/my-app.jar
ENTRYPOINT ["java", "-XX:AOTCache=/app/app.aot", "-jar", "/app/my-app.jar"]
```

Notes on the pattern:

- Extraction and training run in the final stage. The JARs are never copied after training, so their
  times cannot change.
- If you train in a separate stage, that stage must use the same runtime image by digest, and the copy
  into the final stage must keep the extracted JARs' modification times. Check with the strict-mode
  step.
- Pin the runtime image by digest. A rebuilt tag with a new JDK patch release would make every cache
  stale.
- The training step runs the application inside the image build. It must not reach production
  databases or need production secrets. If it does, give it a training profile with local stand-ins.

**Paketo buildpacks** (Cloud Native Buildpacks that build container images without a Dockerfile): `BP_JVM_AOTCACHE_ENABLED=true` runs a training run during the build and writes
`application.aot` (JDK 25 and later) (reported, buildpack docs; URL not recorded). `TRAINING_RUN_JAVA_TOOL_OPTIONS`
sets JVM options for the training run only (reported, [README](https://github.com/paketo-buildpacks/spring-boot)). `BP_JVM_CDS_ENABLED` is deprecated in favour of it. Two
reported problems: with `BPL_DEBUG_ENABLED` (JDWP) the cache is discarded, and the suggested
workaround `-XX:-AOTClassLinking` in training was reported to cause metaspace growth (reported,
[paketo-buildpacks/spring-boot#578](https://github.com/paketo-buildpacks/spring-boot/issues/578)).

## 9. Debuggers, JFR and Java agents

**JDWP discards the cache.** With `-agentlib:jdwp=...` the JVM printed
`[error][aot] AOT cache has aot-linked classes. It cannot be used with JDWP agent` and started cold:
1139 ms with the cache flag, 1158 ms without (measured 2026-11-16, Temurin 25.0.5, reference app,
n = 5 and 3). Whether training with JDWP changes this is not measured. `-XX:-AOTClassLinking` in
training is reported to make the cache usable with JDWP, at the cost of the linking gain (reported,
[paketo-buildpacks/spring-boot#578](https://github.com/paketo-buildpacks/spring-boot/issues/578) and a
blog; blog URL not recorded).

**JFR must match between training and production.** A JFR recording started with
`-XX:StartFlightRecording` adds the module `jdk.jfr`, and the JVM rejected the cache (fresh
measurement, n = 5):

```
[error][aot] Mismatched values for property jdk.module.addmods: jdk.jfr specified during runtime but not during dump time
[error][aot] AOT cache has aot-linked classes. It cannot be used when archived full module graph is not used.
```

A cache trained with `-XX:StartFlightRecording` worked with JFR in production: 669 ms median (fresh measurement, n = 3). The JVM disabled JFR during the dump itself (`JFR will be disabled during CDS dumping`). The
same cache, used without JFR, was rejected the other way round (1152 ms, fresh measurement, n = 3). So: train with JFR if
production starts with JFR, and without JFR if it does not. Starting a recording later with `jcmd` is
not measured. See [`../../java-debug/references/jfr.md`](../../java-debug/references/jfr.md).

**Java agents: the OpenTelemetry agent gets no cache.** JEP 483 forbids agents that rewrite arbitrary
classes through a JVMTI `ClassFileLoadHook`, and the OpenTelemetry Java agent is such an agent. With
agent 2.33.1 in training and run (measured 2026-11-16, Linux arm64 (OrbStack VM), Temurin 25.0.5 and
27.0.1.0.2, demo app, which is the reference app extracted, n = 3):

| Case | JDK 25.0.5 | JDK 27.0.1.0.2 |
|---|---|---|
| training with `-javaagent` | many `[warning][aot] Skipping ...: From ClassFileLoadHook`, then `SIGSEGV`, exit 134, `hs_err` file, **no cache** | exit 1, `[error][aot] Critical class java.lang.Class has been excluded. AOT configuration file cannot be written.`, **no cache** |
| the same plus `--add-modules=java.instrument` in training and run | same failure | same failure |
| cache trained without the agent, run with it | `Mismatched values for property jdk.module.addmods: java.instrument specified during runtime but not during dump time`; strict mode exits, default mode starts without the cache | the same |

So the reported workaround `--add-modules=java.instrument` (reported, issue tracker; issue not recorded) did not help with
this agent version. The OpenTelemetry project reported its agent with a cache on JDK 25.0.1 (reported,
[project benchmark](https://github.com/open-telemetry/opentelemetry-java-instrumentation/pull/20003): 4.481 s with the agent and no cache, 3.554 s with agent and cache); whether that
cache was really used is not stated. Origin of the rule "check every agent with strict mode (section
7)": these failures. Reason: a cache that the agent breaks fails in training or falls back silently at
run time. Limit: one agent version and two JDK builds; other agents and versions can behave
differently. The startup cost of agents is in [debug-agents.md](debug-agents.md#24-opentelemetry-java-agent).

## 10. Garbage collectors

| JDK | Heap objects in the cache | Collectors |
|---|---|---|
| 24, 25 | mapped into memory | Serial, Parallel, G1; ZGC cannot use the archived heap objects (reported, JEP 516), but a ZGC-trained cache still cut the start by 12 % to 22 % on 25 (measured, two series, matrix below) |
| 26 and later | mapped, or streamed in a GC-neutral format | all collectors, including ZGC (reported, JEP 516) |
| 28, compiled code | code contains GC barriers | same collector in training and production, otherwise the JVM drops the compiled code and keeps the rest (reported, JEP 544) |

From JDK 26 the JVM streams the objects when the training ran with ZGC, without compressed oops (32-bit object references, the default for heaps below 32 GB), or
with a heap above 32 GB, and maps them otherwise. Streaming needs an extra CPU core during start;
mapping is faster with a warm page cache (reported, JEP 516). `-XX:+AOTStreamableObjects`
(diagnostic) forces streaming.

Training with G1 and running with `-XX:+UseSerialGC` kept the cache in use on JDK 25 (fresh
measurement, 571 ms).

**Rule: train with the collector that production uses.** Origin: the matrix below. Reason: "allowed"
in the JEPs means the JVM starts; a cache trained with G1 still gave no gain under ZGC (19 % slower on
27), and a ZGC cache was 25 % slower under G1 on 25, all with exit 0.
Limit: G1, Parallel and Serial caches were interchangeable in default mode on all three JDKs.

Measured 2026-11-16, Linux arm64 (OrbStack VM), extracted demo app, one-step training (3.2 to 3.3 s on
every JDK), median ms, n = 5 (n = 3 in the last column). The percentages compare with the cold start
under the collector of the same run:

| JDK | cold G1 | AOT cache, G1 | cache MB | cold ZGC | G1 cache, run with ZGC | ZGC cache, run with ZGC | ZGC cache, run with G1 |
|---|---|---|---|---|---|---|---|
| Temurin 25.0.5 | 1064 | 579 | 57.9 | 1157 | 1215 (+5 %, noise) | 898 (-22 %) | 1335 (+25 %; 1216 to 1576) |
| Temurin 26.0.2.1 | 1172 | 571 | 60.9 | 1187 | 1212 (+2 %, noise) | 596 (-50 %) | 1193 (+2 %, noise) |
| Temurin 27.0.1.0.2 | 1133 | 581 | 61.5 | 1200 | 1422 (+19 %; one run 2277) | 628 (-48 %) | 1159 (+2 %, noise) |

- **The ZGC-cache gain is unstable between series.** The table is the second series (n = 5). An
  earlier series (n = 3, same VM and app) gave 1022 ms on 25 and 549 and 550 ms on 26 and 27 for the
  ZGC cache under ZGC. Against the cold ZGC starts above, the gain is -12 % to -22 % on 25 and about
  -48 % to -54 % on 26 and 27. The first series also had no cold ZGC run of its own.
- **ZGC on JDK 25 gains less.** The ZGC cache on 25 was smaller (47.8 MB against 62.5 and 62.1 MB on 26
  and 27), consistent with JEP 516: before JDK 26, ZGC cannot use archived heap objects, so only the
  class part works (mechanism reported, JEP 516).
- **Strict mode with a G1 cache under ZGC** failed on all three JDKs with `The saved state of
  UseCompressedOops ... is different from runtime, CDS will be disabled`; default mode started without
  the cache.
- **G1 cache under Parallel or Serial:** strict mode worked on 25 and 26 (546 to 597 ms, n = 2). On 27,
  strict mode failed with `AOT Code Cache disabled: it was created with GC = "g1 gc" vs current
  "parallel gc"` (or `"serial gc"`), while default mode still ran at 572 to 591 ms. The log line names
  only the AOT code cache. That the JVM drops only this GC-bound code part and keeps the rest is an
  inference from the line and from the unchanged start time, not a measurement of what else is skipped.
- Caches trained with Parallel or Serial ran under G1 without error on all three (567 to 595 ms, n = 3).

More on collectors per technique: [gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md).

## 11. CPU features: the SIGILL trap

**Rule:** train on the CPU type with the fewest features that production uses, or switch off adapter
caching.

**Origin:** on JDK 25.0.4 x86_64, a cache trained on a CPU with AVX-512 can crash with SIGILL (illegal
instruction) on a CPU with AVX2 only (reported, blog; source URL not recorded). The team measured the mechanism: the
cache held 328 adapters (small pieces of machine code that connect interpreted and compiled code,
about 250 KB of VEX-encoded code, the instruction encoding of AVX), and the JVM loaded them in 56 of 56 runs, even with `-XX:UseAVX=0`
(measured 2026-09, JDK 25.0.4, x86_64 Linux).

**Mitigation:**

```bash
java -XX:+UnlockDiagnosticVMOptions -XX:-AOTAdapterCaching -XX:AOTCache=app.aot ...
```

Use it both for training and in production, or train on the weakest CPU of the fleet.

**Limit:** sources disagree on the JDK release that fixes this: 25.0.5 or 27. The sources and the bug
ID were not recorded, and the bug tracker was not readable. Treat the trap as open until you have tested your own JDK build on your weakest CPU type.
arm64 was not tested.

**JDK 28 compiled code** needs the same CPU architecture and the same CPU features (for example
AVX-512) in training and production. Otherwise the JVM prints a warning and does not load the
compiled code; classes and profiles stay usable (reported, JEP 544).

## 12. Training: context refresh or real traffic

`-Dspring.context.exit=onRefresh` trains the start only. Request handling code is not loaded, not
linked and not profiled in that run.

Training with traffic loads and profiles the request path too. A third-party benchmark found almost
the same ready time (2022 ms with context-refresh training, 1949 ms with traffic training) but a much
faster first request: 142.8 ms against 67.7 ms (reported,
[blog](https://ankurm.com/spring-boot-jdk-aot-cache-jep-514-515-startup-benchmarks/); Spring Boot 4.1.1, Temurin 25.0.4.1,
2 vCPU).

To train with traffic: start the app with `-XX:AOTCacheOutput` (or `-XX:AOTMode=record`), send
representative requests, then stop the JVM with SIGTERM. The cache is written at exit.

**Limit:** the training traffic must not need production data or production secrets (section 14).
Profiles from unrepresentative traffic can steer the JIT the wrong way at first; the JIT corrects
this later (reported, JEP 515).

## 13. Cache sizes and build times

Fresh measurement (Temurin 25.0.5, macOS, reference app; one run each, not repeated):

| Artifact | Command | Wall time | Size |
|---|---|---|---|
| one-step cache, fat JAR | `-XX:AOTCacheOutput` | 3.1 s | 54.9 MB |
| two-step cache, fat JAR | `record` 1.8 s + `create` 0.7 s | 2.5 s | `.aotconf` 54.9 MB, `.aot` 54.9 MB |
| one-step cache, extracted | `-XX:AOTCacheOutput` | 3.1 s | 57.9 MB |
| two-step cache, extracted | `record` 1.9 s + `create` 1.0 s | 2.9 s | `.aotconf` 54.0 MB, `.aot` 58.0 MB |
| dynamic CDS archive, for scale | `-XX:ArchiveClassesAtExit` | 1.9 s | 33.7 MB |

Published sizes: about 11.4 MB for a hello-world app (reported, JEP 483); about 133 MB for PetClinic
(reported, buildpack blog). JDK 28 compiled code makes the cache "significantly larger" (reported,
JEP 544).

The one-step workflow runs two JVMs, one after the other. It is reported to need about twice the heap
of a single run (reported, blog; URL not recorded). Give the build container enough memory.

## 14. What the cache file contains

Short version; the full matrix is in [security.md](security.md).

- **Absolute paths:** the cache records the class path with absolute paths. The rejection messages in
  section 7 print them.
- **Strings:** the cache holds string literals and other archived strings of loaded classes.
  `-Xlog:aot*=info` prints archived strings into the log (measured 2026-09, JDK 25). Do not keep
  that log level in a build whose log is public.
- **Canary test:** training ran with a canary value in an environment variable and another in a `-D`
  property. A byte search found 0 hits for both in every `.aot`, `.aotconf` and `.jsa` file (fresh
  measurement). The search covered UTF-8 and Latin-1 only, and the app never read the two values.
  0 hits does not prove that a file is clean: a value that the application reads and stores in a
  static field during training is not covered by this test.
- **Training options in the build log:** the one-step workflow starts a second JVM for the assembly.
  In a team run, that JVM printed the training options, including a `-D` value, as
  `Picked up JAVA_TOOL_OPTIONS: ...` on stderr (measured 2026-09, JDK 25). Pass no secrets on the
  training command line. `JDK_AOT_VM_OPTIONS` sets options for the assembly step only (reported,
  JEP 514).

## 15. Rollback

Remove `-XX:AOTCache` from the start command, or set `-XX:AOTMode=off`. The JVM then starts as
without the cache. Nothing else in the application depends on it. If Spring AOT processing was added
(section 5), remove `-Dspring.aot.enabled=true` too.

## 16. Claims not to believe

| Claim | Verdict |
|---|---|
| The cache is architecture-neutral and holds no heap data | Wrong. It is bound to the JDK build, OS, CPU architecture, and the JARs' modification times and sizes. It holds archived strings and literals. No runtime values were found in the canary test (section 14) |
| JFR works with the AOT cache | Wrong as a general statement. The cache is discarded unless training and production both use JFR, or both do not (measured 2026-11-16). JDWP always discards it (section 9) |
| Leyden forbids all Java agents | Nuanced. JEP 483 forbids class-rewriting `ClassFileLoadHook` agents. The OpenTelemetry agent 2.33.1 broke the training run on JDK 25 and 27, also with `--add-modules=java.instrument` (measured 2026-11-16, Linux arm64 (OrbStack VM); section 9). Other agents: check with strict mode |
| An AOT cache works with any collector from JDK 26 | Nuanced. The JVM starts, but a G1-trained cache gave no gain under ZGC on 25, 26 and 27 (19 % slower on 27); train with the production collector (section 10) |
| The cache is bound to its path | Contested. A JAR directory copied to another path with the same times and sizes kept the cache in use (measured 2026-11-16). The file embeds absolute paths, and a vendor (source not recorded) reports that a different path makes the JVM ignore the cache. Verify with strict mode after any move |
| `-XX:AOTMode=on` is the strict mode | True for JDK 24 to 26 (measured on 25.0.5 and 26.0.2.1). From JDK 27 it is `required` (measured on 27.0.1.0.2; section 2) |
| The adapter SIGILL is fixed in 25.0.5 | Unverified. Sources say 25.0.5 or 27. Use the mitigation in section 11 |

The complete list for all techniques: [struck-claims.md](struck-claims.md).

## 17. Numbers

Each table is one setup. Do not compare numbers or ratios across tables.

**Fresh measurement** (measured 2026-11-16, Temurin 25.0.5, macOS 26, Apple M2 Max 12 cores, no CPU
limit; Spring Boot 4.1.2 demo app with web and actuator, 7,958 loaded classes; metric: launch until
first health 200; n = 5, median; setup in [measuring.md](measuring.md), section 9):

| Configuration | Median ms | Min to max ms | Change | RSS MB | CPU s |
|---|---|---|---|---|---|
| fat JAR, cold | 1212 | 1205 to 1245 | baseline | 249 | 4.92 |
| extracted JAR, cold | 1053 | 1036 to 1089 | -13 % | 234 | 3.84 |
| fat JAR + AOT cache, one-step | 887 | 867 to 947 | -27 % | 426 | 4.08 |
| fat JAR + AOT cache, two-step | 903 | 866 to 1026 | -25 % | 413 | 4.14 |
| extracted + AOT cache, one-step | 597 | 581 to 619 | -51 % | 264 | 3.40 |
| extracted + AOT cache, two-step | 575 | 570 to 594 | -52 % | 261 | 3.19 |
| extracted + AOT cache + `-XX:TieredStopAtLevel=1` | 526 | 501 to 556 | -57 % | 173 | 1.11 |

One-step and two-step rows are equal within the noise. `TieredStopAtLevel=1` is explained in
[gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md). The higher RSS of the fat-JAR rows is how macOS
`ps` counts mapped archive pages; it is not a container memory figure.

**Team measurement, arm64** (earlier runs by this skill's author, see
[measuring.md](measuring.md), section 10; measured 2026-09, Linux container on arm64; PetClinic-class app on
Spring Boot 4.0.3, class count not recorded, CPU limit not recorded; metric: launch until
`/actuator/health` 200; median of 5, extracted rows median of 3):

| Configuration | Zulu 25.0.4.1 | Zulu 27 |
|---|---|---|
| fat JAR, cold | 2.925 s | 2.955 s |
| fat JAR + AOT cache | 1.884 s | 2.727 s |
| extracted + AOT cache | 0.98 s | 0.98 s |

**Linux VM** (measured 2026-11-16, Linux arm64 (OrbStack VM), Temurin 25, 26 and 27): the
cold and cached starts per JDK and collector are in section 10.

**Third-party** (reported; each row its own hardware, JDK and metric; not comparable with each other
or with the tables above):

| Source | Setup | Without cache | With cache |
|---|---|---|---|
| [JEP 483](https://openjdk.org/jeps/483) | PetClinic 3.2.0, JDK 23 against 24, hardware not stated | 4.486 s | 2.604 s (-42 %) |
| [buildpack blog](https://blog.paketo.io/posts/spring-boot-performance/) | PetClinic, Java 25, Docker, single runs | 2.379 s, 391.8 MiB | 0.579 s, 309.5 MiB (with Spring AOT) |
| [blog](https://ankurm.com/spring-boot-jdk-aot-cache-jep-514-515-startup-benchmarks/) | small Spring Boot 4.1.1 app, Temurin 25.0.4.1, 2 vCPU, median of 10 | 3,920 ms (extracted) | 1,436 ms (with Spring AOT, traffic training) |
| [blog](https://blog.rasc.ch/2026/04/spring-boot-startup.html) | Spring Boot 4.1.1 PetClinic, Zulu 27, cloud VM, median of 15, first HTTP 200 | 6,406 ms (fat JAR) | 2,622 ms; 2,356 ms with Spring AOT |
| [JEP 544](https://openjdk.org/jeps/544) | 5 framework apps, 2-core Linux x64, JDK 28 early access | baseline | -50 to -70 % without compiled code, -65 to -80 % with it |
