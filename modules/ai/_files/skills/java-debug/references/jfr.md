# Java Flight Recorder (JFR) – Pragmatic Reference

> Focus: Spring Boot with Gradle. Kotlin briefly at the end.
> Audience: developers **and** coding agents that consume shell output.
>
> For Scala/sbt/Pekko specifics, see `scala-jvm.md` in this directory.

## Table of Contents

- [1. Core concepts (read this first)](#1-core-concepts-read-this-first)
- [2. Quick start](#2-quick-start)
- [3. Spring Boot — idiomatic](#3-spring-boot--idiomatic)
- [4. Defining custom events and spans](#4-defining-custom-events-and-spans)
- [5. CLI analysis with `jfr`](#5-cli-analysis-with-jfr)
- [6. Kotlin](#6-kotlin)
- [8. Tips for agent consumption](#8-tips-for-agent-consumption)
- [9. Alternatives and complements](#9-alternatives-and-complements)
- [10. Common pitfalls](#10-common-pitfalls)

---

## 1. Core concepts (read this first)

| Term | Meaning |
|---|---|
| **JFR** | Java Flight Recorder. Event recorder built into the JDK. Open-sourced into OpenJDK since JDK 11 (previously commercial in Oracle JDK). |
| **Event** | Structured data point with timestamp, thread, stack trace, and custom fields. Examples: `jdk.GarbageCollection`, `jdk.CPULoad`, `jdk.ObjectAllocationInNewTLAB`. |
| **Recording** | Time window during which events are collected. Output: a `.jfr` file (binary, chunk-based). |
| **Settings / `.jfc` file** | XML configuration controlling which events are recorded at which threshold. Shipped configs: `default.jfc` (~1 % overhead) and `profile.jfc` (~2 %). Path: `$JAVA_HOME/lib/jfr/`. |
| **`jcmd`** | Diagnostic tool in the JDK. Talks to running JVMs via the attach mechanism. |
| **`jfr` CLI** | Standalone tool (JDK 14+) for analyzing `.jfr` files without the JMC GUI. Since JDK 21 it offers `jfr view` for predefined reports. |
| **JMC** | JDK Mission Control. GUI for analysis. Not covered here — unusable for agents. |
| **Spring `ApplicationStartup`** | Spring Framework API (5.3+) for tracking startup phases. The `FlightRecorderApplicationStartup` implementation emits steps as JFR events. Not the same as general JFR profiling. |

"JFR tracing" and "application profiling" cover two distinct use cases:

- **Continuous / black-box recording**: a recording with `maxage`/`maxsize` runs permanently; you dump on demand when something happens. Default settings. Production-grade.
- **Targeted profiling**: you start a bounded recording (say 60 s) under load, dump, and analyze. Profile settings. Higher overhead, more data.

---

## 2. Quick start

Helper scripts in the parent skill wrap the common workflows. Prefer them over hand-rolled `jcmd` / `jfr` invocations:

- `scripts/jfr-record.sh` — starts a JFR recording on a running JVM (wraps `jcmd JFR.start` / `JFR.dump` / `JFR.stop`).
- `scripts/jfr-summary.sh` — runs `jfr summary` on a `.jfr` file for a quick sanity check.
- `scripts/jfr-view.sh` — runs `jfr view <view-name>` with sensible width defaults.
- `scripts/jfr-events.sh` — runs `jfr print --json --events <pattern>` with an event-count cap that keeps output token-sized.

### 2.1 Recording at JVM startup

```bash
java \
  -XX:StartFlightRecording=duration=60s,filename=app.jfr,settings=profile \
  -jar app.jar
```

Important options (comma-separated after `=`):

| Option | Effect |
|---|---|
| `name=myRec` | Name; required if you want to address the recording later via `jcmd`. |
| `duration=60s` | Recording stops automatically. Omit for unbounded. |
| `filename=...` | Where the file is written. |
| `settings=default\|profile\|/path/to/custom.jfc` | Profile. |
| `maxage=1h` | Ring-buffer age (only with `disk=true`). |
| `maxsize=200M` | Ring-buffer size. |
| `disk=true` | Streams chunks to disk continuously instead of holding them in RAM only. Default since JDK 11+. |
| `dumponexit=true` | Dumps automatically on JVM shutdown. |

Idiomatic continuous recording in production:

```bash
-XX:StartFlightRecording=settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true,filename=/var/log/app/recording.jfr
```

You always have the last hour at hand without constantly consuming storage, and a crash leaves a dump automatically.

### 2.2 Recording on a running JVM

```bash
# 1. Find the PID
jcmd -l            # lists all JVMs on this host
# or
pgrep -f 'app.jar'

# 2. Start a recording
jcmd <PID> JFR.start name=adhoc settings=profile duration=120s filename=/tmp/adhoc.jfr

# 3. Check status
jcmd <PID> JFR.check

# 4. Dump a snapshot (recording continues)
jcmd <PID> JFR.dump name=adhoc filename=/tmp/snapshot.jfr

# 5. Stop
jcmd <PID> JFR.stop name=adhoc filename=/tmp/final.jfr
```

Watch the syntax: `jcmd` parameters are **space-separated**, while `-XX:StartFlightRecording=` parameters are **comma-separated**. A common trap.

If `jcmd` reports "Unable to open socket file": different user or container namespace mismatch. In Kubernetes you need the same PID namespace (`shareProcessNamespace: true` on the pod, or a sidecar with `processNamespace`), or `kubectl exec` as the JVM's user.

---

## 3. Spring Boot — idiomatic

### 3.1 `FlightRecorderApplicationStartup` for startup phases

This is **not an alternative** to a regular JFR recording — it is an **addition**: Spring then emits additional JFR events of type `spring.startup` for every bean, every auto-configuration, every context initialization.

```java
@SpringBootApplication
public class Application {
    public static void main(String[] args) {
        SpringApplication app = new SpringApplication(Application.class);
        app.setApplicationStartup(new FlightRecorderApplicationStartup());
        app.run(args);
    }
}
```

Import: `org.springframework.core.metrics.jfr.FlightRecorderApplicationStartup` (in `spring-core`, so no extra dependency in a normal Spring Boot project).

For the startup to actually be captured, you must enable the recording **at JVM startup** (see 2.1). A recording started later via `jcmd` misses the startup phase by definition.

Alternative without JFR: `BufferingApplicationStartup` plus the Actuator endpoint `/actuator/startup` (returns JSON). Lightweight, good when you care **only** about startup.

### 3.2 Gradle: `bootRun` with JFR

`build.gradle.kts`:

```kotlin
import org.springframework.boot.gradle.tasks.run.BootRun

tasks.named<BootRun>("bootRun") {
    jvmArgs = listOf(
        "-XX:StartFlightRecording=" +
            "name=bootrun," +
            "settings=profile," +
            "duration=120s," +
            "filename=${layout.buildDirectory.get()}/jfr/bootrun.jfr," +
            "dumponexit=true",
        "-XX:FlightRecorderOptions=stackdepth=128"
    )
}
```

Groovy variant (`build.gradle`):

```groovy
bootRun {
    jvmArgs = [
        '-XX:StartFlightRecording=name=bootrun,settings=profile,duration=120s,filename=build/jfr/bootrun.jfr,dumponexit=true',
        '-XX:FlightRecorderOptions=stackdepth=128'
    ]
}
```

For **tests** with `@SpringBootTest`, analogously:

```kotlin
tasks.test {
    useJUnitPlatform()
    jvmArgs("-XX:StartFlightRecording=duration=60s,filename=build/jfr/test.jfr,settings=profile")
}
```

For the **deployed artifact** (container, systemd, etc.) you do **not** go through Gradle. Set `JAVA_TOOL_OPTIONS` or pass JVM args directly in your deployment manifest:

```yaml
# Kubernetes example
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-XX:StartFlightRecording=settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true,filename=/tmp/recording.jfr"
```

`stackdepth=128` matters because Spring stacks are deep. The default is 64; stacks then get truncated and `jfr view hot-methods` produces useless aggregates. It costs some overhead, but the trade-off is usually worth it.

---

## 4. Defining custom events and spans

### 4.1 Up front: JFR has no spans

JFR only knows **events** — no hierarchical spans. Two consequences:

- **Duration events** (with `begin()` / `end()`) are functionally span-like, but **flat**. No parent-child relation, no implicit trace IDs, no context propagation across threads.
- If you want real nested spans, build them yourself via fields (`traceId`, `parentSpanId`, your own `ThreadLocal`-based stack management) — or use **OpenTelemetry** for that and JFR for deep JVM-internal profiling. That is the clean split.

When are JFR custom events nonetheless the right choice?

- High-frequency, JVM-internal operations with a measurable overhead budget (< 1 µs per event is achievable when done right).
- Domain-specific events that you want to correlate with GC / allocation / CPU in the same recording — this is JFR's killer feature over OTel.
- Audit-style records you want to keep running as a ring buffer in production.

### 4.2 Instant event (Java)

```java
package com.example.observability;

import jdk.jfr.*;

@Name("com.example.OrderProcessed")
@Label("Order Processed")
@Category({"Application", "Orders"})
@Description("An order was processed successfully")
@StackTrace(false)   // stacks cost — default is true, often unnecessary
public class OrderProcessedEvent extends Event {

    @Label("Order ID")
    String orderId;

    @Label("Customer ID")
    String customerId;

    @Label("Amount in Cents")
    long amountCents;

    @Label("Item Count")
    int itemCount;
}
```

Usage:

```java
var event = new OrderProcessedEvent();
event.orderId = order.id();
event.customerId = order.customerId();
event.amountCents = order.totalCents();
event.itemCount = order.items().size();
event.commit();   // implicitly sets endTime = now
```

Important annotations:

| Annotation | Purpose |
|---|---|
| `@Name` | Unique event-type name. **Fully qualify** it (`com.example.X`), otherwise it collides with `jdk.*` events. |
| `@Label` | Human-readable label for JMC and `jfr view`. |
| `@Category` | Hierarchy for grouping in the GUI. Use an array for multiple levels. |
| `@Description` | Longer explanation. |
| `@StackTrace(false)` | Disables stack sampling. Saves significant overhead on frequent events. |
| `@Threshold("10 ms")` | Only events ≥ the threshold are committed (only meaningful on duration events). |
| `@Enabled(false)` | Class-level disabled-by-default. Activate later via settings or the recording API. |
| `@Period("1 s")` | For periodic events (see 4.5). |

Allowed field types: `boolean`, `byte`, `short`, `int`, `long`, `float`, `double`, `char`, `String`, `Class`, `Thread`. **No** collections, no custom objects. If you need complexity, serialize to `String` beforehand (sparingly — string allocations are expensive).

### 4.3 Duration event (span replacement)

```java
@Name("com.example.PaymentProcessing")
@Label("Payment Processing")
@Category({"Application", "Payment"})
@Threshold("5 ms")
public class PaymentProcessingEvent extends Event {
    @Label("Payment Method") String method;
    @Label("Provider")       String provider;
    @Label("Success")        boolean success;
}
```

Idiomatic pattern with `try`/`finally`:

```java
var event = new PaymentProcessingEvent();
event.method = "card";
event.provider = "stripe";
event.begin();
try {
    var result = paymentService.process(payment);
    event.success = result.isSuccess();
    return result;
} finally {
    event.commit();   // internally calls end() and shouldCommit()
}
```

`commit()` does, in one call:
1. `end()` (if not already called) → sets `endTime`.
2. Threshold check via `shouldCommit()`.
3. If accepted → writes to the recording.

### 4.4 Hot-path optimization

For frequent events, an explicit guard pays off:

```java
var event = new PaymentProcessingEvent();
if (!event.isEnabled()) {
    // Recording is not running or this event type is disabled.
    // Skip expensive field population.
    return paymentService.process(payment);
}
event.method = method;       // potentially expensive population
event.begin();
try {
    return paymentService.process(payment);
} finally {
    event.end();
    if (event.shouldCommit()) {   // separate threshold check
        event.success = ...;
        event.commit();
    }
}
```

This matters from about 10k events/s. For single-digit events per second it is micro-optimization and detracts from readability.

### 4.5 Periodic events

For regular sampling of your own metrics (e.g. cache size):

```java
@Name("com.example.CacheStats")
@Label("Cache Statistics")
@Period("10 s")
public class CacheStatsEvent extends Event {
    @Label("Entry Count") long entries;
    @Label("Hit Rate")    float hitRate;
}

// Register once at application startup:
FlightRecorder.addPeriodicEvent(CacheStatsEvent.class, () -> {
    var event = new CacheStatsEvent();
    event.entries = cache.size();
    event.hitRate = cache.stats().hitRate();
    event.commit();
});
```

### 4.6 Enabling and filtering custom events

Custom events are **enabled by default** as long as a recording is running and the event is not explicitly disabled. But: settings (`default.jfc` / `profile.jfc`) can configure filters, thresholds, and stack sampling per event type. Without a JFC entry, the per-class annotations apply.

**Configure programmatically** (e.g. for tests or via Spring config):

```java
var recording = new Recording();
recording.enable("com.example.PaymentProcessing")
    .withThreshold(Duration.ofMillis(20))
    .withStackTrace();
recording.setDestination(Path.of("/tmp/custom.jfr"));
recording.start();
// ... workload ...
recording.stop();
recording.close();
```

**Custom `.jfc` file** for production: take `$JAVA_HOME/lib/jfr/default.jfc`, copy it, and add your event configs:

```xml
<event name="com.example.PaymentProcessing">
    <setting name="enabled">true</setting>
    <setting name="threshold">20 ms</setting>
    <setting name="stackTrace">false</setting>
</event>
```

Then: `-XX:StartFlightRecording=settings=/path/to/myapp.jfc,...`

### 4.7 `RecordingStream` — consume events live

Since JDK 14 you can read events **without a file round-trip**, in-process. Extremely useful for an agent: you can stream custom events directly as JSON over stdout, a socket, or a REST endpoint.

```java
import jdk.jfr.consumer.RecordingStream;
import java.time.Duration;

try (var rs = new RecordingStream()) {
    rs.enable("com.example.PaymentProcessing")
      .withThreshold(Duration.ofMillis(10));

    rs.onEvent("com.example.PaymentProcessing", event -> {
        System.out.printf(
            "{\"method\":\"%s\",\"durationMs\":%d,\"success\":%b}%n",
            event.getString("method"),
            event.getDuration().toMillis(),
            event.getBoolean("success")
        );
    });

    rs.startAsync();   // or rs.start() (blocking)
    // ... application runs ...
}
```

You can also stream from a **live file** (`EventStream.openFile(path)`) or from a **remote JVM** via JMX / `FlightRecorderMXBean` — the latter is production-grade for agent-driven live monitoring without a sidecar.

### 4.8 Spring Boot integration

There is no Spring-specific API for custom JFR events — you just use plain Java events. Pragmatic patterns:

- **Instrument service methods manually** (see 4.3). Works, is explicit, no magic.
- **Spring AOP / `@Aspect`** for method-level tracing (all `@Service` methods, etc.):
  ```java
  @Aspect
  @Component
  public class JfrTracingAspect {
      @Around("@within(org.springframework.stereotype.Service)")
      public Object traceServiceCall(ProceedingJoinPoint pjp) throws Throwable {
          var event = new ServiceCallEvent();
          if (!event.isEnabled()) return pjp.proceed();
          event.className = pjp.getSignature().getDeclaringTypeName();
          event.methodName = pjp.getSignature().getName();
          event.begin();
          try {
              return pjp.proceed();
          } finally {
              event.commit();
          }
      }
  }
  ```
  Reflection-based AOP carries overhead itself — measure whether that is acceptable on the hot path.
- **Spring `ApplicationStartup` API** for your own startup steps. If you have `FlightRecorderApplicationStartup` active (see chapter 3), you can emit your own steps:
  ```java
  var step = applicationStartup.start("my.custom.warmup");
  step.tag("cache", "products");
  // ... work ...
  step.end();
  ```
  These land as `spring.startup` events in the recording. No event-class setup needed — but limited to the startup phase.

### 4.9 Analyzing custom events

`jfr view` only shows **built-in views**. For custom events you go through `print` and `metadata`:

```bash
# Which custom events are in the recording?
jfr metadata recording.jfr | grep -A 3 'com.example'

# Tabular, all fields
jfr print --events com.example.PaymentProcessing recording.jfr

# JSON, filtered with jq
jfr print --json --events com.example.PaymentProcessing recording.jfr \
  | jq '.recording.events[]
        | {method, duration: .duration, success}'

# Multiple custom event types
jfr print --json --events 'com.example.*' recording.jfr
```

For agents: write a small wrapper function `jfr_custom_events(pattern, path)` with a hard event-count cap (`.recording.events[0:1000]` in `jq`), otherwise busy recordings will blow the context window.

---

## 5. CLI analysis with `jfr`

This is the part that matters for agents. The tool ships with the JDK (`$JAVA_HOME/bin/jfr`).

Helper scripts in `scripts/` wrap the most common invocations — prefer them over hand-rolled commands:

- `scripts/jfr-summary.sh <recording.jfr>` — equivalent to `jfr summary`.
- `scripts/jfr-view.sh <view-name> <recording.jfr>` — equivalent to `jfr view --width 200 …`.
- `scripts/jfr-events.sh <event-pattern> <recording.jfr>` — equivalent to `jfr print --json --events …` with a built-in event-count cap.

### 5.1 Get an overview

```bash
jfr summary recording.jfr
```

Returns event counts per type, recording duration, and chunks. First question: "What is in here at all?"

```bash
jfr metadata recording.jfr
```

Lists every event type in the file along with its fields. Useful to know what you can filter on.

### 5.2 Predefined views (JDK 21+) — **most important for agents**

`jfr view` renders prebuilt reports as ASCII tables. Stable, deterministic, parseable by agents.

```bash
jfr view <view-name> recording.jfr
jfr view --width 200 hot-methods recording.jfr
```

Important views:

| View | Shows |
|---|---|
| `jvm-information` | Version, flags, arguments. Sanity check first. |
| `system-information` | OS, CPU, memory. |
| `gc` | GC pauses, reason, duration. |
| `gc-statistics` | Aggregated GC metrics. |
| `heap-statistics` | Heap usage over time. |
| `hot-methods` | CPU hot methods from sampling. The classic. |
| `allocation-by-class` | TLAB allocations per class. Heap-pressure analysis. |
| `allocation-by-site` | Allocations per allocation site (stack). More precise. |
| `contention-by-site` / `contention-by-thread` | Java monitor contention. |
| `exception-count` / `exception-by-type` | Exceptions thrown. Surfaces hidden control-flow-via-exception. |
| `file-io` / `socket-io` | Blocking I/O calls > threshold. Latency hunting. |
| `thread-cpu-load` | CPU per thread. Find hot threads. |
| `recording` | Metadata of the recording itself. |

Full list: `jfr view --help`.

### 5.3 Print selected events

```bash
# Specific event types, text output
jfr print --events jdk.GarbageCollection,jdk.GCPhasePause recording.jfr

# With stack traces (for jdk.ExecutionSample etc.)
jfr print --stack-depth 32 --events jdk.ExecutionSample recording.jfr

# Wildcards
jfr print --events 'jdk.GC*' recording.jfr
jfr print --events 'spring.*' recording.jfr   # for FlightRecorderApplicationStartup
```

### 5.4 JSON output — the agent's real path

```bash
jfr print --json --events jdk.GarbageCollection recording.jfr > gc.json
jfr print --json --events spring.startup recording.jfr | jq '.recording.events | length'
```

JSON is **large**. Always filter with `--events`, otherwise it overruns any context window. For `jdk.ExecutionSample` (CPU sampling), we are easily talking about 100k+ events per minute.

XML also works (`--xml`), but is rarely useful.

### 5.5 Strip sensitive data

```bash
jfr scrub --exclude-events jdk.SystemProcess,jdk.InitialEnvironmentVariable input.jfr output.jfr
```

Run this before you hand a production `.jfr` file to anyone (including an agent in the cloud) — environment variables, JVM args, and possibly hostnames are in there.

### 5.6 Chunks (`assemble` / `disassemble`)

`.jfr` files are streams of chunks. With continuous recording, you often want to extract individual chunks:

```bash
jfr disassemble --max-chunks 1 recording.jfr   # splits into single chunks
jfr assemble <directory> output.jfr            # reassembles them
```

Rarely needed in practice, but useful when the dump is 2 GB and you only want the time window around the incident.

---

## 6. Kotlin

Identical to Java. The Gradle Kotlin DSL (`build.gradle.kts`) is already shown above. The Spring Boot setup does not change — `FlightRecorderApplicationStartup` works the same way:

```kotlin
@SpringBootApplication
class Application

fun main(args: Array<String>) {
    runApplication<Application>(*args) {
        setApplicationStartup(FlightRecorderApplicationStartup())
    }
}
```

Coroutines appear in the JFR recording as frames in `kotlinx.coroutines.*` — stack traces are often fragmented because continuation resumes break JVM stack locality. For coroutine-specific debugging, prefer `-Dkotlinx.coroutines.debug` or the debugger agent.

**Custom events in Kotlin** (see chapter 4): no `data class`, no `val` fields. JFR needs mutable fields because it accesses them via bytecode manipulation.

```kotlin
package com.example.observability

import jdk.jfr.*

@Name("com.example.OrderProcessed")
@Label("Order Processed")
@Category("Application", "Orders")
class OrderProcessedEvent : Event() {
    @Label("Order ID")     var orderId: String = ""
    @Label("Amount Cents") var amountCents: Long = 0
}

// Usage
OrderProcessedEvent().apply {
    orderId = order.id
    amountCents = order.totalCents
    commit()
}
```

For duration events, an inline function makes an idiomatic wrapper:

```kotlin
inline fun <E : Event, R> E.recorded(block: (E) -> R): R {
    if (!isEnabled()) return block(this)
    begin()
    try { return block(this) } finally { commit() }
}

// Call site
PaymentProcessingEvent().recorded { event ->
    event.method = "card"
    paymentService.process(payment)
}
```

---

## 8. Tips for agent consumption

When a coding agent (Claude Code or similar) does the analysis:

1. **Never push `.jfr` straight into the context** — it is binary. Always go through the `jfr` CLI.
2. **Start with `jfr summary`** as a sanity check (size, events, time window). Few lines, cheap.
3. **Then use `jfr view <view>` with `--width`** for targeted sub-analyses. Output is tabular and tokenizes well. Set `--width 200` or higher, otherwise method names get truncated.
4. **Use `jfr print --json --events <concrete>`** only when `view` is not enough. First run `jfr metadata` to learn the event names.
5. **Bound recording size** before handing it to an agent:
   - `duration` 30–120 s for targeted profiling sessions.
   - `maxsize=100m` for continuous recording with a manageable footprint.
   - Pre-scrub via `jfr scrub`, then `jfr assemble --max-chunks 1`.
6. **Custom events have no `jfr view` support**. If you emit your own events (chapter 4), you need `jfr print --json --events ...` plus your own aggregation (typically via `jq`). Plan for that in your tool design.
7. **`RecordingStream` instead of a file round-trip**, when the agent should read along live. Saves disk I/O and lets you write JSON to stdout per event, which fits tool-output conventions perfectly (see 4.7).
8. **Agent tool wrapping**: when you build bash tools for an agent, expose:
   - `jfr_summary(path) -> str`
   - `jfr_view(view: str, path: str, width: int = 200) -> str`
   - `jfr_events_json(events: list[str], path: str) -> list[dict]` (with a hard cap on event count, otherwise it is a token bomb)

   Do not expose a generic "run jfr" function — the agent burns context on help flags.

---

## 9. Alternatives and complements

JFR is not always the right choice. When to use what:

| Tool | Strength | When better than JFR |
|---|---|---|
| **async-profiler** | Wall-clock + CPU + alloc + locks; correct native stacks via AsyncGetCallTrace + perf_events. | CPU profiling on Linux when you want to escape the notorious "JFR samples skewed by safepoint bias". Flame graphs out of the box. https://github.com/async-profiler/async-profiler |
| **perf / bpftrace** | Kernel-level, includes kernel stacks. | When the question is "is this the JVM or the kernel?". |
| **OpenTelemetry** | Distributed tracing across services. | Request-centric latency analysis. Complementary to JFR, not a replacement. |
| **Micrometer + Prometheus** | Aggregated metrics over time. | Trends, SLOs, alerting. JFR is point analysis, not trend. |
| **Spring Boot Actuator `/actuator/startup`** | Pure startup trace without JFR overhead. | When you care **only** about startup and nothing else. |
| **JITWatch** | JIT compiler behavior. | Understanding inlining decisions. |

Further reading:

- **JFR Event Reference**: https://docs.oracle.com/en/java/javase/21/docs/specs/man/jfr.html
- **Java Tool Reference (`jcmd`, `jfr`)**: https://docs.oracle.com/en/java/javase/21/docs/specs/man/index.html
- **Marcus Hirt's Blog** (JFR lead at Oracle): https://hirt.se/blog/ — the source for in-depth knowledge.
- **OpenJDK JFR Wiki**: https://wiki.openjdk.org/display/jmc/The+JMC+Project
- **Spring `ApplicationStartup` docs**: https://docs.spring.io/spring-framework/reference/core/beans/context-introduction.html#context-functionality-startup
- **async-profiler vs JFR discussion**: https://github.com/async-profiler/async-profiler/blob/master/docs/CompareWithJFR.md
- **Brendan Gregg, "Java in Flames"** (to understand safepoint bias): https://www.brendangregg.com/blog/2014-06-12/java-flame-graphs.html

---

## 10. Common pitfalls

- **`-XX:+UnlockCommercialFeatures`** is **no longer needed** on JDK 11+ and now causes an error. Old tutorials still show it.
- **Containers without `procfs` / PID-namespace isolation**: `jcmd` finds nothing. Fix: `shareProcessNamespace`, or set `JAVA_TOOL_OPTIONS` from the start.
- **`duration=` without a unit**: defaults to seconds, but explicit (`60s`, `5m`, `1h`) is more readable and less error-prone.
- **`profile.jfc` in production**: 2 % overhead sounds small, but under load and with low sampling intervals it is noticeable. Default is usually enough; switch to `profile` deliberately for diagnostic windows.
- **`stackdepth=64`** (default) is too shallow for Spring. Set 128 or 256.
- **Recording on tmpfs / `/tmp`**: long continuous recordings fill RAM. Mount on persistent storage, or the OOM killer will visit.
- **JFR and native / off-heap memory**: JFR sees the Java heap and TLABs very well; native memory (Netty direct buffers, mmap) only coarsely via `jdk.NativeMemoryUsage`. For DirectByteBuffer leaks, add `-XX:NativeMemoryTracking=summary` + `jcmd <PID> VM.native_memory`.
- **`@Name` without a package** in custom events: `@Name("OrderProcessed")` will collide with something eventually. Always fully qualify (`com.example.app.OrderProcessed`).
- **`String` fields in hot-path events**: every `event.foo = someString` may allocate a fresh reference, and JFR deduplicates strings in chunk constant pools — that is not free. If an event fires > 100k times/s, prefer enum ordinals or integer IDs.
- **`@StackTrace(true)` is the default** on custom events. For frequent events, set `@StackTrace(false)` explicitly, otherwise it eats most of the overhead.
- **Inner classes as events**: non-static inner classes (Kotlin: nested without `companion`; Java: `class X` inside `class Y`) hold an implicit outer reference. JFR works, but you leak lifetime. Always declare them top-level or `static`-nested.
- **Periodic events registered twice**: if you call `FlightRecorder.addPeriodicEvent` from a Spring `@PostConstruct` and the bean is created multiple times in tests (e.g. with `@DirtiesContext`), you get N parallel periodic hooks. Defensive fix: clean up in `@PreDestroy` via `FlightRecorder.removePeriodicEvent`.
