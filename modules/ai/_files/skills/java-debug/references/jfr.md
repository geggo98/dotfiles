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
- [7. Tips for agent consumption](#7-tips-for-agent-consumption)
- [8. Alternatives and complements](#8-alternatives-and-complements)
- [9. Common pitfalls](#9-common-pitfalls)
- [10. Pitfalls measured in containers and on network file systems](#10-pitfalls-measured-in-containers-and-on-network-file-systems)

---

## 1. Core concepts (read this first)

| Term | Meaning |
|---|---|
| **JFR** | Java Flight Recorder. Event recorder built into the JDK. Open-sourced into OpenJDK since JDK 11 (previously commercial in Oracle JDK). |
| **Event** | Structured data point with timestamp, thread, stack trace, and custom fields. Examples: `jdk.GarbageCollection`, `jdk.CPULoad`, `jdk.ObjectAllocationInNewTLAB`. |
| **TLAB** | Thread-local allocation buffer. A small part of the heap that belongs to one thread, so the thread can allocate objects without locking. JFR records allocations per TLAB (`jdk.ObjectAllocationInNewTLAB`) instead of per object, which keeps the overhead low. |
| **Repository** | The directory where a disk recording writes its chunk files while it runs. Set it with `-XX:FlightRecorderOptions=repository=<dir>`. Default: a new directory below `java.io.tmpdir` (see `disk=true` in §2.1 and §10). |
| **Chunk** | A self-contained segment of a recording, with its own metadata and constant pools. A JFR constant pool is the per-chunk table in which JFR stores each distinct string, class or stack trace once; events refer to it by ID. It is not the constant pool of a class file. JFR closes the current chunk and starts a new one when it reaches a size or time limit. The files in the repository are chunks, and a `.jfr` file is a sequence of chunks. |
| **Recording** | Time window during which events are collected. Output: a `.jfr` file (binary, chunk-based). |
| **Settings / `.jfc` file** | XML configuration controlling which events are recorded at which threshold. Shipped configs: `default.jfc` (~1 % overhead) and `profile.jfc` (~2 %). Path: `$JAVA_HOME/lib/jfr/`. |
| **`jcmd`** | Diagnostic tool in the JDK. Talks to running JVMs via the attach mechanism. |
| **`jfr` CLI** | Standalone tool for analyzing `.jfr` files without the JMC GUI. Present as `bin/jfr` in Temurin 11, 17, 21 and 25, and `jfr summary` works on all four (measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 21.0.13, 25.0.5, in a container; first release not verified). Since JDK 21 it offers `jfr view` for predefined reports. |
| **JMC** | JDK Mission Control, the GUI for analysis. Agents use `../scripts/jfr-rules-report.sh` (in the `java-debug` skill root) for its rule-based report (see [jmc.md](jmc.md)). |
| **Spring `ApplicationStartup`** | Spring Framework API (5.3+) for tracking startup phases. The `FlightRecorderApplicationStartup` implementation emits steps as JFR events. Not the same as general JFR profiling. |

"JFR tracing" and "application profiling" cover two distinct use cases:

- **Continuous (black-box) recording**: a recording with `maxage` or `maxsize` runs all the time, and you dump it on demand when something happens. It uses the default settings and is safe for production.
- **Targeted profiling**: you start a bounded recording (for example 60 s) under load, dump it, and analyze it. It uses the profile settings, which cost more overhead and give more data.

---

## 2. Quick start

Helper scripts in the `java-debug` skill wrap the common workflows. The `scripts/` paths below are relative to the skill root, not to this `references/` directory: from here, `scripts/jfr-record.sh` is `../scripts/jfr-record.sh`. Prefer them over hand-written `jcmd` and `jfr` calls, because they set the output width and the event-count cap that keep the output small enough for an agent's context (see §7):

- `scripts/jfr-record.sh` starts a JFR recording on a running JVM (it wraps `jcmd JFR.start`, `JFR.dump` and `JFR.stop`).
- `scripts/jfr-summary.sh <recording.jfr>` runs `jfr summary` for a quick sanity check.
- `scripts/jfr-view.sh <view-name> <recording.jfr>` runs `jfr view --width 200 …`.
- `scripts/jfr-events.sh <event-pattern> <recording.jfr>` runs `jfr print --json --events …` with an event-count cap that keeps the output token-sized.

### 2.1 Recording at JVM startup

```bash
java \
  -XX:StartFlightRecording=duration=60s,filename=app.jfr,settings=profile \
  -jar app.jar
```

Important options (comma-separated after `=`):

| Option | Effect |
|---|---|
| `name=myRec` | Name of the recording. Required if you want to address the recording later through `jcmd`. |
| `duration=60s` | The recording stops automatically. Omit it for an unbounded recording. Always write the unit, because without it the JVM does not start (see §9). Without `filename=`, Temurin 21 and 25 announce `hotspot-pid-<pid>-id-1-<ts>.jfr` in the working directory as the target (seen 2026-11-15, in a container; not checked on 11 and 17). |
| `filename=...` | Where the file is written. |
| `settings=default\|profile\|/path/to/custom.jfc` | The settings profile. |
| `maxage=1h` | Maximum age of the ring buffer (only with `disk=true`). |
| `maxsize=200M` | Maximum size of the ring buffer. |
| `disk=true` | Streams chunks to disk continuously instead of holding them in RAM only. This is the default since JDK 11: a recording without `disk=`, from `-XX:StartFlightRecording` or from `jcmd JFR.start`, writes chunks to the repository and, when you set no limit, gets `maxsize=250MB` (`No limit specified, using maxsize=250MB as default`). The default repository is `<java.io.tmpdir>/<yyyy_mm_dd_hh_mm_ss>_<pid>/`. `JFR.check verbose` never prints `disk=`; only `maxsize=250.0MB` hints at it. Measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 21.0.13, 25.0.5, in a container. |
| `dumponexit=true` | Dumps automatically on JVM shutdown. |

Idiomatic continuous recording in production:

```bash
-XX:StartFlightRecording=settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true,filename=/var/log/app/recording.jfr
```

This keeps the last hour available while `maxage` and `maxsize` cap the disk use, and a crash leaves a dump automatically.

### 2.2 Recording on a running JVM

```bash
# 1. Find the PID
jcmd -l            # lists all JVMs on this host
# or
pgrep -f 'app.jar'

# 2. Start a recording
jcmd <PID> JFR.start name=adhoc settings=profile duration=120s filename=/tmp/adhoc.jfr

# 3. Check status. Not a passive query: in a JVM without a recording, JFR.check starts
#    the JFR subsystem (JFR threads, ~15 MB native memory). Measured 2026-11-15 on
#    Temurin 17, 21, 25, in a container; JetBrains Runtime not measured. Avoid it on
#    JetBrains Runtime (see §10, item 7).
jcmd <PID> JFR.check

# 4. Dump a snapshot (recording continues)
jcmd <PID> JFR.dump name=adhoc filename=/tmp/snapshot.jfr

# 5. Stop
jcmd <PID> JFR.stop name=adhoc filename=/tmp/final.jfr
```

Watch the syntax, because the two forms are easy to mix up: `jcmd` parameters are **space-separated**, while `-XX:StartFlightRecording=` parameters are **comma-separated**.

If `jcmd` reports "Unable to open socket file", it runs as a different user than the JVM, or in a different container namespace. In Kubernetes you need the same PID namespace (`shareProcessNamespace: true` on the pod, or an ephemeral debug container started with `kubectl debug --target=<container>`, which joins the PID namespace of that container), or `kubectl exec` as the JVM's user.

---

## 3. Spring Boot — idiomatic

### 3.1 `FlightRecorderApplicationStartup` for startup phases

This **adds to** a regular JFR recording and does not replace it: Spring then emits additional JFR events of type `spring.startup` for every bean, every auto-configuration, every context initialization.

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

To capture the startup, enable the recording **at JVM startup** (see 2.1), because a recording started later through `jcmd` misses the startup phase.

An alternative without JFR is `BufferingApplicationStartup` plus the Actuator endpoint `/actuator/startup`, which returns JSON. It is lightweight and a good choice when you care **only** about startup.

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

The **deployed artifact** (container, systemd unit and so on) does not start through Gradle, so the Gradle settings above do not reach it. Set `JAVA_TOOL_OPTIONS` or pass JVM args directly in your deployment manifest:

```yaml
# Kubernetes example
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-XX:StartFlightRecording=settings=default,disk=true,maxage=1h,maxsize=500m,dumponexit=true,filename=/tmp/recording.jfr"
```

`stackdepth=128` matters because Spring stacks are deep. The default is 64 (measured 2026-11-15 on Temurin 11, 17, 21, 25, in a container: `jcmd <PID> JFR.configure` without arguments prints `Stack depth: 64`, and recorded stacks are cut at 64 frames). With truncated stacks, `jfr view hot-methods` produces useless aggregates. The deeper stacks cost some overhead, but the trade-off is usually worth it.

---

## 4. Defining custom events and spans

### 4.1 Up front: JFR has no spans

JFR only knows **events**. It has no hierarchical spans, which has two consequences:

- **Duration events** (with `begin()` and `end()`) work like spans, but they are **flat**. They have no parent-child relation, no implicit trace IDs and no context propagation across threads.
- If you want real nested spans, build them yourself with fields (`traceId`, `parentSpanId`, your own stack management based on a `ThreadLocal`). The cleaner split is to use **OpenTelemetry** for spans and JFR for deep profiling inside the JVM.

JFR custom events are still the right choice for these cases:

- High-frequency operations inside the JVM with a measurable overhead budget (less than 1 µs per event is achievable when done right).
- Domain-specific events that you want to correlate with GC, allocation or CPU data in the same recording. This is the main advantage of JFR over OTel.
- Audit-style records you want to keep running as a ring buffer in production.

### 4.2 Instant event (Java)

```java
package com.example.observability;

import jdk.jfr.*;

@Name("com.example.OrderProcessed")
@Label("Order Processed")
@Category({"Application", "Orders"})
@Description("An order was processed successfully")
@StackTrace(false)   // stacks cost overhead; the default is true, and the stack is often unnecessary
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
| `@Name` | Unique name of the event type. **Fully qualify** it (`com.example.X`), otherwise it collides with `jdk.*` events. |
| `@Label` | Human-readable label for JMC and `jfr view`. |
| `@Category` | Hierarchy for grouping in the GUI. Use an array for multiple levels. |
| `@Description` | Longer explanation. |
| `@StackTrace(false)` | Disables stack sampling. This saves significant overhead on frequent events. |
| `@Threshold("10 ms")` | Only events at or above the threshold are committed (only meaningful on duration events). |
| `@Enabled(false)` | Disables the event class by default. Enable it later through the settings or the recording API. |
| `@Period("1 s")` | For periodic events (see 4.5). |

Allowed field types: `boolean`, `byte`, `short`, `int`, `long`, `float`, `double`, `char`, `String`, `Class`, `Thread`. Collections and custom objects are **not** allowed. If you need a complex value, serialize it to a `String` first. Do this sparingly, because string allocations are expensive.

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

`commit()` does three things in one call:

1. It calls `end()` if that was not called yet, which sets `endTime`.
2. It checks the threshold through `shouldCommit()`.
3. If the event passes, it writes the event to the recording.

### 4.4 Hot-path optimization

For frequent events, an explicit guard pays off, because it skips the field population when no recording runs or the event type is disabled:

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

This matters from about 10k events/s. At a few events per second it is a micro-optimization that makes the code harder to read.

### 4.5 Periodic events

Use periodic events to sample your own metrics at regular intervals (for example the cache size):

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

Custom events are **enabled by default** as long as a recording is running and the event is not explicitly disabled. The settings files (`default.jfc`, `profile.jfc`) can still configure filters, thresholds and stack sampling per event type. Without a JFC entry, the annotations on the class apply.

**Configure programmatically** (for example in tests or through Spring configuration):

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

Since JDK 14 you can read events in the same process, **without a file round-trip**. This is useful for an agent, because you can stream custom events directly as JSON to stdout, a socket or a REST endpoint.

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

You can also stream from a **live file** (`EventStream.openFile(path)`) or from a **remote JVM** through JMX and `FlightRecorderMXBean`. The remote variant is fit for production and lets an agent monitor live without a sidecar.

### 4.8 Spring Boot integration

Spring has no specific API for custom JFR events, so you use plain Java events. Three patterns work:

- **Instrument service methods manually** (see 4.3). This works and is explicit, with no hidden behavior.
- **Spring AOP / `@Aspect`** for method-level tracing (all `@Service` methods, etc.). `ServiceCallEvent` is a duration event built like the one in 4.3, with two `String` fields:
  ```java
  @Name("com.example.ServiceCall")
  @Label("Service Call")
  @Category({"Application", "Services"})
  @StackTrace(false)
  public class ServiceCallEvent extends Event {
      @Label("Class")  String className;
      @Label("Method") String methodName;
  }
  ```
  The aspect:
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
  AOP based on reflection has its own overhead. Measure whether that is acceptable on the hot path.
- **Spring `ApplicationStartup` API** for your own startup steps. If you have `FlightRecorderApplicationStartup` active (see chapter 3), you can emit your own steps:
  ```java
  var step = applicationStartup.start("my.custom.warmup");
  step.tag("cache", "products");
  // ... work ...
  step.end();
  ```
  These land as `spring.startup` events in the recording. They need no event class, but they only cover the startup phase.

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

For agents, write a small wrapper function `jfr_custom_events(pattern, path)` with a hard event-count cap (`.recording.events[0:1000]` in `jq`). Without the cap, the output of a busy recording overflows the context window.

---

## 5. CLI analysis with `jfr`

This part matters most for agents. The tool ships with the JDK (`$JAVA_HOME/bin/jfr`). The helper scripts listed in §2 wrap the most common calls; prefer them, because they set the width and the event-count cap for you.

### 5.1 Get an overview

```bash
jfr summary recording.jfr
```

This returns the event count per type, the recording duration and the chunks. It answers the first question: what is in the file at all?

```bash
jfr metadata recording.jfr
```

This lists every event type in the file with its fields, so you know what you can filter on.

### 5.2 Predefined views (JDK 21+) — **most important for agents**

`jfr view` renders prebuilt reports as ASCII tables. The output is stable and deterministic, and agents can parse it.

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
| `exception-count` / `exception-by-type` | Exceptions thrown. Shows code that uses exceptions for control flow. |
| `file-io` / `socket-io` | Blocking I/O calls above the threshold. Useful to find latency. |
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

JSON output is **large**. Always filter with `--events`, otherwise it overruns any context window. `jdk.ExecutionSample` (CPU sampling) alone easily produces more than 100k events per minute.

XML also works (`--xml`), but it is rarely useful.

### 5.5 Strip sensitive data

```bash
jfr scrub --exclude-events jdk.SystemProcess,jdk.InitialEnvironmentVariable input.jfr output.jfr
```

Run this before you hand a production `.jfr` file to anyone, including an agent in the cloud, because the file contains environment variables, JVM arguments and possibly hostnames.

### 5.6 Chunks (`assemble` / `disassemble`)

A `.jfr` file is a stream of chunks. With continuous recording, you often want to extract individual chunks:

```bash
jfr disassemble --max-chunks 1 recording.jfr   # splits into single chunks
jfr assemble <directory> output.jfr            # reassembles them
```

You rarely need this in practice. It helps when the dump is 2 GB and you only want the time window around the incident.

---

## 6. Kotlin

Kotlin works the same as Java. Section 3.2 already shows the Gradle Kotlin DSL (`build.gradle.kts`). The Spring Boot setup does not change, and `FlightRecorderApplicationStartup` works the same way:

```kotlin
@SpringBootApplication
class Application

fun main(args: Array<String>) {
    runApplication<Application>(*args) {
        setApplicationStartup(FlightRecorderApplicationStartup())
    }
}
```

Coroutines appear in the JFR recording as frames in `kotlinx.coroutines.*`. Their stack traces are often fragmented, because a resumed continuation does not continue the JVM stack it started on. To debug coroutines, prefer `-Dkotlinx.coroutines.debug`, which adds coroutine names and IDs to thread names, or the coroutine debug agent from the `kotlinx-coroutines-debug` library. Start it with `-javaagent:kotlinx-coroutines-debug-<version>.jar` or `DebugProbes.install()`; `DebugProbes.dumpCoroutines()` then prints every live coroutine with its creation stack.

**Custom events in Kotlin** (see chapter 4): do not use a `data class` or `val` fields. JFR needs mutable fields, because it accesses them through bytecode manipulation.

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

For duration events, an inline function is an idiomatic wrapper:

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

## 7. Tips for agent consumption

When a coding agent (Claude Code or similar) does the analysis:

1. **Never put a `.jfr` file straight into the context**, because it is binary. Always go through the `jfr` CLI.
2. **Start with `jfr summary`** as a sanity check (size, events, time window). Its output is a few lines and cheap.
3. **Then use `jfr view <view>` with `--width`** for targeted analyses. The output is tabular and tokenizes well. Set `--width 200` or higher, otherwise method names get truncated.
4. **Use `jfr print --json --events <concrete>`** only when `view` is not enough, because JSON output is large (see 5.4). First run `jfr metadata` to learn the event names.
5. **Bound the recording size** before you hand it to an agent, so that the output fits the context:
   - `duration` 30–120 s for targeted profiling sessions.
   - `maxsize=100m` for continuous recording with a manageable footprint.
   - Scrub first with `jfr scrub`, then `jfr assemble --max-chunks 1`.
6. **Custom events have no `jfr view` support**. If you emit your own events (chapter 4), you need `jfr print --json --events ...` plus your own aggregation, typically with `jq`. Plan for that in your tool design.
7. **Use `RecordingStream` instead of a file round-trip** when the agent should read along live. It saves disk I/O and lets you write JSON to stdout for each event, so the agent reads one JSON object per line (see 4.7).
8. **Agent tool wrapping**: when you build bash tools for an agent, expose these functions:
   - `jfr_summary(path) -> str`
   - `jfr_view(view: str, path: str, width: int = 200) -> str`
   - `jfr_events_json(events: list[str], path: str) -> list[dict]` (with a hard cap on the event count, otherwise its output floods the context)

   Do not expose a generic "run jfr" function, because the agent then spends context on reading help output.

---

## 8. Alternatives and complements

For some questions another tool fits better than JFR:

| Tool | Strength | When better than JFR |
|---|---|---|
| **async-profiler** | Wall-clock + CPU + alloc + locks; correct native stacks via AsyncGetCallTrace (an internal HotSpot API that samples a Java stack without waiting for a safepoint) + perf_events (the Linux kernel interface for performance counters and sampling). | CPU profiling on Linux when you want to avoid JFR samples that safepoint bias skews. A safepoint is a point at which every Java thread is stopped in a known state; threads check for it at poll instructions in compiled code (loop back-edges and method returns). Safepoint bias: a sampler that can take a stack only at a JVM safepoint over-reports the code next to safepoint polls and under-reports hot code between them (Brendan Gregg's "Java in Flames" under "Further reading" below explains it). It produces flame graphs out of the box. https://github.com/async-profiler/async-profiler |
| **perf / bpftrace** | Kernel-level, includes kernel stacks. | When the question is "is this the JVM or the kernel?". |
| **OpenTelemetry** | Distributed tracing across services. | Request-centric latency analysis. Complementary to JFR, not a replacement. |
| **Micrometer + Prometheus** | Aggregated metrics over time. | Trends, SLOs, alerting. JFR is point analysis, not trend. |
| **Spring Boot Actuator `/actuator/startup`** | Pure startup trace without JFR overhead. | When you care **only** about startup and nothing else. |
| **JITWatch** | JIT compiler behavior; reads the JIT compilation log that the JVM writes with `-XX:+LogCompilation`. | Understanding inlining decisions. https://github.com/AdoptOpenJDK/jitwatch |

Further reading:

- **JFR Event Reference**: https://docs.oracle.com/en/java/javase/21/docs/specs/man/jfr.html
- **Java Tool Reference (`jcmd`, `jfr`)**: https://docs.oracle.com/en/java/javase/21/docs/specs/man/index.html
- **Marcus Hirt's Blog** (JFR lead at Oracle), the source for in-depth knowledge: https://hirt.se/blog/
- **OpenJDK JFR Wiki**: https://wiki.openjdk.org/display/jmc/The+JMC+Project
- **Spring `ApplicationStartup` docs**: https://docs.spring.io/spring-framework/reference/core/beans/context-introduction.html#context-functionality-startup
- **async-profiler vs JFR discussion**: https://github.com/async-profiler/async-profiler/blob/master/docs/CompareWithJFR.md
- **Brendan Gregg, "Java in Flames"** (to understand safepoint bias): https://www.brendangregg.com/blog/2014-06-12/java-flame-graphs.html

---

## 9. Common pitfalls

- **`-XX:+UnlockCommercialFeatures`** is **no longer needed** on JDK 11+ and now causes an error on OpenJDK builds: `Unrecognized VM option`, and the JVM does not start (exit 1). Measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 21.0.13, 25.0.5, in a container. Old tutorials still show it.
- **Containers without `procfs`, or with PID-namespace isolation**: `jcmd` finds no JVM. Fix: set `shareProcessNamespace`, or set `JAVA_TOOL_OPTIONS` from the start so that the recording needs no `jcmd`.
- **`duration=` without a unit**: the JVM does not start (`Integer parsing error nanotime value: unit required`, exit 1; measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 21.0.13, 25.0.5, in a container, and seen earlier on JDK 11.0.27). Always write the unit (`60s`, `5m`, `1h`).
- **`profile.jfc` in production**: 2 % overhead sounds small, but under load and with short sampling intervals it is noticeable. The default settings are usually enough. Switch to `profile` deliberately for a diagnostic window.
- **`stackdepth=64`** (the default) is too shallow for Spring. Set 128 or 256, because truncated stacks make `jfr view hot-methods` aggregates useless (see 3.2).
- **Recording on tmpfs or `/tmp`**: without `-XX:FlightRecorderOptions=repository=<dir>`, the chunks of every disk recording go to `java.io.tmpdir` (usually `/tmp`; measured 2026-11-15, see `disk=true` in §2.1). On tmpfs, long continuous recordings fill RAM, and then the OOM killer can end the process. Put the repository on persistent storage.
- **JFR and native or off-heap memory**: JFR sees the Java heap and TLABs very well, but native memory (Netty direct buffers, mmap) only coarsely through `jdk.NativeMemoryUsage`. For DirectByteBuffer leaks, add `-XX:NativeMemoryTracking=summary` and `jcmd <PID> VM.native_memory`.
- **`@Name` without a package** in custom events: `@Name("OrderProcessed")` will collide with another event type eventually. Always fully qualify the name (`com.example.app.OrderProcessed`).
- **`String` fields in hot-path events**: every `event.foo = someString` may allocate a fresh reference, and JFR deduplicates strings in the constant pools of each chunk, which costs time (constant pool: see the Chunk row in §1). If an event fires more than 100k times/s, prefer enum ordinals or integer IDs.
- **`@StackTrace(true)` is the default** on custom events. For frequent events, set `@StackTrace(false)` explicitly, because the stack trace otherwise causes most of the overhead.
- **Inner classes as events**: non-static inner classes (Kotlin: nested without `companion`; Java: `class X` inside `class Y`) hold an implicit reference to the outer object. JFR works, but the outer object then lives as long as the event. Always declare event classes top-level or `static`-nested.
- **Periodic events registered twice**: if you call `FlightRecorder.addPeriodicEvent` from a Spring `@PostConstruct` and the bean is created several times in tests (for example with `@DirtiesContext`), you get N parallel periodic hooks. Defensive fix: remove the hook in `@PreDestroy` with `FlightRecorder.removePeriodicEvent`.

---

## 10. Pitfalls measured in containers and on network file systems

These pitfalls apply in every environment, not only in containers.

1. **JFR repository on a file system that can go stale kills the JVM.** JFR keeps a write handle on the current chunk in its repository. When the file system invalidates that handle, the next write gets `ESTALE`. HotSpot handles only `ENOSPC` for a chunk write; any other error ends in `guarantee(successful_write)` and the JVM aborts with SIGABRT (exit code 134). The OpenJDK bug [JDK-8307579](https://bugs.openjdk.org/browse/JDK-8307579) ("The return values of the os::write in jfrStreamWriterHost.inline.hpp … should be handled more robustly") is closed as "Won't Fix". The crash shows up at the first I/O after the handle went stale, for example right after a debugger pause. Measured on container bind paths of OrbStack Kubernetes (date not recorded). OrbStack is a container and VM runtime for macOS with a built-in single-node Kubernetes cluster; its container paths and why they go stale are described in the `jvm-remote-debug` skill, file [orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md). Expected on any network file system (NFS, SMB, FUSE mounts), but not measured there. **Fix:** keep the repository on a local disk with `-XX:FlightRecorderOptions=repository=/local/path`, and do the same for the `filename=` of `dumponexit`.

2. **Chunks are created with mode 0644, and you cannot change that.** A recording holds stack traces, method arguments, system properties and the environment, so other users must not read it. Protect it with a parent directory of mode 0700. Before you `chmod` that directory, check that it is not a symlink and that the JVM user owns it. Otherwise you change the mode of someone else's directory. When you hand a recording over or copy it to a shared volume, copy it with mode 0600.

3. **JFR flags do not override each other the way you expect.**
   - `-XX:StartFlightRecording` cannot be overridden: every mention adds one more recording. A second mention in `JAVA_TOOL_OPTIONS` and on the command line gives two recordings.
   - `-XX:FlightRecorderOptions=repository=` is last-wins.
   - `-XX:-FlightRecorder` only took effect on the real command line, not through `JAVA_TOOL_OPTIONS` (observed; date, JDK version and environment not recorded, so treat it as unverified).

4. **`dumponexit=true` creates the target file empty at startup.** So an empty file does not mean that the recording failed. Emergency dumps land in the JVM's working directory, not next to `filename=`. Newer JDKs can redirect them with `-XX:FlightRecorderOptions:dumppath=<dir>`. Measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 21.0.13, 25.0.5, in a container:
   - JDK 21 and 25 accept it at startup (exit 0). After `jcmd <PID> JFR.configure dumppath=<dir>` and a forced OOM crash, the emergency `hs_err_pid*.jfr` really landed there (the `hs_err_pid*.log` stays in the working directory). The directory must exist, or the JVM does not start. `jcmd <PID> JFR.configure` without arguments shows the current `Dump path:`.
   - JDK 11 and 17 reject it at startup with `Unknown argument 'dumppath'` (exit 1). At runtime it is worse, because the failure is silent: `jcmd <PID> JFR.configure dumppath=<dir>` is accepted and echoes `Dump path: <dir>`, but does nothing. The dump still goes to the working directory.
   - JDK 18 to 20 not tested.

5. **JDK 25: the active chunk has no `.part` suffix** (observed; date, exact JDK build and environment not recorded, so treat it as unverified). To find the chunk that is still being written, use the newest modification time, not the file name.

6. **`jfr view` needs a `jfr` binary from JDK 21 or newer.** The `jfr` of JDK 11 and 17 has no `view`: `jfr: unknown command 'view'`, exit 2 (measured 2026-11-15 on Temurin 11.0.33, 17.0.21, 21.0.13, 25.0.5, in a container). Exit 0 alone does not prove a result: on a recording without matching events, `jfr view gc` prints only `No events found for 'Garbage Collections'` and still exits 0. Find a matching JDK: on macOS `$(/usr/libexec/java_home -v 21+)/bin/jfr` (or plain `$(/usr/libexec/java_home)/bin/jfr` when the default JDK is new enough), elsewhere `readlink -f "$(command -v java)"` shows the JDK directory behind `java`. **Output size:** an unfiltered `jfr print` of an 11 MB recording produced 137 MB of text. For that reason, always filter with `--events`, or redirect the output to a file and read only parts of it. Never read such output into an agent's context.

7. **On JetBrains Runtime a running recording turns off enhanced class redefinition.** While any recording runs, `-XX:+AllowEnhancedClassRedefinition` is off and structural hot swaps fail. For that reason, do not record JFR in a JVM that you hot-swap. The `spring-boot-repl` skill explains both terms: [jbr-hotswap-install.md](../../spring-boot-repl/references/jbr-hotswap-install.md#why-jbr) says what JetBrains Runtime and enhanced class redefinition are, and [redefine.md](../../spring-boot-repl/references/redefine.md#a-jfr-turns-off-enhanced-redefinition-on-jbr) describes this pitfall and how to check for it. Even `jcmd <PID> JFR.check` starts the JFR subsystem (see §2.2). Whether that alone turns off enhanced redefinition on JetBrains Runtime was not measured. Avoid `JFR.check` there, because it might.
