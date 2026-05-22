---
name: java-debug
description: >-
  Diagnose, profile, trace, and debug Java/JVM applications using three
  complementary strategies. (1) Java Flight Recorder (JFR) for low-overhead
  in-JVM recording — GC, allocation, lock contention, I/O, custom events.
  (2) OpenTelemetry (OTel) for real distributed traces with spans across one
  or many services, with a local file exporter so no backend is required.
  (3) Java Debugger (JDB / JDWP) for interactive breakpoint debugging,
  thread dumps, and deadlock analysis. Use whenever the user mentions Java
  performance, JVM diagnostics, Spring Boot startup, GC, heap, allocation
  hot spots, slow endpoints, deadlocks, breakpoints, JDB, JDWP, JFR, Flight
  Recorder, jcmd, jfr CLI, OpenTelemetry, OTel, traces, spans, distributed
  tracing, otelcol, fileexporter — or wants to profile, trace, or debug a
  Java, Kotlin, or Scala application on JDK 11+.
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
  Bash(./scripts/otel-agent-download.sh *)
  Bash(./scripts/otel-collector-up.sh *)
  Bash(./scripts/otel-spans-extract.sh *)
  Bash(jcmd:*) Bash(jfr:*) Bash(jdb:*) Bash(java:*) Bash(jq:*) Bash(curl:*)
  Read
dependencies: >-
  JDK 11+ (ships jcmd, jfr, jdb). For OTel: opentelemetry-collector-contrib
  (load via the nix-shell skill if not on PATH). For JSON wrangling: jq.
compatibility: >-
  macOS, Linux. On Windows invoke scripts via WSL.
metadata:
  based-on: "https://github.com/brunoborges/jdb-agentic-debugger/tree/main/skills/jdb-debugger"
---

# Java / JVM Diagnostics — JFR, OpenTelemetry, JDB

Three complementary diagnostic strategies for Java/JVM applications. Pick the one that matches the question; combine them when needed.

| Strategy | Best for | Overhead | Local-only? |
|---|---|---|---|
| **JFR** (Flight Recorder) | "What is the JVM doing?" — GC, allocation, locks, I/O, custom events | ~1–2 % | Yes (a `.jfr` file) |
| **OTel** (OpenTelemetry) | "Where does latency live across endpoints/services?" — distributed traces, spans | Low at the agent; some per-span | Yes (file exporter) |
| **JDB** (Java Debugger) | "Why does this code take this branch? What's the state right here?" | Interactive only | Yes (JDWP socket) |

They do **not** replace each other. JFR sees JVM internals OTel cannot. OTel sees cross-service causality JFR cannot. JDB sees per-frame variables neither can.

## Pick a strategy

```
What's the question?
  ├─ "Where is CPU / allocation / GC time going?"                → JFR
  ├─ "Why is endpoint X slow in production?"                     → JFR (+ OTel if multi-service)
  ├─ "Where does latency live across N services?"                → OTel (cross-service)
  ├─ "What's the state at this line / why this branch?"          → JDB
  ├─ "Is the app deadlocked? Which threads are blocked?"         → JDB diagnostics first, then JFR
  ├─ "How long do my Spring-startup beans take?"                 → JFR (FlightRecorderApplicationStartup)
  └─ "How does my own business logic look in a trace?"           → OTel + @WithSpan or programmatic API
```

## Tooling availability

`jcmd`, `jfr`, and `jdb` ship with the JDK. `otelcol-contrib` is a separate binary.

If any of these is missing on the host, use the `nix-shell` skill to make it available without polluting the global environment:

```bash
# JDK on demand (provides jcmd, jfr, jdb)
${CLAUDE_SKILL_DIR}/../nix-shell/scripts/nix_shell.sh run jdk21 -- jfr summary recording.jfr

# OTel collector on demand
${CLAUDE_SKILL_DIR}/../nix-shell/scripts/nix_shell.sh \
  run opentelemetry-collector-contrib -- otelcol-contrib --config /tmp/otel.yaml
```

`scripts/otel-collector-up.sh` already falls back to `nix run nixpkgs#opentelemetry-collector-contrib` automatically when `otelcol-contrib` is not on PATH, so the agent rarely needs to invoke `nix_shell.sh` directly for OTel.

---

## Strategy A — JFR (Java Flight Recorder)

Built into every JDK 11+. Records structured JVM events (GC, allocation in TLAB, lock contention, file/socket I/O, JIT decisions) plus any custom events you define. Recordings are binary `.jfr` files — analyse them with the JDK's `jfr` CLI (or, if you must, JDK Mission Control).

Two operating modes:

- **Continuous (ringbuffer)** — `disk=true, maxage=1h, maxsize=500m, dumponexit=true`. Runs forever, dump on demand or at crash. Production default.
- **Targeted** — `duration=60s, settings=profile`. Short, deeper sampling. Diagnostic windows.

### Quick start

Start a 60-second profile recording on a running JVM:

```bash
scripts/jfr-record.sh start --match 'myapp\.jar' --filename /tmp/myapp.jfr
# resolves the PID by grepping `jcmd -l` and runs `jcmd <PID> JFR.start ...`
```

Or emit the JVM startup flag for embedding in `JAVA_TOOL_OPTIONS` / a Dockerfile / a Spring `bootRun` task:

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

---

## Strategy B — OpenTelemetry (OTel)

Vendor-neutral spec for traces, metrics, and logs. This skill focuses on **traces**. The standard Java path is the [OpenTelemetry Java agent](https://github.com/open-telemetry/opentelemetry-java-instrumentation), a `-javaagent` JAR that auto-instruments dozens of libraries (Spring MVC/WebClient, JDBC, Hibernate, Reactor Netty, gRPC, Kafka, Lettuce, OkHttp, …). Custom application code gets spans via the `@WithSpan` annotation or the programmatic `Tracer` API.

Three deployment shapes, increasing in complexity:

1. **Agent + console exporter** — fastest for ad-hoc debugging. Spans land on stdout.
2. **Agent + `logging-otlp` exporter + Logback** — OTLP-JSON-lines to a file, no extra process.
3. **Agent + OTLP exporter + local Collector** — collector writes JSON-lines via the file exporter (or fans out to Tempo, Jaeger, etc.). Required for processors (sampling, attribute filtering, PII redaction) and multi-backend setups.

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

OTel's superpower: a single trace spans **all** services that participate in one request, glued by W3C TraceContext headers (`traceparent`, `tracestate`) which the agent propagates automatically for every supported library — Spring WebClient, RestTemplate, OkHttp, gRPC, Kafka, RabbitMQ, JDBC, Reactor Netty, etc. No code changes required.

For the runnable 2-service Spring Boot example (caller → callee, both with the agent, one collector, one `traces.jsonl`, single `traceId` spanning both), see [`references/otel.md`](references/otel.md) §5. It also covers the propagation pitfalls (raw `Thread`/`ExecutorService` without context wrapping; baggage projection onto child spans; sampling decisions across services).

### Manual spans for your own code

`@WithSpan` for the 90 % case, `Tracer`/`spanBuilder` for the rest. Programmatic API requires `makeCurrent()` to propagate context, `span.end()` in `finally` to avoid leaks, and `span.recordException()` + `setStatus(ERROR)` on failure paths. See [`references/otel.md`](references/otel.md) §4 for the full pattern and [`references/scala-jvm.md`](references/scala-jvm.md) §4 for the Scala idiom.

### OTel scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/otel-agent-download.sh` | Idempotently fetch `opentelemetry-javaagent.jar`; prints the absolute path |
| `scripts/otel-collector-up.sh` | Start `otelcol-contrib` (or `nix run` it) with a default file-exporter config |
| `scripts/otel-spans-extract.sh` | Resource-context-aware `jq` extraction; filters by service / name / traceId / min duration |

---

## Strategy C — JDB (Java Debugger / JDWP)

The JDK's command-line debugger. Connects via the **Java Debug Wire Protocol (JDWP)** to a JVM started with `-agentlib:jdwp=...`. Use it for interactive step-debugging, thread dumps, deadlock analysis, and "what is the local state at this point" questions that neither tracing nor profiling can answer.

**Golden rule:** never create files in the workspace. No `bp.txt`, no `cmds.txt`, no wrapper scripts. Use the inline `--bp` / `--cmd` / `--auto-inspect` / `--timeout` flags on `scripts/jdb-breakpoints.sh`. The script handles temp files in `/tmp/` and cleans up.

### Quick start

Attach to a JVM that was launched with `-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005`:

```bash
scripts/jdb-attach.sh --host localhost --port 5005
```

Or launch a fresh JVM under JDB:

```bash
scripts/jdb-launch.sh com.example.MyApp --sourcepath src/main/java
```

Collect a thread dump + deadlock check non-interactively:

```bash
scripts/jdb-diagnostics.sh --port 5005
```

Automated batch debugging (NPE investigation, no workspace files):

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

## Cross-cutting

- **Compile with `-g`** if you plan to use JDB — without it, `locals` shows "no variable info". (Gradle's `application` plugin defaults to `options.debug = true`; Maven needs `<debug>true</debug>` in `maven-compiler-plugin`.)
- **`stackdepth=128`** for JFR on Spring — the default 64 is too shallow. `scripts/jfr-record.sh startup` sets this by default.
- **JDWP has no authentication.** Anyone who reaches the port has full code execution on the JVM. Bind to `127.0.0.1` in production; use `ssh -L 5005:localhost:5005` for remote sessions; never expose `*:5005` on public interfaces.
- **PII and secrets** must not land in span attributes, baggage entries, or JFR custom-event fields. For sanitisation: JFR has `jfr scrub --exclude-events …`; OTel has the collector `attributes`/`redaction` processors.
- **Async boundaries** are subtle:
  - JFR: stacks fragment across `CompletableFuture`/Reactor/coroutine/fiber boundaries — see `references/jfr.md` §6 and §8.
  - OTel: the agent's instrumentation wraps known executors and reactive types; raw `Thread`/`new Thread(...)` loses context unless you use `Context.taskWrapping(executor)`. See `references/otel.md` §5.3.

---

## All references

| File | Contents |
|---|---|
| [`references/jfr.md`](references/jfr.md) | JFR: concepts, Spring Boot idioms, custom events, `jfr` CLI analysis, Kotlin specifics, pitfalls |
| [`references/otel.md`](references/otel.md) | OpenTelemetry: Java agent, OTLP exporters, local collector, custom spans, **cross-service tracing example**, comparison table |
| [`references/jdb.md`](references/jdb.md) | JDB: decision tree, attach vs launch, interactive command catalogue, workflow patterns (NPE, deadlock, watch-method) |
| [`references/jdb-commands.md`](references/jdb-commands.md) | Complete alphabetical JDB command reference |
| [`references/jdwp-options.md`](references/jdwp-options.md) | Every JDWP agent option (transport, server, suspend, address, onthrow, …) and security guidance |
| [`references/scala-jvm.md`](references/scala-jvm.md) | Scala 3.5+ `scala` runner, sbt, Scala-specific JFR/OTel/JDB idioms, Pekko/ZIO/Cats Effect async caveats |
