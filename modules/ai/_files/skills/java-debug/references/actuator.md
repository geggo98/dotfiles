# Spring Boot Actuator — Spring-Specific Runtime Introspection

Spring Boot Actuator is the Spring-Boot-specific introspection layer sitting on top of JMX and HTTP. It is auto-configured the moment `spring-boot-starter-actuator` lands on the classpath, and it is the canonical answer for any question about a running Spring application that depends on framework-level knowledge: which beans are wired, which auto-configurations matched (or, more usefully, did not match), the effective `Environment` after merging all property sources, the `@ConfigurationProperties` bindings, the request-mapping table, and the live Micrometer metrics registry. For non-Spring questions (raw thread state, GC counters, MBeans the application registered directly) prefer JMX (`references/jmx.md`); for low-overhead startup or allocation profiling prefer JFR (`references/jfr.md`). Actuator is the layer that knows about Spring; the other strategies do not.

## Contents

- [1. What Actuator gives you](#1-what-actuator-gives-you)
- [2. Endpoint catalogue](#2-endpoint-catalogue)
- [3. The Spring management.* property catalogue](#3-the-spring-management-property-catalogue)
- [4. Security and authentication](#4-security-and-authentication)
  - [4.1 In-app security](#41-in-app-security)
  - [4.5 Authentication for actuator.sh — resolution chain](#45-authentication-for-actuatorsh--resolution-chain)
- [5. JMX vs HTTP for Actuator](#5-jmx-vs-http-for-actuator)
- [6. Cross-reference Strategy D (JMX) and Strategy A (JFR)](#6-cross-reference-strategy-d-jmx-and-strategy-a-jfr)
- [7. Troubleshooting & deployment shapes](#7-troubleshooting--deployment-shapes)
- [8. References](#8-references)

## 1. What Actuator gives you

- **Auto-configured** when `spring-boot-starter-actuator` is on the classpath. No code change is required: the starter contributes `EndpointAutoConfiguration`, which registers every endpoint Spring knows about, then exposes the subset selected via `management.endpoints.*.exposure.include`.
- **Two transports.** HTTP under `/actuator/*` by default (served by the same `Servlet` or `WebFlux` engine as the application unless `management.server.port` is set), and JMX MBeans under `org.springframework.boot:type=Endpoint,name=*` whenever the Spring context's JMX support is enabled (`spring.jmx.enabled=true`). The two transports expose identical data; they differ only in framing.
- **Boot 3.x default exposure is intentionally narrow.** Only `/health` is exposed over HTTP out of the box. Everything else must be opted in explicitly via `management.endpoints.web.exposure.include`. This is a hardening default introduced because `/env`, `/configprops`, `/heapdump`, and `/threaddump` are dangerous to expose to anonymous traffic. JMX exposure defaults are slightly broader (because JMX is normally local-only), but the same `management.endpoints.jmx.exposure.include` knob applies.
- **Sanitisation by default.** Values in `/env` and `/configprops` are masked for keys that look like secrets (`password`, `secret`, `token`, `key`, `credentials`, ...). Override per-endpoint with `management.endpoint.env.show-values=ALWAYS` and `management.endpoint.configprops.show-values=ALWAYS`, but only do so in development. In production, prefer `WHEN_AUTHORIZED` so the data is visible to authenticated callers and masked to everyone else.
- **Composition over invention.** Actuator does not add new runtime instrumentation; it surfaces what the framework already knows. The bean graph comes from `ConfigurableApplicationContext`, the condition decisions from `ConditionEvaluationReport`, the metrics from the Micrometer `MeterRegistry`, the mappings from the `RequestMappingHandlerMapping`. This is why Actuator and JMX overlap: many Actuator endpoints simply wrap an existing MBean.
- **Versioning.** Actuator is part of `spring-boot`. The endpoint set, payload shapes, and property names track the Boot version. This reference targets Boot 3.x; legacy 1.x payloads were flatter and used different property names (for example `management.security.enabled` rather than `management.endpoint.<id>.enabled` and per-endpoint `sensitive` flags), and Boot 2.x renamed `/autoconfig` to `/conditions` and introduced the actuator-versus-management split that still applies. When inheriting a codebase the first check is `spring-boot.version` in the build file.
- **Read-mostly with a small mutating surface.** `/loggers`, `/caches`, `/scheduledtasks` (cancel), `/quartz` (pause/resume), and `/env` (refresh, when `spring-cloud-context` is on the classpath) accept `POST` or `DELETE`. Read these mutating surfaces as carefully as you would any other RPC, and never expose them anonymously: changing a logger level live is the most useful thing Actuator can do, and also the easiest way for an attacker to silence audit logs.

## 2. Endpoint catalogue

The endpoints below are the production-ready set as of Boot 3.3+. Path segments after the endpoint ID work in a uniform way: `GET /actuator/<id>` returns the full payload, `GET /actuator/<id>/{selector}` drills in, `POST` mutates where supported. The `actuator.sh` subcommand for each endpoint follows the same naming.

**`/health`** — Composite health check aggregating every registered `HealthIndicator` (database, disk space, downstream HTTP probes, custom indicators). Exposed by default. Use `?show-details=always|when_authorized|never` (also configurable globally as `management.endpoint.health.show-details`) to control whether sub-component status appears in the response, and `/health/{component}` (for example `/health/db`) to read a single indicator. Group definitions under `management.endpoint.health.group.<name>` carve out subsets — `liveness` and `readiness` are the standard groups. The status field is one of `UP`, `DOWN`, `OUT_OF_SERVICE`, `UNKNOWN`; the aggregate status is the lowest of any sub-component using the configured `StatusAggregator`. The `actuator.sh health` subcommand wraps this.

**`/info`** — Static build, git, and application info contributed by `InfoContributor` beans (typically the `git-commit-id` plugin and Boot's `build-info` Gradle/Maven task). Small payload, safe to expose. `actuator.sh info`.

**`/beans`** — Full bean graph. Returns `{contexts: {appName: {beans: {beanName: {scope, type, resource, dependencies}}}}}` — a node-per-bean map keyed by bean name, with the parent application context separately listed. Each entry's fields:
- `scope` — `singleton` (the overwhelming majority), `prototype`, `request`, `session`, or a custom scope.
- `type` — fully-qualified class name of the *concrete* runtime class. This is the type after CGLIB or JDK-dynamic-proxy enhancement, so a `@Transactional` bean shows up as `com.example.MyService$$EnhancerBySpringCGLIB$$abc123` rather than the original class.
- `resource` — the configuration source (typically a `@Configuration` class plus method name, or the auto-configuration class for auto-wired beans).
- `dependencies` — array of bean names this bean depends on (constructor args, autowired fields, autowired setters).

Read this when you need to verify that a specific bean was created, learn its concrete type after autowiring, or trace its dependency edges. `actuator.sh beans` or `actuator.sh beans --filter <pattern>`.

**`/conditions`** (legacy name `/autoconfig`) — Auto-configuration decisions. Returns three sections: `positiveMatches` (every `@Conditional` that fired and the matched bean), `negativeMatches` (every `@Conditional` that did *not* fire and the reason), and `unconditionalClasses`. The agent should reach for `negativeMatches` whenever a bean is missing or a starter "did nothing" — the textual reason explains exactly which class, property, or bean was absent. A typical `notMatched` entry looks like `{"condition":"OnClassCondition","message":"@ConditionalOnClass did not find required class 'org.springframework.data.redis.core.RedisTemplate'"}` — the message names the exact missing dependency, so a one-line classpath fix usually follows. `actuator.sh conditions` or `actuator.sh conditions --negative`.

**`/configprops`** — `@ConfigurationProperties` bindings. Returns `{contexts: {appName: {beans: {beanName: {prefix, properties, inputs}}}}}`. `prefix` is the configuration key root, `properties` is the bound effective value, `inputs` is the per-source provenance with sanitisation applied. Use this when you want to know what a `@ConfigurationProperties` class actually resolved to after merging YAML, environment variables, and command-line overrides. `actuator.sh configprops`.

**`/env`** — Spring `Environment` property sources. The top-level `propertySources` array is ordered by precedence (highest first). `/env/{name}` resolves a single property across all sources and returns each source's value plus the winning value. Source names tell you where a value came from: `systemProperties` (`-D` flags), `systemEnvironment` (env vars), `commandLineArgs`, `applicationConfig: [classpath:/application-prod.yml]` (a YAML file under a specific profile), `Config resource 'file [/etc/myapp/override.yml]'` (an external override). When debugging "why is this property X and not Y", the first source listed under `/env/<key>.propertySources[]` that has a non-null value is the winner. Sanitisation rules apply by default. `actuator.sh env` and `actuator.sh env <key>`.

**`/mappings`** — Request → controller mapping table. Per-mapping shows the URL pattern, HTTP methods, produces/consumes types, the handler method, and the bean. Use this to discover what routes a deployed application actually serves, which is invaluable when a path 404s and you cannot find the controller. The shape is `{contexts: {appName: {mappings: {dispatcherServlets: {dispatcherServlet: [...]}, servletFilters: [...], servlets: [...]}}}}` — three categories: servlets, filters, and the Spring MVC dispatch handler. Most controllers live under `dispatcherServlet[]`; static-resource handlers, OPTIONS handlers, and error pages also appear there. `actuator.sh mappings`.

**`/loggers`** — Every registered logger plus its effective and configured level. `GET /loggers/{name}` reads one logger. `POST /loggers/{name}` with body `{"configuredLevel": "TRACE"}` changes the level at runtime without restart — the single most useful endpoint for live debugging. Valid levels are `OFF`, `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE` (plus `null` to revert to the inherited level). The endpoint also lists `groups` (logical bundles of loggers, e.g. `web`, `sql`) so an entire concern can be raised to `DEBUG` with one call. `actuator.sh loggers`, `actuator.sh logger <name>`, `actuator.sh logger-set <name> <level>`.

**`/metrics`** — Lists every Micrometer meter name registered in the live registry. `/metrics/{name}?tag=k:v` reads one meter, optionally filtered by tag. The schema is `{name, baseUnit, measurements, availableTags}`. `measurements` is a list of `{statistic, value}` pairs where `statistic` is one of `COUNT`, `TOTAL_TIME`, `MAX`, `VALUE`, `ACTIVE_TASKS`, `DURATION` depending on the meter kind. The most commonly inspected meters are `jvm.memory.used`, `jvm.gc.pause`, `system.cpu.usage`, `process.cpu.usage`, `http.server.requests` (HTTP throughput and latency), `hikaricp.connections.*` (connection pool), and `tomcat.threads.busy`. `actuator.sh metrics` and `actuator.sh metric <name>`.

**`/threaddump`** — JSON thread dump including stack traces, lock-monitor relationships, and thread state. Equivalent to `jstack` or JDB's `threads`+`where all`, but consumable from a script. Each thread entry has `threadName`, `threadId`, `threadState` (`RUNNABLE`/`WAITING`/`TIMED_WAITING`/`BLOCKED`), `stackTrace[]` (frames with class/method/line), `lockedMonitors[]`, `lockedSynchronizers[]`, and `lockInfo` (the lock the thread is blocked on). Filter for deadlocks by looking for two threads with `lockInfo` referencing each other's `lockedMonitors`. `actuator.sh threaddump` returns the parsed JSON; for the classic text format use `?format=text` (Boot 3.2+).

**`/heapdump`** — Streams a binary HPROF download. Large (gigabytes for sizeable heaps). The dump is "live" (only reachable objects, after a full GC) rather than "all" (every object). Do not invoke casually in production: the GC pause to produce the dump can be tens of seconds on a multi-GB heap, the network transfer can saturate the pod's egress, and the resulting file is sensitive enough to warrant the same handling as a database export. `actuator.sh heapdump --out heap.hprof`.

**`/scheduledtasks`** — Lists `@Scheduled` tasks grouped by type (`cron`, `fixedDelay`, `fixedRate`, `custom`) with their next fire time and runnable target. `actuator.sh scheduledtasks`.

**`/caches`** — Lists Spring `Cache` instances grouped by `CacheManager`. `GET /caches/{name}` reads one. `DELETE /caches/{name}` evicts. `actuator.sh caches`.

**`/sessions`** — HTTP session inventory when Spring Session is on the classpath. Indexed by `username` and `sessionId`.

**`/integrationgraph`** — Channels, endpoints, and components of the running Spring Integration graph. Only present when Spring Integration is on the classpath.

**`/quartz`** — Quartz `Job` and `Trigger` inventory when the Quartz starter is on the classpath. Drill into `/quartz/jobs/{group}/{name}` and `/quartz/triggers/{group}/{name}`.

**`/flyway`**, **`/liquibase`** — Database migration history for whichever migration tool is on the classpath. Returns the ordered list of applied migrations with timestamps and checksums. `actuator.sh flyway`, `actuator.sh liquibase`.

**`/startup`** — Application startup steps with timing and parent/child relationships. Requires `BufferingApplicationStartup` to be wired on the `SpringApplication` before `run()` is called. Without that, the endpoint exists but returns nothing useful. The wiring lives in the application bootstrap, not in properties — see §7. `actuator.sh startup`.

**`/sbom`** — Software bill of materials. New in Boot 3.3. Surfaces CycloneDX or SPDX SBOM artifacts produced at build time. `/sbom/{id}` returns one document. Use this to verify a deployed artifact's transitive dependencies match what the build system thinks it shipped — the SBOM is generated at build time and embedded in the JAR. `actuator.sh sbom`.

**`/prometheus`** (when `micrometer-registry-prometheus` is on the classpath) — Prometheus text-exposition format for every Micrometer meter. This is the endpoint Prometheus scrapes. The payload is large and not designed for human reading; use `/metrics` and `/metrics/<name>` for ad-hoc queries. `actuator.sh prometheus` returns the raw text.

**`/httpexchanges`** (when an `HttpExchangeRepository` bean is registered, typically `InMemoryHttpExchangeRepository`) — Rolling buffer of the most recent HTTP exchanges with headers, timings, and response codes. Useful for diagnosing transient request failures when application logs are insufficient. Default buffer size is 100; configurable via the `HttpExchangeRepository` bean constructor.

**Agent-facing diagnostic recipes.** Five of the endpoints above carry almost all of the agent's load:

- **Bean missing or unexpected type.** Combine `/beans` (does it exist? what is its concrete type?) with `/conditions` `negativeMatches` (why was it not created?). The condition reason is almost always a missing class on the classpath, a missing bean of some type, or a property switch that defaulted off. Read both before changing anything.
- **Configuration not taking effect.** Combine `/env/<property>` (which source won?) with `/configprops` (which `@ConfigurationProperties` class bound it?). Spring resolves properties via an ordered `PropertySource` chain: command-line, environment, profile-specific YAML, default YAML, defaults. `/env/<property>` shows the resolved value alongside every source's contribution, which surfaces precedence bugs immediately.
- **Endpoint returns 404 but the application appears to be running.** Read `/actuator` (the HAL index) for the actual exposed set, then compare against `management.endpoints.web.exposure.include`. The HAL response is the ground truth.
- **Live debugging.** `POST /loggers/<name>` with `{"configuredLevel": "TRACE"}` enables trace logging for a specific package without restart. Pair with `/threaddump` for snapshot-style debugging. Reset with `{"configuredLevel": null}` (Boot interprets null as "revert to inherited").
- **Performance triage.** Start with `/metrics`, filter by domain (`http.server.requests`, `jvm.memory.used`, `hikaricp.connections.active`), then drill into a single meter with `/metrics/<name>?tag=...`. Cross-check with `/threaddump` if a meter shows pool exhaustion.

## 3. The Spring management.* property catalogue

These are the user-facing knobs that control Actuator. Set them in `application.yml`, `application.properties`, `-D` flags, or environment variables (`MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=*`).

```properties
# Exposure (which endpoints are visible over which protocol)
management.endpoints.web.exposure.include=*|<comma list>
management.endpoints.web.exposure.exclude=<comma list>
management.endpoints.jmx.exposure.include=*|<comma list>
management.endpoints.jmx.exposure.exclude=<comma list>

# Per-endpoint enable/disable (enable is global; exposure is per-protocol)
management.endpoint.<id>.enabled=true|false
management.endpoints.enabled-by-default=true|false

# Value visibility (sanitisation)
management.endpoint.env.show-values=NEVER|WHEN_AUTHORIZED|ALWAYS
management.endpoint.env.show-components=NEVER|WHEN_AUTHORIZED|ALWAYS
management.endpoint.configprops.show-values=NEVER|WHEN_AUTHORIZED|ALWAYS
management.endpoint.health.show-details=NEVER|WHEN_AUTHORIZED|ALWAYS
management.endpoint.health.show-components=NEVER|WHEN_AUTHORIZED|ALWAYS

# Endpoint relocation
management.endpoints.web.base-path=/actuator       # default; can be /management, /admin, ...
management.server.base-path=/admin                  # prepended (when set, full path becomes <server.base-path><web.base-path>/<endpoint>)
management.server.port=8081                         # separate HTTP server for Actuator (production-typical)
management.server.address=10.0.0.5                  # bind interface

# JMX
spring.jmx.enabled=true                             # enable JMX for the whole context; required for jmx.exposure.* to work
```

Two distinctions worth keeping straight:

- `enabled` versus `exposure.include` — `enabled=false` removes the endpoint from the registry entirely (it cannot be reached over either protocol). `exposure.include` controls which registered endpoints are reachable per protocol. Disable an endpoint with `enabled=false` only when you are sure no transport should reach it.
- `management.endpoints.web.base-path` versus `management.server.base-path` — the first **replaces** `/actuator` in the path, so endpoints become `/<new-base>/<endpoint>`. The second is **prepended** (typically by a reverse proxy or for grouping) and combines with web base-path. Both can be set: `management.server.base-path=/admin` and `management.endpoints.web.base-path=/management` yields `/admin/management/health`.

Use the `scripts/actuator-startup.sh` helper to emit a coherent set of `-D` flags. Its `--dev` profile expands to a developer-friendly preset:

```sh
$ ./scripts/actuator-startup.sh --dev --print-args-only
-Dmanagement.endpoints.web.exposure.include=*
-Dmanagement.endpoint.env.show-values=ALWAYS
-Dmanagement.endpoint.configprops.show-values=ALWAYS
-Dmanagement.endpoint.health.show-details=ALWAYS
-Dspring.jmx.enabled=true
-Dmanagement.endpoints.jmx.exposure.include=*
```

The same configuration expressed in `application.yml`:

```yaml
management:
  endpoints:
    web:
      exposure:
        include: "*"
    jmx:
      exposure:
        include: "*"
  endpoint:
    env:
      show-values: ALWAYS
    configprops:
      show-values: ALWAYS
    health:
      show-details: ALWAYS

spring:
  jmx:
    enabled: true
```

Prefer the `-D` form for ad-hoc debugging of an already-built application; prefer the YAML form when you control the build.

**Wiring `BufferingApplicationStartup`** for the `/startup` endpoint requires a code change at bootstrap because the buffer must exist before any startup events fire. There is no equivalent property switch:

```java
public static void main(String[] args) {
    SpringApplication app = new SpringApplication(MyApp.class);
    app.setApplicationStartup(new BufferingApplicationStartup(2048));
    app.run(args);
}
```

The `2048` is the buffer capacity in events; raise it for applications with hundreds of beans. If the buffer fills, later events are dropped silently. The endpoint returns events once and clears the buffer (calling it twice returns nothing the second time), which is intentional — the data is post-mortem, not live.

## 4. Security and authentication

### 4.1 In-app security

- **Never expose `*` in production over HTTP without Spring Security in front.** The exposure list controls visibility, not authorisation. With no security on the classpath, exposed endpoints are anonymously reachable on the management port. Any of `/env`, `/heapdump`, `/threaddump`, or even `/beans` is a serious information disclosure if leaked.
- **Sanitisation.** Boot's default `SanitizingFunction` masks values whose keys contain `password`, `secret`, `token`, `key`, or `credentials`. Boot 3.x replaces the old `KEYS_TO_SANITIZE` property with a `SanitizingFunction` `@Bean` — implement that bean for custom rules, returning `SanitizableData.withValue(...)` to override or pass the input through to keep the default behaviour.
- **`show-values=WHEN_AUTHORIZED`** only emits real values to authenticated users as defined by Spring Security. This is the safest production setting: secrets stay masked for anonymous traffic but operations engineers with credentials can still see them.
- **The canonical production pattern** is a separate `management.server.port`, bound to an internal interface or fronted by a network ACL, with Spring Security configured for Basic Auth or mTLS. Application traffic stays on 8080; Actuator stays on 8081 with auth and not reachable from outside the cluster. This isolates blast radius and keeps the application's security filter chain simple.
- **Why a separate port.** Boot 3.x's `WebMvcMetricsFilter` and security filter chain run on the application port. Co-hosting Actuator means every actuator request runs the application filter chain — including authentication redirects, CSRF protections, request logging that does not understand the management traffic shape. A separate port skips all of that: the management server gets its own minimal filter chain (Spring Security alone, no CSRF, no session, no MVC handler interceptors). Sub-millisecond probe responses depend on this.
- **Custom `HealthIndicator` beans.** Implement `HealthIndicator` (synchronous) or `ReactiveHealthIndicator` (reactive), then register as a `@Component`. Spring picks up the bean name (less the `HealthIndicator` suffix) as the sub-component name in `/health/{name}`. Use `Health.up().withDetail(...).build()` for success and `Health.down(throwable).build()` for failure; the throwable contributes to `show-details` output without leaking stack traces to unauthenticated callers.
- **Custom endpoints.** Annotate a `@Component` with `@Endpoint(id="<name>")` and add `@ReadOperation`, `@WriteOperation`, or `@DeleteOperation` methods. The endpoint is then automatically exposed under both HTTP (`/actuator/<name>`) and JMX subject to the same exposure rules. Use `@WebEndpoint` or `@JmxEndpoint` for transport-specific endpoints. This is the right tool when a custom operational concern needs the same auth, sanitisation, and exposure plumbing as the built-ins.

### 4.5 Authentication for actuator.sh — resolution chain

This is the agent-facing concern. The goal is that the agent can reach a protected Actuator endpoint without the secret ever appearing in its prompt, its conversation history, or its shell history. Secrets in the conversation transcript are an exfiltration vector; secrets passed via `*-cmd` indirection never enter the prompt at all.

The script consults sources in this order and stops at the first hit:

1. **Per-call CLI flag.** Either the direct literal form (`--bearer TOKEN`, `--basic USER:PASS`, `--header 'X-API-Key: K'`) or the safer command form (`--bearer-cmd CMD`, `--basic-cmd CMD`, `--header-cmd 'NAME:' CMD`). The `*-cmd` variants execute the supplied command, capture its standard output, trim trailing newlines, and treat the result as the credential. **Prefer the `*-cmd` variants** — they document where the secret comes from without revealing it, so the conversation transcript records `--bearer-cmd 'vault kv get -field=token kv/prod/actuator'` rather than the token itself.
2. **Environment variables.** First-match wins between the literal and `*_CMD` form:
   - `ACTUATOR_BEARER` — Bearer token literal.
   - `ACTUATOR_BEARER_CMD` — command whose stdout is the Bearer token.
   - `ACTUATOR_BASIC` — `user:pass` literal.
   - `ACTUATOR_BASIC_CMD` — command whose stdout is `user:pass`.
   - `ACTUATOR_AUTH_HEADER` — full header string (`Name: value`) for arbitrary header schemes (API keys, mTLS-bypass headers).
   - `ACTUATOR_AUTH_HEADER_CMD` — command whose stdout is the full header string.
3. **Credentials file** at `$ACTUATOR_CREDENTIALS` (highest priority) or `${XDG_CONFIG_HOME:-$HOME/.config}/java-debug/actuator-credentials`. INI-style. The file mode must be `0600`; the script refuses to read world-readable or group-readable files because that would defeat the point of keeping the secret out of the prompt. Sections are keyed by base URL — longest-prefix wins, so an environment-specific section overrides a generic one:
   ```ini
   [http://localhost:8080/actuator]
   bearer = local-dev-token

   [https://prod.example.com/actuator]
   basic-cmd = vault kv get -field=basic kv/prod/actuator
   header = X-Tenant-Id: ops
   ```
4. **No auth.** Proceed without an `Authorization` header. If the response is `401` or `403`, the script prints `auth required: try --bearer-cmd / ACTUATOR_BEARER_CMD / credentials file` so the agent can pick the right indirection.

Cookbook recipes for the `*-cmd` form across common secret stores:

- **HashiCorp Vault:** `ACTUATOR_BEARER_CMD='vault kv get -field=token kv/myapp/actuator'`
- **1Password CLI (`op`):** `ACTUATOR_BASIC_CMD='op item get "Actuator ops" --fields username,password --format=json | jq -r ".[0].value+\":\"+.[1].value"'`
- **macOS Keychain:** `ACTUATOR_BEARER_CMD='security find-generic-password -a actuator -s prod -w'`
- **`pass` (password-store):** `ACTUATOR_BEARER_CMD='pass show actuator/prod'`
- **`gopass`:** `ACTUATOR_BEARER_CMD='gopass show -o actuator/prod'`
- **Bitwarden CLI:** `ACTUATOR_BASIC_CMD='bw get item actuator-prod | jq -r ".login.username+\":\"+.login.password"'`
- **AWS Secrets Manager:** `ACTUATOR_BEARER_CMD='aws secretsmanager get-secret-value --secret-id prod/actuator --query SecretString --output text'`

Non-leakage guarantees the script implements:

- The resolved secret is never printed to stdout, stderr, or any spilled file under `/tmp/`. Internal logging redacts to `***`.
- `--verbose` prints only the command text or environment variable name, never the resolved value. So `--verbose --bearer-cmd 'pass show actuator/prod'` shows the command, not the token.
- The `Authorization` header is attached only to the actual outgoing HTTP request. Verbose URL logging strips it.
- The credentials file is opened read-only. The script `os.stat`s it and aborts with a clear error if the mode includes any group or other bits.

JMX parallel (slimmer; see `references/jmx.md` §4 for the full chain):

- `JMX_USER` + `JMX_PASSWORD`, or `JMX_PASSWORD_CMD`.
- `--user USER --password PASS` or `--password-cmd CMD`.
- Same credentials-file format, sections keyed by `host:port`.

**One concrete worked example.** An agent inherits a production application behind Vault-managed Basic Auth. The convention is one credential per environment under `kv/<env>/actuator`. Putting these two lines in the agent's shell profile makes every `actuator.sh` call against any environment safe:

```sh
export ACTUATOR_BASE='https://prod.internal.example.com/management'
export ACTUATOR_BASIC_CMD='vault kv get -field=basic kv/prod/actuator'
```

Now `actuator.sh health`, `actuator.sh beans`, `actuator.sh conditions --negative` all just work — the script discovers the base URL from the environment, the credentials chain resolves Vault on each call, and the token never enters the conversation. For multi-environment work, drop the `ACTUATOR_BASE` line and use `--base https://stage.../management` per-call; the credentials file resolves the right Vault path based on the longest URL prefix match.

**The `actuator.sh` invocation surface.** Thirteen subcommands plus a free-form passthrough:

- `health [--show-details] [<component>]` — `/health` or `/health/{component}`.
- `info` — `/info`.
- `beans [--filter <pattern>] [--type <fqcn>]` — `/beans` with optional client-side filtering.
- `conditions [--positive|--negative|--unconditional] [--filter <pattern>]` — `/conditions` with section selector.
- `configprops [--filter <prefix>]` — `/configprops`.
- `env [<key>]` — `/env` or `/env/{key}`.
- `mappings [--path <pattern>] [--method GET|POST|...]` — `/mappings` with filtering.
- `loggers [<name>]` — `/loggers` or `/loggers/{name}`.
- `logger-set <name> <level>` — `POST /loggers/{name}` to change level.
- `metrics [<name>] [--tag k:v ...]` — `/metrics` or `/metrics/{name}`.
- `threaddump [--format json|text]` — `/threaddump`.
- `heapdump --out <file>` — `/heapdump` streamed to disk.
- `scheduledtasks` — `/scheduledtasks`.

Plus `actuator.sh <endpoint-id>` (the passthrough) for any endpoint not in the above list, including custom endpoints. All subcommands accept the global `--scheme`, `--host`, `--port`, `--base-path`, `--base`, `--verbose`, and auth flags described in §4.5.

## 5. JMX vs HTTP for Actuator

- **JMX** has zero security at the protocol layer by default; the JVM binds the JMX connector to localhost unless `com.sun.management.jmxremote.host` is set otherwise. That property makes it safe-by-default for local development and for the SSH-tunnel-then-attach pattern used to reach production. JMX speaks RMI under the hood, which is awkward to firewall but easy to tunnel.
- **HTTP** is production-ready when Spring Security sits in front. It is also script-friendly (curl, jq, the `actuator.sh` wrapper). The two-port pattern (`management.server.port=8081`) keeps HTTP Actuator isolated from application traffic while staying simple to operate.
- **Mental model.** For agent introspection in local development, HTTP is friendlier: `actuator.sh` plus `curl` plus `jq` covers every endpoint. For production diagnosis where the management HTTP port is not externally reachable, JMX over an SSH tunnel is the standard pattern: forward the JMX connector locally, then `scripts/jmx.sh` against `localhost:<forwarded-port>`. Same data, different framing.
- **Payload differences.** HTTP returns JSON; JMX returns either a `CompositeData` tree (for `Data` attributes) or a plain string for endpoints whose data shape is awkward to compose. `scripts/jmx.sh` normalises both to JSON so downstream `jq` filters work uniformly. When the agent has a choice, prefer HTTP — the schema is documented per endpoint and the responses are friendlier to filter with `jq`.
- **Auth differences.** HTTP authentication is whatever Spring Security configures (Basic, Bearer, OAuth2 Resource Server, mTLS); JMX authentication is the JVM's built-in password file mechanism, unrelated to Spring's auth. The two are configured independently and can use different credentials. This is why `actuator.sh` and `jmx.sh` keep separate credential chains.
- **Performance.** Each Actuator HTTP request reconstructs the response payload from the live Spring context. `/beans` on a large application is genuinely expensive — tens of milliseconds, megabytes of JSON. JMX MBeans for the same endpoint use the same backing data, so they are no cheaper. Treat all of `/beans`, `/conditions`, `/configprops`, `/env`, `/mappings`, `/metrics` (with no name selector) as "occasional diagnostic" rather than "polled in production". Polling is fine for `/health`, `/info`, `/metrics/<one-name>`.

## 6. Cross-reference Strategy D (JMX) and Strategy A (JFR)

- **Strategy D (JMX).** Every Actuator endpoint is also an MBean. See `references/jmx.md` §5. So if HTTP is firewalled but JMX is reachable, use `scripts/jmx.sh attr 'org.springframework.boot:type=Endpoint,name=beans' ...` to read the bean graph through JMX. Spring registers each endpoint as `org.springframework.boot:type=Endpoint,name=<id>` with a `Data` attribute and an `invoke(...)` operation. The data shape is identical to the HTTP body. Other MBean families to combine with Actuator: HikariCP exposes `com.zaxxer.hikari:type=Pool (<name>)` MBeans with the same connection-pool counters as `/actuator/metrics/hikaricp.connections.*` — choose whichever the app exposes. JVM intrinsics (`java.lang:type=Threading`, `type=Memory`, `type=GarbageCollector`) sit alongside Actuator and are accessible regardless of whether the application uses Spring at all.
- **Strategy A (JFR).** Spring Boot's `FlightRecorderApplicationStartup` (covered in `references/jfr.md` §3) emits startup phase events as JFR events that show up in JDK Mission Control's `Application` view. Actuator's `/startup` endpoint returns the same data as JSON when `BufferingApplicationStartup` is set on the `SpringApplication` instead. The two are mutually exclusive — the `SpringApplication` holds one `ApplicationStartup` reference. Pick the one that fits the workflow: `BufferingApplicationStartup` for live HTTP querying via Actuator, `FlightRecorderApplicationStartup` for post-mortem analysis in JMC alongside other JFR data.
- **Strategy choice by question.** The question you are answering picks the strategy. *"Which bean was created and why?"* → Actuator `/beans` and `/conditions`. *"Where is GC time going?"* → JFR. *"Is the connection pool exhausted right now?"* → either Actuator `/metrics/hikaricp.connections.*` or JMX `com.zaxxer.hikari:type=Pool` — agent's choice. *"What is the application stuck on?"* → Actuator `/threaddump`, or `jstack` if Actuator is firewalled, or JDB if you have a JDWP port. Avoid using Actuator as a hammer for non-Spring questions: JMX surfaces JVM intrinsics (`java.lang:type=Threading.findDeadlockedThreads`, `type=Memory.gc()`) that Actuator does not expose.

## 7. Troubleshooting & deployment shapes

**Where Actuator can live.** Spring exposes three independent knobs that move endpoints around:

- `management.server.port=N` — separate HTTP server for Actuator. The common production pattern; isolates Actuator traffic from the application port.
- `management.server.base-path=/admin` — prepended (`/admin/actuator/health`). Typical when a reverse proxy wants a single shared prefix for everything operational.
- `management.endpoints.web.base-path=/management` — **replaces** `/actuator` (`/management/health`). This is the one users most often forget when reverse-engineering somebody else's deployment.
- `management.server.address=10.0.0.5` — bind to a specific interface. Rare; mostly seen behind reverse proxies with explicit internal-network NICs.

**How `actuator.sh` deals with this.** The four flags `--scheme`, `--host`, `--port`, `--base-path` compose into the final URL. `--base URL` short-circuits all four. The `ACTUATOR_BASE` environment variable makes the choice sticky across a session. When nothing is configured the script auto-probes: it tries `/actuator` and `/management` against `:8080` and `:8081`, picks the first that returns a HAL `_links` index, and remembers the winner for subsequent calls.

**How to detect the live deployment** when nothing seems to work:

1. Read the application's `application.yml` or `application.properties` for `management.*` keys. The configuration is usually authoritative.
2. If HTTP Actuator is exposed: `curl -s http://HOST:PORT/actuator/` returns a HAL `_links` index of every exposed endpoint. The index is definitive proof of the base path and the exposed set — when it returns, you know exactly what is available.
3. If only JMX is exposed: every Actuator endpoint is also an MBean, so `scripts/jmx.sh list --domain org.springframework.boot` enumerates them by name.
4. Spring Boot logs the management port and base path at `INFO` on startup, for example `Exposing 3 endpoint(s) beneath base path '/management'`. Tail the log; the answer is there.

**Common 4xx/5xx and how to fix:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `404` on `/actuator/health` but the app is up | wrong base-path or wrong port | probe `/management/health` and `:8081`; supply `--base-path` |
| `403` on every endpoint | Spring Security enabled, anonymous denied | use the auth chain (§4.5) |
| `401` with `WWW-Authenticate: Basic` | Basic Auth required | `--basic-cmd` or `ACTUATOR_BASIC_CMD` |
| `401` with `WWW-Authenticate: Bearer` | Bearer required | `--bearer-cmd` or `ACTUATOR_BEARER_CMD` |
| `200` from `/actuator` but `404` from `/actuator/beans` | endpoint not exposed | read `/actuator` HAL index for the actually-exposed list, or add to `management.endpoints.web.exposure.include` |
| `Connection refused` everywhere | HTTP Actuator not exposed | try the JMX path: `scripts/jmx.sh list --domain org.springframework.boot` |
| Endpoint returns `{}` or an empty array | endpoint registered but feature absent | confirm the underlying feature is enabled — `/startup` needs `BufferingApplicationStartup`, `/flyway` needs Flyway on the classpath, `/integrationgraph` needs Spring Integration |
| `503 Service Unavailable` from `/health` | one or more `HealthIndicator` reports DOWN | drill in: `/health?show-details=always` or `/health/<component>`; check liveness vs readiness groups |
| Endpoint returns sanitised `******` for everything | `show-values` defaults to `NEVER` in 3.x | set `management.endpoint.env.show-values=WHEN_AUTHORIZED` and authenticate, or `ALWAYS` for local development |
| Endpoint hangs | `/heapdump` writing to disk on large heap | wait — heap dumps for multi-GB heaps take minutes; do not retry, you will queue dumps and exhaust disk |

**Deployment shape: liveness and readiness groups.** Boot 3.x ships two probe-style health groups out of the box. `/actuator/health/liveness` returns whether the application can recover by being killed (typically only fails on unrecoverable internal errors); `/actuator/health/readiness` returns whether the application is ready to accept traffic. Kubernetes deployments wire these to `livenessProbe` and `readinessProbe` respectively. The agent can read both directly without authentication when `management.endpoint.health.probes.enabled=true` and `management.health.probes.enabled=true` are set, which is the standard production pattern.

**Deployment shape: behind a reverse proxy.** When the application sits behind nginx or AWS ALB and the operator wants only one externally-reachable hostname, the conventional layout is `https://api.example.com/admin/actuator/*` reverse-proxied to `http://app:8081/actuator/*`. The application sets `management.server.port=8081` and `management.server.base-path=/admin`; the proxy strips `/admin/` and forwards. When debugging from outside, hit `https://api.example.com/admin/actuator/health` (the full external path); when debugging from inside the pod, hit `http://localhost:8081/actuator/health` (the internal path). `actuator.sh --base https://api.example.com/admin/actuator health` handles the external case.

**Deployment shape: Spring Cloud Gateway and reactive applications.** WebFlux applications expose the same endpoints under the same paths, but the request mapping table at `/mappings` is structured differently (per `RouterFunction` rather than per `@RequestMapping`). Output shape changes apply to `/mappings` only; every other endpoint is identical.

**Deployment shape: GraalVM native-image.** Native-image builds work with most Actuator endpoints, but reflective access patterns matter. The `/beans`, `/conditions`, `/configprops`, and `/env` endpoints rely on reflective introspection — they work but require the Boot AOT-processing step (`spring-boot-maven-plugin:process-aot` or its Gradle equivalent) to have run. `/heapdump` is unavailable in native-image because HPROF dumping is a HotSpot feature. `/threaddump` works but reports a subset of fields. Plan accordingly when triaging a native-image deployment.

**Deployment shape: profile-specific exposure.** Production deployments often set `management.endpoints.web.exposure.include=health,info,metrics` while leaving `dev` and `local` profiles wide open via a profile-specific `application-dev.yml`. When inheriting a codebase, read every `application-*.yml` to learn which profiles change exposure — what you see depends on `SPRING_PROFILES_ACTIVE`.

**Deployment shape: empty `/actuator` index.** A `200 OK` response with an `_links` object containing only `self` means Actuator is wired but every endpoint is filtered out. The diagnostic is either `management.endpoints.web.exposure.include` is unset (or set to an empty string) or every endpoint is disabled via `management.endpoints.enabled-by-default=false` without a compensating per-endpoint enable. Inspect the application's `application.yml` and any environment-variable overrides.

**Deployment shape: trailing-slash and content negotiation.** Some endpoints require an `Accept` header. `/actuator/prometheus` ships with `application/openmetrics-text` and `text/plain` content types and returns `406 Not Acceptable` if the client requests something else. `actuator.sh prometheus` sets the right header automatically. `/actuator/heapdump` returns `application/octet-stream` and `200 OK` with the binary body; do not consume that endpoint with a JSON-aware tool.

**Diagnostic playbook: "the bean is not being created."** The agent's most common Spring question. Sequence:

1. Confirm classpath: `actuator.sh conditions --unconditional` lists classes that auto-configuration assumed present. Compare against the missing bean's expected starter — if the starter is absent the bean cannot exist.
2. Confirm condition: `actuator.sh conditions --negative | jq '.contexts.application.negativeMatches | to_entries[] | select(.key | contains("<class-fragment>"))'`. The `notMatched` array records exactly which `@Conditional` did not fire and why ("did not find class", "did not find any beans of type", "property was not set", "the @ConditionalOnProperty did not match").
3. Confirm property: if the condition was `@ConditionalOnProperty`, read `actuator.sh env <property>` to see the resolved value. Frequently the property is set in the wrong source (a `bootstrap.yml` instead of `application.yml`, or a profile-specific YAML when the active profile is something else).
4. Confirm bean order: if the condition was `@ConditionalOnMissingBean`, look at `/beans` for the type — a user-defined bean often shadows the auto-configured one.

This four-step recipe resolves the overwhelming majority of "missing bean" investigations without any code reading.

**Diagnostic playbook: "the application's configuration is wrong."** Sequence:

1. `actuator.sh env <property>` — see resolved value and full provenance chain. The top entry in the per-source list is the winning value.
2. `actuator.sh configprops | jq '.contexts.application.beans["<bean-name>"]'` — see the bound `@ConfigurationProperties` snapshot, including any default values that filled in when no property was set.
3. If the property is bound to a `@Value("${...}")` field instead of `@ConfigurationProperties`, `/configprops` will not show it. Use `/beans` to find the bean and check the actual injected value with a heap dump or by adding logging.

**Diagnostic playbook: "the metric is not being recorded."** Sequence:

1. `actuator.sh metrics | jq '.names[] | select(contains("<fragment>"))'` — does the meter exist at all?
2. If yes, `actuator.sh metric '<full-name>'` — what is its current value and what tags does it carry? `availableTags` shows every dimension recorded so far.
3. If the meter does not exist, the registration code has not run. Common causes: the relevant starter is missing (`micrometer-core` provides the API but not all instrumentation), the relevant feature is disabled (`management.metrics.enable.<group>=false`), or the code that creates the meter has not executed yet (lazy initialisation).

## 8. References

- [Spring Boot Reference — Production-ready Features (Actuator)](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html)
- [innoQ — Spring Boot Actuator Endpoints (2025)](https://www.innoq.com/en/articles/2025/04/spring-boot-actuator-endpoints/)
- [Baeldung — Spring Boot Actuator](https://www.baeldung.com/spring-boot-actuators)
- `references/jmx.md` — raw JMX, including how to reach Actuator endpoints via JMX MBeans.
- `references/jfr.md` — for the `FlightRecorderApplicationStartup` alternative to `/actuator/startup`.
