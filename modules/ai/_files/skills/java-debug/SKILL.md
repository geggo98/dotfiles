---
name: java-debug
description: >-
  Diagnose, profile, trace, debug, and introspect Java/JVM applications
  using five complementary strategies. (1) JFR for low-overhead in-JVM
  recording. (2) OpenTelemetry for real distributed traces with spans
  across services. (3) JDB for interactive breakpoint debugging. (4) JMX
  & MBeans for runtime introspection — Tomcat/Jetty connectors, HikariCP
  pool stats, Lettuce/Redis, custom MBeans, any JVM. (5) Spring Boot
  Actuator for Spring-specific wiring — /beans, /conditions, /configprops,
  /env, /health, /mappings, /loggers, /metrics. Triggers on: Java
  performance, JVM diagnostics, Spring Boot startup, GC, heap, allocation,
  deadlocks, breakpoints, JFR, jcmd, OpenTelemetry, OTel, traces, spans,
  JMX, MBean, jmxterm, Jolokia, Spring Actuator, beans, autoconfig,
  conditions, configprops, configuration, wiring, bean missing, Tomcat
  connector, HikariCP, Lettuce, Redis health, log level change, request
  mappings — or to introspect the runtime state of a Java/Kotlin/Scala
  app on JDK 11+.
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

Five complementary diagnostic strategies. Pick the one that matches the question; combine them when needed.

| Strategy | Best for | Overhead | Local-only? |
|---|---|---|---|
| **JFR** (Flight Recorder) | "What is the JVM doing?" — GC, allocation, locks, I/O, custom events | ~1–2 % | Yes (a `.jfr` file) |
| **OTel** (OpenTelemetry) | "Where does latency live across endpoints/services?" — distributed traces, spans | Low at the agent; some per-span | Yes (file exporter) |
| **JDB** (Java Debugger) | "Why does this code take this branch? What's the state right here?" | Interactive only | Yes (JDWP socket) |
| **JMX** (MBeans) | "What's the runtime state? — connector/pool/cache/Redis stats; any JVM" | Near-zero (RMI on demand) | Yes (RMI port or HTTP via Jolokia) |
| **Actuator** (Spring) | "Spring wiring: which beans, which conditions, which config?" | Near-zero | Yes (HTTP or JMX) |

They do **not** replace each other. JFR sees JVM internals OTel cannot. OTel sees cross-service causality JFR cannot. JDB sees per-frame variables neither can. JMX & Actuator see **effective configuration and runtime introspection** — the state of the running process — which sampling/tracing tools and the source-level debugger cannot answer cheaply.

## Pick a strategy

```
What's the question?
  ├─ "Where is CPU / allocation / GC time going?"                → JFR
  ├─ "Why is endpoint X slow in production?"                     → JFR (+ OTel if multi-service)
  ├─ "Where does latency live across N services?"                → OTel (cross-service)
  ├─ "What's the state at this line / why this branch?"          → JDB
  ├─ "Is the app deadlocked? Which threads are blocked?"         → JDB diagnostics first, then JFR
  ├─ "How long do my Spring-startup beans take?"                 → JFR (FlightRecorderApplicationStartup)
  ├─ "How does my own business logic look in a trace?"           → OTel + @WithSpan or programmatic API
  ├─ "Which beans got created / which conditional was rejected?" → Actuator (E)
  ├─ "What's the effective config (env, properties, profiles)?"  → Actuator: /env, /configprops
  ├─ "Is the HikariCP/Redis/Tomcat pool healthy? How many active?"→ Actuator: /health + /metrics, OR JMX (D)
  ├─ "What port is Tomcat actually listening on?"                → JMX: Catalina:type=Connector,*
  └─ "Bump log level at runtime without restart"                 → Actuator: /loggers (POST)
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

## Strategy D — JMX (Java Management Extensions / MBeans)

JMX is the JVM's built-in introspection layer. Every JDK exposes MBeans for the runtime (memory, threads, GC, class loaders); every well-behaved Java library publishes its own MBeans for state and metrics — Spring Boot, Tomcat, Jetty, Netty, HikariCP, Lettuce, Kafka, Hibernate, Camel, Quartz.

Two access protocols:

- **RMI** (the JDK default) — JVM listens on an RMI registry port. `jmxterm` connects, reads/writes attributes, invokes operations. Works on any JDK 11+ JVM with the right flags; nothing on the app's classpath.
- **HTTP via Jolokia** — Jolokia agent (jar on the classpath) translates JMX to/from JSON over HTTP. Easier in containers; needs a deploy-time change. See `references/jmx.md` §4.

### Quick start

Emit the JVM JMX flags (for `JAVA_TOOL_OPTIONS` / Dockerfile / bootRun):

```bash
scripts/jmx-startup.sh --port 5000 --print-args-only
# -Dcom.sun.management.jmxremote=true
# -Dcom.sun.management.jmxremote.port=5000
# -Dcom.sun.management.jmxremote.rmi.port=5000
# -Dcom.sun.management.jmxremote.authenticate=false
# -Dcom.sun.management.jmxremote.ssl=false
# -Djava.rmi.server.hostname=127.0.0.1
```

Inspect the running JVM:

```bash
scripts/jmx.sh domains --port 5000                                            # list MBean domains
scripts/jmx.sh list --port 5000 --domain Catalina                             # MBeans in a domain
scripts/jmx.sh attr --port 5000 'Catalina:type=Connector,port=*' 'localPort'  # read attribute(s)
scripts/jmx.sh attr --port 5000 'com.zaxxer.hikari:type=Pool (HikariPool-1)' \
                                 'ActiveConnections,IdleConnections,ThreadsAwaitingConnection'
scripts/jmx.sh invoke --port 5000 'java.lang:type=Memory' 'gc'                # manual GC (sparingly)
```

Full reference: [`references/jmx.md`](references/jmx.md) — MBean catalogues for Tomcat, HikariCP, Lettuce, Spring, JVM built-ins; container/k8s hostname tricks; the Jolokia HTTP-bridge path.

### JMX scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/jmx-startup.sh` | Emit the `-Dcom.sun.management.jmxremote.*` JVM flags (default port 5000) |
| `scripts/jmx.sh` | Wrap `jmxterm` (or `nix run nixpkgs#jmxterm`); subcommands `domains`, `list`, `attr`, `invoke`; password chain via `JMX_PASSWORD_CMD` / credentials file |

---

## Strategy E — Spring Boot Actuator

The Spring-Boot-specific introspection layer. Sits on top of JMX (every Actuator endpoint is also an MBean when `spring.jmx.enabled=true`) and on top of HTTP (under `/actuator/*` by default).

Use when the question is Spring-specific: bean wiring, auto-configuration decisions, effective configuration, request mappings, runtime log-level changes, scheduled tasks, Spring/HikariCP/Redis metrics. For non-Spring JVMs, fall back to Strategy D.

**Boot 3.x defaults**: only `/actuator/health` over HTTP; JMX exposure requires `spring.jmx.enabled=true`. Values in `/env` and `/configprops` are masked unless `--show-values=ALWAYS`.

### Quick start

Emit the Spring `management.*` properties:

```bash
scripts/actuator-startup.sh --print-args-only --dev
# -Dspring.jmx.enabled=true
# -Dmanagement.endpoints.web.exposure.include=*
# -Dmanagement.endpoints.jmx.exposure.include=*
# -Dmanagement.endpoint.health.show-details=ALWAYS
# -Dmanagement.endpoint.env.show-values=ALWAYS
# -Dmanagement.endpoint.configprops.show-values=ALWAYS
```

The script auto-detects the Actuator base URL by probing the common shapes — Spring default `http://localhost:8080/actuator`, separate management port `:8081`, alternative base-paths `/management` and `/admin`. Override explicitly when the deployment is unusual:

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

Actuator over HTTP is almost always behind auth (Spring Security Basic/Bearer, a reverse-proxy, an API gateway). The script supports a resolution chain that lets the agent reach the endpoint **without ever needing the secret in its prompt**:

```bash
# ENV vars (precedence: bearer > basic > custom header)
export ACTUATOR_BEARER='eyJ...'                     # literal Bearer
export ACTUATOR_BEARER_CMD='vault kv get -field=token kv/myapp/actuator'
export ACTUATOR_BASIC='ops:s3cret'                  # literal Basic
export ACTUATOR_BASIC_CMD='op item get "Actuator ops" --fields username,password --format=json | jq -r ".[0].value+\":\"+.[1].value"'
export ACTUATOR_AUTH_HEADER='X-API-Key: abc123'

# Or a credentials file (mode 0600, INI per base-URL section):
#   $ACTUATOR_CREDENTIALS or ~/.config/java-debug/actuator-credentials
#     [https://prod.example.com/actuator]
#     bearer-cmd = vault kv get -field=token kv/prod/actuator

# Or a per-call CLI flag:
scripts/actuator.sh --bearer-cmd 'pass show actuator/local' health
```

The script never echoes the resolved secret — `--verbose` prints only the *command text* or env-var *name*. Full chain + 1Password / Vault / Keychain / pass / gopass / Bitwarden / AWS Secrets Manager recipes in [`references/actuator.md`](references/actuator.md) §4.5.

### Actuator scripts at a glance

| Script | One-liner |
|---|---|
| `scripts/actuator-startup.sh` | Emit the `management.*` Spring properties as `-D` flags; `--dev` / `--prod` presets; `--server-port` / `--web-base-path` for non-default deployments |
| `scripts/actuator.sh` | Bash wrapper → `actuator.py`; subcommands per endpoint with smart filtering/pretty-print + token caps + auth chain |
| `scripts/actuator.py` | Python implementation: base-URL resolution + auto-probe, auth chain (env/file/cmd), 13 subcommands, non-leakage guarantees |

---

## Cross-cutting

- **Compile with `-g`** if you plan to use JDB — without it, `locals` shows "no variable info". (Gradle's `application` plugin defaults to `options.debug = true`; Maven needs `<debug>true</debug>` in `maven-compiler-plugin`.)
- **`stackdepth=128`** for JFR on Spring — the default 64 is too shallow. `scripts/jfr-record.sh startup` sets this by default.
- **JDWP and JMX have no authentication by default.** Anyone who reaches the port has full code execution on the JVM. Bind to `127.0.0.1` in dev; in production use SSH tunnels, JMX SSL + password files, or Spring Security in front of Actuator. *Never* expose `*:5005` / `*:5000` on public interfaces.
- **Actuator's `/env` and `/configprops` masking is on by default in Boot 3.x.** `--show-values=ALWAYS` is fine for local dev but a leak in production — keep it `WHEN_AUTHORIZED` or `NEVER` with Spring Security in front.
- **Credentials for Actuator / JMX never go into the agent's prompt.** Use the `ACTUATOR_BEARER` / `ACTUATOR_BASIC` / `ACTUATOR_*_CMD` env vars, the `~/.config/java-debug/actuator-credentials` file (chmod 600), or a per-call `--*-cmd` flag whose argument is the *command* (e.g. `vault kv get -field=token …`). The scripts resolve the chain and never echo the resolved secret to stdout, stderr, or shell history.
- **PII and secrets** must not land in span attributes, baggage entries, or JFR custom-event fields. JFR has `jfr scrub --exclude-events …`; OTel has the collector `attributes`/`redaction` processors.
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
| [`references/jmx.md`](references/jmx.md) | JMX: JVM flags, jmxterm usage, Jolokia HTTP bridge, MBean catalogues (Tomcat, HikariCP, Lettuce, JVM, Spring), container/k8s hostname tricks |
| [`references/actuator.md`](references/actuator.md) | Spring Boot Actuator: endpoint catalogue, management.* properties, security + auth chain, JMX-vs-HTTP exposure, troubleshooting non-standard paths |
| [`references/scala-jvm.md`](references/scala-jvm.md) | Scala 3.5+ `scala` runner, sbt, Scala-specific JFR/OTel/JDB idioms, Pekko/ZIO/Cats Effect async caveats |
