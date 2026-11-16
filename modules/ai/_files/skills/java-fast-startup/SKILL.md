---
name: java-fast-startup
description: >-
  Make a JVM or Spring Boot app start faster, and prove that the speed-up is
  really used: fair startup measurement, fat-JAR extraction, CDS and AppCDS
  archives, the Leyden AOT cache of JDK 24+ (AOTCache, AOTCacheOutput,
  AOTMode, Spring AOT processing), CRaC checkpoint and restore (warp, CRIU,
  criuengine, image layers, Resource callbacks), and GraalVM native image as
  a comparison with facts only. Covers the silent fallback to a cold start,
  secrets in checkpoint files, CPU features, garbage collectors, debuggers and
  agents per technique. Triggers on: JVM startup time, Spring Boot startup
  time, slow start, cold start, scale-to-zero, CDS, AppCDS, Leyden, AOT
  cache, AOTMode, AOTCache, CRaC, checkpoint restore, warp, CRIU, native
  image comparison, startup tuning without jlink. For the diagnosis of a
  slow or failing JVM (JFR, thread dumps, a checkpoint that fails), load
  `java-debug`. For a JVM in a pod, also load `jvm-remote-debug`. Hot swap
  and REPL: `spring-boot-repl`.
allowed-tools: >-
  Read
  Read(references/*)
  Bash(./scripts/checkpoint-secret-scan.py *)
  Bash(jcmd -l) Bash(jcmd * VM.flags)
  Bash(jcmd * VM.version) Bash(java -version)
  Bash(java -XX:+PrintFlagsFinal -version)
dependencies: >-
  JDK 24+ for the AOT cache (JDK 25+ for the one-step workflow, where `-XX:AOTCacheOutput` trains and writes the cache in one run), any JDK 12+
  for CDS. CRaC needs a vendor CRaC build (for example Azul Zulu CRaC) on
  Linux; on a Mac, run it in a Linux container. The scripts need Python 3.9+
  and uv (PEP 723 header: inline dependency metadata that uv reads), no
  third-party packages.
compatibility: >-
  macOS and Linux. CRaC on Linux only (x86_64, aarch64). Development and test
  targets; production only when the user asks.
---

# Java Fast Startup: Measure, Cache, Checkpoint, Verify

**TL;DR:** Measure first: the start must be spent in the JVM, not in a slow dependency. Then extract the
fat JAR and add an AOT cache (JDK 24+). Use CRaC only when the warm-up is the cost and the exclusion
criteria below do not apply. Every technique falls back to a cold start **silently, with exit code 0**,
when something does not match. So the step "verify it is really used" is mandatory, not optional.

**Terms.** *CDS* (Class Data Sharing) maps class metadata from an archive instead of parsing class
files; *AppCDS* adds the application's classes ([cds-appcds.md §1](references/cds-appcds.md#1-what-cds-stores)).
The *AOT cache* is the first product of Project Leyden, the OpenJDK project for faster start: a
*training run* records what the app does at start, and production maps the result
([leyden-aot.md §1](references/leyden-aot.md#1-what-the-cache-holds)). The *one-step workflow* (JDK 25+)
trains and writes the cache in one run with `-XX:AOTCacheOutput` ([§3](references/leyden-aot.md#3-recipes)).
*Spring AOT* is a separate build-time step that generates code for the bean definitions
([§5](references/leyden-aot.md#5-spring-aot-processing-as-an-extra-step)). *CRaC* (Coordinated Restore at
Checkpoint) restores a saved process image through an engine: `warp`, a library inside the JVM, or
`criuengine`, the adapter to the Linux tool CRIU ([crac-engines.md §2](references/crac-engines.md#2-engines)).

This skill decides which startup technique fits, sets it up, and proves that production uses it. It
does not diagnose a broken JVM. For that, use `java-debug`; its
[crac.md](../java-debug/references/crac.md) is the owner of checkpoint debugging (blockers, engines,
glibc 2.42, noexec mounts).

**Evidence classes.** Numbers carry one of five labels, and they are never mixed in one table:
*fresh Mac* (measured 2026-11-16, Temurin 25.0.5, bare-metal macOS on Apple M2 Max, Spring Boot 4.1.2
demo app with 7,958 classes; [measuring.md §9](references/measuring.md#9-reference-setup-of-the-fresh-measurement)),
*Linux VM* (measured 2026-11-16, Linux arm64 (OrbStack VM), Temurin 25/26/27, Zulu CRaC 25/27, GraalVM
CE 25, the demo app and PetClinic; [§11](references/measuring.md#11-linux-vm-measurements)),
*team Linux* (the "team measurements" of [§10](references/measuring.md#10-team-measurements-and-third-party-numbers): earlier runs by the skill's author; measured 2026-08/09, Zulu 25/27, arm64 VM or x86 KVM with 2 CPUs; **open inconsistency:** the KVM guest has 4 vCPUs and the containers are limited to 2 CPUs),
*container 2026-11-15* (Zulu 25.0.5 CRaC in arm64 containers; setup in the introduction of
[java-debug crac.md](../java-debug/references/crac.md)), and *reported* (JEPs, vendor docs, blogs).
Compare ratios only inside one table: each table is one setup, and a ratio does not carry over to
another setup ([measuring.md §2](references/measuring.md#2-sample-size-and-noise)).

## Decision tree

```
0. Measure (references/measuring.md). Ready = first health 200, n >= 5, medians.
   Is the time spent waiting on a network, database or secrets service?   -> fix that first; no JVM flag helps
1. Spring Boot fat JAR?                     -> extract it (java -Djarmode=tools ... extract)
2. JDK 24 or later?                         -> AOT cache (+ Spring AOT if the bean graph is the same everywhere)
   JDK 13-23?                               -> dynamic AppCDS archive (references/cds-appcds.md)
3. Still too slow, and the cost is warm-up? -> CRaC, if no exclusion below applies
4. Need ~0.1 s and accept a closed world?   -> native image: facts only (references/native-image.md)
```

| Step | Do not use it when | Rollback |
|---|---|---|
| 1. Extract | packaging is not a nested fat JAR (plain class path, jlink image) | start the fat JAR again |
| 2. AOT cache | JDWP must attach to this start: the cache is discarded ([leyden-aot.md §9](references/leyden-aot.md#9-debuggers-jfr-and-java-agents)); use CDS. JFR runs in production but not in training, or the reverse: train the same way. The OpenTelemetry agent runs: no cache at all; other class-rewriting agents: check with strict mode (`-XX:AOTMode=on`, see the verify section). Production uses another collector than training: no gain ([§10](references/leyden-aot.md#10-garbage-collectors)). Spring AOT freezes `@Conditional` and profiles at build time | remove `-XX:AOTCache` or set `-XX:AOTMode=off`; remove `-Dspring.aot.enabled=true` ([§15](references/leyden-aot.md#15-rollback)) |
| 3. CRaC | the start does little work worth skipping: a trivial app restored in 16-23 ms against 18-44 ms cold (measured 2026-11-15). A checkpoint without warm-up still skips the framework start (PetClinic 43-62 ms against about 3 s cold, Linux VM), but the first seconds of throughput stay like a cold JIT ([gc §7](references/gc-cpu-ram-throughput.md#7-throughput-and-warm-up)). You must build the checkpoint under QEMU, Rosetta or another emulator: never ([crac-engines.md §7](references/crac-engines.md#7-platforms-and-emulation)). The nodes have mixed CPU models: a checkpoint is bound to the CPU features of its host ([§6](references/crac-engines.md#6-cpu-features)). About 150-200 (**open inconsistency:** [frameworks.md §7](references/frameworks.md#7-apps-with-many-file-descriptors) says about 140 to 200) file descriptors from several libraries that implement no CRaC `Resource` callbacks ([frameworks.md §7](references/frameworks.md#7-apps-with-many-file-descriptors)). Listener agents (Jolokia, remote JMX, nREPL), which keep a listening socket open and so block the checkpoint, must run in that JVM ([crac.md §2](../java-debug/references/crac.md#2-what-blocks-a-checkpoint)). Your secrets policy forbids credentials at rest: the image is a plaintext heap; prefer the AOT cache | deploy the plain (non-checkpoint) image, or empty the checkpoint directory where it is a mounted volume, so the [wrapper](references/crac-build-and-deploy.md#1-the-wrapper) (the start script that restores or starts cold) starts cold; remove `-Dspring.context.checkpoint=onRefresh` ([crac-build-and-deploy.md §10](references/crac-build-and-deploy.md#10-rollback)) |
| 4. Native | you need a JIT, runtime Java agents, full JDWP or CRaC | not covered; no recipe in this skill |

CRaC engine: decide by **privileges**, not CPU architecture. `warp` needs none; `criuengine` needs a
privileged container for the restore ([crac-engines.md §3](references/crac-engines.md#3-privileges-per-runtime-setting)).

## Comparison

Qualitative; the numbers are in the next section.

| Property | JIT only | CDS / AppCDS | AOT cache (Leyden) | CRaC (warp) | Native image |
|---|---|---|---|---|---|
| Start gain | baseline | small on a fat JAR, -32 % extracted (fresh Mac, second session: a separate series, [cds-appcds.md §7](references/cds-appcds.md#7-numbers)) | large | largest on the JVM, only for skipped work | largest |
| Warm-up after ready | baseline | not measured | slowest ramp-up in one test ([gc §7](references/gc-cpu-ram-throughput.md#7-throughput-and-warm-up)) | none if the checkpoint was warmed up; otherwise like JIT only | no JIT |
| RAM | baseline | mapped archive | about equal in Linux containers (reported, URL not recorded; [gc §5](references/gc-cpu-ram-throughput.md#5-rss-and-cpu-time-at-start)); macOS `ps` counts mapped pages | heap and CPU count fixed at checkpoint ([gc §4](references/gc-cpu-ram-throughput.md#4-heap-size-and-cpu-count-are-fixed-at-checkpoint)) | lowest |
| Build cost | none | one training run | one training run; the one-step workflow needs more heap (reported, URL not recorded; [leyden-aot.md §13](references/leyden-aot.md#13-cache-sizes-and-build-times)) | warm-up, checkpoint, [self-test restore, bake into an image layer](references/crac-build-and-deploy.md#3-self-test-restore-then-harvest); per image, environment and config, on the target CPU | minutes and GBs of RAM |
| Privileges | none | none | none | none for `warp`; privileged for `criuengine` | none |
| JDK | any | 12+ | 24+ (one-step `-XX:AOTCacheOutput` 25+), any OpenJDK build | vendor CRaC build, Linux | GraalVM |
| JDWP / agents | all | JDWP works (reported) | JDWP and mismatched JFR discard the cache; OTel agent breaks training | JDWP from the checkpoint launch and JFR work; listener agents block; OTel agent blocks once it exported | experimental JDWP, no `-javaagent` |
| GC | all | all | train with the production GC; a ZGC cache gains -12 to -22 % on 25, about -48 to -54 % on 26+ (two series, [leyden-aot.md §10](references/leyden-aot.md#10-garbage-collectors)) | all five (Serial, Parallel, G1, ZGC, Shenandoah; [gc §1](references/gc-cpu-ram-throughput.md#1-collectors-per-technique)) with `warp` on Zulu 25/27, arm64, demo and PetClinic, first request only; not tested: CRIU with ZGC, other vendors, x86, load after restore, ZGC with a database over the network | Serial, Epsilon; G1 in Oracle GraalVM on Linux |
| Secrets on disk | none | string literals, absolute paths | as CDS plus profiles and archived strings | full plaintext heap and environment | values read at build time |

Details: [debug-agents.md](references/debug-agents.md#1-matrix), [gc-cpu-ram-throughput.md](references/gc-cpu-ram-throughput.md),
[security.md](references/security.md#1-disk-leak-matrix-per-technique).

## Numbers

The headline is a range: extraction plus AOT cache cut 52 % on the fresh Mac, JEP 483 reports -42 % for
the cache alone, a team PetClinic-class app (about the size of Spring PetClinic; see Team Linux below)
went from 2.9 to 0.98 s. Your app can land outside it.

**Fresh Mac** (n = 5, median; noise floor about 7 %, derived from one pair of identical runs that
differed by 6 %; [measuring.md §2](references/measuring.md#2-sample-size-and-noise)):

| Configuration | ms | RSS MB | CPU s |
|---|---|---|---|
| fat JAR, cold | 1212 | 249 | 4.92 |
| extracted JAR, cold | 1053 (-13 %) | 234 | 3.84 |
| fat JAR + dynamic CDS archive | 1050 (-13 %) | 411 | 4.44 |
| extracted + AOT cache | 575 (-52 %) | 261 | 3.19 |
| extracted + AOT cache + `-XX:TieredStopAtLevel=1` | 526 | 173 | 1.11 |

`TieredStopAtLevel=1` gave no measurable start gain, but saved CPU and RSS
([gc §5](references/gc-cpu-ram-throughput.md#5-rss-and-cpu-time-at-start)). The 411 MB RSS is a macOS
`ps` effect of mapped archives (hypothesis), not a container figure. macOS has no real CRaC engine.

**Team Linux, arm64** (Zulu 25.0.4.1, PetClinic-class Spring Boot 4.0.3 app, that is, about the size
of Spring PetClinic, class count not recorded; median of 5, extracted
row of 3): fat JAR 2.925 s, + AppCDS 2.26 s, + AOT cache 1.884 s, extracted + AOT cache 0.98 s,
`criuengine` restore 0.200 s, `warp` 0.176 s. **x86** (x86_64 KVM guest, AMD EPYC, 4 vCPUs, container limited to 2 CPUs with `--cpus=2`, Spring
Boot 4.1.0 app; [measuring.md §10](references/measuring.md#10-team-measurements-and-third-party-numbers)): cold 9.4-10 s, `warp` 0.123 s.

**Linux VM, arm64** (median of 5): demo app extracted cold 1064-1172 ms, AOT cache 571-581 ms on
Temurin 25 to 27 ([leyden-aot.md §10](references/leyden-aot.md#10-garbage-collectors)); `warp` restore
28-74 ms (demo), 43-62 ms (PetClinic, cold about 3 s), all five collectors ([crac-engines.md §4](references/crac-engines.md#4-engine-speed-and-image-size));
native image 53 ms, about 97 MB RSS, 90 s build with 5.3 GB peak ([native-image.md](references/native-image.md)).

**Reported** (own hardware each): JEP 483 PetClinic 4.486 → 2.604 s; buildpack blog 2.379 s → 0.579 s
(AOT cache + Spring AOT) → native 0.117 s. URLs: [leyden-aot.md §17](references/leyden-aot.md#17-numbers).

## Verify it is really used (mandatory)

**Rule:** after every change of the start command, the image, the JDK, the JARs or the collector, prove
that the technique is active. Origin: on the fresh Mac, every rejected AOT cache (touched JAR, missing
file, JDWP, JFR mismatch) started cold in about 1150 ms instead of about 580 ms, with exit code 0
([leyden-aot.md §7](references/leyden-aot.md#7-verify-that-the-cache-is-used-mandatory)); a stale CDS
archive did the same. Reason: a silent fallback looks like success in every exit-code check. Limit:
none; this applies to every technique here.

**AOT cache:**

1. In CI or a test stage, start once with the production flags plus strict mode: `-XX:AOTMode=on`
   (JDK 24-26) or `-XX:AOTMode=required` (JDK 27+), and `-Dspring.context.exit=onRefresh`. The JVM
   then refuses to start without the cache. Do not use strict mode in production: an injected agent
   would stop the app.
2. Count classes from the cache: `-Xlog:class+load`, then count `source: shared objects file`
   (7,685 of 7,958 on the fresh Mac).
3. Search the log for `[error][aot]` and `Unable to map shared spaces`. **`Opened AOT cache` is not
   proof**: the JVM printed it and rejected the cache a few lines later.

**CDS:** same idea, see [cds-appcds.md §6](references/cds-appcds.md#6-verify-that-the-archive-is-used).

**CRaC:** read the text of `jcmd <pid> JDK.checkpoint`, never its exit code (always 0): success prints
`0` after the PID line, and the log ends with `warp: Checkpoint successful!`. Let the wrapper log its
branch, alert on the cold one, and measure time to ready on every rollout ([crac-build-and-deploy.md §9](references/crac-build-and-deploy.md#9-verify-that-the-restore-really-happens)).

## Symptoms

| Symptom | Cause | Reference |
|---|---|---|
| No speed-up after adding the AOT cache, exit 0 | silent fallback: touched JAR, other JDK build, other class path | [leyden-aot.md §6](references/leyden-aot.md#6-constraints), [§7](references/leyden-aot.md#7-verify-that-the-cache-is-used-mandatory) |
| `AOT cache ... cannot be used with JDWP agent` | JDWP discards the cache | [leyden-aot.md §9](references/leyden-aot.md#9-debuggers-jfr-and-java-agents) |
| `Mismatched values for property jdk.module.addmods: jdk.jfr` | JFR in only one of training and production | [leyden-aot.md §9](references/leyden-aot.md#9-debuggers-jfr-and-java-agents) |
| SIGILL with an AOT cache on other x86 hosts | adapters (call stubs between interpreted and compiled code) compiled for a newer CPU | [leyden-aot.md §11](references/leyden-aot.md#11-cpu-features-the-sigill-trap) |
| Fat JAR + cache only -25 % | nested JARs; extract first | [leyden-aot.md §4](references/leyden-aot.md#4-extract-the-fat-jar) |
| `CheckpointOpenSocketException` | open listener or pool connection; port 4318: the OTel exporter | [crac.md §2](../java-debug/references/crac.md#2-what-blocks-a-checkpoint), [crac-build-and-deploy.md §2](references/crac-build-and-deploy.md#2-when-to-take-the-checkpoint), [debug-agents.md §2.4](references/debug-agents.md#24-opentelemetry-java-agent) |
| AOT training: SIGSEGV, or `Critical class java.lang.Class has been excluded` | `-javaagent` (OTel) in training | [leyden-aot.md §9](references/leyden-aot.md#9-debuggers-jfr-and-java-agents) |
| `jdb` gets `Connection refused` after a restore | JDWP given only at restore | [debug-agents.md §2.1](references/debug-agents.md#21-jdwp) |
| `CheckpointOpenFileException` on a log file | file appender | [frameworks.md §4](references/frameworks.md#4-logging) |
| `kcmp ... Operation not permitted` | `criuengine` without privileges | [crac-engines.md §3](references/crac-engines.md#3-privileges-per-runtime-setting) |
| `Restore failed due to incompatible or missing CPU features` | restore on another CPU model | [crac-engines.md §6](references/crac-engines.md#6-cpu-features) |
| `warp: error: Cannot change protection ...`, exit 134 | image on a noexec mount | [crac.md §5](../java-debug/references/crac.md#5-version-traps-and-checkpoint-images) |
| `... is not restore-settable` | flag in `JAVA_TOOL_OPTIONS` at restore | [crac.md §3](../java-debug/references/crac.md#3-what-the-restored-process-sees) |
| Restore not faster than a cold start; or slow first seconds after it | little start work to skip, or a cold page cache; slow first seconds: no warm-up before the checkpoint | [crac-engines.md §4](references/crac-engines.md#4-engine-speed-and-image-size), [measuring.md §3](references/measuring.md#3-page-cache-warm-and-cold) |
| Restored app uses an old setting or credential | value cached at checkpoint; image identity too coarse | [crac-build-and-deploy.md §5](references/crac-build-and-deploy.md#5-identity-of-a-checkpoint), [security.md](references/security.md) |
| `Stream Closed` right after a restore | threads resume before `afterRestore` | [frameworks.md §8](references/frameworks.md#8-writing-a-resource-correctly) |
| A worker stops or misfires right after a restore | deadline or schedule computed before the checkpoint | [frameworks.md §6](references/frameworks.md#6-clocks-deadlines-schedules-and-random-numbers) |
| Start slow in every variant | the app waits on the network | [measuring.md §5](references/measuring.md#5-rule-out-external-dependencies-first) |

## Safety rules

- **Treat checkpoint images and caches as secrets.** A CRaC image holds the whole heap and the process
  environment in plaintext, also variables the app never read (measured 2026-09 and on the Linux VM,
  [security.md §2](references/security.md#2-what-a-crac-image-holds)). Keep files 0600 and directories
  0700, bake with `COPY --chown=<jvm-user>`, never push a checkpoint image to a shared registry, and
  start the checkpoint or training JVM without production secrets. Limit: AOT caches and CDS archives
  held no environment or `-D` canary (a planted dummy secret; fresh Mac), but they hold string literals
  and absolute paths and are written 0644 by default.
- **0 hits does not mean clean.** Scan with `checkpoint-secret-scan.py` and a control string (one known to be in the files), and report
  "0 hits for these encodings" ([security.md §5](references/security.md#5-rule-0-hits-does-not-mean-clean)).
- **No `--privileged`** except for a `criuengine` restore in a throwaway measurement container: it removes the isolation (origin and reason:
  [measuring.md §8](references/measuring.md#8-isolating-the-measurement)).
- **Ask before heavy or disruptive operations:** image builds, benchmark series that load the machine
  for minutes, `jcmd <pid> JDK.checkpoint` (the JVM exits after it), rollouts. Run the scripts only
  against the user's own development or throwaway targets.
- **Isolate measurements:** use a container as a barrier, pin base images by digest, verify checksums of
  downloaded JDKs ([measuring.md §8](references/measuring.md#8-isolating-the-measurement)).

## Do not believe

| Claim | Corrected |
|---|---|
| CRIU does not run on arm64 with the JVM | the cause is privileges; `warp` needs none |
| `warp` runs as two processes, use `pgrep -P 1` | library in the JVM; use `jcmd -l` |
| ZGC is incompatible with CRaC | refuted for `warp` on Zulu 25/27, arm64, demo and PetClinic; CRIU, x86, load untested |
| An AOT cache works with any GC from JDK 26 | it starts, but a G1-trained cache gives no gain under ZGC (19 % slower on 27) |
| Leyden forbids agents / allows them | OTel agent 2.33.1 breaks training; check others with strict mode |
| `System.getenv` is frozen after a restore | contested; set variables override, absent ones keep the old value |
| JFR works fine with an AOT cache | only when training and production match |
| An AOT cache is architecture-neutral | bound to JDK build, OS, architecture and JAR times and sizes |
| A restore is always fast | only when it skips real start work; without warm-up, throughput ramps up like cold |
| `Opened AOT cache` in the log proves use | it does not; see the verify step |

All claims with evidence: [struck-claims.md](references/struck-claims.md).

## Scripts

Run from the skill directory, with absolute paths to the app.

```bash
./scripts/startup-bench.py --runs 5 --baseline-repeat --out /tmp/bench.json -- java -jar /path/app/app.jar
./scripts/checkpoint-secret-scan.py --canary-env CANARY_DB --control 'spring.context.exit' /path/to/crac-dir
```

- `startup-bench.py`: launch until the URL answers 200 (default `http://127.0.0.1:8080/actuator/health`;
  a non-loopback URL needs `--allow-remote`), median, min, max, RSS and CPU, noise check with
  `--baseline-repeat`; warm page cache only. It executes the command after `--`, so the user approves
  each call. Exit codes: [measuring.md §7](references/measuring.md#7-using-startup-benchpy).
- `checkpoint-secret-scan.py`: canary values come from environment variables named with `--canary-env`,
  never from argv. Exit 0 no hit, 1 hit, 2 usage, 3 blind (control not found), 4 internal error.

## Known gaps

Open: moving a checkpoint between Apple Silicon generations (M1 to M5); x86 for every Linux VM result; Kubernetes
variants (containerd, `readOnlyRootFilesystem` and Podman were tried with `warp` only, measured 2026-09;
[crac-engines.md §3](references/crac-engines.md#3-privileges-per-runtime-setting)); a native image of a JPA or
reflection-heavy app, and secrets in a native image; why `AutoCreateSharedArchive` did not refresh a stale archive.
Closed in part (Linux VM): ZGC with CRaC (`warp`, Zulu 25/27, first request only; CRIU, other vendors, x86, load
after restore, network database untested), throughput (one app, one load), native start (demo app), AOT cache on 26/27.

## References

| File | Contents |
|---|---|
| [measuring.md](references/measuring.md) | ready vs "Started", n and noise, page cache, external dependencies, isolation, `startup-bench.py`, evidence classes |
| [cds-appcds.md](references/cds-appcds.md) | default CDS, dynamic AppCDS, `AutoCreateSharedArchive`, stale archives, when CDS beats the AOT cache |
| [leyden-aot.md](references/leyden-aot.md) | AOT cache JEPs, recipes, extraction, Spring AOT, constraints, verification, containers and buildpacks, JDWP/JFR/agents, SIGILL, training, sizes |
| [crac-engines.md](references/crac-engines.md) | vendors, `warp` vs `criuengine`, privileges, restore speed and image size, CPU features, emulation |
| [crac-build-and-deploy.md](references/crac-build-and-deploy.md) | wrapper, on-demand checkpoint, self-test restore, image layer, checkpoint identity, stale variants, rollout, memory, verification, rollback |
| [frameworks.md](references/frameworks.md) | Spring lifecycle, JPA and pools, logging, clocks and randomness, many file descriptors, writing a `Resource` |
| [gc-cpu-ram-throughput.md](references/gc-cpu-ram-throughput.md) | collectors per technique, container ergonomics, fixed heap and CPU count, RSS and CPU at start, CPU feature cost, throughput |
| [security.md](references/security.md) | disk-leak matrix per technique, CRaC image content, mitigations, caches, the 0-hits rule |
| [debug-agents.md](references/debug-agents.md) | JDWP, JFR, JMX, OTel agent, HotswapAgent per technique; strict-mode checks; agent startup cost |
| [native-image.md](references/native-image.md) | native image numbers and constraints, facts only |
| [struck-claims.md](references/struck-claims.md) | refuted, nuanced and contested claims with evidence |
