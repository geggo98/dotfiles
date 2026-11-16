Applies to: all (macOS, Linux, containers and Kubernetes)

# Measuring JVM Startup Fairly

TL;DR: Measure from the `java` launch until the first HTTP 200 of a health endpoint, not until the
"Started" log line. Run each configuration at least five times and compare medians. On the reference
machine (section 9), two runs with identical flags differed by 6 % (measured 2026-11-16), so treat differences below about 7 % as
equal. Check that the time is spent in the JVM at all: a slow external dependency can dominate the
start. Use [`../scripts/startup-bench.py`](../scripts/startup-bench.py) for the runs.

Numbers in this file carry one of three markers: `measured <date>, <JDK>, <setup>`,
`reported (<source type>)`, or `not measured`. A number without a marker does not belong here.
Reason: an unmarked number cannot be traced to a setup, so nobody can tell whether it is comparable
(§2) or still true.

## Contents

- [1. What to measure: ready, not "Started"](#1-what-to-measure-ready-not-started)
- [2. Sample size and noise](#2-sample-size-and-noise)
- [3. Page cache: warm and cold](#3-page-cache-warm-and-cold)
- [4. Pod ready is not JVM ready](#4-pod-ready-is-not-jvm-ready)
- [5. Rule out external dependencies first](#5-rule-out-external-dependencies-first)
- [6. Memory during warm-up](#6-memory-during-warm-up)
- [7. Using startup-bench.py](#7-using-startup-benchpy)
- [8. Isolating the measurement](#8-isolating-the-measurement)
- [9. Reference setup of the fresh measurement](#9-reference-setup-of-the-fresh-measurement)
- [10. Team measurements and third-party numbers](#10-team-measurements-and-third-party-numbers)
- [11. Linux VM measurements](#11-linux-vm-measurements)

## 1. What to measure: ready, not "Started"

**Rule:** measure the time from the launch of `java` until the first `GET` on a health or readiness
endpoint returns 200. Do not use the "Started ... in X seconds" line of Spring Boot.

**Reason:** the "Started" line comes before the first request is served. The first request still
initialises the web layer (in Spring MVC, the `DispatcherServlet`). It also excludes the JVM's own
start before Spring logs anything. In the reference run, the health 200 came about 0.2 s after the
"Started" line (measured 2026-11-16, Temurin 25.0.5, macOS on Apple M2 Max, Spring Boot 4.1.2 demo
app). A user waits for the 200, not for the log line.

**Limit:** the health endpoint must be cheap. A health check that calls a database or a remote service
measures that dependency too. For a batch program without HTTP, measure until the first unit of real
work is done, and say so next to the number.

Poll the endpoint with a short interval. The reference run polled every 5 ms. A coarse interval, such
as 100 ms, adds up to that much error to every sample.

## 2. Sample size and noise

**Rule:** run each configuration at least five times (n ≥ 5) and report the median, the minimum and
the maximum. Compare medians only.

**Reason:** single runs scatter. A control run on the reference machine used the default flags
spelled out explicitly (`-Xshare:auto`), so it was the same configuration as the baseline. Its median
was 1282 ms against 1212 ms for the baseline, 6 % apart (measured 2026-11-16, Temurin 25.0.5, macOS
on Apple M2 Max, n = 5 each). Differences below about 7 % therefore mean nothing on that machine.

**Limit:** the 7 % threshold comes from one pair of runs on one machine. It is a lower bound for the
noise, not a measured constant. On a shared CI runner or a busy laptop, expect more. Run the same
command twice with `--baseline-repeat` (§7) to see the noise of your own setup.

Pairs that fall inside the noise are equal. Say "equal" in the text, even when one median is lower:
inside the noise, the lower median is chance, not a gain.

**Rule:** compare numbers only inside one table, from one machine, one JDK build and one app. A
startup time on a 12-core laptop and a startup time in a container limited to two CPUs are not
comparable. Ratios from different setups are not comparable either.

**Reason:** CPU count and limit, the JDK build and the size of the app all change the start time, so
a difference across setups mixes their effect with the effect of the technique (§9 notes the same
for app size).

## 3. Page cache: warm and cold

The operating system keeps recently read files in memory (the page cache). The second start reads
the JAR files, the JDK modules and any archive from memory. The first start after a reboot, or on a
fresh node, reads them from disk.

**Rule:** say which case you measured. Five runs in a row measure the warm case.
[`startup-bench.py`](../scripts/startup-bench.py) never drops the page cache, so it always measures
the warm case.

**Reason:** the cold case can cost more than the technique saves. A CRaC restore (Coordinated Restore at Checkpoint: the JVM restores a saved process
image; see [crac-engines.md](crac-engines.md)) of a 238 MB image
took 0.12 s with a warm page cache and 0.42 s with a cold one (measured 2026-09, Zulu 25 CRaC with
warp, x86_64 KVM guest with 4 vCPUs, container limited to 2 CPUs). The first read of all pages of
that image took 317 ms, against 11 to 17 ms when warm (same setup).

**Limit:** dropping the cache needs root on Linux (`/proc/sys/vm/drop_caches`) and a privileged
command on macOS. Measure the cold case only when cold starts matter, for example for scale-from-zero.
The cold case for an AOT cache file is not measured.

## 4. Pod ready is not JVM ready

In Kubernetes, a pod is "ready" when all its containers pass their readiness probes. That time
includes image pull, sidecar start and probe intervals.

- A pod with sidecars took about 20 s to become ready, while its JVM restored in 153 ms (measured
  2026-08, Zulu 25 CRaC with warp, arm64 Kubernetes; team measurement, §10).
- Without a readiness probe, Kubernetes marked a container ready after 2.0 s, but the app answered
  its first real request after 11.2 s (measured 2026-08, Zulu 25, arm64 Kubernetes; team
  measurement, §10).

**Rule:** measure the JVM and the pod separately. Report which one a number describes. Give the pod
a readiness probe that checks the app, so that "ready" means the app answers.

## 5. Rule out external dependencies first

**Rule:** before you tune the JVM, check what the application waits for during start.

**Origin:** a service that needed minutes to start was not slowed by the JVM. It read many secrets
at start through a proxy, and each read waited for its full connect timeout on an unreachable
upstream. The waits added up (measured 2026 in a Kubernetes setup; exact figures not kept here).

**Reason:** no JVM technique removes network time. CDS, an AOT cache or CRaC save seconds of class
loading and JIT warm-up. A blocked connection costs its full timeout.

**How to check:**

- Take a thread dump during the slow phase (`jcmd <pid> Thread.print`) and look for threads in socket
  reads or connection setup.
- Record the start with JFR and look at socket and file events with long durations. See
  [`../../java-debug/references/jfr.md`](../../java-debug/references/jfr.md).
- Start the app once with the dependency unreachable and once with it fast, and compare.

## 6. Memory during warm-up

The first minutes of a JVM need more memory than steady state: the JIT compiles, caches fill, and
the heap grows before the first full collections.

One service needed a 6 GiB memory limit during its cold start and warm-up. It ran at 3 GiB in steady
state (earlier run by the skill's author on arm64 Kubernetes; exact date and cluster details not recorded). With 3 GiB, the kernel
killed the container during warm-up.

**Rule:** set the memory limit from the peak of the start and warm-up phase, not from the steady
state. Measure the peak RSS with `startup-bench.py` (§7) or from the container's cgroup.

**Limit:** a CRaC restore skips the warm-up and its peak. An AOT cache shortens the start but the
JIT still warms up after it (see [gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md)).

## 7. Using startup-bench.py

[`../scripts/startup-bench.py`](../scripts/startup-bench.py) starts a command several times and
measures each run until a URL returns HTTP 200.

```
startup-bench.py [--url URL] [--runs N] [--timeout S] [--poll-ms MS] [--baseline-repeat]
                 [--out FILE] [--log FILE] [--kill-grace S] [--lock-file FILE] [--allow-remote]
                 -- <command...>
```

| Option | Meaning |
|---|---|
| `--runs N` | number of runs (default 5) |
| `--timeout S` | a run that does not reach 200 within S seconds is an error, not a sample |
| `--poll-ms MS` | poll interval for the URL (default 5 ms) |
| `--baseline-repeat` | runs the same command as a second series and reports the difference between the two medians: the noise of your setup |
| `--out FILE` | writes the JSON result to FILE (mode 0600) |
| `--url URL` | URL to poll (default `http://127.0.0.1:8080/actuator/health`); a host that is not loopback needs `--allow-remote`. Only `http://`: `https://` is refused, because a loopback service usually has a self-signed certificate and every poll would fail until the timeout |
| `-- <command...>` | the command to start, without a shell. The script executes it as given, so the user approves every call; the skill does not pre-approve the script |

Example, comparing a cold start with an AOT cache:

```bash
startup-bench.py --runs 7 --url http://127.0.0.1:8080/actuator/health --out cold.json \
  -- java -jar app/app.jar
startup-bench.py --runs 7 --url http://127.0.0.1:8080/actuator/health --out aot.json \
  -- java -XX:AOTCache=app.aot -jar app/app.jar
```

The JSON result holds, per run, `ready_ms`, and for the series the median, minimum and maximum, the
peak RSS and the CPU seconds of the child process tree. It also records the URL without query string
and fragment (they can carry a token), the poll interval and the Python and operating system versions.

The script does not write the command line or the child's output into the JSON. The child's stdout
and stderr go to a separate log file with mode 0600, and the script prints its path. Read that log:
a JVM that rejects an AOT cache says so there and still starts (see
[leyden-aot.md](leyden-aot.md), section 7).

Before each run, the port must be free. A child that exits before the 200, or a run that times out,
counts as an error. A poll that connects waits for its answer up to the remaining `--timeout`, so a
slow first request counts in `ready_ms` instead of being cut off and retried. The script ends the
child's process group with SIGTERM, then SIGKILL.

Exit codes: 0 done, 1 a run failed, 2 usage (also a lock file that is a symbolic link), 4 internal
error (an unexpected exception, for example an `--out` directory that does not exist), 75 another
benchmark holds the lock, 130 SIGINT, 143 SIGTERM.

**Peak RSS on macOS:** `ps` counts mapped archive pages in RSS. With a mapped CDS or AOT archive the
reference app showed about 410 MB instead of about 240 MB (measured 2026-11-16, setup in §9). This is a hypothesis about how macOS
reports RSS. It does not transfer to a container memory limit; see
[gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md).

## 8. Isolating the measurement

**Rule:** run downloaded JDKs, demo apps and test images in a container, with these limits:

- No `--privileged` and no extra capabilities unless the technique needs them (a checkpoint with CRIU, Checkpoint/Restore In Userspace,
  does; see [crac-engines.md](crac-engines.md)).
- Restrict the network to what the test needs. Mount only the volumes the test needs.
- Verify downloads with their published checksum or signature (SHA-256 or PGP).
- Pin base images by digest, and use base images that are at least two weeks old.

**Origin:** the rule of this skill's author for running third-party code during these measurements.

**Reason:** a benchmark runs code you did not write. The container is the security barrier. A
privileged container removes that barrier. A fresh image or package has had no time for the community
to find a compromise; two weeks give that time.

**Limit:** a container adds its own overhead and changes CPU and memory ergonomics. Compare a
containerised run only with another containerised run.

## 9. Reference setup of the fresh measurement

Other files in this skill cite "the fresh measurement". Its setup:

| Item | Value |
|---|---|
| Date | 2026-11-16 |
| Machine | Apple M2 Max, 12 cores, macOS 26, bare metal, no CPU or memory limit |
| JDK | Temurin 25.0.5 |
| App | Spring Boot 4.1.2 from the Spring Initializr with `web` and `actuator` only; fat JAR 22 MB; 7,958 loaded classes |
| Metric | launch of `java` until the first `GET /actuator/health` returns 200, polled every 5 ms |
| Sample | n = 5 per configuration (n = 3 for the cache-invalidation and agent tests); median, min, max |
| RSS | `ps -o rss=` right after ready, includes mapped archive pages |
| CPU | user + system time of the `java` process until it was stopped shortly after ready |
| Not measured on the Mac | CRaC (macOS has only the simulation engine `simengine`, see [crac-engines.md §2](crac-engines.md#2-engines)), JDK 26, a large real application; the Linux VM class (§11) covers CRaC, JDK 26 and 27, and PetClinic |

Other files call this app "the reference app". The results apply to this minimal app. A large
application loads more classes and does more work at start; its gains can be larger or smaller.

## 10. Team measurements and third-party numbers

Other files also cite four further classes of evidence: the three below and the Linux VM class (§11).
Each stays in its own table.

- **Team measurements:** earlier runs by this skill's author, on Linux: an arm64 Linux VM with
  containers (Zulu 25 and 27, a PetClinic-class Spring Boot 4.0.3 app: an app of about the size of
  Spring PetClinic; class count not recorded), an x86_64 KVM guest (AMD
  EPYC, 4 vCPUs, containers limited to 2 CPUs, Spring Boot 4.1.0, cold start about 9.4 to 10 s), and
  Kubernetes on arm64 with containerd (cluster details not recorded).
  They are marked `measured 2026-08` or `measured 2026-09` with the JDK and setup that are known. **Open inconsistency:** other files also attribute runs with no recorded date (arm64 Kubernetes, for example in [gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md)) to the skill's author; this definition does not cover them.
  Their numbers are not comparable with each other or with the reference app.
- **Container measurements of 2026-11-15:** Zulu 25.0.5 CRaC in arm64 containers, marked
  `measured 2026-11-15`. The setup (runtime, kernel, base images) is described at the start of
  [`../../java-debug/references/crac.md`](../../java-debug/references/crac.md).
- **Third-party numbers:** JEPs, vendor documentation and blog benchmarks, marked `reported (<source
  type>)`. Each used its own hardware, JDK and metric. Compare ratios only inside one source.

## 11. Linux VM measurements

Other files cite this class as "measured 2026-11-16, Linux arm64 (OrbStack VM)", short *Linux VM*.
OrbStack is a local Docker and Kubernetes runtime for macOS; see
[orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md#orbstack). It
was run on the same day as the fresh Mac measurement (§9), to close gaps the Mac cannot measure: CRaC,
JDK 26 and 27, debuggers and agents with CRaC, native image. Its numbers are not comparable with the
fresh Mac numbers or the team numbers.

| Item | Value |
|---|---|
| Date | 2026-11-16 |
| Machine | Linux arm64 VM (OrbStack on an Apple Silicon Mac), kernel 7.2, 10 CPUs, 15 GiB; other workloads in the VM stopped |
| JDKs | Temurin 25.0.5, 26.0.2.1 and 27.0.1.0.2 (`eclipse-temurin:{25,26,27}-jdk`); Zulu CRaC 25.0.5 and 27 (`azul/zulu-openjdk:{25,27}-jdk-crac`, engines warp, criuengine, simengine); GraalVM CE 25.0.2 (`ghcr.io/graalvm/native-image-community:25`); OpenTelemetry Java agent 2.33.1, OpenTelemetry collector 0.165.0 |
| Apps | the reference app of §9, extracted (`-Djarmode=tools extract`), called *demo app*; Spring PetClinic (Spring Boot 4.1.0, JPA, HikariCP, in-memory H2) with `org.crac:crac:1.5.0` added |
| Metric | inside the container, a shell loop polls `GET /actuator/health` every 5 ms from the `java` launch (or the restore command) until it returns 200 |
| Sample | n = 5 per configuration, n = 3 for agent and cross-collector checks (a cache trained with one collector and run with another, [leyden-aot.md §10](leyden-aot.md#10-garbage-collectors)), n = 2 for the throughput series; median, min, max |
| RSS, CPU | `ps` over the JVM process tree right after ready |

**Noise:** single cold runs reached up to 2.8 s. The typical cold median is about 1.1 s
([leyden-aot.md §10](leyden-aot.md#10-garbage-collectors)), but one series (Temurin 27, Serial) had a
median of 1610 ms, min 1221, max 2768 (measured 2026-11-16, Linux arm64 (OrbStack VM)). Compare medians, and
repeat a series whose maximum is far from its median. The demo app is the same app as on the fresh Mac
(§9), but the two classes stay separate: do not compare their numbers.

**Limit:** one VM on one host, arm64 only. Restore times include no image pull and no page-cache miss
(§3). The demo app is minimal, PetClinic is small; neither is a large real application.
