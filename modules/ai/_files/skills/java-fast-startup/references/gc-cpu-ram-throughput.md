Applies to: all (CRaC rows: Linux only; container rows: containers and Kubernetes)

# Garbage Collectors, CPU, RAM and Throughput

TL;DR: The AOT cache runs under every collector from JDK 26, but it only gains when training used the
production collector: a G1 cache under ZGC was within noise of a cold start on JDK 25 and 26 and 19 %
slower on 27. CRaC (Coordinated Restore at Checkpoint), which restores a saved JVM process, worked
with `warp`, Azul's default CRaC engine ([crac-engines.md §2](crac-engines.md#2-engines)), and all
five collectors on Zulu 25 and 27 (arm64, demo app and PetClinic;
[measuring.md §11](measuring.md#11-linux-vm-measurements)). This refutes "ZGC is incompatible with
CRaC" for that setup; limits in section 1.
A checkpoint fixes the heap size and the CPU count, so set `-Xmx` or `MaxRAMPercentage` explicitly. On
the reference app, the AOT cache with an extracted JAR saved CPU time (4.92 to 3.19 s).
`-XX:TieredStopAtLevel=1` gave no faster start but much less CPU and RSS. Throughput after a start was
measured for one app and one load (section 7): every variant reached the same steady state; a restore
from a warmed-up checkpoint reached it within the first 5 s, an AOT cache needed the longest.

## Contents

- [1. Collectors per technique](#1-collectors-per-technique)
- [2. Heap cleanup before a checkpoint](#2-heap-cleanup-before-a-checkpoint)
- [3. Container ergonomics](#3-container-ergonomics)
- [4. Heap size and CPU count are fixed at checkpoint](#4-heap-size-and-cpu-count-are-fixed-at-checkpoint)
- [5. RSS and CPU time at start](#5-rss-and-cpu-time-at-start)
- [6. CPU features: what a portable checkpoint costs](#6-cpu-features-what-a-portable-checkpoint-costs)
- [7. Throughput and warm-up](#7-throughput-and-warm-up)

## 1. Collectors per technique

| Technique | Serial | Parallel | G1 | ZGC | Shenandoah | Evidence |
|---|---|---|---|---|---|---|
| CDS archive, class metadata | yes | yes | yes | yes | yes | reported (blog, URL not recorded); which collectors can use archived heap objects on older JDKs is unverified |
| AOT cache, JDK 24 and 25 | yes | yes | yes | classes only, if trained with ZGC (-12 % to -22 % on 25, two series) | not stated | reported (JEP 516); measured 2026-11-16 on the fresh Mac ([measuring.md §9](measuring.md#9-reference-setup-of-the-fresh-measurement)) and on the Linux VM ([measuring.md §11](measuring.md#11-linux-vm-measurements)) ([leyden-aot.md §10](leyden-aot.md#10-garbage-collectors)) |
| AOT cache, JDK 26 and later | yes | yes | yes | yes, if trained with ZGC (about -48 % to -54 % on 26 and 27, two series) | all collectors per JEP 516; Shenandoah not named explicitly | reported (JEP 516); measured 2026-11-16, Linux arm64 (OrbStack VM), JDK 26 and 27 |
| AOT compiled code, JDK 28 | yes | yes | yes | yes | yes | reported (JEP 544); same collector in training and production required |
| CRaC, engines warp and criuengine (the CRIU-based engine) ([crac-engines.md](crac-engines.md)) | yes | yes | yes | yes | yes | measured 2026-09 (minimal apps, x86_64, below); measured 2026-11-16, Linux arm64 (OrbStack VM), warp only, demo app and PetClinic ([crac-engines.md §4, table C](crac-engines.md#4-engine-speed-and-image-size)) |
| GraalVM Native Image | yes (default) | no | Oracle GraalVM on Linux only | no | no | reported (GraalVM docs); also Epsilon (a collector that never frees memory) |

**ZGC and CRaC: the claim "incompatible" is refuted for `warp` on Zulu 25 and 27** (see
[struck-claims.md](struck-claims.md)). On arm64, all five collectors, ZGC included, checkpointed and
restored the demo app and PetClinic, and the first request after every restore returned 200 (measured
2026-11-16, Linux arm64 (OrbStack VM); restore times in
[crac-engines.md §4, table C](crac-engines.md#4-engine-speed-and-image-size)). Earlier runs on minimal
apps agree: checkpoint and restore with ZGC worked 9 of 9 times with warp and 6 of 6 times with
criuengine, and the restored JVMs ran 623 to 780 ZGC cycles afterwards (measured 2026-09, Zulu 25 to 27
CRaC, x86_64 Linux containers).

**Not tested:** CRIU (criuengine) with ZGC on a real app, other JDK vendors, x86 with a real app, load
after the restore, and ZGC with a database over the network. Before you use ZGC with CRaC in
production, test a checkpoint and restore of your own app under load.

**Related trap:** this skill's author's team hard-coded ZGC in a checkpoint command for a small container without setting a
heap limit. The container was killed for exceeding its memory limit (measured 2026, Zulu 25, arm64
Kubernetes; exact date not recorded; team measurement, see
[measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers)). The cause was the sizing, not CRaC. Set the collector and the
heap size together (section 4).

## 2. Heap cleanup before a checkpoint

Before a CRaC checkpoint, the JVM calls the `beforeCheckpoint` methods of registered `org.crac.Resource` objects, runs a full garbage collection,
and trims the native heap (reported, JDK source; file not recorded). The purpose is a smaller image, not confidentiality.
`-XX:+DisableExplicitGC` does not switch this collection off.

Objects that the application dropped are not always gone. A team test dropped a secret value (a canary)
before the checkpoint and searched the image for leftover copies (measured 2026-09, Zulu 25 CRaC,
Linux containers; the row marked Zulu 26 used Zulu 26; team measurement, see
[measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers)):

| Collector | Copies left, canary still young | Copies left, canary promoted to the old generation |
|---|---|---|
| G1 | 0 % | about 14 % |
| G1 with `-Xms` equal to `-Xmx` (Zulu 26) | 100 % | 100 % |
| Serial | 0 % | about 28 % |
| Parallel | 0 % | 0.01 % |
| Shenandoah | 100 % | 100 % |
| ZGC | 0 to 100 % | 35 to 97 % |
| Epsilon (a collector that never frees memory) | no collection, everything stays | no collection, everything stays |

Soft references were not cleared by the checkpoint collection. G1 with `-Xms` equal to `-Xmx` does not
shrink the heap below its minimum size, so dropped objects stay in the image.

**Rule:** never rely on the garbage collector to remove secrets from a checkpoint. Treat every
checkpoint image as containing every value the JVM has seen. See [security.md](security.md).

**Limit:** the test used one canary pattern. Parallel had the fewest leftovers in it, and the team
that ran the test recommended Parallel for checkpoint JVMs; the production services used G1. Neither collector
makes the image safe.

## 3. Container ergonomics

Up to JDK 26, a JVM that sees little CPU or little memory selects Serial GC instead of G1. From JDK 27,
G1 is the default in all environments (reported, JEP 523).

**Rule:** set the collector explicitly (`-XX:+UseG1GC`, or another) for every service that uses an AOT
cache with JDK 28 compiled code, or CRaC.

**Reason:** the collector the JVM selects depends on the container limits at start. A cache trained
in a large build container and run in a small pod can meet a different collector. For the class and
object cache this is allowed; for JDK 28 compiled code it discards the code (reported, JEP 544). For
CRaC, the collector of the checkpoint stays after restore (section 4).

**Limit:** on JDK 27 and later, the default no longer depends on the container size, so the rule only
protects against explicit differences.

## 4. Heap size and CPU count are fixed at checkpoint

A restored JVM keeps the heap configuration and the processor count of the checkpointing JVM.

**Rule:** set `-Xmx` or `-XX:MaxRAMPercentage` explicitly in the checkpoint command, and keep the
container's CPU and memory limits the same for checkpoint and restore.

**Reason:** ergonomics run once, at the original start. A checkpoint taken in a pod with 4 GiB and
restored in a pod with 2 GiB keeps a heap sized for 4 GiB. CPU options cannot be changed at restore:
passing `-XX:ActiveProcessorCount`, a CPU feature option, `-XX:UseAVX` or `-XX:-UseSHA` through
`JAVA_TOOL_OPTIONS` at restore made the restore fail (measured 2026-09, Zulu 25 CRaC, x86_64 Linux
container). Azul documents `-XX:CRaCMaxHeapSizeBeforeCheckpoint` to limit the heap before the
checkpoint (reported, vendor docs; URL not recorded).

**Large heaps are not a warp problem.** A service with a 1.2 GB heap restored in 176 ms (measured 2026,
exact date not recorded, Zulu 25, warp, Kubernetes on arm64). The claim that a large heap makes
warp slow is wrong (see [struck-claims.md](struck-claims.md)). **Open inconsistency:** [crac-engines.md](crac-engines.md) gives the same 176 ms under a different setup (Linux VM, measured 2026-09).

## 5. RSS and CPU time at start

**Fresh measurement** (measured 2026-11-16, Temurin 25.0.5, macOS 26, Apple M2 Max 12 cores, no CPU
limit; Spring Boot 4.1.2 demo app, 7,958 classes; n = 5, median; RSS from `ps` right after ready; CPU
is user + system time until the JVM was stopped shortly after ready; setup in
[measuring.md](measuring.md), section 9):

| Configuration | Start ms | RSS MB | CPU s |
|---|---|---|---|
| fat JAR, cold | 1212 | 249 | 4.92 |
| fat JAR, cold, `-XX:TieredStopAtLevel=1` | 1299 | 176 | 2.04 |
| extracted JAR, cold | 1053 | 234 | 3.84 |
| fat JAR + dynamic CDS archive | 1050 | 411 | 4.44 |
| fat JAR + AOT cache | 887 to 903 | 413 to 426 | 4.08 to 4.14 |
| extracted + AOT cache | 575 | 261 | 3.19 |
| extracted + AOT cache + `-XX:TieredStopAtLevel=1` | 526 | 173 | 1.11 |

**`-XX:TieredStopAtLevel=1`** stops the JIT after the C1 compiler (the fast JIT compiler); C2 (the optimising JIT
compiler) never runs. It gave no faster
start (1299 against 1212 ms, inside the noise). It saved CPU time (2.04 against 4.92 s) and RSS (176
against 249 MB). With the extracted JAR and the AOT cache: 526 ms, 173 MB, 1.11 CPU seconds.

**Limit:** without C2, peak throughput of long-running code is lower. Use it for short-lived tools,
batch jobs, or pods where CPU at start is the bottleneck. The throughput cost was not measured here.

**RSS with a mapped archive:** with a dynamic CDS archive or an AOT cache on the fat JAR, macOS `ps`
reported about 410 MB instead of about 240 MB. The extracted JAR with the AOT cache stayed at 261 MB.
The likely cause is how macOS counts mapped archive pages in RSS; this is a hypothesis. It does not
transfer to container memory limits: third-party Linux benchmarks show about equal RSS with and without
a cache (reported, blog, URL not recorded: 189 MB cold, 195 MB with AppCDS, 184 MB with AOT cache and Spring AOT).

**CPU at start matters in small pods.** A JVM limited to two CPUs spends start time waiting for the JIT
threads. JEP 544 reports that compiled code in the cache reduces this contention on 2-core systems
(reported, JEP 544). Many JVMs that start at once on one node compete the same way; a CRaC restore
avoids most of this work (not measured).

**RSS after a CRaC restore** depends on how the engine maps the image. warp, Azul's checkpoint
engine, maps the image file into memory by default (option `direct_map=true`) instead of copying it.
With `direct_map=true`, a 91 MB image gave 15.7 MB anonymous RSS plus 13.1 MB shared RSS; with
`direct_map=false`, 97.7 MB anonymous RSS (measured 2026-09, Zulu 25 CRaC with warp, Linux container).
Details and traps: [crac-build-and-deploy.md](crac-build-and-deploy.md).

## 6. CPU features: what a portable checkpoint costs

A CRaC image is bound to the CPU features of the machine that took it. Zulu CRaC on x86_64 can
restrict the features at checkpoint, so the image runs on more machines (see
[crac-engines.md](crac-engines.md)). The price is lost intrinsics, the hand-written machine-code
versions of JDK methods.

`-XX:CPUFeatures=generic` makes the checkpointing JVM use only a baseline x86_64 feature set
(for example, no AVX and no AES or SHA instructions), so the image restores on almost any x86_64 CPU.
With that setting, compared with the default
(measured 2026-09, Zulu 25.0.4 CRaC, x86_64 Linux container, n = 3):

| Operation | Slowdown |
|---|---|
| SHA-256 | 6.5 times slower |
| AES-GCM | about 54 times slower |
| CRC32C | 14 times slower |
| a vectorisable loop | 2.6 times slower |
| `System.arraycopy` | no change |
| start and restore time | no change |

**Rule:** use a portable feature setting only when the image really has to run on different CPU types.
For a service that does TLS, hashing or checksums, the slowdown can cost more than the start saves.

The AOT cache has its own CPU-feature trap (adapter code, SIGILL); see [leyden-aot.md](leyden-aot.md),
section 11.

## 7. Throughput and warm-up

**Measured: requests per second after the start** (measured 2026-11-16, Linux arm64 (OrbStack VM);
PetClinic, Zulu CRaC 25.0.5, container `--cpus=2 -m 1g`, G1, `-Xmx768m`; load generator `oha` 1.16
with 4 connections on `/vets.html`; 12 windows of 5 s, starting at the first health 200; n = 2 series per
variant, the table shows series 1). How far the two series differ depends on the window:

- **Window 1 (0-5 s):** up to 16 % in requests per second (restore without warm-up: 1048 against
  1220), and up to 30 % in p99 (cold start: 36.3 against 41.2 ms; warmed-up restore: 16.8 against
  21.8 ms).
- **Windows 2 and 3 (5-15 s):** at most about 8 % in requests per second.
- **Steady state (15-60 s):** the median per series differed by at most 5 %. Single windows differed
  more, up to 40 %, because of one dip to 3479 in cold series 1.

The early windows are therefore the least stable part of this table.

| Start variant | 0-5 s | 5-10 s | 10-15 s | 15-60 s range | p99 ms, first two windows | ready incl. `docker run` |
|---|---|---|---|---|---|---|
| cold start, JIT | 1477 | 3549 | 4817 | 3479 to 5034 | 36 / 7.1 | 3.8 to 4.3 s |
| AOT cache | 553 | 1870 | 3698 | 4362 to 4738 | 59 / 30 | 2.1 s |
| CRaC restore, checkpoint without warm-up | 1048 | 3172 | 4708 | 4338 to 4849 | 51 / 17 | 0.8 to 0.9 s |
| CRaC restore, checkpoint after 3000 requests | 3020 | 4622 | 4642 | 4284 to 4906 | 17 / 2.2 | 0.8 to 0.9 s |

- **Steady state is the same** for all four, within ±5 % (4.6 to 4.9 k requests per second).
- **The AOT cache starts sooner but warms up slower** than a cold start in this run: fewer requests in
  each of the first three windows. The cache brings classes and profiles, not compiled code (before JDK
  28), so the JIT still has to compile; that it lagged behind the cold start is measured, the cause is
  not.
- **Only a warmed-up checkpoint skips the warm-up.** Without warm-up requests before the checkpoint,
  the restored JVM ramps up like a cold one, just from an earlier ready time.
- Memory after the series (`docker stats`): cold 372 to 385 MiB, AOT cache 334 to 362, restore without
  warm-up 264, with warm-up 192 to 283.
- **Limit:** one small app, one endpoint, one load level, two CPUs, n = 2. The `docker run` overhead in
  the ready times is about 0.3 s.

Further evidence:

- **Steady state:** a third-party benchmark measured 4 to 5 ms per request in steady state for all JVM
  variants it tested: cold, AppCDS, AOT cache, AOT cache with Spring AOT (reported,
  [blog](https://ankurm.com/spring-boot-jdk-aot-cache-jep-514-515-startup-benchmarks/); Spring Boot
  4.1.1, Temurin 25.0.4.1, 2 vCPU).
- **First request:** in the same benchmark, training the AOT cache with traffic instead of only the
  context refresh cut the first request from 142.8 to 67.7 ms (reported, blog). See
  [leyden-aot.md](leyden-aot.md), section 12.
- **Peak with JDK 28 compiled code:** JEP 544 states that AOT code and the JIT coexist and that the
  JVM reaches roughly the same steady state (reported, JEP 544).
- **After a CRaC restore:** the JIT state comes from the image, and the speed ratios between compiled
  code paths were the same after the restore (measured 2026-09, Zulu 25 CRaC, Linux container).
  Connection pools and TLS sessions start empty. A service that fans out to external partners returned
  fewer results on its first calls after a restore, until its pools refilled (measured 2026-09, Zulu 25
  CRaC, arm64 Kubernetes, one service).
- **Native Image:** no JIT; peak throughput reported lower without profile-guided optimisation; see
  [native-image.md](native-image.md).

**Rule:** if throughput matters, measure it yourself under load, after the start, for each technique.
Do not conclude from a start time that the steady state is unchanged.
