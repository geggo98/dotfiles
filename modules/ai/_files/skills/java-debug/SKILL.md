---
name: java-debug
description: >-
  Diagnose, profile, trace, debug, and introspect the runtime state of
  Java/Kotlin/Scala apps on JDK 11+ with five strategies: JFR recordings;
  OpenTelemetry (OTel) traces and spans across services; JDB breakpoints;
  JMX MBeans via jmxterm or Jolokia (Tomcat/Jetty connector, HikariCP,
  Lettuce/Redis, custom MBeans); Spring Boot Actuator (/beans,
  /conditions, /configprops, /env, /health, /mappings, /loggers,
  /metrics). Also covers heap dumps, thread dumps, class histogram, Eclipse
  MAT, NMT, GC log, virtual threads, async-profiler, jcmd, JMC JFR rules
  report, CRaC checkpoint debugging, and metrics to a
  file (jmx_exporter). Triggers on: Java performance, JVM diagnostics,
  Spring Boot startup, GC, heap, allocation, deadlocks, autoconfig,
  configuration, wiring, bean missing, Redis health, log level change,
  request mappings, PKIX. For a JVM in a pod or container (kubectl debug,
  ephemeral container, agents via initContainer), also load
  `jvm-remote-debug`. Hot code replacement and REPL: `spring-boot-repl`.
allowed-tools: >-
  Read(references/*)
  Bash(./scripts/jdb-attach.sh *)
  Bash(./scripts/jdb-launch.sh *)
  Bash(./scripts/jdb-diagnostics.sh *)
  Bash(./scripts/jdb-breakpoints.sh *)
  Bash(./scripts/jfr-record.sh *)
  Bash(./scripts/jfr-summary.sh *)
  Bash(./scripts/jfr-view.sh *)
  Bash(./scripts/jfr-events.sh *)
  Bash(./scripts/jfr-rules-report.sh *)
  Bash(./scripts/jmx-sample.py *)
  Bash(./scripts/otel-agent-download.sh *)
  Bash(./scripts/otel-collector-up.sh *)
  Bash(./scripts/otel-spans-extract.sh *)
  Bash(./scripts/jmx-startup.sh *)
  Bash(./scripts/jmx.sh *)
  Bash(./scripts/actuator-startup.sh *)
  Bash(./scripts/actuator.sh *)
  Bash(./scripts/actuator.py *)
  Bash(jcmd:*) Bash(jfr:*) Bash(jdb:*) Bash(java:*) Bash(jq:*) Bash(curl:*)
  Bash(jmxterm:*) Bash(python3:*)
  Read
dependencies: >-
  JDK 11+ (ships jcmd, jfr, jdb). For OTel: opentelemetry-collector-contrib
  (load via the nix-shell skill if not on PATH). For JMX: jmxterm (via the
  nix-shell skill if not on PATH). For JSON: jq, python3. curl already
  required.
compatibility: >-
  macOS, Linux. On Windows invoke scripts via WSL.
metadata:
  based-on: "https://github.com/brunoborges/jdb-agentic-debugger/tree/main/skills/jdb-debugger"
---

# Java / JVM Diagnostics — JFR, OpenTelemetry, JDB, JMX, Actuator

This skill offers five diagnostic strategies. Pick the one that matches the question, and combine them when one strategy alone cannot answer it.

| Strategy | Best for | Overhead | Local-only? |
|---|---|---|---|
| **JFR** | "What is the JVM doing?" — GC, allocation, locks, I/O, custom events | ~1–2 % | Yes (a `.jfr` file) |
| **OTel** (OpenTelemetry) | "Where does latency live across endpoints/services?" — distributed traces, spans | Low at the agent; some per-span | Yes (file exporter) |
| **JDB** | "Why does this code take this branch? What's the state right here?" | Interactive only | Yes (JDWP socket) |
| **JMX** | "What's the runtime state? — connector/pool/cache/Redis stats; any JVM" | Near-zero (RMI on demand) | Yes (RMI port or HTTP via Jolokia) |
| **Actuator** (Spring) | "Spring wiring: which beans, which conditions, which config?" | Near-zero | Yes (HTTP or JMX) |

Each strategy sees something that the others cannot, so one does not replace another. JFR sees JVM internals that OTel cannot see. OTel sees causality across services, which JFR cannot see. JDB sees the variables of each stack frame, which neither of them sees. JMX and Actuator show the **effective configuration and runtime state** of the running process, which sampling tools, tracing tools, and the source-level debugger cannot show cheaply.

## Pick a strategy

```
What's the question?
  ├─ "Where is CPU / allocation / GC time going?"                → JFR
  ├─ "Why is endpoint X slow in production?"                     → JFR (+ OTel if multi-service)
  ├─ "Where does latency live across N services?"                → OTel (cross-service)
  ├─ "What's the state at this line / why this branch?"          → JDB
  ├─ "Is the app deadlocked? Which threads are blocked?"         → JDB diagnostics first, then JFR
  ├─ "How long do my Spring-startup beans take?"                 → JFR (FlightRecorderApplicationStartup), references/jfr.md §3.1
  ├─ "How does my own business logic look in a trace?"           → OTel + @WithSpan or programmatic API
  ├─ "Which beans got created / which conditional was rejected?" → Actuator (E)
  ├─ "What's the effective config (env, properties, profiles)?"  → Actuator: /env, /configprops
  ├─ "Is the HikariCP/Redis/Tomcat pool healthy? How many active?"→ Actuator: /health + /metrics, OR JMX (D)
  ├─ "What port is Tomcat actually listening on?"                → JMX: Catalina:type=Connector,*
  ├─ "Bump log level at runtime without restart"                 → Actuator: /loggers (POST)
  ├─ "What is wrong in this recording?" (rule-based findings)    → JMC rules report (references/jmc.md)
  ├─ "Which objects fill the heap?"                              → class histogram, heap dump (references/heap-dumps.md)
  ├─ "Hang, thread states, native memory, flame graph?"          → jcmd, NMT, async-profiler (references/profiling-and-threads.md)
  ├─ "Values over time into a file (JSONL/CSV)?"                 → scripts/jmx-sample.py (references/metrics-export.md)
  └─ "Why does the CRaC checkpoint fail?"                        → references/crac.md
```

CRaC is Coordinated Restore at Checkpoint: the JVM writes a checkpoint image of the running process and restores from it later ([`references/crac.md`](references/crac.md)).

### Symptom → first command

| Symptom | First command | Details |
|---|---|---|
| Hang, requests stuck | `jcmd <pid> Thread.print` or `Thread.dump_to_file -format=json <file>` (JDK 21+) | [`profiling-and-threads.md`](references/profiling-and-threads.md) §1 |
| High CPU | `scripts/jfr-record.sh start …`, or async-profiler | [`profiling-and-threads.md`](references/profiling-and-threads.md) §4 |
| Memory grows | `jcmd <pid> GC.class_histogram -all` (without `-all`: forced full GC), then Native Memory Tracking (NMT: `-XX:NativeMemoryTracking=summary`, `jcmd <pid> VM.native_memory summary`) | [`heap-dumps.md`](references/heap-dumps.md) §1, [`profiling-and-threads.md`](references/profiling-and-threads.md) §2 |
| `OutOfMemoryError` | `-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=<dir>/app_%p.hprof` (`%t` is not expanded) | [`heap-dumps.md`](references/heap-dumps.md) §3 |
| Start fails, flags unclear | `jcmd <pid> VM.flags`, `VM.command_line` | [`profiling-and-threads.md`](references/profiling-and-threads.md) §2 |
| Slow startup | `scripts/actuator.sh startup`, or JFR at startup | Strategy A / E |
| `PKIX path building failed` | `keytool -list -cacerts` (the JDK ignores the OS trust store) | [`heap-dumps.md`](references/heap-dumps.md) §6 |
| CRaC checkpoint fails | open sockets / files in the JVM | [`crac.md`](references/crac.md) |
| Container exit 137 / OOMKilled | not a Java OOM: cgroup limit | [`jvm-remote-debug` wiring.md](../jvm-remote-debug/references/wiring.md#oomkilled-vs-outofmemoryerror) |

Take a heap dump only when the user asks for one, because the dump pauses the JVM and contains every secret in memory. See [`heap-dumps.md`](references/heap-dumps.md) §2.

### Which script when

| Need | Script |
|---|---|
| One MBean value over RMI | `scripts/jmx.sh` |
| A series of MBean values over Jolokia/HTTP, as JSONL or CSV | `scripts/jmx-sample.py` (read requests only; credentials via `JOLOKIA_USER` + `JOLOKIA_PASSWORD` or `JOLOKIA_PASSWORD_CMD`, never in the URL) |
| Spring endpoints (beans, conditions, env, …) | `scripts/actuator.py` / `scripts/actuator.sh` |
| Quick text view of a `.jfr` | `scripts/jfr-summary.sh`, `scripts/jfr-view.sh` |
| JMC's rule-based findings for a `.jfr`, as HTML | `scripts/jfr-rules-report.sh <rec.jfr> [out.html]` (uses an internal JMC class; measured with JMC 9.1.1 on macOS only) |
| Breakpoints, step debugging | `scripts/jdb-*.sh` |

## Tooling availability

`jcmd`, `jfr`, and `jdb` ship with the JDK. `otelcol-contrib` is a separate binary.

If one of them is missing on the host, use the `nix-shell` skill to make it available. The tool then exists only for that command and does not change the global environment:

```bash
# JDK on demand (provides jcmd, jfr, jdb)
${CLAUDE_SKILL_DIR}/../nix-shell/scripts/nix_shell.sh run jdk21 -- jfr summary recording.jfr

# OTel collector on demand
${CLAUDE_SKILL_DIR}/../nix-shell/scripts/nix_shell.sh \
  run opentelemetry-collector-contrib -- otelcol-contrib --config /tmp/otel.yaml
```

When `otelcol-contrib` is not on PATH, `scripts/otel-collector-up.sh` falls back to `nix run nixpkgs#opentelemetry-collector-contrib` by itself. The agent therefore rarely needs to call `nix_shell.sh` directly for OTel.

---

## Strategy A — JFR (Java Flight Recorder)

JFR is built into every JDK 11+. It records structured JVM events (GC, allocation in the TLAB (Thread-Local Allocation Buffer), lock contention, file and socket I/O, JIT decisions) and any custom events that you define. A recording is a binary `.jfr` file, which you analyse with the JDK's `jfr` CLI. JDK Mission Control (JMC) is the GUI for a human. An agent gets the same rule-based findings without the GUI from `scripts/jfr-rules-report.sh` ([`references/jmc.md`](references/jmc.md)).

JFR has two operating modes:

- **Continuous (ring buffer):** `disk=true, maxage=1h, maxsize=500m, dumponexit=true`. The recording runs all the time, and you dump it on demand or at a crash. This is the production default.
- **Targeted:** `duration=60s, settings=profile`. A short recording with deeper sampling, for a diagnostic window.

### Quick start

Start a 60-second profile recording on a running JVM:

```bash
scripts/jfr-record.sh start --match 'myapp\.jar' --filename /tmp/myapp.jfr
# resolves the PID by grepping `jcmd -l` and runs `jcmd <PID> JFR.start ...`
```

Or print the JVM startup flag for `JAVA_TOOL_OPTIONS`, a Dockerfile, or a Spring `bootRun` task:

```bash
scripts/jfr-record.sh startup --filename /var/log/app/rec.jfr --continuous --print-args-only
# -XX:StartFlightRecording=settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true,filename=...
# -XX:FlightRecorderOptions=stackdepth=128
```

Analyse the resulting recording:

```bash
scripts/jfr-summary.sh /tmp/myapp.jfr                          # overview + capped metadata
scripts/jfr-view.sh hot-methods /tmp/myapp.jfr                 # tabular ASCII reports (JDK 21+)
scripts/jfr-view.sh allocation-by-class /tmp/myapp.jfr --grep com.example
scripts/jfr-events.sh /tmp/myapp.jfr --events 'jdk.GC*'        # selective JSON extract, capped
```

Full reference: [`references/jfr.md`](references/jfr.md) (Java + Kotlin). For Scala specifics see [`references/scala-jvm.md`](references/scala-jvm.md).

### JFR scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/jfr-record.sh` | Start/stop/dump/status recordings; emit `-XX:StartFlightRecording=` flags |
| `scripts/jfr-summary.sh` | `jfr summary` + capped `jfr metadata` of a `.jfr` file |
| `scripts/jfr-view.sh` | Wrap `jfr view --width 200`; predefined ASCII reports (hot-methods, gc, allocation, contention, I/O…) |
| `scripts/jfr-events.sh` | Selective `jfr print` with default jq projection and event-count cap |
| `scripts/jfr-rules-report.sh` | JMC "Automated Analysis" rules without the GUI → HTML report (mode 0600); needs an installed JMC; exit 0 ok / 1 failure / 2 usage; see [`references/jmc.md`](references/jmc.md) |

---

## Strategy B — OpenTelemetry (OTel)

OpenTelemetry is a vendor-neutral specification for traces, metrics, and logs. This skill covers **traces**. The standard path for Java is the [OpenTelemetry Java agent](https://github.com/open-telemetry/opentelemetry-java-instrumentation), a `-javaagent` JAR that instruments dozens of libraries automatically (Spring MVC and WebClient, JDBC, Hibernate, Reactor Netty, gRPC, Kafka, Lettuce, OkHttp, and more). Your own application code gets spans from the `@WithSpan` annotation or from the programmatic `Tracer` API.

There are three deployment shapes, from simple to complex:

1. **Agent and console exporter:** the fastest way for ad-hoc debugging. The spans go to stdout.
2. **Agent, `logging-otlp` exporter, and Logback:** OTLP (OpenTelemetry Protocol) JSON lines go to a file, with no extra process. [`references/otel.md`](references/otel.md) §1 defines the terms.
3. **Agent, OTLP exporter, and a local Collector:** the collector writes JSON lines with the file exporter, or forwards to Tempo, Jaeger, or other backends. You need this shape for processors (sampling, attribute filtering, PII redaction) and for setups with more than one backend.

### Quick start (shape 3, single service)

```bash
# 1. Get the agent (idempotent; prints the path).
AGENT=$(scripts/otel-agent-download.sh)

# 2. Start a local collector with the default file exporter config (writes traces.jsonl).
scripts/otel-collector-up.sh --background --output /tmp/traces.jsonl --timeout 300
# stdout: /tmp/traces.jsonl  (the path the collector writes to)

# 3. Start the app, pointing at the collector.
OTEL_SERVICE_NAME=my-app \
OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
  java -javaagent:"$AGENT" -jar my-app.jar

# 4. Trigger workload (curl / load test / whatever).
# 5. Extract spans with resource-context preserved.
scripts/otel-spans-extract.sh /tmp/traces.jsonl --service my-app
```

### Cross-service tracing

In OTel, one trace covers **all** services that take part in one request. The W3C TraceContext headers (`traceparent`, `tracestate`) connect them. The agent propagates these headers automatically for every supported library, such as Spring WebClient, RestTemplate, OkHttp, gRPC, Kafka, RabbitMQ, JDBC, and Reactor Netty. You do not need to change the code.

[`references/otel.md`](references/otel.md) §5 has a runnable Spring Boot example with two services: a caller and a callee, both with the agent, one collector, one `traces.jsonl`, and a single `traceId` that covers both. The section also covers the propagation pitfalls: a raw `Thread` or `ExecutorService` without context wrapping, baggage copied onto child spans, and sampling decisions across services.

### Manual spans for your own code

Use `@WithSpan` for the 90 % case and `Tracer` with `spanBuilder` for the rest. The programmatic API needs `makeCurrent()` to propagate the context, `span.end()` in `finally` to avoid leaked spans, and `span.recordException()` plus `setStatus(ERROR)` on failure paths. See [`references/otel.md`](references/otel.md) §4 for the full pattern and [`references/scala-jvm.md`](references/scala-jvm.md) §4 for the Scala idiom.

### OTel scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/otel-agent-download.sh` | Idempotently fetch `opentelemetry-javaagent.jar`; prints the absolute path |
| `scripts/otel-collector-up.sh` | Start `otelcol-contrib` (or `nix run` it) with a default file-exporter config |
| `scripts/otel-spans-extract.sh` | Resource-context-aware `jq` extraction; filters by service / name / traceId / min duration |

---

## Strategy C — JDB (Java Debugger / JDWP)

JDB is the JDK's command-line debugger. It attaches over the **Java Debug Wire Protocol (JDWP)** to a JVM that was started with `-agentlib:jdwp=...`. Use it for interactive step debugging, thread dumps, deadlock analysis, and the question "what is the local state at this point". Neither tracing nor profiling can answer that question.

**Golden rule:** never create files in the workspace. No `bp.txt`, no `cmds.txt`, no wrapper scripts. Use the inline `--bp` / `--cmd` / `--auto-inspect` / `--timeout` flags on `scripts/jdb-breakpoints.sh`. The script handles temp files in `/tmp/` and cleans up.

### Quick start

Attach to a JVM that was launched with `-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005`. For a JVM in a pod, reach the port with `kubectl port-forward` (see [`jvm-remote-debug`](../jvm-remote-debug/SKILL.md)):

```bash
scripts/jdb-attach.sh --host 127.0.0.1 --port 5005
```

JDWP with `address=5005` (no host) or `127.0.0.1:5005` listens on IPv4 `127.0.0.1` only, not on `::1`. `localhost` works from Java clients such as `jdb` only because Java falls back to `127.0.0.1` after `::1`. A client that tries only `::1` is refused. Measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 25.0.5, in a container. Details: [`references/jdwp-options.md`](references/jdwp-options.md), section "Kubernetes".

`kubectl port-forward` reaches this IPv4 loopback bind. The host `jdb` (JDK 25) attached to a JDK 21 target through `kubectl port-forward pod/<pod> 15005:5005`, and `version` and `threads` worked. The forward connects inside the pod to IPv4 `127.0.0.1` only (on the Docker runtime the forward runs through `socat` on the runtime side, and its error text names the target `TCP4:localhost:<port>`) and does not fall back to IPv6. A Java listener on `127.0.0.1`, `0.0.0.0`, or `[::]` was therefore reachable, and a listener bound only to `::1` or only to the pod IP was not. The client saw the connection open and then end without data. Measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward (Kubernetes 1.36.5, Docker runtime). OrbStack is a local Docker and Kubernetes runtime for macOS; its specifics are in [`../jvm-remote-debug/references/orbstack-telepresence.md`](../jvm-remote-debug/references/orbstack-telepresence.md). containerd and CRI-O implement port-forward differently, so the `::1` result can differ there (not measured).

Or launch a fresh JVM under JDB:

```bash
scripts/jdb-launch.sh com.example.MyApp --sourcepath src/main/java
```

Collect a thread dump and a deadlock check without interaction:

```bash
scripts/jdb-diagnostics.sh --port 5005
```

Debug in batch mode, for example to investigate an NPE, without files in the workspace:

```bash
scripts/jdb-breakpoints.sh \
  --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --bp "stop at com.example.MyClass:42" \
  --auto-inspect 20 --timeout 60
```

Full reference: [`references/jdb.md`](references/jdb.md). All commands: [`references/jdb-commands.md`](references/jdb-commands.md). All JDWP agent options: [`references/jdwp-options.md`](references/jdwp-options.md).

### JDB scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/jdb-attach.sh` | Attach to a running JVM via JDWP |
| `scripts/jdb-launch.sh` | Launch a Java app under JDB for interactive debug |
| `scripts/jdb-diagnostics.sh` | Non-interactive thread dump + deadlock detection |
| `scripts/jdb-breakpoints.sh` | Set breakpoints (inline `--bp`) and drive a session (interactive OR `--auto-inspect`/`--cmd` batch) |

---

## Strategy D — JMX (Java Management Extensions / MBeans)

JMX is the JVM's built-in introspection layer. Every JDK exposes MBeans for the runtime (memory, threads, GC, class loaders). Most Java libraries publish their own MBeans for state and metrics, among them Spring Boot, Tomcat, Jetty, Netty, HikariCP, Lettuce, Kafka, Hibernate, Camel, and Quartz.

There are two access protocols:

- **RMI** (the JDK default): the JVM listens on an RMI registry port. `jmxterm` connects, reads and writes attributes, and invokes operations. This works on any JDK 11+ JVM with the right flags and needs nothing on the app's classpath.
- **HTTP via Jolokia:** the Jolokia agent (a JAR on the classpath) translates between JMX and JSON over HTTP. It is easier to use in containers but needs a change at deploy time. See `references/jmx.md` §4. Safe start flags and a read-only access policy are in [`references/jolokia.md`](references/jolokia.md).

### Quick start

Print the JVM JMX flags for `JAVA_TOOL_OPTIONS`, a Dockerfile, or `bootRun`:

```bash
scripts/jmx-startup.sh --port 5000 --print-args-only
# -Dcom.sun.management.jmxremote=true
# -Dcom.sun.management.jmxremote.port=5000
# -Dcom.sun.management.jmxremote.rmi.port=5000
# -Djava.rmi.server.hostname=127.0.0.1
# -Dcom.sun.management.jmxremote.host=127.0.0.1   # binds to loopback; without it the port listens on all interfaces
# -Dcom.sun.management.jmxremote.authenticate=false
# -Dcom.sun.management.jmxremote.ssl=false
```

These flags work through `kubectl port-forward` with the same port number on both sides. A JMX client on the host read `java.lang:type=Runtime` `Uptime` through the forwards `5000:5000` and `9010:9010`. Measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward.

On macOS, prefer a port other than 5000 for a forwarded JVM, such as `--port 9010`. ControlCenter (the AirPlay Receiver) listens on `*:5000` and `*:7000`, for IPv4 and IPv6. kubectl can still bind `127.0.0.1:5000`, and while the forward runs, the pod answers. When the forward has died, the JMX client connects to ControlCenter instead and hangs without an error message: `gtimeout 20` ended it with exit 124. `gtimeout` is GNU coreutils `timeout` on macOS; exit 124 means that the timeout expired ([`references/jmx.md`](references/jmx.md) §2). Measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward.

Inspect the running JVM:

```bash
scripts/jmx.sh domains --port 5000                                            # list MBean domains
scripts/jmx.sh list --port 5000 --domain Catalina                             # MBeans in a domain
scripts/jmx.sh attr --port 5000 'Catalina:type=Connector,port=*' 'localPort'  # read attribute(s)
scripts/jmx.sh attr --port 5000 'com.zaxxer.hikari:type=Pool (HikariPool-1)' \
                                 'ActiveConnections,IdleConnections,ThreadsAwaitingConnection'
scripts/jmx.sh invoke --port 5000 'java.lang:type=Memory' 'gc'                # manual GC (sparingly)
```

Full reference: [`references/jmx.md`](references/jmx.md) — MBean catalogues for Tomcat, HikariCP, Lettuce, Spring, JVM built-ins; container/k8s setup (§6); the Jolokia HTTP-bridge path.

### JMX scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/jmx-startup.sh` | Emit the `-Dcom.sun.management.jmxremote.*` JVM flags (default port 5000) |
| `scripts/jmx.sh` | Wrap `jmxterm` (or `nix run nixpkgs#jmxterm`); subcommands `domains`, `list`, `attr`, `invoke`; password chain: `--password-cmd` flag, then `JMX_USER` + `JMX_PASSWORD` / `JMX_PASSWORD_CMD`, then the credentials file `$JMX_CREDENTIALS` or `~/.config/java-debug/jmx-credentials` (mode 0600) |
| `scripts/jmx-sample.py` | Sample MBean attributes over Jolokia into JSONL/CSV (`--preset jvm`); read requests only, checks every item's status, output mode 0600; see [`references/metrics-export.md`](references/metrics-export.md) |

---

## Strategy E — Spring Boot Actuator

Actuator is the introspection layer specific to Spring Boot. It sits on top of JMX (every Actuator endpoint is also an MBean when `spring.jmx.enabled=true`) and on top of HTTP (under `/actuator/*` by default).

Use it when the question is specific to Spring: bean wiring, auto-configuration decisions, effective configuration, request mappings, log-level changes at runtime, scheduled tasks, and Spring, HikariCP, or Redis metrics. For a JVM without Spring, use Strategy D.

**Boot 3.x defaults:** only `/actuator/health` is exposed over HTTP, and JMX exposure requires `spring.jmx.enabled=true`. Values in `/env` and `/configprops` are masked unless `management.endpoint.env.show-values=ALWAYS` and `management.endpoint.configprops.show-values=ALWAYS` are set.

### Quick start

Print the Spring `management.*` properties:

```bash
scripts/actuator-startup.sh --print-args-only --dev
# Prints one line; wrapped here:
# -Dspring.jmx.enabled=true
# -Dmanagement.endpoints.web.exposure.include=*
# -Dmanagement.endpoints.jmx.exposure.include=*
# -Dmanagement.endpoints.jmx.exposure.exclude=none
# -Dmanagement.endpoint.health.show-details=ALWAYS
# -Dmanagement.endpoint.health.show-components=ALWAYS
# -Dmanagement.endpoint.env.show-values=ALWAYS
# -Dmanagement.endpoint.configprops.show-values=ALWAYS
```

The script detects the Actuator base URL by probing the common shapes: the Spring default `http://localhost:8080/actuator`, a separate management port `:8081`, and the alternative base paths `/management` and `/admin`. For an unusual deployment, set the URL explicitly:

```bash
# Full URL (highest priority)
scripts/actuator.sh --base https://api.example.com/management health

# Composable: agent overrides only the piece it knows
scripts/actuator.sh --port 9090 --base-path /management health    # http://localhost:9090/management
scripts/actuator.sh --scheme https --host api.example.com health  # https://api.example.com/actuator

# Env var (sticky across calls)
export ACTUATOR_BASE='https://api.example.com:9001/management'
scripts/actuator.sh health
```

Common subcommands:

```bash
scripts/actuator.sh health                                 # recursive details with HikariCP/Redis/disk
scripts/actuator.sh beans --grep com.example               # full bean graph, filtered
scripts/actuator.sh conditions --unmatched                 # auto-config decisions that REJECTED beans
scripts/actuator.sh env spring.datasource.url              # effective value of one property
scripts/actuator.sh configprops --grep hikari              # @ConfigurationProperties bindings
scripts/actuator.sh mappings                               # request → controller mapping table
scripts/actuator.sh metrics hikaricp.connections.active    # pool active connections
scripts/actuator.sh loggers com.example.Foo                # current log level
scripts/actuator.sh loggers com.example.Foo TRACE          # set log level at runtime (POST)
scripts/actuator.sh threaddump --grep RUNNABLE             # thread dump
scripts/actuator.sh heapdump /tmp/heap.hprof               # write heap dump (HPROF binary)
scripts/actuator.sh startup                                # /actuator/startup (BufferingApplicationStartup)
```

### Authentication — without leaking secrets to the agent

Actuator over HTTP is almost always behind authentication: Spring Security with Basic or Bearer, a reverse proxy, or an API gateway. The script resolves credentials through a chain that lets the agent reach the endpoint **without the secret in its prompt**, because a secret behind a `*-cmd` indirection never enters the transcript:

```bash
# ENV vars (precedence: bearer > basic > custom header)
export ACTUATOR_BEARER='eyJ...'                     # literal Bearer
export ACTUATOR_BEARER_CMD='vault kv get -field=token kv/myapp/actuator'
export ACTUATOR_BASIC='ops:s3cret'                  # literal Basic
# op = 1Password CLI
export ACTUATOR_BASIC_CMD='op item get "Actuator ops" --fields username,password --format=json | jq -r ".[0].value+\":\"+.[1].value"'
export ACTUATOR_AUTH_HEADER='X-API-Key: abc123'

# Or a credentials file (mode 0600, INI per base-URL section):
#   $ACTUATOR_CREDENTIALS or ~/.config/java-debug/actuator-credentials
#     [https://prod.example.com/actuator]
#     bearer-cmd = vault kv get -field=token kv/prod/actuator

# Or a per-call CLI flag (pass = the Unix password store CLI, passwordstore.org):
scripts/actuator.sh --bearer-cmd 'pass show actuator/local' health
```

The script never prints the resolved secret. `--verbose` prints only the *command text* or the *name* of the environment variable. The full chain and recipes for 1Password, Vault, Keychain, pass, gopass, Bitwarden, and AWS Secrets Manager are in [`references/actuator.md`](references/actuator.md) §4.2.

### Actuator scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/actuator-startup.sh` | Emit the `management.*` Spring properties as `-D` flags; `--dev` / `--prod` presets; `--server-port` / `--web-base-path` for non-default deployments |
| `scripts/actuator.sh` | Bash wrapper → `actuator.py`; subcommands per endpoint with smart filtering/pretty-print + output caps + auth chain. Output caps: a response above 500 lines or 50,000 bytes goes to a spill file, and stdout shows a shortened version and the file path, so the output fits an agent's context; raise the limits with `--max-lines` and `--max-bytes` |
| `scripts/actuator.py` | Python implementation: base-URL resolution + auto-probe, auth chain (env/file/cmd, [`references/actuator.md`](references/actuator.md) §4.2), 13 subcommands |

---

## Cross-cutting

- **Compile with `-g`** if you plan to use JDB. Without it, `locals` shows "no variable info". Gradle's `JavaCompile` and Maven's `maven-compiler-plugin` both default to `debug = true`, which passes `-g`. Check that the build does not turn it off.
- **Set `stackdepth=128`** for JFR on Spring, because Spring stacks are deep. With the default of 64 (measured 2026-11-15 on Temurin 11, 17, 21, 25), JFR cuts the stacks, and `jfr view hot-methods` then produces useless aggregates. `scripts/jfr-record.sh startup` sets 128 by default.
- **JDWP has no authentication at all, and JMX has none with `authenticate=false`.** `jmx-startup.sh` emits `authenticate=false` without `--auth`, while the JDK default is `true`. Anyone who reaches such a port has full code execution on the JVM. Bind to `127.0.0.1` in dev. In production, use SSH tunnels, JMX SSL with password files, or Spring Security in front of Actuator. *Never* expose `*:5005` or `*:5000` on public interfaces, because that gives code execution to anyone on the network. For JDWP, `*` binds the IPv4 wildcard `0.0.0.0` on JDK 11 and the dual-stack wildcard `[::]` on JDK 17 and 25 (bind measured 2026-11-15 on Temurin, in a container; reaching it from a non-loopback interface was not tested).
- **A loopback bind does not keep out anyone who may run `kubectl port-forward` to the pod.** A forwarded connection arrives in the pod with source and destination `127.0.0.1`, so the server cannot tell it apart from a local connection. This holds for a listener on `[::]` as well. A Jolokia 2.6.3 agent on `127.0.0.1:8778` without a policy file answered reads through the forward without authentication. Measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward. For a Jolokia bridge, add the read-only policy from [`references/jolokia.md`](references/jolokia.md).
- **Forward one port per `kubectl port-forward` process.** One refused connection ends the whole process with `error: lost connection to pod`, and every other port of that process then refuses connections on the host. A listener bound only to `::1` or only to the pod IP causes such a refusal. Measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward.
- **Use `show-values=ALWAYS` for `/env` and `/configprops` only in local dev,** because in production it leaks the values that Boot 3.x masks by default. Keep production at `WHEN_AUTHORIZED` or `NEVER`, with Spring Security in front.
- **Credentials for Actuator and JMX never go into the agent's prompt,** because whatever enters the prompt stays in the conversation transcript. Use the `ACTUATOR_BEARER` / `ACTUATOR_BASIC` / `ACTUATOR_*_CMD` or `JMX_*` environment variables, the credentials files `~/.config/java-debug/actuator-credentials` and `~/.config/java-debug/jmx-credentials` (chmod 600), or a per-call `--*-cmd` flag whose argument is the *command* (for example `vault kv get -field=token …`), as shown under Strategy E, "Authentication". The scripts resolve the chain and never print the resolved secret to stdout, stderr, or shell history.
- **PII and secrets** must not land in span attributes, baggage entries, or fields of custom JFR events. JFR has `jfr scrub --exclude-events …`, and the OTel collector has the `attributes` and `redaction` processors.
- **Async boundaries** need care:
  - JFR: stacks break apart at `CompletableFuture`, Reactor, coroutine, and fiber boundaries, because JFR records one stack per thread and the work hops between threads. For coroutines see `references/jfr.md` §6 (Kotlin).
  - OTel: the agent's instrumentation wraps known executors and reactive types. A raw `Thread` or `new Thread(...)` loses the context unless you use `Context.taskWrapping(executor)`. See `references/otel.md` §5.3.

---

## All references

| File | Contents |
|---|---|
| [`references/jfr.md`](references/jfr.md) | JFR: concepts, Spring Boot idioms, custom events, `jfr` CLI analysis, Kotlin specifics, pitfalls |
| [`references/otel.md`](references/otel.md) | OpenTelemetry: Java agent, OTLP exporters, local collector, custom spans, **cross-service tracing example**, comparison table |
| [`references/jdb.md`](references/jdb.md) | JDB: decision tree, attach vs launch, interactive command catalogue, workflow patterns (NPE, deadlock, watch-method) |
| [`references/jdb-commands.md`](references/jdb-commands.md) | Complete alphabetical JDB command reference |
| [`references/jdwp-options.md`](references/jdwp-options.md) | Every JDWP agent option (transport, server, suspend, address, onthrow, …) and security guidance |
| [`references/jmx.md`](references/jmx.md) | JMX: JVM flags, jmxterm usage, Jolokia HTTP bridge, MBean catalogues (Tomcat, HikariCP, Lettuce, JVM, Spring), container/k8s setup (§6: `java.rmi.server.hostname`, matching port numbers for port-forward) |
| [`references/actuator.md`](references/actuator.md) | Spring Boot Actuator: endpoint catalogue, management.* properties, security + auth chain, JMX-vs-HTTP exposure, troubleshooting non-standard paths |
| [`references/jmc.md`](references/jmc.md) | JDK Mission Control: install, connect over JMX or Jolokia, JFR from the GUI, headless rules report |
| [`references/metrics-export.md`](references/metrics-export.md) | MBean values and JVM counters into a file (`jmx-sample.py`, `jcmd`, JFR streaming); continuous export (jmx_exporter, OTel) |
| [`references/jolokia.md`](references/jolokia.md) | Jolokia: loopback start flags, measured policy semantics, read-only policy template, negative tests |
| [`references/heap-dumps.md`](references/heap-dumps.md) | Class histogram, heap dump on demand and on OOM (`%p`, not `%t`), MAT headless, dumps in containers, TLS trust (`PKIX`) |
| [`references/profiling-and-threads.md`](references/profiling-and-threads.md) | Thread dumps (incl. virtual threads), GC log, NMT vs RSS, `VM.*` commands, attach rules, async-profiler |
| [`references/crac.md`](references/crac.md) | CRaC: engines (warp, CRIU), checkpoint blockers, what a restore keeps, debug agents vs checkpoint, restore failure with glibc >= 2.42 guard regions (§5) |
| [`references/scala-jvm.md`](references/scala-jvm.md) | Scala 3.5+ `scala` runner, sbt, Scala-specific JFR/OTel/JDB idioms, Pekko/ZIO/Cats Effect async caveats |

