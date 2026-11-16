Applies to: all (build per OS and CPU architecture; the binary runs only there)

# GraalVM Native Image: Facts for the Decision

TL;DR: A native image starts in about 0.05 to 0.13 s with about 90 to 120 MB RSS: 53 ms and about
97 MB for the demo app on the Linux VM, and similar values in third-party benchmarks. The build takes
minutes and gigabytes of RAM. The binary has no JIT, no runtime Java agents, only experimental JDWP,
and it cannot be combined with CRaC. Values read at build time are frozen into the binary. This file
holds facts only, not a build recipe.

## Contents

- [1. Numbers](#1-numbers)
- [2. Constraints](#2-constraints)

## 1. Numbers

**Linux VM** (measured 2026-11-16, Linux arm64 (OrbStack VM), GraalVM CE 25.0.2 on Oracle Linux, 10
CPUs; the extracted demo app of [measuring.md §11](measuring.md#11-linux-vm-measurements): Spring Boot
4.1.2, web and actuator only):

| Item | Value |
|---|---|
| build | `mvn -Pnative native:compile`, 90 s wall in total, of which `native-image` 1 min 22 s |
| peak build memory | 5.3 GB (`memory.peak` of the build container's cgroup, including Maven); `native-image` itself reported a peak RSS of 4.72 GB |
| binary | 90.8 MB (86.6 MiB), plus six small shared libraries of 1.7 MB together |
| start to first `/actuator/health` 200 | median 53 ms (47 to 63 ms), n = 5, polled every 5 ms |
| RSS after ready | about 97 MB |
| CPU time until ready | 0.04 s |
| JIT cold start of the same app on the same VM, for scale | about 1.1 s ([leyden-aot.md §10](leyden-aot.md#10-garbage-collectors)) |

**Limit:** a minimal app without JPA and without reflection-heavy libraries. Such apps need more
reachability metadata and a longer build; that was not measured. No canary test for build-time
secrets was run, because the demo app reads no value at build time.

**Third-party** (reported; each row its own setup; not comparable with the table above or with each
other):

| Source | Setup | Start | RSS | Build cost |
|---|---|---|---|---|
| reported (blog, URL not recorded) | small Spring Boot 4.1.1 app, GraalVM CE 25.0.2, 2 vCPU, 8 GB | 133 ms | 120 MB | 5 min 18 s, 4.7 GB peak build RAM |
| reported ([buildpack blog](https://blog.paketo.io/posts/spring-boot-performance/)) | PetClinic, Java 25, Docker, single runs | 0.117 s | 90.2 MiB | not stated |

Peak throughput without profile-guided optimisation is reported to be lower than with the JIT
(reported, blog; URL not recorded). No primary benchmark was found. Not measured here.

## 2. Constraints

| Topic | Fact |
|---|---|
| garbage collectors | Serial (default), Epsilon, and G1 with `--gc=G1` in Oracle GraalVM on Linux only, not in the Community Edition; no ZGC, no Shenandoah, no Parallel (reported, GraalVM docs) |
| debugging | JDWP is experimental: build with `-H:+UnlockExperimentalVMOptions -H:+JDWP`; no class redefinition, no exception breakpoints, no field watchpoints (reported, GraalVM docs) |
| Java agents | no `-javaagent` at run time; the OpenTelemetry Java agent cannot be used; use the OpenTelemetry SDK or a framework starter instead (reported, issue tracker, 2023; see also [GraalVM issue 8177](https://github.com/oracle/graal/issues/8177)) |
| JFR | partial, enabled with `--enable-monitoring=jfr`; no class-loading or JIT events (reported, blog; URL not recorded) |
| reflection and proxies | closed world: needs reachability metadata, the configuration that lists what the code reaches only through reflection, proxies or resource lookups; Spring AOT generates it for Spring Boot 3 and later (reported, GraalVM docs) |
| build-time values | static state initialised at build time lives in the image heap, the set of pre-built objects stored in the binary. A value read at build time, such as an environment variable or a mounted secret, is frozen into the binary. Spring AOT also fixes conditions at build time (see [leyden-aot.md](leyden-aot.md), section 5). Mechanism reported; not measured here |
| CRaC | no combination: CRaC needs a HotSpot JVM ([crac-engines.md](crac-engines.md)) |

Compare security properties of all techniques in [security.md](security.md), and debugger and agent
support in [debug-agents.md](debug-agents.md).
