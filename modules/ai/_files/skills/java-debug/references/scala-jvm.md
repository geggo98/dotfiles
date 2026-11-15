# Scala-on-JVM Diagnostics

Scala compiles to JVM bytecode, so every tool that works for Java also works for Scala. The language idioms and the build tools differ, however. Async runtimes also split stacks in ways that change how you read profiles. Pekko is the Apache fork of the Akka actor toolkit. ZIO and Cats Effect are effect-system runtimes that run work as fibers: lightweight tasks that the runtime schedules itself and multiplexes onto a small thread pool, so many fibers share few OS threads. This reference covers what is different for Scala in JFR, OpenTelemetry, and JDB. It assumes that you have read the language-neutral guides [`references/jfr.md`](jfr.md), [`references/otel.md`](otel.md), and [`references/jdb.md`](jdb.md).

Paths that start with `references/` or `scripts/` are relative to the root of the `java-debug` skill, not to this file. For example, `scripts/jdb-attach.sh` is the file `java-debug/scripts/jdb-attach.sh`, and from this `references/` directory it is `../scripts/jdb-attach.sh`. Run the commands below from the skill root.

## Contents

- [1. Running with the modern `scala` runner (Scala 3.5.0+)](#1-running-with-the-modern-scala-runner-scala-350)
- [2. sbt and other build tools](#2-sbt-and-other-build-tools)
- [3. JFR (Java Flight Recorder) from Scala](#3-jfr-java-flight-recorder-from-scala)
- [4. OpenTelemetry spans from Scala](#4-opentelemetry-spans-from-scala)
- [5. JDB attach / step-debug for Scala](#5-jdb-attach--step-debug-for-scala)
- [6. Async runtime gotchas — Pekko/Akka, ZIO, Cats Effect](#6-async-runtime-gotchas--pekkoakka-zio-cats-effect)
- [7. References](#7-references)

## 1. Running with the modern `scala` runner (Scala 3.5.0+)

Since Scala 3.5.0 (released August 2024), the `scala` binary **is** Scala CLI. The historical `scala-cli` binary still exists as an alias to the same code, with identical flags and behavior. This change came with [SIP-46](https://docs.scala-lang.org/sips/scala-cli.html). See also the [`scala` command reference](https://scala-cli.virtuslab.org/docs/reference/scala-command/).

As a result, `scala Main.scala` no longer opens a REPL. It compiles and runs the file. All Scala CLI flags work directly: `--jvm` selects the JVM version, `--jvm-opt` passes an option to the JVM, `--java-prop` sets a system property, and `--dep` adds a library dependency. The same settings can also live in the source file as `//> using` directives (see "Embed JVM options in the source file" below). Older documentation that shows `scala-cli run …` therefore still applies word for word.

### Run a single-file program with JFR

```bash
scala --jvm-opt='-XX:StartFlightRecording=duration=60s,filename=rec.jfr,settings=profile' Main.scala
```

The `settings=profile` preset is a balanced default. For memory work, prefer `settings=default` plus `gc=detailed`. `gc=detailed` is an option of `-XX:StartFlightRecording` (JDK 17+) that turns on detailed GC events on top of the chosen settings file. `references/jfr.md` explains the two shipped settings files in the §1 table (row "Settings / `.jfc` file") and lists the common `-XX:StartFlightRecording` options in the §2.1 table. That table does not include `gc=`, so this paragraph is the only description of it.

### Run with the OpenTelemetry Java Agent

```bash
scala --jvm-opt="-javaagent:$(./scripts/otel-agent-download.sh)" \
      --java-prop=otel.service.name=my-scala-app \
      --java-prop=otel.traces.exporter=otlp \
      --java-prop=otel.exporter.otlp.endpoint=http://localhost:4317 \
      Main.scala
```

`--java-prop=K=V` becomes `-DK=V` on the JVM command line, and the OTel agent reads its configuration from system properties. Section 4 lists what the agent instruments in Scala code.

### Run under JDB

Launch the program with a JDWP listener, then attach:

```bash
scala --jvm-opt='-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005' Main.scala &
bash scripts/jdb-attach.sh --port 5005
```

`suspend=y` makes the JVM wait at startup until JDB connects, so you can step through `main` from its first line. Use `suspend=n` to attach to a long-lived process that is already running.

### Embed JVM options in the source file

`//> using` directives let a `.scala` file carry its JVM configuration. Collaborators and CI then get the same recording without remembering the flags:

```scala
//> using jvm 21
//> using javaOpt -XX:StartFlightRecording=duration=60s,filename=rec.jfr,settings=profile
//> using javaProp otel.service.name=my-scala-app

@main def run() = …
```

Each directive becomes a separate flag, and several `javaOpt` lines add up. This helps to reproduce a performance issue: commit the file with the JFR flag enabled, and everyone who runs `scala foo.scala` gets the recording.

## 2. sbt and other build tools

### sbt

sbt forks the JVM only when you ask it to. Without `fork := true`, sbt ignores `javaOptions` without a warning. This is the most common reason why a JFR flag "does nothing".

```scala
javaOptions ++= Seq(
  "-XX:StartFlightRecording=duration=60s,filename=target/sbt.jfr,settings=profile"
)
fork := true   // mandatory: without it, the flags do not reach the running JVM
```

For tests, the same trap applies to `Test / fork`. For `run`, set `run / fork := true` or the global `fork := true`. Verify the result with `sbt "show javaOptions"`, which prints exactly what sbt will pass.

### Mill

Mill, a Scala build tool, forks by default. Add JVM arguments with `def forkArgs` inside the module definition in the build file (`build.mill`, or `build.sc` in older Mill versions):

```scala
def forkArgs = Seq("-XX:StartFlightRecording=duration=60s,filename=out/mill.jfr,settings=profile")
```

For OTel, attach the agent the same way: `def forkArgs = Seq("-javaagent:/path/to/opentelemetry-javaagent.jar", "-Dotel.service.name=mill-app")`.

### Spring Boot in Scala

Scala services on Spring are rare, but they exist. They use the same flags as Java. On the command line, pass JVM arguments with `--jvmArgs=…` for Gradle `bootRun` and `-Dspring-boot.run.jvmArguments=…` for Maven `spring-boot:run`; `references/jdb.md` §3 shows both forms. To set them in the build file instead, see `references/jfr.md` §3.2.

## 3. JFR (Java Flight Recorder) from Scala

The concepts are in `references/jfr.md`: `settings=profile` versus `default`, periodic versus duration events, and CLI output that an agent can read. The sections below cover only what is different in Scala.

### Custom events: no `case class`, no `val` fields

JFR generates bytecode that writes to event fields through direct field access. Each field must therefore be a mutable JVM field that reflection can reach. That rules out:

- **`case class`**: its fields are `val` (final), and the compiler generates `copy`, `equals`, and `hashCode` methods that conflict with the bytecode that JFR generates. The result is runtime errors or events that stay empty without a warning.
- **`val` fields**: they are final, which causes the same problem.

Use a plain `class extends jdk.jfr.Event` with `var` fields. Annotations work as usual, with one exception. The Java annotation `@Category` declares `String[]`, so in Scala you must pass `Array(…)`:

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

In Scala 3, a small wrapper can mirror the Java `try-with-resources` pattern for duration events. The wrapper checks `isEnabled()` first: if the recording filters out the event type, the code skips `begin()` and `commit()` and does not pay for them.

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

The wrapper passes the event to `block`, so the caller can fill fields *inside* the timed region. This matters when the values to record (transaction id, retry count) exist only after the work is done.

### Helper scripts work unchanged

`.jfr` is a binary format that the JDK defines, and the format is the same whichever language produced the events. The helper scripts of this skill (`scripts/jfr-record.sh`, `scripts/jfr-summary.sh`, `scripts/jfr-view.sh`, and `scripts/jfr-events.sh`, described in `references/jfr.md` §2) therefore work the same way for recordings from Scala. Custom event types appear under their `@Name`. Query them with `jfr print --events com.example.OrderProcessed rec.jfr`.

## 4. OpenTelemetry spans from Scala

The OTel Java Agent works on bytecode, without source changes. Its auto-instrumentation (HTTP servers, JDBC drivers, HTTP clients, Kafka clients, JMS, gRPC, Redis) therefore also fires for Scala code that uses those libraries. This includes Scala wrappers such as sttp (HTTP client), Cask and the blaze backend of http4s (HTTP servers), and Quill (database access through JDBC). Skunk, a native PostgreSQL client, does not go through JDBC, so the JDBC instrumentation does not cover it.

Trace propagation across services works the same way. The agent passes the trace context in the W3C `traceparent` and `tracestate` HTTP headers, so a downstream service can attach its spans to the caller's trace. In `references/otel.md`, §5.1 describes this header chain, §4.5 covers baggage, and §2 (Variant A) and §3.4 configure the OTLP exporters.

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

The order matters. Open the scope **after** `startSpan()`, so that the span becomes the current context. Close the scope **before** `span.end()`, because the scope is thread-local state and the span holds the data. An auto-instrumented call inside the span, for example an HTTP call inside `doCharge`, becomes a child of the span only while the scope is active.

### `Using`-based helper

`scala.util.Using` removes the boilerplate, but it needs a `Releasable[Span]` typeclass instance. A span needs two actions on two different objects: close the scope and end the span. A clean `Using` wrapper therefore needs a small case class:

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

A plain `try/finally`, as in the first example, works equally well. Pick the form that your codebase prefers. The `Releasable` form fits well if the codebase already uses `Using` for resources elsewhere.

### Effect-system wrappers

The raw OTel API keeps the context in thread-locals (`Context.makeCurrent`). Fiber-based runtimes (ZIO and Cats Effect) move a fiber between threads without notice, so the context gets lost. Use the bridge libraries for these runtimes instead:

- **ZIO**: [`zio-opentelemetry`](https://github.com/zio/zio-telemetry) (the `zio-telemetry` repo). It provides a `Tracing` service and `ZIO`-aware span propagation that follows the fiber rather than the thread.
- **Cats Effect and the Typelevel stack** (the functional Scala libraries built on Cats, such as http4s, fs2, Doobie, and Skunk): [`otel4s`](https://github.com/typelevel/otel4s). It is a purely functional wrapper and integrates with `IO`, `Resource`, and `MonadCancel` (the Cats Effect typeclass for cancellable effects with guaranteed cleanup). The type encodes the span lifecycle, so you cannot forget `end()`.

Both libraries exchange context with the auto-instrumentation of the OTel Java Agent when you configure them to share the global tracer provider. Incoming HTTP spans from the agent then become the parents of the application spans in your effect types.

## 5. JDB attach / step-debug for Scala

JDB sees compiled Scala as it sees compiled Java: classes, methods, line numbers, and local variables. The full workflow (attach modes, breakpoint syntax, batch automation with `scripts/jdb-breakpoints.sh`) is in `references/jdb.md`. Scala adds two problems:

### Name mangling makes method names verbose

The Scala compiler generates `$anonfun$` methods for lambdas and pattern-match cases, `$$Lambda$` for SAM conversions (a lambda passed as a Java functional interface), and `Foo$.bar` for module (`object`) members. The JDB command `methods <class>` shows the real bytecode names. Run it before you guess a name:

```
methods com.example.Foo$
```

Then set the breakpoint on the verbose name:

```
stop in com.example.Foo$.bar$$anonfun$1
```

### Prefer line-number breakpoints over method-name breakpoints

A single `match` expression compiles into several synthetic methods, each with its own `$anonfun$N` suffix. A `for`-comprehension expands into nested `flatMap` and `map` lambdas, and each lambda is a separate method. When you step through this code with `next`, you can land in places that look unrelated to your source. The reason is that the compiler moved the body of a `case` into its own method.

Set breakpoints at line numbers instead. They stay stable, because the compiler keeps them accurate in the LineNumberTable attribute of the class file:

```
stop at com.example.MyClass:42
```

Make sure that the build emits debug info. Scala compiles with `-g:vars` (line numbers and local variables) by default. Do not strip this info: without it, `locals` in JDB reports "Local variable information not available" (see `references/jdb.md` §6). sbt and `scala` (Scala CLI) use this default. If you call `scalac` directly, verify that `-g:vars` is present.

## 6. Async runtime gotchas — Pekko/Akka, ZIO, Cats Effect

`references/jfr.md` §5.2 describes the predefined JFR views that `jfr view` prints, such as `hot-methods` and `thread-cpu-load`. In synchronous code, the JFR view `hot-methods` and a thread stack trace show the same picture. In async runtimes they differ. A dispatcher thread, that is, a worker thread of the runtime's thread pool, runs fibers or actor messages, so the methods at the top of the stack belong to the runtime, not to your application code.

### Pekko and Akka

Stacks show dispatcher threads named `pekko.actor.default-dispatcher-N` (or `akka.actor.default-dispatcher-N` for Akka). `jfr view thread-cpu-load rec.jfr` (the "CPU per thread" view) aggregates by thread and shows which dispatchers are busy. This helps with capacity planning, but it does not show what the dispatcher is busy with.

JFR does **not** record actor mailbox latency. A message that waits in the mailbox of a slow actor uses no CPU and produces no JFR event. To observe actors, use one of two kinds of instrumentation, both listed on the [Pekko observability page](https://pekko.apache.org/docs/pekko/current/typed/observability.html):

- a third-party instrumentation library in the style of Cinnamon, which is Lightbend Telemetry, the commercial instrumentation agent for Akka;
- the official OTel bridge from Pekko 1.1+, an integration that reports actor message processing to OpenTelemetry.

The OTel bridge produces one real span per processed message, which JFR cannot provide.

### ZIO

ZIO fibers move between dispatcher threads at every suspension point (`*>`, `flatMap`, `ZIO.yieldNow`, semantic blocking). The operator `*>` is ZIO's `zipRight`: it runs two effects in sequence and keeps the result of the second. Semantic blocking means that a fiber waits, for example on a `Promise`, a `Queue`, or `sleep`, without blocking an OS thread. A stack trace at any moment shows `FiberRuntime.runLoop` of the ZIO runtime on top and the application code several frames lower. The lower frames also change between samples, even while the same fiber is "running".

`hot-methods` therefore counts too many ZIO runtime methods. `FiberRuntime`, `ZIO$flatMap`, or `Cause` at the top of a profile are the runtime doing its normal work, not a bug.

### Cats Effect

Cats Effect fibers also move between threads. `IOFiber.resume`, `IOFiber.runLoop`, and the trampoline dominate the profiles. The trampoline is the part of the Cats Effect run loop that executes chained `IO` steps one after another in a loop instead of through recursive calls, so its frames appear where you would expect your own code. The `IO` code that you wrote is still in the stack, but not at the hot spot.

### Common advice for all three

Two things help much more than a raw JFR profile:

1. **OTel auto-instrumentation for entry points** (HTTP, databases, message brokers). The agent records spans around these calls, whichever fiber or actor handles them. You then see the latency of each request and where it comes from.
2. **Manual OTel spans for application logic**, through `zio-opentelemetry` or `otel4s`, so that the spans follow the fiber and not the thread. The resulting trace tree shows the *logical* flow of work, which a thread-based profile cannot show.

In async code, use JFR for what it still shows well: GC behavior, allocation hot spots, lock contention, and file and socket I/O. Use OTel for everything that crosses a fiber or actor boundary, because JFR follows threads, not fibers or actors.

## 7. References

- `references/jfr.md`: JFR concepts, recording lifecycle, CLI tools, and custom events, from the Java side.
- `references/otel.md`: OTel agent setup, OTLP exporters, and propagation across services.
- `references/jdb.md`: the JDB attach and launch workflow, breakpoint syntax, and batch automation.
- [SIP-46: Scala CLI as the default Scala runner](https://docs.scala-lang.org/sips/scala-cli.html): the proposal that made `scala` and `scala-cli` the same binary.
- [`scala` command reference](https://scala-cli.virtuslab.org/docs/reference/scala-command/): the complete flag list, including `--jvm-opt` and `--java-prop`. The `//> using` directives are covered in section 1 under "Embed JVM options in the source file".
- [`zio-opentelemetry`](https://github.com/zio/zio-telemetry): OTel for ZIO that follows fibers.
- [`otel4s`](https://github.com/typelevel/otel4s): OTel bindings for Typelevel and Cats Effect.
