Applies to: JDK 24+ AOT caches, CDS/AppCDS, CRaC (Azul Zulu), GraalVM Native Image, with JDWP, JFR, JMX/Jolokia, the OpenTelemetry Java agent, HotswapAgent/REPL tools

# Debug Tools and Agents with Fast-Startup Techniques

TL;DR: Every fast-startup technique restricts some debug tool, and most restrictions fail silently. A
JDWP agent or a JFR recording that was not in the training run makes the JVM discard the AOT cache and
start cold, with exit 0 and only an `[error][aot]` line on stdout. The OpenTelemetry agent gets no AOT
cache at all. CRaC tolerates JDWP and a JFR file recording, but not a listener agent such as Jolokia,
and not the OpenTelemetry agent once it has exported. A debugger attaches to a restored JVM only if
JDWP was in the checkpoint launch. Native Image has no `-javaagent` at all. Check every combination in
strict mode (section 3) before you trust it.

Evidence markers:

- **M** measured. "2026-11-16" = bare-metal macOS, Apple M2 Max, Temurin 25.0.5, Spring Boot 4.1.2 demo
  app (web and actuator, 7,958 loaded classes), n=3 to 5. "2026-11-15" = Azul Zulu 25.0.5 CRaC, warp
  2.12.0, Linux containers on arm64 (see [java-debug crac.md](../../java-debug/references/crac.md)).
  "2026-09" = earlier unpublished measurements by the skill's author with Zulu 25 CRaC in Linux
  containers, exact build not recorded (**open inconsistency:** other files give Zulu 25.0.4.1 for some of these runs, see [struck-claims.md](struck-claims.md)). "VM" = measured 2026-11-16, Linux arm64 (OrbStack VM): Temurin
  25.0.5 and 27.0.1.0.2, Zulu CRaC 25.0.5 and 27, the same demo app extracted
  ([measuring.md §11](measuring.md#11-linux-vm-measurements)). The demo app is not published.
- **R** reported by a public source (kind in brackets).
- **C** contested: sources disagree.
- **N** not measured, no reliable report.

Terms: an *AOT cache* (JDK 24+, [JEP 483](https://openjdk.org/jeps/483)) stores classes loaded and
linked ahead of time ("AOT class linking"); a *training run* records them, and the *assembly step*
writes the cache ([leyden-aot.md](leyden-aot.md)). `ClassFileLoadHook` is the JVMTI event that lets an
agent rewrite class bytes at load time. *warp* is Azul's default CRaC engine
([crac-engines.md](crac-engines.md)). A *restore-settable* flag may differ between checkpoint and
restore ([crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees)).

## Contents

- [1. Matrix](#1-matrix)
- [2. Per tool](#2-per-tool)
- [3. Strict-mode checks](#3-strict-mode-checks)
- [4. Do not believe](#4-do-not-believe)
- [5. Related skills](#5-related-skills)

## 1. Matrix

| Tool | JIT only | CDS / AppCDS | AOT cache (Leyden) | CRaC | Native Image |
|---|---|---|---|---|---|
| JDWP | works (M) | works (R, blog; N here) | **cache discarded** (M 2026-11-16) | does not block the checkpoint; a debugger attaches after restore only if the agent was in the checkpoint launch (M VM), see 2.1 | experimental, many limits (R, docs) |
| JFR | works (M) | N | **cache discarded** unless training and run both use JFR (M 2026-11-16) | file recording does not block (M 2026-11-15); older builds were reported to block (R, Azul release notes; version not recorded) | partial, `--enable-monitoring=jfr` (R, docs) |
| JMX / Jolokia | works | N | Jolokia agent: N, see 2.3 | Jolokia **blocks** (M 2026-11-15); remote JMX: N | built-in MBeans only (R, source not recorded; unverified) |
| OTel Java agent | works, costs about 2.8 s at startup (R, [OTel benchmark](https://github.com/open-telemetry/opentelemetry-java-instrumentation/pull/20003)) | works, transformed classes do not come from the archive (R, blog) | **no cache**: training fails (M VM), see 2.4 | **blocks** once it has exported (open exporter socket); works when nothing was exported before the checkpoint or after a long idle time (M VM), see 2.4 | no `-javaagent` (R, [GraalVM issue 8177](https://github.com/oracle/graal/issues/8177)) |
| HotswapAgent / REPL | works on a JVM built for it ([spring-boot-repl](../../spring-boot-repl/SKILL.md)) | N | discarded: needs JDWP (M) and a class-rewriting agent (R, JEP 483) | excluded: listener sockets block (M for a plain `ServerSocket` and Jolokia; nREPL and Arthas N) | no class redefinition (R, docs) |
| `JAVA_TOOL_OPTIONS` | read at every JVM launch | as JIT | one-step training passes options to a child JVM through it (M 2026-09), see 2.6 | the restore reads it; a non-restore-settable flag aborts the restore (M 2026-11-15) | N |

## 2. Per tool

### 2.1 JDWP

- **AOT cache:** with `-agentlib:jdwp=...` the JVM prints
  `[error][aot] AOT cache has aot-linked classes. It cannot be used with JDWP agent` and
  `Unable to map shared spaces`, then starts cold: 1139 ms with the cache, 1158 ms without it, cold
  start 1212 ms (M 2026-11-16, n=5 and n=3; differences under about 7 % are noise in this setup). JDWP
  itself cost no measurable startup time.
- Training with JDWP: N.
- Workaround: train with `-XX:-AOTClassLinking`. The cache then works like AppCDS and loses the linking
  gain. The reporter of a [buildpack issue](https://github.com/paketo-buildpacks/spring-boot/issues/578) saw Metaspace growth with it (R). Not measured.
- **CRaC:** see [crac.md §4](../../java-debug/references/crac.md#4-debug-agents-and-crac) for the
  checkpoint side. Attaching after the restore (M VM: demo app; Zulu 25 with warp, Zulu 27 with warp,
  Zulu 25 with criuengine under `--privileged`). The first three variants ran on all three setups with
  the same result; the `onjcmd=y` variant ran only on Zulu 25 with warp:

  | Variant | Result |
  |---|---|
  | `-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005` on the launch that is checkpointed | checkpoint works; after the restore `jdb -attach` connects, a breakpoint in `DispatcherServlet.doDispatch` is hit, 14 threads are listed. The image grew from 136 MB to 154 MB (Zulu 25, warp) |
  | the same flag only on the restore command | ignored: `Connection refused` |
  | no agent at checkpoint, `jcmd <pid> VM.start_java_debugging` after the restore | `Unknown diagnostic command` on Zulu 25.0.5 and 27; their `jcmd help` lists no debug command |
  | `onjcmd=y` in the JDWP option (Zulu 25 with warp only; not run on the other two) | `JDWP option syntax error`; the JVM does not start |

  **Rule:** to debug a restored JVM, put the JDWP agent into the checkpoint launch, in a separate debug
  image. Reason: the restore reuses the agent state of the checkpoint and ignores a new `-agentlib`.
  Limit: two Zulu versions and one app; only the first request after the restore was debugged. The
  listening port is unauthenticated, so never in production images.
- **Native Image:** experimental JDWP support, built once with a special option. No class redefinition,
  no exception breakpoints, no field watchpoints (R, docs).

### 2.2 JFR

- **AOT cache:** a run with `-XX:StartFlightRecording` and a cache trained without JFR prints
  `Mismatched values for property jdk.module.addmods: jdk.jfr specified during runtime but not during dump time`
  and starts cold: 1204 ms (M 2026-11-16, n=5). A cache trained with `-XX:StartFlightRecording` works in
  a run with JFR (669 ms, n=3) and is discarded in a run without it (1152 ms, n=3). The training log says
  `JFR will be disabled during CDS dumping`. JFR without a cache: 1120 ms against 1212 ms for the cold start (-7.6 %), near the noise floor.
- Rule: decide per deployment whether JFR runs, and train the cache the same way. Origin: the
  measurement above. Reason: JFR adds the `jdk.jfr` module, and the cache requires the same module graph.
  Limit: a recording started later with `jcmd JFR.start` does not change the launch module graph; N.
- **CRaC:** see [crac.md §4](../../java-debug/references/crac.md#4-debug-agents-and-crac). JFR chunks
  are created with mode 0644 ([jfr.md §10](../../java-debug/references/jfr.md#10-pitfalls-measured-in-containers-and-on-network-file-systems)).

### 2.3 JMX and Jolokia

- **CRaC:** Jolokia 2.6.3 blocks the checkpoint with its listener socket (M 2026-11-15). Remote JMX holds a
  listener too; N. Debug a normal start of the same container image instead
  ([crac.md §4](../../java-debug/references/crac.md#4-debug-agents-and-crac)).
- **AOT cache:** Jolokia N. Every `-javaagent` adds the `java.instrument` module, and a cache trained
  without an agent is then discarded for the same module-graph reason as JFR: measured with the OTel
  agent (`Mismatched values for property jdk.module.addmods: java.instrument`, M VM; section 2.4). Check
  Jolokia with strict mode (section 3).
- Wiring Jolokia and JMX in a pod: [jvm-remote-debug](../../jvm-remote-debug/SKILL.md).

### 2.4 OpenTelemetry Java agent

- **Startup cost** (R, [OTel project benchmark](https://github.com/open-telemetry/opentelemetry-java-instrumentation/pull/20003): Spring Boot 2.6.15 smoke app, JDK 25.0.1, 2 CPU, 1 GiB,
  median of 20 runs): without agent 1.658 s, with agent 4.481 s. With an AOT cache: 1.022 s without
  agent, 3.554 s with agent. The agent costs more than the cache saves.
- **Startup cost, measured** (M VM, agent 2.33.1, extracted demo app, no cache, exporting to an OpenTelemetry collector,
  n = 3, median without → with agent): Temurin 25.0.5 1904 → 4518 ms, CPU 5.4 → 16.5 s, RSS 280 → 466 MB;
  Temurin 27.0.1.0.2 1674 → 4008 ms, CPU 5.3 → 15.5 s, RSS 334 → 687 MB. Compare the agent only with the
  no-agent number of the same series. That baseline is not comparable with the 1064 to 1172 ms of the
  AOT matrix ([leyden-aot.md §10](leyden-aot.md#10-garbage-collectors)): this series used another
  build of the app (with the `org.crac` JAR on the class path), an OpenTelemetry collector on the network, and n = 3
  with runs from 1667 to 1985 ms on JDK 25. The cause of the difference was not isolated.
- **AOT cache: no cache with this agent.** Training with agent 2.33.1 failed on JDK 25 (SIGSEGV) and 27
  (`Critical class java.lang.Class has been excluded`), also with `--add-modules=java.instrument`; a
  cache trained without the agent is discarded when the agent is added (M VM). Owner of the details:
  [leyden-aot.md §9](leyden-aot.md#9-debuggers-jfr-and-java-agents).
- **CRaC** (M VM: Zulu 25.0.5 with warp, demo app, agent 2.33.1, OpenTelemetry collector reachable over
  a Docker network; n = 1 run per variant). The upstream project closed CRaC support as "not planned" (R,
  [issue 10363](https://github.com/open-telemetry/opentelemetry-java-instrumentation/issues/10363)):

  | Before the checkpoint | Result |
  |---|---|
  | 30 requests, then checkpoint | **blocked**: `CheckpointOpenSocketException: Socket[addr=<collector>/...,port=4318,...]`, the exporter's keep-alive connection |
  | no request (ready taken from the log) | checkpoint works (image 218 MB); restore 223 ms to the first health 200, which includes the exporter start; the collector log showed 31 spans for the requests after the restore: 30 requests plus the readiness poll (n = 1, counts read live from the collector log) |
  | 30 requests, then 330 s idle, then checkpoint | checkpoint works (image 195 MB); restore 63 ms; the collector log showed 31 spans after the restore, 30 requests plus the readiness poll (n = 1, counts read live from the collector log) |

  **Rule:** take the checkpoint before the first export, or after the exporter has closed its idle
  connection. Origin: the table above. Reason: the agent has no CRaC `Resource`, so an open exporter
  socket blocks the checkpoint like any other socket. Limit: one run per variant, one agent version,
  HTTP/protobuf export to port 4318, one idle time; the time after which the connection closes was not narrowed down below
  330 s. Prefer a checkpoint without the agent's traffic, and check the checkpoint output text.
- **Native Image:** no runtime agents; use the OTel SDK or a framework starter (R, [GraalVM issue 8177](https://github.com/oracle/graal/issues/8177)).

### 2.5 HotswapAgent, JetBrains Runtime (JBR) and REPL tools

These tools need JDWP or a class-rewriting agent, and they hold listener sockets. Both a cache and a
checkpoint are therefore off the table for the JVM you develop in. A JBR is also a
different JVM build from the production JDK, so a cache trained on one does not load on the other
(R, JEP 483: same JVM build required). Setup and limits: [spring-boot-repl](../../spring-boot-repl/SKILL.md).

### 2.6 `JAVA_TOOL_OPTIONS`

- **AOT training, one-step mode:** the JVM passes the training options to the child JVM of the assembly
  step through `JAVA_TOOL_OPTIONS`, and the child prints them with `Picked up JAVA_TOOL_OPTIONS:` to
  stderr (M 2026-09). Secrets in training options land in the build log ([security.md §4](security.md#4-cds-archives-and-aot-caches)).
  `JDK_AOT_VM_OPTIONS` applies only to the assembly step (R, [JEP 514](https://openjdk.org/jeps/514)).
- **Agents in `JAVA_TOOL_OPTIONS`:** a platform that injects an agent at run time but not at training
  time changes the module graph or adds a `ClassFileLoadHook`; JEP 483 names this case (R, JEP 483).
- **CRaC restore:** the restore command reads `JAVA_TOOL_OPTIONS`; `-D` values arrive; a flag that is not
  restore-settable aborts the restore. Restore with `env -u JAVA_TOOL_OPTIONS` (M 2026-11-15, details in
  [crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees)). `env -u` does not
  remove `JDK_JAVA_OPTIONS`, which the `java` launcher also reads.

## 3. Strict-mode checks

Default mode falls back to a cold start, with exit 0, when the cache does not fit. Origin: every discard
in section 2 behaved that way (M 2026-11-16). Reason: a fallback looks like success in every exit-code
check. Run these checks in CI or a test stage, not in production.

```bash
# AOT cache, JDK 24-26: a cache that does not fit becomes a hard error
java -XX:AOTMode=on -XX:AOTCache=app.aot <your debug flags> -jar app.jar
#   failure: "Error occurred during initialization of VM" / "Unable to use AOT cache."
# JDK 27 and later: -XX:AOTMode=required (measured on 27.0.1.0.2, see leyden-aot.md §2)

# Was the cache opened, and how many classes came from it?
# Open inconsistency: leyden-aot.md section 7 says that "Opened AOT cache" does not prove that the cache is used.
# For a Spring app, add -Dspring.context.exit=onRefresh so that the JVM exits after startup.
java -Xlog:aot,cds -XX:AOTCache=app.aot <flags> -jar app.jar | grep -E 'Opened AOT cache|\[error\]\[aot\]'
java -Xlog:class+load -XX:AOTCache=app.aot <flags> -jar app.jar > classload.log
grep -c 'source: shared objects file' classload.log   # measured 7685 of 7958 when the cache fits
```

For CRaC, read the text of `jcmd <pid> JDK.checkpoint`, never its exit code (always 0), and find the JVM
with `jcmd -l` ([crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)).

## 4. Do not believe

| Claim | Verdict | Corrected wording |
|---|---|---|
| JFR and OTel hold file descriptors, so tracing and CRaC exclude each other | JFR: struck. OTel: nuanced | A JFR file recording does not block a checkpoint (measured 2026-11-15, Zulu 25.0.5; older builds were reported to block). The OTel agent blocks the checkpoint once it has exported, and works when nothing was exported or after 330 s idle (measured 2026-11-16, Linux arm64 (OrbStack VM), section 2.4) |
| Leyden forbids agents | nuanced | JEP 483 forbids agents that rewrite classes through `ClassFileLoadHook`. The OTel agent 2.33.1 broke AOT training on JDK 25 and 27, also with `--add-modules=java.instrument` (measured 2026-11-16, Linux arm64 (OrbStack VM)). Check other agents with strict mode |
| A debugger can be attached to a restored JVM later | struck | Only an agent present at checkpoint listens after the restore; `-agentlib:jdwp` on the restore command is ignored, and `VM.start_java_debugging` does not exist on Zulu 25.0.5 and 27 (measured 2026-11-16, Linux arm64 (OrbStack VM), section 2.1) |
| JFR works fine with an AOT cache | struck | The cache is discarded unless training and run both use JFR (`jdk.module.addmods` mismatch). JDWP discards the cache too: "AOT cache has aot-linked classes. It cannot be used with JDWP agent" (measured 2026-11-16) |

All struck claims: [struck-claims.md](struck-claims.md).

## 5. Related skills

- [java-debug](../../java-debug/SKILL.md): how to use JFR, JDWP, JMX, OTel, and
  [crac.md](../../java-debug/references/crac.md) for checkpoint debugging.
- [jvm-remote-debug](../../jvm-remote-debug/SKILL.md): agents in a pod, JMX and JDWP over port-forward.
- [spring-boot-repl](../../spring-boot-repl/SKILL.md): hot swap and REPL.
