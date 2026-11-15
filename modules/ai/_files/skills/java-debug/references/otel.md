# Local Tracing with the OpenTelemetry Java Agent

This reference shows two ways to see the traces of a Java application locally, without a commercial backend and without a cloud service:

1. **Directly from the Java Agent** to console or file.
2. **Through the OpenTelemetry Collector**, provisioned declaratively via Nix.

## Table of Contents

- [§1 Core Concepts](#1-core-concepts)
- [§2 Variant A — Direct from the Java Agent](#2-variant-a--direct-from-the-java-agent)
- [§3 Variant B — OpenTelemetry Collector via Nix](#3-variant-b--opentelemetry-collector-via-nix)
- [§4 Creating Custom Spans](#4-creating-custom-spans)
- [§5 Cross-Service Tracing — End-to-End Example](#5-cross-service-tracing--end-to-end-example)
- [§6 Comparison](#6-comparison)
- [§7 Alternative Tools](#7-alternative-tools)
- [§8 Further Reading](#8-further-reading)

---

## §1 Core Concepts

- **OpenTelemetry (OTel)**: a vendor-neutral standard for telemetry (traces, metrics, and logs). This reference covers only traces.
- **Span**: an instrumented operation with a start, an end, attributes, and a parent-child relationship. Spans that share a `traceId` form a **trace**.
- **Java Agent**: the OTel javaagent JAR. The JVM loads it at startup through `-javaagent`, and it uses the Java Instrumentation API to rewrite the bytecode of known libraries. Source: [`opentelemetry-java-instrumentation`](https://github.com/open-telemetry/opentelemetry-java-instrumentation).
- **Auto-instrumentation**: the spans that the agent produces without a code change. It works only for [supported libraries](https://github.com/open-telemetry/opentelemetry-java-instrumentation/blob/main/docs/supported-libraries.md) (JDBC, Hibernate, Servlet/Spring MVC, Reactor Netty, Apache HttpClient, OkHttp, Lettuce, Jedis, Kafka, gRPC, …).
- **Resource**: the set of attributes that describes the process that sends the telemetry, for example `service.name`, the host, and the container. All spans from that process share it.
- **Exporter**: a component in the OTel SDK that sends spans to a destination. The exporters for local debugging are `console`, `logging-otlp`, and `otlp`.
- **OTLP**: the OpenTelemetry Protocol, over gRPC or HTTP/Protobuf. It is the standard wire format between the app or agent and the collector.
- **Collector**: a separate process that receives telemetry through receivers, runs it through processors, and forwards it through exporters. It has two official distributions: **core** (minimal) and **contrib** (all community components).
- **fileexporter**: the collector exporter that writes spans as OTLP JSON Lines to a file. Only the **contrib** distribution contains it.

### What auto-instrumentation does **not** give you

Auto-instrumentation does not produce a full method-level trace. The agent creates spans only at points with a defined meaning: an inbound or outbound HTTP request, a database query, a cache operation, or a message that is published or consumed. Tracing therefore cannot show which method called which method. For that question, use a **profiler** such as [async-profiler](https://github.com/async-profiler/async-profiler) or Java Flight Recorder (JFR, `-XX:StartFlightRecording`), not tracing.

---

## §2 Variant A — Direct from the Java Agent

This variant needs no extra process. The output goes either to stdout or, through the logging framework of the app, to a file.

### §2.1 Get the agent

The helper script downloads the latest agent JAR, or a pinned version, and prints the path of the JAR:

```bash
AGENT_JAR=$(./scripts/otel-agent-download.sh)
```

See [`scripts/otel-agent-download.sh`](../scripts/otel-agent-download.sh) for details and for its caching behavior.

### §2.2 Console exporter (quick & dirty)

```bash
OTEL_SERVICE_NAME=my-app \
OTEL_TRACES_EXPORTER=console \
OTEL_METRICS_EXPORTER=none \
OTEL_LOGS_EXPORTER=none \
java -javaagent:$(./scripts/otel-agent-download.sh) -jar app.jar 2>&1 | tee trace.log
```

- `OTEL_TRACES_EXPORTER=console` writes one human-readable entry per span to stdout.
- The old name `logging` is an alias and is deprecated.
- `tee` shows the output live and also saves it to `trace.log`.
- The output is **unstructured text** that a program cannot parse. That is enough for one-off debugging.

### §2.3 OTLP JSON to a file via `logging-otlp` + Logback

The `logging-otlp` exporter writes **OTLP-compliant JSON** through SLF4J. Route it through Logback into a dedicated file, separate from the application logs, so that every line in the file is JSON that `jq` can read.

```bash
OTEL_SERVICE_NAME=my-app \
OTEL_TRACES_EXPORTER=logging-otlp \
OTEL_METRICS_EXPORTER=none \
OTEL_LOGS_EXPORTER=none \
java -javaagent:$(./scripts/otel-agent-download.sh) -jar app.jar
```

`logback.xml` (or `logback-spring.xml`):

```xml
<configuration>
  <!-- Console appender for the application logs. If your existing config already defines STDOUT, keep that one. -->
  <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <pattern>%d{HH:mm:ss.SSS} %-5level %logger{36} - %msg%n</pattern>
    </encoder>
  </appender>

  <appender name="OTEL_FILE" class="ch.qos.logback.core.FileAppender">
    <file>traces.jsonl</file>
    <encoder>
      <!-- Only the JSON message, no timestamp prefix -->
      <pattern>%msg%n</pattern>
    </encoder>
  </appender>

  <logger name="io.opentelemetry.exporter.logging.otlp" level="INFO" additivity="false">
    <appender-ref ref="OTEL_FILE"/>
  </logger>

  <root level="INFO">
    <appender-ref ref="STDOUT"/>
  </root>
</configuration>
```

The result is `traces.jsonl` with one JSON line per batch (NDJSON style). You can filter it with `jq`. The format is the same as the output of the collector's `fileexporter`, but **no** collector runs.

> **With other logging frameworks**: For Log4j2 or `java.util.logging`, configure the same routing in that framework. The exporter logs through SLF4J, so this setup works wherever SLF4J is wired in.

### §2.4 Important configuration switches

```bash
# SQL statements as span attribute (default: values are sanitized)
-Dotel.instrumentation.jdbc.statement-sanitizer.enabled=true
-Dotel.instrumentation.jdbc.experimental.capture-query-parameters=false

# Redis command args (caution: keys/values may be sensitive)
-Dotel.instrumentation.lettuce.experimental-span-attributes=true

# 100% sampling for local debugging, so that no trace is dropped
-Dotel.traces.sampler=always_on

# Agent debug output when instrumentation does not take effect
-Dotel.javaagent.debug=true
```

References: [Agent Configuration](https://opentelemetry.io/docs/zero-code/java/agent/configuration/), [SDK Environment Variables](https://opentelemetry.io/docs/languages/sdk-configuration/general/).

---

## §3 Variant B — OpenTelemetry Collector via Nix

The collector is a separate process between the app and the sink. It is useful in these cases:

- Multiple backends must be fed in parallel (file *and* Tempo *and* Jaeger). [Grafana Tempo](https://grafana.com/oss/tempo/) and [Jaeger](https://www.jaegertracing.io/) are open-source backends that store traces and show them in a UI.
- Processors are needed in between (sampling, attribute filters, batching, removal of personally identifiable information; see [§4.7](#47-practical-notes)).
- Resource detection should be added automatically: the collector processor [`resourcedetection`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourcedetectionprocessor) adds host, container, or Kubernetes attributes to the resource of each span.
- The app config should stay stable and variation happens only on the collector side.

If you only want to write spans to a file, the collector is more than the job needs. Use [§2.3](#23-otlp-json-to-a-file-via-logging-otlp--logback) instead. It writes the same OTLP JSON Lines format without an extra process.

### §3.1 Packages in nixpkgs

nixpkgs is the Nix package collection. The "Attribute" column holds the package name, as you use it in `pkgs.<name>` or `nixpkgs#<name>`.

| Attribute | Binary | Contents |
|---|---|---|
| `opentelemetry-collector` | `otelcol` | Core distribution. **No fileexporter.** |
| `opentelemetry-collector-contrib` | `otelcol-contrib` | Contrib distribution with all community components. |
| `opentelemetry-collector-builder` | `ocb` | OpenTelemetry Collector Builder (OCB), for your own minimal distributions. |

You need **contrib** for the fileexporter.

### §3.2 Ad-hoc

The helper script wraps the collector and starts it with a default file-exporter config:

```bash
./scripts/otel-collector-up.sh --output traces.jsonl
```

The script runs `otelcol-contrib` from nixpkgs and writes OTLP JSON Lines to the path that you pass. See [`scripts/otel-collector-up.sh`](../scripts/otel-collector-up.sh) for its flags.

To run the collector by hand instead:

```bash
nix shell nixpkgs#opentelemetry-collector-contrib
otelcol-contrib --config config.yaml
```

Or:

```bash
nix run nixpkgs#opentelemetry-collector-contrib -- --config config.yaml
```

Both commands work on NixOS and on nix-darwin.

### §3.3 Collector configuration

`config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

exporters:
  file:
    path: ./traces.jsonl
    format: json          # default; alternatively "proto"
    rotation:
      max_megabytes: 100
      max_days: 7
      max_backups: 5
      localtime: true
    flush_interval: 1s    # default; relevant for tail -f

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [file]
  telemetry:
    logs:
      level: warn
```

Docs: [fileexporter README](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/fileexporter).

### §3.4 Switch the app to OTLP

```bash
OTEL_SERVICE_NAME=my-app \
OTEL_TRACES_EXPORTER=otlp \
OTEL_METRICS_EXPORTER=none \
OTEL_LOGS_EXPORTER=none \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
java -javaagent:$(./scripts/otel-agent-download.sh) -jar app.jar
```

### §3.5 devenv module

[devenv](https://devenv.sh/) is a Nix-based tool that declares a development environment per project, including services that run beside the code. For details, see the `devenv` skill ([`../../devenv/SKILL.md`](../../devenv/SKILL.md)), if you have it.

Use the devenv module for local development in one project:

```nix
# devenv.nix
{ pkgs, ... }: {
  services.opentelemetry-collector = {
    enable = true;
    package = pkgs.opentelemetry-collector-contrib;
    settings = {
      receivers.otlp.protocols = {
        grpc.endpoint = "127.0.0.1:4317";
        http.endpoint = "127.0.0.1:4318";
      };
      exporters.file = {
        path = "./traces.jsonl";
        rotation = {
          max_megabytes = 100;
          max_backups = 5;
        };
      };
      service.pipelines.traces = {
        receivers = [ "otlp" ];
        exporters = [ "file" ];
      };
    };
  };
}
```

`devenv up` starts the collector as a process, and `devenv down` stops it. Source: [devenv otel-collector module](https://github.com/cachix/devenv/blob/main/src/modules/services/opentelemetry-collector.nix).

### §3.6 NixOS module

Use the NixOS module to run the collector permanently:

```nix
services.opentelemetry-collector = {
  enable = true;
  package = pkgs.opentelemetry-collector-contrib;
  validateConfigFile = true;   # invokes otelcol validate during the Nix build
  settings = {
    receivers.otlp.protocols.grpc.endpoint = "0.0.0.0:4317";
    exporters.file.path = "/var/lib/otelcol/traces.jsonl";
    service.pipelines.traces = {
      receivers = [ "otlp" ];
      exporters = [ "file" ];
    };
  };
};
```

- `settings` is a Nix attrset that the module serializes to YAML. An attrset (attribute set) is a key-value map, like a JSON object.
- `validateConfigFile = true` (the default) stops the build if the config is invalid.
- The service runs under a dynamic systemd user (`DynamicUser=yes`). systemd creates this user when the service starts, so the output path must be in a directory that the module creates, such as the `StateDirectory` under `/var/lib` (here `/var/lib/otelcol`).

Source: [nixos/modules/services/monitoring/opentelemetry-collector.nix](https://github.com/nixos/nixpkgs/blob/master/nixos/modules/services/monitoring/opentelemetry-collector.nix).

### §3.7 nix-darwin

[nix-darwin](https://github.com/nix-darwin/nix-darwin) is the Nix module system for the system configuration of macOS. [home-manager](https://github.com/nix-community/home-manager) manages the configuration of one user with Nix. Neither nix-darwin nor home-manager has an equivalent service module. On macOS, three options remain:

1. Add `home.packages = [ pkgs.opentelemetry-collector-contrib ]` and start the collector when you need it. `home.packages` is a [home-manager option](https://nix-community.github.io/home-manager/options.xhtml).
2. Run the collector permanently through `launchd.user.agents.<name>` with `ProgramArguments`. `launchd.user.agents.<name>` is a [nix-darwin option](https://nix-darwin.github.io/nix-darwin/manual/) that creates a launchd user agent, which is a per-user background job on macOS. `ProgramArguments` is the launchd job key that holds the command line, here the `otelcol-contrib` binary and `--config <file>`.
3. Use devenv per project (see §3.5).

### §3.8 Minimal custom distribution via OCB

The contrib binary is several hundred MB and contains many components that one pipeline does not use. There are two ways to build a smaller collector:

- Natively, with `pkgs.opentelemetry-collector-builder` and a manifest YAML.
- In idiomatic Nix, with the flake [`FriendsOfOpenTelemetry/opentelemetry-nix`](https://github.com/FriendsOfOpenTelemetry/opentelemetry-nix). It provides the function `mkOtelCollectorBuilderConfiguration`. You declare the components as a Nix attrset, and the result is a reproducible custom build.

```nix
packages.minimal-otelcol = pkgs.mkOtelCollectorBuilderConfiguration {
  pname = "otelcol-fileonly";
  version = "0.1.0";
  config = {
    receivers = [{
      gomod = "go.opentelemetry.io/collector/receiver/otlpreceiver v0.117.0";
    }];
    exporters = [{
      gomod = "github.com/open-telemetry/opentelemetry-collector-contrib/exporter/fileexporter v0.117.0";
    }];
  };
  vendorHash = "...";
};
```

`vendorHash` is the hash of the Go module dependencies. Nix needs it to fetch them. To get the value, build once with a fake hash (for example `pkgs.lib.fakeHash`) and copy the correct hash from the error message.

For debug tracing alone, a custom build is more than the job needs. It pays off for production collector deployments that need a defined, small footprint.

### §3.9 Output format and pitfalls

`traces.jsonl` contains OTLP `ExportTraceServiceRequest` JSON, with one line per batch:

```json
{"resourceSpans":[{"resource":{"attributes":[...]},"scopeSpans":[{"scope":{...},"spans":[{"traceId":"...","spanId":"...","name":"GET /endpoint",...}]}]}]}
```

**Pitfall 1, batching latency**: with `flush_interval: 1s`, spans reach the file up to one second late. If the app exits fast and the collector does not stop cleanly, the last batch can be lost.

**Pitfall 2, resource context**: the `resource` object (`service.name`, the host, and other attributes) appears **once** per batch. It applies to all spans in the same `resourceSpans` block. A naive `.spans[]` extraction loses that context.

The helper [`scripts/otel-spans-extract.sh`](../scripts/otel-spans-extract.sh) keeps the resource context for each span, so use it instead of a plain extraction:

```bash
./scripts/otel-spans-extract.sh traces.jsonl
```

The equivalent raw `jq` pipeline shows what the script does:

```bash
tail -f traces.jsonl | jq -c '
  .resourceSpans[] as $rs
  | $rs.scopeSpans[].spans[]
  | {
      service: ($rs.resource.attributes[] | select(.key=="service.name") | .value.stringValue),
      name,
      traceId,
      durationMs: ((.endTimeUnixNano | tonumber) - (.startTimeUnixNano | tonumber)) / 1000000
    }
'
```

---

## §4 Creating Custom Spans

Auto-instrumentation covers only known libraries, so business logic, custom calculations, and custom workflows produce no spans. There are four ways to add spans for them. They are independent of the choice between Variant A and Variant B, because they control how spans are **created**, not how they are exported.

### §4.1 Preconditions

Each of the three scenarios has different requirements:

| Scenario | What you need |
|---|---|
| **With Java Agent** | Nothing extra for annotations or API calls. The agent supplies `GlobalOpenTelemetry`, the process-wide `OpenTelemetry` instance of the OTel API from which code gets a `Tracer` (see [§4.4](#44-path-c--programmatic-via-the-otel-api)). |
| **Without agent, with OTel annotation** | This does not work, because the annotation is a no-op without the agent. |
| **Without agent, wired manually** | Initialize the OTel SDK in code. This needs more boilerplate but gives full control over the exporter. |

This section assumes the **agent scenario**.

### §4.2 Path A — Declarative via `methods.include` (no code touch)

This path needs no code change, only a system property or an environment variable:

```bash
-Dotel.instrumentation.methods.include="\
com.example.service.OrderService[place,refund];\
com.example.repo.UserRepository[findById]"
```

The syntax is `package.Class[method1,method2];other.Class[method3]`. Method wildcards are officially not supported.

Use this path to debug code that you did not write or cannot change, to trace third-party code, and for quick experiments. The spans carry no attributes and record no exceptions. Each span has only a start, an end, and the method name.

### §4.3 Path B — `@WithSpan` annotation

`@WithSpan` is the idiomatic way for your own code. Add the dependency:

```kotlin
// Gradle Kotlin DSL
implementation("io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations:2.10.0")
```

Annotate the methods:

```java
import io.opentelemetry.instrumentation.annotations.WithSpan;
import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.api.trace.SpanKind;

public class OrderService {

    @WithSpan                                        // span name = Class#method
    public Order place(Order order) { ... }

    @WithSpan(value = "order.refund",                // explicit name
              kind = SpanKind.INTERNAL)
    public void refund(@SpanAttribute("order.id") String orderId,
                       @SpanAttribute("amount") BigDecimal amount) {
        // orderId and amount are recorded automatically as span attributes
    }
}
```

**What happens**: at class load time, the agent finds the annotation, wraps the method in a span, and propagates the trace context. Without an active agent, the annotation is a no-op: no spans, no exceptions, and no performance cost.

**Async methods** (`CompletableFuture`, Reactor `Mono`/`Flux`, Kotlin coroutines): the agent handles them. The span ends only when the `CompletableFuture` completes or the publisher signals completion, not when the method call returns.

**What you cannot do** with the annotation alone:
- set the span status to `ERROR` without throwing an exception
- add events to the span
- add attributes that do not come from method parameters

For that you need Path C or D.

### §4.4 Path C — Programmatic via the OTel API

The OTel API gives full control. Add the dependency:

```kotlin
implementation("io.opentelemetry:opentelemetry-api:1.43.0")
```

Get a tracer and build the span by hand:

```java
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;

public class PaymentService {

    // Tracer is thread-safe; cache once per class or component
    private static final Tracer TRACER =
        GlobalOpenTelemetry.getTracer("com.example.payment", "1.0.0");

    public PaymentResult charge(String customerId, BigDecimal amount) {
        Span span = TRACER.spanBuilder("payment.charge")
                .setSpanKind(SpanKind.INTERNAL)
                .setAttribute("customer.id", customerId)
                .setAttribute("amount", amount.doubleValue())
                .startSpan();

        try (Scope scope = span.makeCurrent()) {       // context propagation
            PaymentResult result = doCharge(customerId, amount);
            span.setAttribute("payment.transaction_id", result.txId());
            return result;
        } catch (Exception e) {
            span.recordException(e);                    // stack trace as event
            span.setStatus(StatusCode.ERROR, e.getMessage());
            throw e;
        } finally {
            span.end();                                 // mandatory — not inside try
        }
    }
}
```

**Critical points**:

1. **`makeCurrent()` and `Scope`**: without `makeCurrent()`, the span exists but is not the current context. Follow-up spans, for example auto-instrumented outbound HTTP calls, do not find it as their parent and become root spans. The trace then falls apart into separate traces.
2. **`Scope` and `Span.end()` always in `finally`**: try-with-resources closes the `Scope`, but **not** the span. End the span explicitly. Otherwise the span leaks and is never exported.
3. **Tracer name**: by convention, it is the fully qualified module name (`com.example.payment`). It appears as `scope.name` in the OTLP data, so you can filter on it. The instrumentation scope is the tracer (or library) that created the span. In the OTLP JSON it is the `scope` object inside each `scopeSpans` entry (see the sample in [§3.9](#39-output-format-and-pitfalls)).

#### Adding attributes and events to an existing span

Inside an auto-instrumented method (for example, a Spring controller handler), get the current span:

```java
import io.opentelemetry.api.trace.Span;

Span current = Span.current();                          // returns INVALID span if none active
current.setAttribute("user.tier", "premium");
current.addEvent("cache.miss", Attributes.of(
    AttributeKey.stringKey("cache.key"), key));
```

`Span.current()` is safe. When no span is active, it returns a no-op span and does not throw a `NullPointerException`.

#### Nested spans (parent-child)

A new span automatically becomes a child of the span in the current context:

```java
Span outer = TRACER.spanBuilder("import.run").startSpan();
try (Scope s1 = outer.makeCurrent()) {

    Span inner = TRACER.spanBuilder("import.parse").startSpan();
    try (Scope s2 = inner.makeCurrent()) {
        parse();
    } finally {
        inner.end();
    }

    // another child span, automatically under outer
    TRACER.spanBuilder("import.persist").startSpan().end();

} finally {
    outer.end();
}
```

### §4.5 Path D — Baggage for cross-cutting attributes

When the same attribute must appear on **every** span of a trace (for example, `tenant.id` or `correlation.id`), use **Baggage** instead of adding the attribute to each span by hand. Baggage propagates automatically across thread and service boundaries, provided that the agent has W3C Baggage propagation enabled. That is the default.

```java
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;

Context ctx = Context.current().with(
    Baggage.current().toBuilder()
        .put("tenant.id", tenantId)
        .build());

try (Scope scope = ctx.makeCurrent()) {
    // all downstream spans in this scope have access to the baggage
    doWork();
}
```

Baggage does **not** automatically become a span attribute. To copy Baggage entries into span attributes, enable the agent's `BaggageSpanProcessor`. This span processor is part of the agent, so you install nothing extra. The following system property switches it on:

```bash
-Dotel.java.experimental.span-attributes.copy-from-baggage.include=tenant.id,correlation.id
```

Alternatively, project the entries in the collector with the `transform` processor. This processor changes telemetry with statements in the OpenTelemetry Transformation Language (OTTL), for example to set a span attribute from another value. See the [`transform` processor README](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor).

### §4.6 Comparison of the four paths

| Path | Code change | Attributes | Events / exceptions | Async-capable | When to use |
|---|---|---|---|---|---|
| A: `methods.include` | no | no | no | yes (agent) | Foreign code, quick debug |
| B: `@WithSpan` | minimal | via `@SpanAttribute` | no | yes | Own code, default case |
| C: Programmatic | medium | full | full | manual (propagate context) | Business logic with status/errors |
| D: Baggage | minimal | cross-cutting | n/a | yes | Cross-cutting concerns |

### §4.7 Practical notes

- **Keep span names low-cardinality**. `GET /orders/{id}` is good. `GET /orders/42` is bad, because a name with an ID inflates the backend indexes. Put the ID in an attribute, not in the name.
- **Attribute conventions**: use the names from the [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/), for example `http.request.method`, `db.system`, and `messaging.system`. Do not invent your own schema if a standard name exists.
- **Sensitive data** (personal data, secrets, cardholder data) must never become a span attribute, because the exporters write every attribute to the file or the backend. To remove such data in the collector, add an `attributes` processor with `delete` or `hash`, or a `redaction` processor. The [`attributes` processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/attributesprocessor) inserts, updates, deletes, or hashes named span attributes. The [`redaction` processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/redactionprocessor) deletes every attribute that is not on an allow list and masks values that match blocked patterns.
- **Performance**: spans are cheap but not free. In hot loops (millions of iterations), do **not** create a span per iteration. Wrap the loop in a single span with a counter attribute instead.
- **Manual spans and sampling**: if a sampler decides `RECORD_ONLY`, the span records its data inside the process but is not sampled. The code still sets the attributes, but no exporter receives the span. Nothing fails, and the span stays invisible.

---

## §5 Cross-Service Tracing — End-to-End Example

### §5.1 What changes for cross-service?

The OTel Java Agent automatically propagates W3C TraceContext through the HTTP headers `traceparent` and `tracestate`, and W3C Baggage through the `baggage` header. The libraries that the agent knows need no code changes: Spring WebClient, RestTemplate, OkHttp, Apache HttpClient, gRPC, Reactor Netty, Kafka, RabbitMQ, and JDBC. The caller injects the context into outbound calls, and the callee extracts it from inbound calls. Both sides need only the `-javaagent:…` flag.

The resulting trace has spans from **both** services under the same `traceId`. The callee's server span carries a `parentSpanId` that points to the caller's client span, so the chain can be rebuilt end to end. Any OTLP-compatible backend (Jaeger, Tempo, Honeycomb, otel-desktop-viewer) can render the waterfall directly. [Honeycomb](https://www.honeycomb.io/) is a hosted observability service. Jaeger and Tempo are described in [§3](#3-variant-b--opentelemetry-collector-via-nix), and otel-desktop-viewer in [§7](#7-alternative-tools). Locally, you need no UI: the fileexporter and `jq` are enough to verify and analyze the topology.

### §5.2 Runnable 2-service Spring Boot example

The example has two minimal Spring Boot services. Service A calls Service B over HTTP. Both services start with the OTel Java agent and export OTLP to the same collector. The collector writes everything to one `traces.jsonl`.

#### Service A (caller)

`service-a/build.gradle.kts`:

```kotlin
plugins {
    java
    id("org.springframework.boot") version "3.3.4"
    id("io.spring.dependency-management") version "1.1.6"
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-webflux") // WebClient
}
```

`service-a/src/main/java/com/example/a/HelloController.java`:

```java
package com.example.a;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.reactive.function.client.WebClient;

@RestController
public class HelloController {

    private final WebClient client = WebClient.builder()
            .baseUrl("http://localhost:8082")
            .build();

    @GetMapping("/a/hello")
    public String hello() throws InterruptedException {
        // small business-logic pause so the parent-child duration is visible
        Thread.sleep(20);
        String downstream = client.get()
                .uri("/b/work")
                .retrieve()
                .bodyToMono(String.class)
                .block();
        return "service-a says: " + downstream;
    }
}
```

#### Service B (callee)

`service-b/build.gradle.kts`:

```kotlin
plugins {
    java
    id("org.springframework.boot") version "3.3.4"
    id("io.spring.dependency-management") version "1.1.6"
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jdbc")
    runtimeOnly("com.h2database:h2") // optional: shows JDBC auto-instrumentation
}
```

`service-b/src/main/java/com/example/b/WorkController.java`:

```java
package com.example.b;

import io.opentelemetry.instrumentation.annotations.WithSpan;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class WorkController {

    private final JdbcTemplate jdbc;

    public WorkController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping("/b/work")
    public String work() throws InterruptedException {
        return doWork();
    }

    @WithSpan("b.doWork")
    String doWork() throws InterruptedException {
        Thread.sleep(50);   // simulate I/O
        Integer one = jdbc.queryForObject("SELECT 1", Integer.class);
        return "ok=" + one;
    }
}
```

#### Start each service with the OTel agent

```bash
# terminal 1 — Service A
OTEL_SERVICE_NAME=service-a \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
java -javaagent:$(./scripts/otel-agent-download.sh) -jar service-a.jar --server.port=8081

# terminal 2 — Service B
OTEL_SERVICE_NAME=service-b \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
java -javaagent:$(./scripts/otel-agent-download.sh) -jar service-b.jar --server.port=8082
```

For local debugging, add `-Dotel.traces.sampler=always_on` to both services so that no trace is lost (see §5.4).

#### Start the collector

```bash
# terminal 3 — collector
./scripts/otel-collector-up.sh --output traces.jsonl
```

The helper starts `otelcol-contrib` with a default config. The config opens OTLP gRPC on `:4317` and HTTP on `:4318` and writes everything to `traces.jsonl` through the fileexporter.

#### Trigger a request

```bash
curl http://localhost:8081/a/hello
```

#### Extract the trace

```bash
./scripts/otel-spans-extract.sh traces.jsonl
```

The script projects each span to `{ service, name, traceId, spanId, parentSpanId, durationMs }`. A single request gives three spans, all under one `traceId`. The expected output:

```json
{"service":"service-a","name":"GET /a/hello","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"00f067aa0ba902b7","parentSpanId":"","durationMs":78.4}
{"service":"service-b","name":"GET /b/work","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"a1c9d2e3f4b56789","parentSpanId":"00f067aa0ba902b7","durationMs":54.1}
{"service":"service-b","name":"b.doWork","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"b9e8d7c6b5a49382","parentSpanId":"a1c9d2e3f4b56789","durationMs":52.6}
```

Service A's controller span is the trace root, because it has no `parentSpanId`. Service B's controller span has Service A's span as its parent. This parent link is the cross-service link from the propagated `traceparent` header. The `@WithSpan` span `b.doWork` is a child of B's server span. If H2 is wired in, an additional `SELECT <db-name>` JDBC span (for example `SELECT my-db`) appears under `b.doWork`. The agent names a JDBC span after the SQL operation and the database name. The database name depends on the datasource configuration.

#### Filter to one specific trace

```bash
./scripts/otel-spans-extract.sh traces.jsonl --trace-id 4bf92f3577b34da6a3ce929d0e0e4736
```

The output is the same projection, limited to one `traceId`. This filter helps when many requests share one file.

### §5.3 Propagation pitfalls and how the agent handles them

- **Async boundaries** (`CompletableFuture`, Reactor `Mono`/`Flux`, Kotlin coroutines): the agent instruments known async-aware libraries, and the parent context flows automatically. The problem appears when you start raw `Thread`s or pass work to a plain `ExecutorService` that the agent has not wrapped. The context is then **lost** at the thread boundary, and the resulting spans become orphans (new root traces). To fix this, wrap the executor with `Context.taskWrapping(executor)`, or use Spring's `@Async`, which the agent instruments.
- **Kafka / RabbitMQ**: the context travels in message headers. The producer adds the headers, and the consumer extracts them. Both sides must run the OTel agent. If only one side is instrumented, the consumer's spans appear as new root traces, and the link to the producer is broken.
- **gRPC**: propagation is built into the agent. It needs no configuration.
- **Cross-language services** (for example, a Java caller and a Python callee): the W3C TraceContext spec is the same in all official OTel SDKs. The trace joins across languages automatically, as long as each service is instrumented with the OTel agent or SDK of its language.
- **Baggage propagation**: the agent propagates the `baggage` header, but it does **not** copy Baggage entries into span attributes (see [§4.5](#45-path-d--baggage-for-cross-cutting-attributes)). Either enable `-Dotel.java.experimental.span-attributes.copy-from-baggage.include=tenant.id,correlation.id` on every service, or apply the projection centrally in the collector via the `transform` processor. Centralizing it in the collector is usually easier because the rule lives in one place.

### §5.4 Sampling decisions across services

The trace root makes the sampling decision and propagates it through the `sampled` flag in the `traceparent` header. If Service A samples a trace out, Service B sees a non-sampled context and drops the trace as well. The decision is therefore consistent across the whole call chain, which is what you want. The downside is symmetric: if A samples a trace **in**, B records it too, even if B alone would have dropped it.

For local debugging, set `-Dotel.traces.sampler=always_on` on every service so that nothing is lost. For production, use `parentbased_traceidratio` with `-Dotel.traces.sampler.arg=<ratio>`; the agent's default is `parentbased_always_on`, which keeps every trace. Then only the root service makes the probabilistic decision, and the downstream services follow it. This guarantees a complete trace or a complete drop, never a half-recorded trace.

---

## §6 Comparison

| Criterion | §2.2 Console exporter | §2.3 `logging-otlp` + Logback | §3 Collector + fileexporter |
|---|---|---|---|
| Extra process | no | no | **yes** |
| Output format | text dump | OTLP JSON Lines | OTLP JSON Lines |
| Machine-parseable | no | yes | yes |
| Setup effort | trivial | low | medium |
| Multi-sink possible | no | no (one file) | yes (file + Tempo + Jaeger in parallel) |
| Processors (filter, sample, redact) | no | no | yes |
| Live latency | immediate | immediate (per span) | up to `flush_interval` |
| Configuration expressible in Nix | only via app | only via app | **yes**, collector + pipeline |

### Decision guide

- **One-off ad-hoc debugging**: use [§2.2](#22-console-exporter-quick--dirty) (console exporter), because its setup is trivial.
- **Recurring debugging with filtering**: use [§2.3](#23-otlp-json-to-a-file-via-logging-otlp--logback) (`logging-otlp` + Logback + `jq`). It writes machine-parseable OTLP JSON Lines without an extra process.
- **Multiple backends in parallel, or processors**: use Variant B ([§3](#3-variant-b--opentelemetry-collector-via-nix), collector via Nix). Only the collector can feed several sinks and run processors.
- **Permanent setup on a NixOS host that runs all the time**: use Variant B with the NixOS module ([§3.6](#36-nixos-module)). The module runs the collector as a service and validates the config during the Nix build.
- **Per-project devshell**: use Variant B with the devenv module ([§3.5](#35-devenv-module)). `devenv up` and `devenv down` start and stop the collector with the project.

---

## §7 Alternative Tools

Tracing shows **semantic operations**, not every method call. Other tools answer other questions:

- **"Which methods are called, and where do CPU time and allocations go?"**: [async-profiler](https://github.com/async-profiler/async-profiler), with the output as a flame graph.
- **"Full JVM behavior, including GC, I/O, and locks"**: [JFR](https://docs.oracle.com/en/java/javase/21/jfapi/), built into the JDK, analyzed with JDK Mission Control. See [`jfr.md`](jfr.md) and [`jmc.md`](jmc.md).
- **"Local trace UI without a backend setup"**: [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer). It is a single binary with an OTLP endpoint and a local web UI.
- **"Mini backend with UI"**: Jaeger all-in-one as a Docker or Nix package. It runs the OTLP receiver and the UI in one process.

---

## §8 Further Reading

- [OpenTelemetry Java Agent: Configuration](https://opentelemetry.io/docs/zero-code/java/agent/configuration/)
- [OpenTelemetry Java Instrumentation: Supported Libraries](https://github.com/open-telemetry/opentelemetry-java-instrumentation/blob/main/docs/supported-libraries.md)
- [OpenTelemetry Java: Manual Instrumentation](https://opentelemetry.io/docs/languages/java/instrumentation/)
- [`opentelemetry-instrumentation-annotations`](https://javadoc.io/doc/io.opentelemetry.instrumentation/opentelemetry-instrumentation-annotations/latest/index.html)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
- [Baggage Specification](https://opentelemetry.io/docs/specs/otel/baggage/api/)
- [SDK Environment Variable Specification](https://opentelemetry.io/docs/languages/sdk-configuration/general/)
- [Collector fileexporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/fileexporter)
- [Collector Builder (OCB)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder)
- [NixOS module `services.opentelemetry-collector`](https://github.com/nixos/nixpkgs/blob/master/nixos/modules/services/monitoring/opentelemetry-collector.nix)
- [devenv module for otel-collector](https://github.com/cachix/devenv/blob/main/src/modules/services/opentelemetry-collector.nix)
- [FriendsOfOpenTelemetry/opentelemetry-nix](https://github.com/FriendsOfOpenTelemetry/opentelemetry-nix)
