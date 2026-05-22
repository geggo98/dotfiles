# Scala-on-JVM Diagnostics

Scala compiles to JVM bytecode, so every tool that works for Java works for Scala — but the language idioms differ, the build tools differ, and async runtimes (Pekko, ZIO, Cats Effect) fragment stacks in ways that change how you read profiles. This reference covers the Scala-specific deltas for JFR, OpenTelemetry, and JDB; it assumes you have read the language-neutral guides under `references/jfr.md`, `references/otel.md`, and `references/jdb.md`.

## Contents

- [1. Running with the modern `scala` runner (Scala 3.5.0+)](#1-running-with-the-modern-scala-runner-scala-350)
- [2. sbt and other build tools](#2-sbt-and-other-build-tools)
- [3. JFR (Java Flight Recorder) from Scala](#3-jfr-java-flight-recorder-from-scala)
- [4. OpenTelemetry spans from Scala](#4-opentelemetry-spans-from-scala)
- [5. JDB attach / step-debug for Scala](#5-jdb-attach--step-debug-for-scala)
- [6. Async runtime gotchas — Pekko/Akka, ZIO, Cats Effect](#6-async-runtime-gotchas--pekkoakka-zio-cats-effect)
- [7. References](#7-references)

## 1. Running with the modern `scala` runner (Scala 3.5.0+)

Since Scala 3.5.0 (released August 2024), the `scala` binary **is** Scala CLI — the historical `scala-cli` binary still exists as an alias to the same code, and both flags and behavior are identical. This is the result of [SIP-46](https://docs.scala-lang.org/sips/scala-cli.html). See also the [`scala` command reference](https://scala-cli.virtuslab.org/docs/reference/scala-command/).

Practically this means: `scala Main.scala` no longer drops you in a REPL — it compiles and runs the file. All Scala CLI flags (`--jvm`, `--jvm-opt`, `--java-prop`, `--dep`, `--using`) work directly. Older docs that suggest `scala-cli run …` still apply verbatim; you can read `scala-cli` as a synonym for `scala`.

### Run a single-file program with JFR

```bash
scala --jvm-opt='-XX:StartFlightRecording=duration=60s,filename=rec.jfr,settings=profile' Main.scala
```

The `settings=profile` preset is a balanced default; for memory work prefer `settings=default` plus `gc=detailed`. See `references/jfr.md` §2 for the full settings matrix.

### Run with the OpenTelemetry Java Agent

```bash
scala --jvm-opt="-javaagent:$(./scripts/otel-agent-download.sh)" \
      --java-prop=otel.service.name=my-scala-app \
      --java-prop=otel.traces.exporter=otlp \
      --java-prop=otel.exporter.otlp.endpoint=http://localhost:4317 \
      Main.scala
```

`--java-prop=K=V` becomes `-DK=V` on the JVM command line; the OTel agent reads its config from system properties. The agent is bytecode-level and instruments libraries (HTTP servers, JDBC, JMS, Kafka) without source changes — Scala wrappers around those libraries inherit the instrumentation for free.

### Run under JDB

Launch the program with a JDWP listener, then attach:

```bash
scala --jvm-opt='-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005' Main.scala &
bash scripts/jdb-attach.sh --port 5005
```

`suspend=y` makes the JVM wait at startup until JDB connects, which is what you want for stepping through `main`. Use `suspend=n` to attach to an already-running long-lived process.

### Embed JVM options in the source file

`//> using` directives let a `.scala` file carry its JVM configuration so collaborators (and CI) get the same recording without remembering the flags:

```scala
//> using jvm 21
//> using javaOpt -XX:StartFlightRecording=duration=60s,filename=rec.jfr,settings=profile
//> using javaProp otel.service.name=my-scala-app

@main def run() = …
```

Each directive becomes a separate flag — multiple `javaOpt` lines stack. Useful for reproducing a perf issue: commit the file with the JFR flag enabled, anyone running `scala foo.scala` gets the recording.

## 2. sbt and other build tools

### sbt

sbt forks the JVM only when you ask it to. Without `fork := true`, `javaOptions` are silently ignored — this is the most common reason "my JFR flag does nothing".

```scala
javaOptions ++= Seq(
  "-XX:StartFlightRecording=duration=60s,filename=target/sbt.jfr,settings=profile"
)
fork := true   // mandatory — otherwise the flags don't reach the running JVM
```

For tests, the same trap applies in `Test / fork`. For `run`, set `run / fork := true` or the global `fork := true`. Verify with `sbt "show javaOptions"` — sbt prints exactly what it will pass.

### Mill

Mill ships forking by default; add JVM args via `forkArgs`:

```scala
def forkArgs = Seq("-XX:StartFlightRecording=duration=60s,filename=out/mill.jfr,settings=profile")
```

For OTel attach the agent the same way: `def forkArgs = Seq("-javaagent:/path/to/opentelemetry-javaagent.jar", "-Dotel.service.name=mill-app")`.

### Spring Boot in Scala

Rare in practice, but it exists (Scala-on-Spring services). Identical flags to the Java path — see `references/jfr.md` §3 for `bootRun` JVM-arg syntax (`--jvmArgs=…` for Gradle, `-Dspring-boot.run.jvmArguments=…` for Maven).

## 3. JFR (Java Flight Recorder) from Scala

The conceptual material — `settings=profile` vs `default`, periodic vs duration events, agent-friendly CLI output — is in `references/jfr.md`. The deltas below are Scala-language specific.

### Custom events: no `case class`, no `val` fields

JFR generates bytecode that writes to event fields via direct field access. The field must be a JVM-level mutable field that can be reflected on. That rules out:

- **`case class`** — fields are `val` (final) and the compiler generates `copy`/`equals`/`hashCode` machinery that fights JFR's bytecode synthesis. You will get runtime errors or silently empty events.
- **`val` fields** — same final-field problem.

Use a plain `class extends jdk.jfr.Event` with `var` fields. Annotations apply normally; only watch the `@Category` signature: the Java annotation declares `String[]`, so in Scala you must pass `Array(…)`:

```scala
package com.example.observability

import jdk.jfr.*

@Name("com.example.OrderProcessed")
@Label("Order Processed")
@Category(Array("Application", "Orders"))
class OrderProcessedEvent extends Event:
  @Label("Order ID")     var orderId: String   = ""
  @Label("Amount Cents") var amountCents: Long = 0L

// Use site
val e = OrderProcessedEvent()
e.orderId     = order.id
e.amountCents = order.totalCents
e.commit()
```

### Idiomatic duration-event wrapper

Scala 3 makes it easy to write a small wrapper that mirrors the Java `try-with-resources` pattern for duration events. Note the `isEnabled()` guard — if the event type is filtered out, we should not pay the begin/commit cost.

```scala
def recorded[E <: Event, R](event: E)(block: E => R): R =
  if !event.isEnabled() then block(event)
  else
    event.begin()
    try block(event) finally event.commit()

// Call site
recorded(PaymentProcessingEvent()): event =>
  event.method = "card"
  paymentService.process(payment)
```

Why pass the event to `block`? So the caller can populate fields *while inside* the timed region — useful when the values you want to record (transaction id, retry count) only exist after the work happens.

### Helper scripts work unchanged

`.jfr` is a binary format defined by the JDK; it does not care which language produced the events. The agent scripts `scripts/jfr-record.sh`, `scripts/jfr-summary.sh`, `scripts/jfr-view.sh`, and `scripts/jfr-events.sh` work identically for Scala-produced recordings. Custom event types appear under their `@Name`, queryable as `jfr print --events com.example.OrderProcessed rec.jfr`.

## 4. OpenTelemetry spans from Scala

The OTel Java Agent operates at the bytecode level, so all auto-instrumentation (HTTP servers, JDBC drivers, HTTP clients, Kafka clients, JMS, gRPC, Redis) fires for Scala code that uses those libraries — including Scala wrappers like sttp, Cask, http4s' blaze backend, Quill, or Skunk-via-JDBC. Cross-service trace propagation works identically; see `references/otel.md` for the W3C `traceparent` header chain and exporter configuration.

### Manual spans, idiomatic Scala 3

```scala
import io.opentelemetry.api.GlobalOpenTelemetry
import io.opentelemetry.api.trace.{Span, SpanKind, StatusCode}

val tracer = GlobalOpenTelemetry.getTracer("com.example.payment", "1.0.0")

def charge(customerId: String, amount: BigDecimal): PaymentResult =
  val span = tracer.spanBuilder("payment.charge")
    .setSpanKind(SpanKind.INTERNAL)
    .setAttribute("customer.id", customerId)
    .setAttribute("amount", amount.doubleValue)
    .startSpan()
  val scope = span.makeCurrent()
  try
    val result = doCharge(customerId, amount)
    span.setAttribute("payment.transaction_id", result.txId)
    result
  catch case e: Exception =>
    span.recordException(e)
    span.setStatus(StatusCode.ERROR, e.getMessage)
    throw e
  finally
    scope.close()
    span.end()
```

Order matters: open the scope **after** `startSpan()` so the span becomes the current context, and close it **before** `span.end()` (the scope is a thread-local thing; the span is the data). Auto-instrumentation hanging off this span (e.g. an HTTP call inside `doCharge`) will become a child only while the scope is active.

### `Using`-based helper

`scala.util.Using` cleans up the boilerplate, but it needs a `Releasable[Span]` typeclass instance. Spans need both scope-close and span-end, which is two actions on two different objects, so a clean `Using` wrapper takes a tiny case class:

```scala
import scala.util.Using
import io.opentelemetry.api.trace.Span
import io.opentelemetry.context.Scope

final case class TracedSpan(span: Span, scope: Scope)

given Using.Releasable[TracedSpan] with
  def release(t: TracedSpan): Unit =
    try t.scope.close() finally t.span.end()

def traced[R](name: String)(block: Span => R): R =
  val span = tracer.spanBuilder(name).startSpan()
  Using.resource(TracedSpan(span, span.makeCurrent())) { t =>
    try block(t.span)
    catch case e: Throwable =>
      t.span.recordException(e)
      t.span.setStatus(StatusCode.ERROR, e.getMessage)
      throw e
  }
```

Using a plain `try/finally` (as in the first example) is equally fine; pick whichever your codebase prefers. The `Releasable` shape composes well if you already use `Using` for resource management elsewhere.

### Effect-system wrappers

The raw OTel API uses thread-locals (`Context.makeCurrent`), which breaks under fiber-based runtimes that hop threads transparently. Use the language-level bridge libraries:

- **ZIO** — [`zio-opentelemetry`](https://github.com/zio/zio-telemetry) (the `zio-telemetry` repo). Provides `Tracing` service and `ZIO`-aware span propagation that follows fiber semantics rather than threads.
- **Cats Effect / Typelevel stack** — [`otel4s`](https://github.com/typelevel/otel4s). Pure functional wrapper; integrates with `IO`, `Resource`, and `MonadCancel`. Span lifecycle is encoded in the type so you cannot forget to `end()`.

Both libraries cross-propagate with the OTel Java Agent's auto-instrumentation when configured to share the global tracer provider — incoming HTTP spans from the agent become parents of your effect-typed application spans.

Cross-service tracing (W3C trace context, baggage, OTLP exporter setup) works identically from Scala — see `references/otel.md`.

## 5. JDB attach / step-debug for Scala

JDB sees compiled Scala as it sees compiled Java: classes, methods, line numbers, locals. The full workflow (attach modes, breakpoint syntax, batch automation via `scripts/jdb-breakpoints.sh`) is in `references/jdb.md`. Two Scala-specific friction points:

### Name mangling makes method names verbose

Scala's compiler synthesizes `$anonfun$` methods for lambdas and pattern-match cases, `$$Lambda$` for SAM conversions, and `Foo$.bar` for module (`object`) members. JDB's `methods <class>` command shows the real bytecode names — use it before you guess:

```
methods com.example.Foo$
```

Then set the breakpoint on the verbose name:

```
stop in com.example.Foo$.bar$$anonfun$1
```

Stable line-number breakpoints are usually less painful than method-name breakpoints — see next point.

### Prefer line-number breakpoints over method-name breakpoints

A single `match` expression compiles into multiple synthetic methods, each with its own `$anonfun$N` suffix. A `for`-comprehension expands into nested `flatMap`/`map` lambdas, each a separate method. Stepping `next` through this code can land in places that look unrelated to your source until you realize the compiler hoisted the body of a `case` into its own method.

Solution: set breakpoints at line numbers, which the compiler preserves accurately in the LineNumberTable attribute:

```
stop at com.example.MyClass:42
```

Make sure the build emits debug info — Scala compiles with `-g:vars` (line numbers + locals) by default; do not strip it. For sbt this is the default; for `scala`/Scala CLI it is the default; for `scalac` directly, verify `-g:vars` is present.

## 6. Async runtime gotchas — Pekko/Akka, ZIO, Cats Effect

In synchronous code, a JFR `hot-methods` view and a thread stack trace tell the same story. In async runtimes they diverge — the dispatcher thread is busy running fibers or actor messages, and the methods at the top of the stack are runtime plumbing, not your application code.

### Pekko and Akka

Stacks show dispatcher threads named `pekko.actor.default-dispatcher-N` (or `akka.actor.default-dispatcher-N` for the older fork). `jfr view thread-cpu-load rec.jfr` aggregates by thread and surfaces dispatcher hotspots — useful for capacity planning, but it tells you the dispatcher is busy, not what it is busy doing.

Actor mailbox latency is **not** in JFR. A message sitting in a slow actor's mailbox burns no CPU and produces no JFR event. For actor-level observability use [Pekko Telemetry](https://pekko.apache.org/docs/pekko/current/typed/observability.html) (the Cinnamon-style libraries, or the official OTel bridge from Pekko 1.1+). The OTel bridge produces real spans per message processed, which is what you want.

### ZIO

ZIO fibers hop between dispatcher threads on every suspension point (`*>`, `flatMap`, `ZIO.yieldNow`, semantic blocking). A stack trace captured at any instant shows the ZIO runtime's `FiberRuntime.runLoop` on top with the application code several frames down — and the frames below shift between samples even when the same fiber is "running".

`hot-methods` therefore over-counts ZIO runtime methods. Don't be alarmed by `FiberRuntime`, `ZIO$flatMap`, or `Cause` at the top of a profile — that is the engine, not a bug.

### Cats Effect

Same fiber-hopping behavior. Profiles are dominated by `IOFiber.resume`, `IOFiber.runLoop`, and the trampoline. The user-land `IO` you actually wrote is reachable through the stack but no longer at the hot spot.

### Common advice for all three

Two things help much more than reading a raw JFR profile:

1. **OTel auto-instrumentation for entry points** (HTTP, DB, message brokers). The agent captures spans around the boundary calls regardless of which fiber/actor handles them, giving you actionable latency attribution per request.
2. **Manual OTel spans for application logic**, via `zio-opentelemetry` or `otel4s` so the spans follow the fiber, not the thread. The resulting trace tree describes the *logical* flow of work — exactly what you cannot reconstruct from a thread-based profile.

Use JFR for what it is still good at in async code: GC behavior, allocation hot spots, lock contention, file/socket I/O. Use OTel for everything that crosses a fiber/actor boundary.

## 7. References

- `references/jfr.md` — JFR concepts, recording lifecycle, CLI tools, custom events (Java POV).
- `references/otel.md` — OTel agent setup, OTLP exporters, cross-service propagation.
- `references/jdb.md` — JDB attach/launch workflow, breakpoint syntax, batch automation.
- [SIP-46: Scala CLI as the default Scala runner](https://docs.scala-lang.org/sips/scala-cli.html) — the proposal that made `scala` and `scala-cli` the same binary.
- [`scala` command reference](https://scala-cli.virtuslab.org/docs/reference/scala-command/) — exhaustive flag list including `--jvm-opt`, `--java-prop`, `--using` directives.
- [`zio-opentelemetry`](https://github.com/zio/zio-telemetry) — fiber-aware OTel for ZIO.
- [`otel4s`](https://github.com/typelevel/otel4s) — Typelevel/Cats Effect OTel bindings.
