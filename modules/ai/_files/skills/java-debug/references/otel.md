# Local Tracing with the OpenTelemetry Java Agent

Two ways to make traces of a Java application visible locally — without a commercial backend, without the cloud:

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

- **OpenTelemetry (OTel)**: Vendor-neutral standard for telemetry (traces, metrics, logs). Only traces are relevant here.
- **Span**: An instrumented operation with start/end, attributes, and a parent-child relationship. Multiple spans sharing a `traceId` form a **trace**.
- **Java Agent**: A JAR loaded at JVM startup via `-javaagent` that uses the Java Instrumentation API to rewrite the bytecode of known libraries. Source: [`opentelemetry-java-instrumentation`](https://github.com/open-telemetry/opentelemetry-java-instrumentation).
- **Auto-instrumentation**: Spans the agent produces without any code change. Works only for [supported libraries](https://github.com/open-telemetry/opentelemetry-java-instrumentation/blob/main/docs/supported-libraries.md) (JDBC, Hibernate, Servlet/Spring MVC, Reactor Netty, Apache HttpClient, OkHttp, Lettuce, Jedis, Kafka, gRPC, …).
- **Exporter**: A component in the OTel SDK that ships spans somewhere. Relevant for local debugging: `console`, `logging-otlp`, `otlp`.
- **OTLP**: OpenTelemetry Protocol — gRPC or HTTP/Protobuf, the standardized wire format between app/agent and collector.
- **Collector**: A standalone process that receives telemetry through receivers, runs it through processors, and forwards it through exporters. Two official distributions: **core** (minimal) and **contrib** (all community components).
- **fileexporter**: Collector exporter that writes spans as OTLP JSON Lines to a file. Available only in the **contrib** distribution.

### What auto-instrumentation does **not** give you

It is not a full method-level trace. The agent produces spans at semantically meaningful points (inbound/outbound HTTP request, DB query, cache operation, message publish/consume). To see "which method called which", reach for a **profiler** like [async-profiler](https://github.com/async-profiler/async-profiler) or **Java Flight Recorder** (`-XX:StartFlightRecording`), not tracing.

---

## §2 Variant A — Direct from the Java Agent

No extra process. Output goes either to stdout or, through the app's logging framework, to a file.

### §2.1 Get the agent

Use the helper script — it downloads the latest agent JAR (or a pinned version) and prints the resolved path:

```bash
AGENT_JAR=$(./scripts/otel-agent-download.sh)
```

See [`scripts/otel-agent-download.sh`](../scripts/otel-agent-download.sh) for details and caching behavior.

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
- `tee` gives you live view and persistence in one step.
- The format is **unstructured text**, not machine-parseable. Fine for one-off debugging.

### §2.3 OTLP JSON to a file via `logging-otlp` + Logback

The `logging-otlp` exporter emits **OTLP-compliant JSON** over SLF4J. Route it through Logback into a dedicated file, separate from application logs.

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

Result: `traces.jsonl` with one JSON line per batch (NDJSON-style). Filterable with `jq`. Same format as the collector's `fileexporter`, **without** running the collector.

> **With other logging frameworks**: For Log4j2 or `java.util.logging` the routing must be configured accordingly — the exporter logs over SLF4J, so it works wherever SLF4J is wired in.

### §2.4 Important configuration switches

```bash
# SQL statements as span attribute (default: values are sanitized)
-Dotel.instrumentation.jdbc.statement-sanitizer.enabled=true
-Dotel.instrumentation.jdbc.experimental.capture-query-parameters=false

# Redis command args (caution: keys/values may be sensitive)
-Dotel.instrumentation.lettuce.experimental-span-attributes=true

# 100% sampling for local debugging
-Dotel.traces.sampler=always_on

# Agent debug output when instrumentation isn't taking effect
-Dotel.javaagent.debug=true
```

Reference: [Agent Configuration](https://opentelemetry.io/docs/zero-code/java/agent/configuration/), [SDK Environment Variables](https://opentelemetry.io/docs/languages/sdk-configuration/general/).

---

## §3 Variant B — OpenTelemetry Collector via Nix

A standalone process between app and sink. Useful when:

- Multiple backends must be fed in parallel (file *and* Tempo *and* Jaeger).
- Processors are needed in between (sampling, attribute filters, batching, PII redaction).
- Resource detection should be added automatically.
- The app config should stay stable and variation happens only on the collector side.

For pure "write to a file" it's overkill — Variant A.3 is the more honest choice.

### §3.1 Packages in nixpkgs

| Attribute | Binary | Contents |
|---|---|---|
| `opentelemetry-collector` | `otelcol` | Core distribution. **No fileexporter.** |
| `opentelemetry-collector-contrib` | `otelcol-contrib` | Contrib distribution with all community components. |
| `opentelemetry-collector-builder` | `ocb` | Builder for your own minimal distributions. |

You need **contrib** for the fileexporter.

### §3.2 Ad-hoc

Use the helper script that wraps the collector and points it at a default file-exporter config:

```bash
./scripts/otel-collector-up.sh --output traces.jsonl
```

See [`scripts/otel-collector-up.sh`](../scripts/otel-collector-up.sh) for flags. It runs `otelcol-contrib` from nixpkgs and writes OTLP JSON Lines to the path you pass.

To run the collector by hand instead:

```bash
nix shell nixpkgs#opentelemetry-collector-contrib
otelcol-contrib --config config.yaml
```

Or:

```bash
nix run nixpkgs#opentelemetry-collector-contrib -- --config config.yaml
```

Works on NixOS and nix-darwin.

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

For local development per project:

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

`devenv up` starts the collector as a process, `devenv down` stops it. Source: [devenv otel-collector module](https://github.com/cachix/devenv/blob/main/src/modules/services/opentelemetry-collector.nix).

### §3.6 NixOS module

For permanent operation:

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

- `settings` is a Nix attrset that is serialized to YAML.
- `validateConfigFile = true` (default) aborts the build if the config is invalid.
- The service runs under a dynamic systemd user.

Source: [nixos/modules/services/monitoring/opentelemetry-collector.nix](https://github.com/nixos/nixpkgs/blob/master/nixos/modules/services/monitoring/opentelemetry-collector.nix).

### §3.7 nix-darwin

There is **no** equivalent service module for nix-darwin or home-manager. On macOS three paths remain:

1. `home.packages = [ pkgs.opentelemetry-collector-contrib ]` and start it on demand.
2. Persistent via `launchd.user.agents.<name>` with `ProgramArguments`.
3. devenv per project (see §3.5).

### §3.8 Minimal custom distribution via OCB

The contrib binary is several hundred MB and contains components nobody needs. For minimal footprint:

- Native via `pkgs.opentelemetry-collector-builder` and a manifest YAML.
- Idiomatically in Nix via the flake [`FriendsOfOpenTelemetry/opentelemetry-nix`](https://github.com/FriendsOfOpenTelemetry/opentelemetry-nix), which provides a `mkOtelCollectorBuilderConfiguration` function. Components are declared as a Nix attrset, and the result is a reproducible custom build.

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

For pure debug tracing this is clearly overkill. It pays off for production collector deployments with a defined, slim footprint.

### §3.9 Output format and pitfalls

`traces.jsonl` contains OTLP `ExportTraceServiceRequest` JSON, one line per batch:

```json
{"resourceSpans":[{"resource":{"attributes":[...]},"scopeSpans":[{"scope":{...},"spans":[{"traceId":"...","spanId":"...","name":"GET /endpoint",...}]}]}]}
```

**Pitfall 1 — batching latency**: `flush_interval: 1s` means up to one second of delay. On a fast app exit the last batch can be lost if the collector is not stopped cleanly.

**Pitfall 2 — resource context**: The `resource` object (`service.name`, host, etc.) appears **once** per batch and applies to all spans in the same `resourceSpans` block. A naive `.spans[]` extraction loses that context.

Use the [`scripts/otel-spans-extract.sh`](../scripts/otel-spans-extract.sh) helper, which already does the right thing:

```bash
./scripts/otel-spans-extract.sh traces.jsonl
```

The equivalent raw `jq` pipeline (for understanding what the script does):

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

Auto-instrumentation covers only known libraries. Business logic, custom calculations, and bespoke workflows stay invisible. Four ways to change that — orthogonal to the choice between Variant A and B (this is about span **creation**, not export).

### §4.1 Preconditions

Three scenarios, three different requirements:

| Scenario | What you need |
|---|---|
| **With Java Agent** | Nothing extra for annotations or API calls — the agent supplies `GlobalOpenTelemetry`. |
| **Without agent, with OTel annotation** | The annotation is a no-op without the agent. Does not work. |
| **Without agent, wired manually** | Initialize the OTel SDK programmatically. More boilerplate, but full control over the exporter in code. |

This chapter assumes the **agent scenario**.

### §4.2 Path A — Declarative via `methods.include` (no code touch)

No code change, just a system property or env var:

```bash
-Dotel.instrumentation.methods.include="\
com.example.service.OrderService[place,refund];\
com.example.repo.UserRepository[findById]"
```

Syntax: `package.Class[method1,method2];other.Class[method3]`. Method wildcards are officially not supported.

**When useful**: debugging foreign or non-modifiable code, third-party tracing, quick experiments. **Downside**: no attributes, no exception recording — only a span start/end with the method name.

### §4.3 Path B — `@WithSpan` annotation

Idiomatic for your own code. Dependency:

```kotlin
// Gradle Kotlin DSL
implementation("io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations:2.10.0")
```

Use:

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

**What happens**: The agent recognizes the annotation at class load time, wraps the method in a span, and propagates the trace context. Without an active agent this is a no-op (no spans, no exceptions, no performance cost).

**Async methods** (`CompletableFuture`, Reactor `Mono`/`Flux`, Kotlin coroutines): the agent understands them. The span ends only when the `CompletableFuture` completes or the publisher signals completion — not when the method call returns.

**What you cannot do** with annotation alone:
- Set span status manually to `ERROR` without throwing an exception
- Add events to the span
- Add attributes that don't come from method parameters

For that you need Path C or D.

### §4.4 Path C — Programmatic via the OTel API

Full control. Dependency:

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

1. **`makeCurrent()` and `Scope`**: without it the span exists but is not the current context. Follow-up spans (e.g., auto-instrumented outbound HTTP calls) won't find it as parent and will be created as root spans. The trace ends up torn.
2. **`Scope` and `Span.end()` always in `finally`**: try-with-resources closes the `Scope`, but **not** the span. The span must be ended explicitly, otherwise it leaks and is never exported.
3. **Tracer name**: convention is the fully qualified module name (`com.example.payment`). It appears as `scope.name` in OTLP data — useful for filtering.

#### Adding attributes and events to an existing span

Inside an auto-instrumented method (e.g., a Spring controller handler), reach for the current span:

```java
import io.opentelemetry.api.trace.Span;

Span current = Span.current();                          // returns INVALID span if none active
current.setAttribute("user.tier", "premium");
current.addEvent("cache.miss", Attributes.of(
    AttributeKey.stringKey("cache.key"), key));
```

`Span.current()` is safe — when no span is active it returns a no-op span, no NPE.

#### Nested spans (parent-child)

Spans automatically become children of the current context span. Concretely:

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

When the same attribute must ride on **every** span of a trace (e.g., `tenant.id`, `correlation.id`), don't enrich each span manually — use **Baggage**. Baggage propagates automatically across thread and service boundaries (provided the agent has W3C Baggage propagation enabled, which is the default).

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

Baggage does **not** automatically become a span attribute. If you want that, enable the agent's `BaggageSpanProcessor`:

```bash
-Dotel.java.experimental.span-attributes.copy-from-baggage.include=tenant.id,correlation.id
```

Or project it in the collector via the `transform` processor.

### §4.6 Comparison of the four paths

| Path | Code change | Attributes | Events / exceptions | Async-capable | When to use |
|---|---|---|---|---|---|
| A — `methods.include` | no | no | no | yes (agent) | Foreign code, quick debug |
| B — `@WithSpan` | minimal | via `@SpanAttribute` | no | yes | Own code, default case |
| C — Programmatic | medium | full | full | manual (propagate context) | Business logic with status/errors |
| D — Baggage | minimal | cross-cutting | n/a | yes | Cross-cutting concerns |

### §4.7 Practical notes

- **Keep span names low-cardinality**. `GET /orders/{id}` is good, `GET /orders/42` is bad — it blows up backend indexes. The ID belongs in an attribute, not in the name.
- **Attribute conventions**: stick to the [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/) (`http.request.method`, `db.system`, `messaging.system`, etc.); do not invent your own schema if a standard name exists.
- **Sensitive data** (PII, secrets, cardholder data) must never become a span attribute. In the collector, chain in an `attributes` processor with `delete`/`hash` or a `redaction` processor.
- **Performance**: spans are cheap but not free. In hot loops (millions of iterations) do **not** create a span per iteration — wrap the loop in a single span with a counter attribute instead.
- **Manual spans and sampling**: if a sampler decides `RECORD_AND_DROP`, attributes are still set but the span is not exported. No crash, but invisible.

---

## §5 Cross-Service Tracing — End-to-End Example

### §5.1 What changes for cross-service?

The OTel Java Agent automatically propagates W3C TraceContext via the HTTP headers `traceparent` and `tracestate`, and W3C Baggage via the `baggage` header. No code changes are needed for the libraries the agent knows: Spring WebClient, RestTemplate, OkHttp, Apache HttpClient, gRPC, Reactor Netty, Kafka, RabbitMQ, JDBC. The caller injects the context into outbound calls, the callee extracts it from inbound calls — both sides only need the `-javaagent:…` flag.

The resulting trace has spans from **both** services under the same `traceId`. The callee's server span carries a `parentSpanId` that points to the caller's client span, so the chain is reconstructed end-to-end. Any OTLP-compatible backend (Jaeger, Tempo, Honeycomb, otel-desktop-viewer) can render the waterfall directly. Locally you don't need a UI — the fileexporter plus `jq` is enough to verify and analyze the topology.

### §5.2 Runnable 2-service Spring Boot example

Two minimal Spring Boot services. Service A calls Service B over HTTP. Both are started with the OTel Java agent, both export OTLP to the same collector, and the collector writes everything to one `traces.jsonl`.

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

For local debugging add `-Dotel.traces.sampler=always_on` to both services — see §5.4.

#### Start the collector

```bash
# terminal 3 — collector
./scripts/otel-collector-up.sh --output traces.jsonl
```

The helper starts `otelcol-contrib` with a default config that opens OTLP gRPC on `:4317` and HTTP on `:4318`, and writes everything to `traces.jsonl` via the fileexporter.

#### Trigger a request

```bash
curl http://localhost:8081/a/hello
```

#### Extract the trace

```bash
./scripts/otel-spans-extract.sh traces.jsonl
```

This projects each span as `{ service, name, traceId, spanId, parentSpanId, durationMs }`. Expected output for a single request — three spans, all under one `traceId`:

```json
{"service":"service-a","name":"GET /a/hello","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"00f067aa0ba902b7","parentSpanId":"","durationMs":78.4}
{"service":"service-b","name":"GET /b/work","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"a1c9d2e3f4b56789","parentSpanId":"00f067aa0ba902b7","durationMs":54.1}
{"service":"service-b","name":"b.doWork","traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"b9e8d7c6b5a49382","parentSpanId":"a1c9d2e3f4b56789","durationMs":52.6}
```

Read it: Service A's controller span is the trace root (no `parentSpanId`). Service B's controller span has Service A's span as parent — that's the cross-service link from the propagated `traceparent` header. The `b.doWork` `@WithSpan` span is a child of B's server span. If H2 is wired in, an additional `SELECT my-db` JDBC span shows up under `b.doWork`.

#### Filter to one specific trace

```bash
./scripts/otel-spans-extract.sh traces.jsonl --trace-id 4bf92f3577b34da6a3ce929d0e0e4736
```

The same projection, restricted to a single `traceId`. Useful when many requests share a file.

### §5.3 Propagation pitfalls and how the agent handles them

- **Async boundaries** (`CompletableFuture`, Reactor `Mono`/`Flux`, Kotlin coroutines): the agent instruments known async-aware libraries and the parent context flows automatically. The trap appears when you spawn raw `Thread`s or hand work to a plain `ExecutorService` the agent has not wrapped: the context is **lost** at the thread boundary, and the resulting spans become orphans (new root traces). Fixes: wrap the executor with `Context.taskWrapping(executor)`, or use Spring's `@Async` (which the agent instruments).
- **Kafka / RabbitMQ**: context travels in message headers — the producer adds them, the consumer extracts them. Both sides must run the OTel agent. If only one side is instrumented, the consumer's spans appear as new root traces and the link to the producer is broken.
- **gRPC**: propagation is built into the agent. No configuration required.
- **Cross-language services** (e.g., Java caller, Python callee): the W3C TraceContext spec is the same across all official OTel SDKs. The trace stitches across languages automatically as long as each service is instrumented with its language's OTel agent or SDK.
- **Baggage propagation**: the agent propagates the `baggage` header, but it does **not** automatically project Baggage entries onto child spans as attributes. Either enable `-Dotel.java.experimental.span-attributes.copy-from-baggage.include=tenant.id,correlation.id` on every service, or apply the projection centrally in the collector via the `transform` processor. Centralizing it in the collector is usually easier because the rule lives in one place.

### §5.4 Sampling decisions across services

Sampling decisions are made at the trace root and propagated via the `sampled` flag in the `traceparent` header. If Service A samples a trace out, Service B sees a non-sampled context and drops the trace as well — the decision is consistent across the whole call chain, which is what you want. The downside is symmetric: if A samples a trace **in**, B records it too, even if B alone would have dropped it.

For local debugging, set `-Dotel.traces.sampler=always_on` on every service so nothing is lost. For production, use `parentbased_traceidratio` (default in newer agents) so only the root service makes the probabilistic call and downstream services follow it — this guarantees a complete trace or a complete drop, never a half-recorded one.

---

## §6 Comparison

| Criterion | A.2 Console exporter | A.3 `logging-otlp` + Logback | B Collector + fileexporter |
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

- **One-off ad-hoc debugging** → A.2 (console exporter).
- **Recurring debugging with filtering** → A.3 (`logging-otlp` + Logback + `jq`).
- **Multiple backends in parallel or processors needed** → B (collector via Nix).
- **Permanent setup in the homelab** → B with the NixOS module.
- **Per-project devshell** → B with the devenv module.

---

## §7 Alternative Tools

Tracing shows **semantic operations**, not every method call. For other questions:

- **"Which methods are called, where is CPU/allocation burned?"** → [async-profiler](https://github.com/async-profiler/async-profiler), output as a flame graph.
- **"Full JVM behavior including GC, IO, locks"** → [Java Flight Recorder](https://docs.oracle.com/en/java/javase/21/jfapi/), built in, analyzed with JDK Mission Control.
- **"Local trace UI without a backend setup"** → [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer), single binary, OTLP endpoint plus a local web UI.
- **"Mini backend with UI"** → Jaeger all-in-one as a Docker or Nix package: OTLP receiver and UI in one process.

---

## §8 Further Reading

- [OpenTelemetry Java Agent — Configuration](https://opentelemetry.io/docs/zero-code/java/agent/configuration/)
- [OpenTelemetry Java Instrumentation — Supported Libraries](https://github.com/open-telemetry/opentelemetry-java-instrumentation/blob/main/docs/supported-libraries.md)
- [OpenTelemetry Java — Manual Instrumentation](https://opentelemetry.io/docs/languages/java/instrumentation/)
- [`opentelemetry-instrumentation-annotations`](https://javadoc.io/doc/io.opentelemetry.instrumentation/opentelemetry-instrumentation-annotations/latest/index.html)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
- [Baggage Specification](https://opentelemetry.io/docs/specs/otel/baggage/api/)
- [SDK Environment Variable Specification](https://opentelemetry.io/docs/languages/sdk-configuration/general/)
- [Collector fileexporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/fileexporter)
- [Collector Builder (OCB)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder)
- [NixOS module `services.opentelemetry-collector`](https://github.com/nixos/nixpkgs/blob/master/nixos/modules/services/monitoring/opentelemetry-collector.nix)
- [devenv module for otel-collector](https://github.com/cachix/devenv/blob/main/src/modules/services/opentelemetry-collector.nix)
- [FriendsOfOpenTelemetry/opentelemetry-nix](https://github.com/FriendsOfOpenTelemetry/opentelemetry-nix)
