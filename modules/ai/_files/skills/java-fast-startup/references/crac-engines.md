Applies to: CRaC on Linux (x86_64 and aarch64), in containers and Kubernetes; macOS and Windows only as a simulation for callback tests

# CRaC Engines, Vendors, Platforms and CPU Features

TL;DR: CRaC (Coordinated Restore at Checkpoint) is not part of mainline OpenJDK. You get it from vendor
builds such as Azul Zulu and BellSoft Liberica, on Linux only. Choose the engine by the privileges that
your container has, not by CPU architecture: `warp` needs no extra privileges, and `criuengine` needs a
fully privileged container for a restore. A checkpoint is bound to the CPU features of the machine that
wrote it. Write it on the target hardware, never under QEMU, Rosetta or another cross-architecture
emulator, and never push it to a shared registry. The debugging basics (engine selection, `jcmd`, CRIU
privilege steps, glibc 2.42, noexec mounts) live in
[java-debug crac.md](../../java-debug/references/crac.md). This file adds only what is missing there.

## Contents

- [1. Where CRaC comes from](#1-where-crac-comes-from)
- [2. Engines](#2-engines)
- [3. Privileges per runtime setting](#3-privileges-per-runtime-setting)
- [4. Engine speed and image size](#4-engine-speed-and-image-size)
- [5. Versions, glibc and kernel](#5-versions-glibc-and-kernel)
- [6. CPU features](#6-cpu-features)
- [7. Platforms and emulation](#7-platforms-and-emulation)
- [8. Container-level checkpoints](#8-container-level-checkpoints)
- [9. Claims not to believe](#9-claims-not-to-believe)

Evidence markers: "measured <date>, <JDK>, <setup>" means the skill's author ran it. "reported (<source
type>)" means a public source states it and nobody here repeated it. "reported, team <date>" marks a
finding from the skill author's unpublished work, not a public source and not re-measured here; see
[measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers). "not measured" means
nobody checked. **Open inconsistency:** the marker "reported, team <date>" is defined here, in [frameworks.md](frameworks.md) and in [crac-build-and-deploy.md](crac-build-and-deploy.md) only; [measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers) and [SKILL.md](../SKILL.md) define "reported" for public sources only.

## 1. Where CRaC comes from

| Vendor build | JDK versions | Platforms with a real engine | Evidence |
|---|---|---|---|
| Azul Zulu (CRaC builds) | 17, 21, 24, 25, 26; 27 per the Zulu 27 release notes | Linux x64 and aarch64, also Alpine 3.16 and later | reported (vendor docs) |
| Azul Zing (Prime) | 17, 21 from build 25.08.1.0 | Linux; `warp` and simulation engine | reported (vendor docs) |
| BellSoft Liberica (CRaC bundle) | 25 LTS | Linux x86_64 and AArch64 | reported (vendor blog) |
| OpenJ9 / Semeru | own mechanism (`-XX:+EnableCRIUSupport`), not the CRaC API of this file | Linux | reported (vendor docs) |

- **Not in mainline OpenJDK.** The JDK 26 and JDK 27 feature lists do not mention CRaC, and no JEP for
  CRaC was found on 2026-11-16. This is a finding of absence, not a statement by OpenJDK. The work
  continues in the OpenJDK `crac` project repository,
  [github.com/openjdk/crac](https://github.com/openjdk/crac) (reported, project page).
- **Consequence:** CRaC ties you to a vendor build. Every other fast-startup technique of this skill
  ([cds-appcds.md](cds-appcds.md), [leyden-aot.md](leyden-aot.md)) runs on any OpenJDK build. Weigh that
  before you build a deployment around CRaC.

## 2. Engines

The engine is the component that writes and reads the process image. Select it with
`-XX:CRaCEngine=<name>`. Engine selection on restore, the `help` option and the process layout of
`warp` are in [crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines).

| Engine | What it is | Where it runs |
|---|---|---|
| `warp` | Azul's own engine, a library inside the JVM process. Default engine of Zulu 25.0.5 CRaC | Linux; no extra privileges |
| `criuengine` | Adapter from the JVM to CRIU (Checkpoint/Restore In Userspace), the Linux tool that dumps a process tree to files | Linux; restore needs a privileged container |
| `simengine` | Simulation. Writes no image; a checkpoint is a no-op | Default on macOS and Windows; for testing `Resource` callbacks only |

- **"CRaC uses CRIU" is outdated.** The Zulu builds measured here used `warp` by default (measured
  2026-11-15, Zulu 25.0.5 CRaC, container on arm64). Older articles describe CRIU as the only engine.
- **PIDs differ by engine.** A `warp` restore gives the JVM new PIDs. A CRIU restore recreates the old
  PIDs, and a collision with a running process stops the restore (measured 2026-09, Zulu 25, Linux
  container). The fix `-XX:CRaCMinPid` is in
  [crac-build-and-deploy.md §8](crac-build-and-deploy.md#8-memory-heap-cpu-and-pids).
- **`warp` options** listed by `-XX:CRaCEngineOptions=help` (measured 2026-09, Zulu 25): `direct_map`,
  `keep_running`, `save_zero_pages`, `load_concurrency`, `vdso_always_proxify`, `brk_mode` and
  `log_level` (`perf` prints timings). No option excludes a memory region from the image. Read the `help`
  output of your build before you use one; this list is not a contract.
- **CRIU checks file sizes on restore.** A file that the JVM had open, such as a log file that stdout went
  to, must exist with the same size. A redirected stdout log that grew after the first restore broke the
  second restore (measured 2026-09, Zulu 25, `criuengine`, Linux container). `warp` writes to the
  stdout of the restore command instead, see
  [crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees).

## 3. Privileges per runtime setting

The step-by-step CRIU table (unprivileged, capabilities, privileged; uid 1000 and root) and the setuid
warning for the bundled `criu` binary are in
[crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines). This table adds the runtime
settings that were tried with `warp`.

| Runtime setting | `warp` | `criuengine` |
|---|---|---|
| Docker, default seccomp profile, non-root | checkpoint and restore work | checkpoint fails: `kcmp ... Operation not permitted` (`kcmp` is the Linux system call that checks whether two processes share a kernel resource) |
| Docker, `CAP_CHECKPOINT_RESTORE` + `CAP_SYS_PTRACE` | not measured separately; the row above already works | checkpoint works; restore fails: `Can't fork ... Read-only file system` (`/proc/sys/kernel/ns_last_pid` is read-only) |
| Docker, `--privileged` | not measured separately; not needed | checkpoint and restore work |
| Podman | works | not measured |
| containerd 2.3.1, seccomp `RuntimeDefault`, non-root, all capabilities dropped, `readOnlyRootFilesystem` | works if `/tmp` is writable | not measured |

All rows: measured 2026-09, Zulu 25, Linux containers (Docker on arm64 and x86_64; Kubernetes with
containerd), and the Docker rows again 2026-11-15, Zulu 25.0.5 CRaC, Docker on arm64.

- **Rule: decide the engine by privileges.** Origin: the claim "CRIU does not run on arm64 with the JVM"
  came from a failed checkpoint in a normal container. Reason: the failure was the missing `kcmp` and
  `ns_last_pid` rights, and the same JVM checkpointed and restored on arm64 under `--privileged`. Limit:
  a production pod rarely gets `--privileged`, so in practice this leaves `warp` for most clusters.
- **Writable `/tmp`:** `warp` needs it for the restore. Details and numbers are in
  [crac-build-and-deploy.md §8](crac-build-and-deploy.md#8-memory-heap-cpu-and-pids).
- Public sources disagree on what CRIU needs. One cloud vendor blog names `CHECKPOINT_RESTORE` plus
  `SYS_PTRACE` on kernel 5.9 or later, and a privileged container on older kernels (reported, vendor
  blog). A 2026 benchmark took its checkpoint with `--privileged` (reported, blog). The table above is
  what worked here; your runtime can differ.

## 4. Engine speed and image size

Each of the three tables compares variants inside one setup only. Do not compare numbers across the
tables: the CPU, the JDK build and the app differ.

**Table A: arm64, PetClinic-class app** (measured 2026-09)

| App | JDK | OS | CPU limit | Metric |
|---|---|---|---|---|
| PetClinic-class web app, Spring Boot 4.0.3 | Zulu 25.0.4.1 | Linux VM on arm64, container | not recorded | median of 5, `java` launch to first `/actuator/health` 200 |

| Variant | Time |
|---|---|
| Cold start, fat jar | 2.925 s |
| `criuengine` restore (CRIU 4.2.1, root) | 0.200 s |
| `warp` restore (warp 2.10.2, unprivileged) | 0.176 s |

- Time inside the JVM for the restore: `warp` 22 to 26 ms, CRIU 83 to 93 ms.
- Image size: 230 to 245 MB for both engines. `warp` writes 2 files, CRIU 56 to 60 files.
- Writing the checkpoint took about 2.8 s.

**Table B: x86_64, Spring Boot app** (measured 2026-09)

| App | JDK | OS | CPU limit | Metric |
|---|---|---|---|---|
| Spring Boot 4.1.0 web app | Zulu 25 | Linux KVM guest, AMD EPYC-Milan, 4 vCPU | `--cpus=2` | `java` launch to app ready |

| Variant | `warp` | `criuengine` |
|---|---|---|
| Cold start | 9.97 s | 9.37 s |
| Restore, image in page cache | 0.123 s | 0.168 s |
| Restore, image on tmpfs | 0.147 s | 0.175 s |
| Restore, page cache dropped | 0.416 s | 0.503 s |
| Restore after decrypting the image with a separate tool ([security.md §3](security.md#3-mitigations)) | 0.66 s | 0.71 s |
| `jcmd` checkpoint request to process end | 0.66 s | 0.74 s |
| Image size | 237 to 251 MB | 237 to 251 MB |

**Table C: arm64, warp, every collector** (measured 2026-11-16, Linux arm64 (OrbStack VM, a Linux VM
on macOS); setup in [measuring.md §11](measuring.md#11-linux-vm-measurements))

| App | JDK | Heap | Checkpoint | Metric |
|---|---|---|---|---|
| demo app (Spring Boot 4.1.2, extracted with `-Djarmode=tools extract`, see [measuring.md §11](measuring.md#11-linux-vm-measurements)); PetClinic (Spring Boot 4.1.0, JPA, HikariCP, H2) | Zulu CRaC 25.0.5 and 27, `warp` | `-Xmx512m` demo, `-Xmx768m` PetClinic | `jcmd <pid> JDK.checkpoint` after 300 requests (demo) or after ready without requests (PetClinic) | restore command to first `/actuator/health` 200, median of 5, ms |

| App | JDK | G1 | Parallel | Serial | ZGC | Shenandoah | cold start, G1 |
|---|---|---|---|---|---|---|---|
| demo | 25 | 41 | 38 | 38 | 53 | 45 | 1386 |
| demo | 27 | 40 | 28 | 38 | 74 | 65 | 1303 |
| PetClinic | 25 | 62 | 54 | 56 | 57 | 50 | 2991 |
| PetClinic | 27 | 48 | 46 | 43 | 62 | 51 | 3298 |

- All 20 combinations checkpointed and restored, and the first request after every restore returned 200.
  The checkpoint took 0.33 to 0.75 s wall time.
- ZGC images were the largest: 14 to 24 % above G1 for the same app and JDK (demo 155 to 161 MiB,
  PetClinic 282 to 284 MiB). Restored RSS was 122 to 160 MB (demo) and 181 to 254 MB (PetClinic), highest
  with ZGC. `core.img` was 0600 in every run.
- **Limit:** only `warp`, only Zulu 25 and 27, and only the first request after the restore was
  checked; ZGC cycles after the restore and long-running behaviour were not observed here (see the
  2026-09 runs in [gc-cpu-ram-throughput.md §1](gc-cpu-ram-throughput.md#1-collectors-per-technique)).
- **Table C mixes two checkpoint regimes:** the demo app took 300 requests before the checkpoint,
  PetClinic none. Compare collectors within one row, not the demo rows with the PetClinic rows.
- PetClinic restored in 43 to 62 ms although no request ran before the checkpoint: the skipped work is
  the Spring context start (about 3 s cold). A restore needs skipped work, not necessarily traffic.

- **The page cache hides a cost.** The first read of all pages of a 238 MB image took 317 ms (`warp`) and
  420 ms (CRIU), against 11 to 17 ms when the pages were cached (same setup). Measure a restore after a
  node reboot or on a fresh node, not only the second restore on a warm node. See
  [measuring.md](measuring.md).
- **A restore is only fast when the checkpoint skipped real work.** A trivial app with almost no start
  work restored about as fast as it started cold, see
  [crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines).
- **A large heap is not a `warp` problem.** A service with a 1.2 GB heap restored in 176 ms (measured
  2026, exact date not recorded, Zulu 25, warp, Kubernetes on arm64). **Open inconsistency:** Table A above lists the same 176 ms for warp 2.10.2 on a Linux VM (measured 2026-09, PetClinic-class app); whether both are one run is not recorded.

## 5. Versions, glibc and kernel

The glibc 2.42 guard-region problem (which CRIU and `warp` versions fail, how to check a running JVM, and
which base images avoid it) has one owner:
[crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images). Read it before
you choose a base image. This file adds only these reported points, none re-measured here:

- Kernel and CRIU must match. The kernel, glibc 2.42 and CRIU version facts have one owner:
  [crac.md section 5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images). CRIU
  older than 4.2 also failed to dump INET sockets on kernel 6.16 or later (reported; source not
  recorded).
- On arm64, CRIU needs version 4.1 or later for the vDSO (the small shared library that the kernel maps
  into every process) hash table of current kernels (reported, team 2026-09).
- The OpenJDK `crac` project dropped its own CRIU fork (reported, team 2026-09). Azul does not support an
  upstream CRIU inside Zulu (reported, team 2026-09). If you need CRIU, take the version that your JDK
  build bundles and check it against the glibc and kernel of your base image.

## 6. CPU features

A checkpoint holds machine code that the JIT compiler wrote for the CPU of the checkpoint host. A restore
on a CPU without one of those instructions crashes with SIGILL, or the JVM refuses the restore first.

**x86_64, Zulu 25.0.4 and later** (measured 2026-09, Zulu 25, KVM guests on x86_64):

- The image stores the CPU architecture and a bitmap of CPU features.
- By default, the restore accepts a host that has all the features in the image (the image's features are
  a subset of the host's).
- `-XX:CheckCPUFeatures=exact` requires equal feature sets.
- A missing feature stops the restore with
  `Restore failed due to incompatible or missing CPU features`.
- Bypass options exist (`CheckCPUFeatures=skip`, `IgnoreCPUFeatures`). Do not use them in production.
  Reason: they turn a clean refusal into a possible SIGILL at an unknown later point. Check the exact flag
  names of your build with `java -XX:+PrintFlagsFinal -version`.
- `-XX:CPUFeatures=generic` at checkpoint time limits the JIT to a baseline (`UseAVX=0`, `UseSSE=2`, no
  AES, SHA, FMA, BMI or POPCNT intrinsics). The native code of `libjvm` itself (for example `memset`,
  `memmove`, `strlen`) still uses AVX2, so a restore on a CPU without AVX2 will probably still crash
  (not measured).
- **The cost of `generic`** (measured 2026-09, Zulu 25, x86_64 KVM guest, n=3): SHA-256 6.5 times
  slower, AES-GCM about 54 times slower, CRC32C 14 times slower, a vectorizable loop 2.6 times slower,
  array copy unchanged. Start and restore times did not change. Use `generic` only when the target
  hardware is really unknown, and measure your crypto and checksum paths.
- CPU options are not restore-settable (`ActiveProcessorCount`, `CPUFeatures`, `UseAVX`, `-UseSHA`).
  Passed through `JAVA_TOOL_OPTIONS` to a restore, they abort it (measured 2026-09, Zulu 25). See
  [crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees) for restore-settable
  flags.

**aarch64:**

- Zulu 25 and 26 do not check CPU features on aarch64 (measured 2026-09, Zulu 25: `-XX:+ShowCPUFeatures`
  prints no architecture-specific feature strings). Zulu 27 is reported to add the checks (reported,
  vendor release notes).
- Reported problems (vendor release notes, not measured): moving an image between server CPU generations
  with different SVE (Arm Scalable Vector Extension) vector lengths crashes with SIGILL (workaround
  `-XX:MaxVectorSize=16`); differences in pointer authentication (PAC, an Arm feature that signs
  pointers) need `-XX:-UsePAC` (Zulu 27 only).
- Moving an image between Apple Silicon generations (for example M1 to M5) was not measured.

**Other reported points:** restores that failed between AMD and Intel hosts (reported, vendor issue
tracker); the bundled CRIU 3.17.1 does not know the 16 KiB XSAVE area (where the CPU saves extended
register state) of AMX (Intel Advanced Matrix Extensions) (reported, team 2026-09).

**Rule:** write the checkpoint on the same CPU model that runs the restore, and pin the workload to such
nodes (node labels, node affinity). Origin: the measured refusals and crashes above. Reason: the JIT code
in the image uses the instructions of the checkpoint host. Limit: inside one homogeneous node pool, one
image serves all nodes. Expiry: none; this is how compiled code works.

## 7. Platforms and emulation

- **Linux only.** macOS and Windows have only `simengine`, which writes no image (see
  [crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)). On a Mac, run the real
  engines in a Linux container or VM.
- **Never write a checkpoint under QEMU, Rosetta or another emulator for a foreign architecture.**
  Origin: a team reported that the CRaC JVM did not start at all under QEMU in a cross-arch build
  (date not recorded). Reason: the emulated CPU reports features that the real target does not have, or lacks features
  that it has, and the JIT code in the image follows the emulated CPU (see §6). Limit: building the
  plain application image cross-arch is fine. Only the step that runs the JVM and writes the checkpoint
  must happen on the target architecture and CPU. A common split: CI builds the plain image on any
  runner; the target host or node writes the checkpoint and bakes it into an image layer
  ([crac-build-and-deploy.md](crac-build-and-deploy.md)).
- **Never push a checkpoint image to a shared registry.** Two reasons: the image is CPU-bound (§6), and
  it contains a plaintext copy of the heap, including environment variables that the app never read
  (see [security.md](security.md)). Keep checkpoint images on the node that wrote them or in a store with
  the access rules of a secret.

## 8. Container-level checkpoints

Status 2026-11 (all reported, from release notes and issue trackers; not measured): Docker
`start --checkpoint` fails since Docker 28 unless the container uses host networking; containerd removed
container restore in 2.4.0; CRI-O 1.37 disables it; Kubernetes `ContainerCheckpoint` is beta, and
pod-level checkpoint and restore ([KEP-5823](https://www.kubernetes.dev/resources/keps/5823/)) is
planned as alpha for Kubernetes 1.38. CRaC does not need any of these: the engine runs inside the
container, and the image ships as a file or an image layer.

## 9. Claims not to believe

The full list is in [struck-claims.md](struck-claims.md). These lines concern engines and platforms:

| Claim | Verdict |
|---|---|
| CRIU does not run on arm64 with the JVM | Struck. The cause was privileges (EPERM on the `kcmp` system call, read-only `ns_last_pid`); `warp` needs none (measured 2026-09, Zulu 25, Docker) |
| `warp` runs as two processes, find the JVM with `pgrep -P 1` | Struck. `warp` is a library in the JVM process; there are two processes only when the `java` launcher is PID 1. Use `jcmd -l` ([crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)) |
| A restore is always fast | Nuanced. The start gains only by the work the checkpoint skips, so a trivial app gains almost nothing. A checkpoint without warm-up still skips the framework start (PetClinic 43 to 62 ms against 3.0 to 3.3 s cold, table C), but the first seconds of throughput stay like a cold JIT start ([gc-cpu-ram-throughput.md §7](gc-cpu-ram-throughput.md#7-throughput-and-warm-up)). A cold page cache costs 0.4 to 0.5 s more (§4; **open inconsistency:** the restore table in §4 shows a difference of only 0.29 to 0.34 s) |
| A large heap is a `warp` problem | Struck. 1.2 GB heap restored in 176 ms (§4) |
| `warp` <= 2.9.0 crashes on glibc 2.42 | Reported by a team (2026-09), not re-measured; `warp` 2.12.0 works (measured 2026-11-15). Owner: [crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images) |
| CRaC always uses CRIU | Outdated. `warp` is the default of the Zulu builds measured here (§2) |
