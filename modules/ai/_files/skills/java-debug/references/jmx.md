# Java Management Extensions (JMX) — Runtime Introspection of Any JVM

JMX is the JVM's built-in introspection and control layer. Every JDK ships with
a populated MBeanServer that exposes memory pools, threads, garbage collectors,
class loaders, the runtime arguments, the operating system, and direct-buffer
usage as readable (and often invokable) MBeans. Libraries — Tomcat, HikariCP,
Kafka clients, Hibernate, Spring Boot — publish their own MBeans on top of that
server, so a single JMX connection is often the fastest way to inspect a
running process without redeploying, attaching a debugger, or wiring up an
APM. This reference covers the protocol, the flags, the tooling, and the
catalogue of MBeans worth knowing.

## Contents

- [1. Core concepts](#1-core-concepts)
- [2. JVM flags](#2-jvm-flags)
- [3. jmxterm — the agent's primary JMX client](#3-jmxterm--the-agents-primary-jmx-client)
- [4. Jolokia — HTTP+JSON alternative](#4-jolokia--httpjson-alternative)
- [5. MBean catalogues](#5-mbean-catalogues)
- [6. Container & Kubernetes tricks](#6-container--kubernetes-tricks)
- [7. Security](#7-security)
- [8. References](#8-references)

## 1. Core concepts

- **MBean.** A Java object that exposes named *attributes* (read and sometimes
  write) and named *operations* (callable methods). The JVM keeps every MBean
  in its in-process MBeanServer; remote JMX clients talk to that server over
  RMI by default.
- **ObjectName.** The canonical identity of an MBean in the form
  `domain:key1=value1,key2=value2`. Examples:
  - `java.lang:type=Memory`
  - `Catalina:type=Connector,port=8080`
  - `com.zaxxer.hikari:type=Pool (HikariPool-1)`
  The domain segments the namespace; the key/value pairs disambiguate
  instances. Quote ObjectNames in shells — the parentheses and commas are
  shell-active.
- **Attribute.** A named, typed value on an MBean, e.g. `HeapMemoryUsage`
  (a `CompositeData` with `init`, `used`, `committed`, `max`).
- **Operation.** A method on the MBean. Examples: `gc()` on `type=Memory`,
  `findDeadlockedThreads()` on `type=Threading`.
- **Notification.** An asynchronous event the MBean publishes to subscribers.
  You almost never consume these from a CLI; relevant if you build a dashboard
  or a long-lived monitor.
- **RMI registry vs RMI server (the "double port" problem).** JMX over RMI
  historically uses *two* TCP ports. The JVM exposes an RMI *registry* on the
  port you configure with `com.sun.management.jmxremote.port`, but the
  registry then redirects the client to an RMI *server* on a second port —
  by default a random, ephemeral one. A client behind a firewall, a port
  forward, or a NAT will complete the registry lookup, receive a callback
  address pointing at the random port, and then hang forever waiting for a
  connection that can never be made. The fix is to *pin the second port equal
  to the first* by setting `com.sun.management.jmxremote.rmi.port` to the
  same value as `com.sun.management.jmxremote.port`. Always do this. The
  legacy two-port behaviour exists only because the original RMI spec assumed
  flat networks.
- **JMXMP.** An alternative JMX transport that doesn't use RMI at all. It
  exists but is rare in the wild; most clients (including jmxterm) accept it,
  but you'll seldom see a server configured for it. Mention here only so you
  recognise the URL form `service:jmx:jmxmp://host:port`. If you reach for
  this, you almost certainly want Jolokia instead (see §4).

## 2. JVM flags

The JMX agent is configured entirely with `-D` system properties. Setting any
of the `com.sun.management.jmxremote.*` properties implicitly enables the
remote agent.

| Flag | Purpose |
|---|---|
| `-Dcom.sun.management.jmxremote` | Enable remote JMX. Usually implied by setting `.port`. |
| `-Dcom.sun.management.jmxremote.port=<N>` | RMI registry port. |
| `-Dcom.sun.management.jmxremote.rmi.port=<N>` | RMI server port. **Set equal to `.port` to use a single port.** |
| `-Dcom.sun.management.jmxremote.authenticate=true\|false` | Require user/password. Default `true`. |
| `-Dcom.sun.management.jmxremote.ssl=true\|false` | Use SSL on RMI. Default `true`. |
| `-Dcom.sun.management.jmxremote.password.file=<path>` | Password file. Must be mode `0400` or `0600`, owned by the JVM user. |
| `-Dcom.sun.management.jmxremote.access.file=<path>` | Per-user `readonly`/`readwrite` access file. |
| `-Dcom.sun.management.jmxremote.host=<addr>` | Bind address for the JMX server. Defaults to all interfaces on JDK 8 and earlier; defaults to `127.0.0.1` on newer JDKs. |
| `-Dcom.sun.management.jmxremote.local.only=true\|false` | Restrict to localhost connections. |
| `-Djava.rmi.server.hostname=<addr>` | Hostname/IP the RMI server reports *back to the client* for follow-up calls. **Critical inside containers and behind port forwards — see §6.** |

The companion script `scripts/jmx-startup.sh` emits a flag set for the common
single-port, no-auth, no-SSL development pattern. The shape it produces:

```bash
# Equivalent to what jmx-startup.sh emits for port 5000
-Dcom.sun.management.jmxremote
-Dcom.sun.management.jmxremote.port=5000
-Dcom.sun.management.jmxremote.rmi.port=5000
-Dcom.sun.management.jmxremote.authenticate=false
-Dcom.sun.management.jmxremote.ssl=false
-Dcom.sun.management.jmxremote.local.only=false
-Djava.rmi.server.hostname=127.0.0.1
```

Pass the emitted flags through `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, or
directly on the `java` command line. `JAVA_TOOL_OPTIONS` is the most portable
choice because it is honoured by the launcher, by `mvn`, by Gradle's daemon,
and by Spring Boot's `bootRun`.

## 3. jmxterm — the agent's primary JMX client

[jmxterm](https://github.com/jiaqi/jmxterm) is an open-source, non-interactive
JMX client. It ships as a single ~6 MB uber-jar that runs with
`java -jar jmxterm.jar`. In this skill you invoke it via `scripts/jmx.sh`,
which prefers a system `jmxterm` on `PATH` and falls back to
`nix run nixpkgs#jmxterm --` so the tool is always available.

jmxterm has an interactive REPL, but agents should drive it non-interactively
by piping a small command script on stdin:

```bash
# Read heap memory usage from a JVM listening on localhost:5000
{
  echo "open localhost:5000"
  echo "get -b java.lang:type=Memory HeapMemoryUsage"
  echo "close"
} | scripts/jmx.sh -n -i -
```

Key commands the agent will use:

- `domains` — list every MBean domain on the server. The fastest reconnaissance.
- `beans -d <domain>` — list every ObjectName inside a domain.
- `info -b <objectname>` — show the attributes and operations of a single
  MBean, including the type signature of each operation.
- `get -b <objectname> <attr> [<attr2> ...]` — read one or more attributes.
- `set -b <objectname> <attr> <value>` — write an attribute (only works when
  the attribute declares itself writable).
- `run -b <objectname> <op> [args]` — invoke an operation. Arguments are
  positional; consult `info -b ...` for the signature.

A complete worked example end-to-end. Find the heap usage on a local JVM:

```bash
scripts/jmx-startup.sh 5000   # prints the JVM flags; paste into your launcher

# In another shell, after the JVM started:
{
  echo "open localhost:5000"
  echo "domains"                                  # confirm java.lang is present
  echo "beans -d java.lang"                       # find type=Memory
  echo "info -b java.lang:type=Memory"            # see attributes
  echo "get -b java.lang:type=Memory HeapMemoryUsage"
  echo "run -b java.lang:type=Memory gc"          # optional: force a GC
  echo "get -b java.lang:type=Memory HeapMemoryUsage"
  echo "close"
} | scripts/jmx.sh -n -i -
```

The `-n` flag disables the interactive prompt; `-i -` reads commands from
stdin. The output is plain text — pipe through `grep`/`awk` to extract values
for scripting. There is no JSON mode; for structured output, switch to
Jolokia (§4).

## 4. Jolokia — HTTP+JSON alternative

[Jolokia](https://jolokia.org/) is an HTTP+JSON bridge to JMX. It listens on
port 8778 by default and exposes every JMX operation through REST calls with
JSON bodies. Reach for Jolokia when:

- You're behind a firewall where the double-port RMI dance is hopeless. HTTP
  on one port travels through proxies, ingresses, and port forwards cleanly.
- You want a cross-language client. Any tool that can speak HTTP+JSON
  (`curl`, `httpie`, Python, JavaScript, k6) can read MBeans — no JVM
  required on the client side.
- You're running a Spring Boot app and want auth and SSL handled by Spring
  Security instead of the painful JMX SSL setup.

How to add the agent to a Spring Boot 3.x application:

```bash
# Standalone javaagent — works for any JVM, not just Spring
java -javaagent:/path/to/jolokia-agent-jvm-2.x.x.jar=port=8778,host=0.0.0.0 -jar app.jar
```

Or, declare it as a Maven/Gradle dependency on `org.jolokia:jolokia-agent-jvm`
and load it at runtime. Skip the older `jolokia-spring-boot-starter` — it's
Spring Boot 2-only and unmaintained for 3.x.

Reading the same heap-usage attribute as in §3:

```bash
curl -s http://localhost:8778/jolokia/read/java.lang:type=Memory/HeapMemoryUsage | jq
```

```json
{
  "request": { "mbean": "java.lang:type=Memory", "attribute": "HeapMemoryUsage", "type": "read" },
  "value": { "init": 268435456, "used": 134217728, "committed": 536870912, "max": 4294967296 },
  "status": 200
}
```

Jolokia is fully compatible with JMX semantics: every `read`, `write`, `exec`,
`list`, and `search` call maps one-to-one to the underlying MBeanServer
operation. Anything you can do through jmxterm you can do through Jolokia,
and vice versa.

For a richer interactive UI on top of Jolokia, point [hawt.io](https://hawt.io/)
at the agent — it gives you a browseable tree and live charts, useful for
demos and onboarding new team members.

## 5. MBean catalogues

Skim this section when you need a starting point. For every domain, the most
useful ObjectNames and the attributes worth reading first.

### JVM built-ins (`java.lang:` and `java.nio:`)

- `java.lang:type=Memory` — `HeapMemoryUsage`, `NonHeapMemoryUsage`,
  `ObjectPendingFinalizationCount`. Operation `gc()` triggers a full GC
  (development only — never in production scripts).
- `java.lang:type=GarbageCollector,name=*` — one MBean per collector
  (e.g. `G1 Young Generation`, `G1 Old Generation`). Attributes
  `CollectionCount`, `CollectionTime`, `LastGcInfo` (`CompositeData` with
  before/after pool usage).
- `java.lang:type=Threading` — `ThreadCount`, `DaemonThreadCount`,
  `PeakThreadCount`, `TotalStartedThreadCount`. Operations
  `findDeadlockedThreads()` (returns an array of thread IDs — `null` when no
  deadlock), `getThreadInfo(long)`, `dumpAllThreads(...)`.
- `java.lang:type=OperatingSystem` — `SystemLoadAverage`,
  `OpenFileDescriptorCount`, `MaxFileDescriptorCount`,
  `FreePhysicalMemorySize`, `ProcessCpuLoad`, `SystemCpuLoad`.
- `java.lang:type=ClassLoading` — `LoadedClassCount`, `UnloadedClassCount`,
  `TotalLoadedClassCount`.
- `java.lang:type=Runtime` — `Uptime`, `StartTime`, `InputArguments`
  (the JVM flags actually applied — useful for verifying that
  `JAVA_TOOL_OPTIONS` took effect).
- `java.nio:type=BufferPool,name=direct` — `MemoryUsed`, `Count`,
  `TotalCapacity`. Same for `name=mapped`. The only canonical way to see how
  much off-heap `DirectByteBuffer` memory the JVM has allocated.

Example:

```bash
{ echo "open localhost:5000"
  echo "get -b java.lang:type=Threading findDeadlockedThreads"
  echo "close"
} | scripts/jmx.sh -n -i -
```

### Tomcat (`Catalina:` domain)

- `Catalina:type=Connector,port=*` — `localPort`, `protocolHandlerClassName`,
  `protocol`, `secure`.
- `Catalina:type=ThreadPool,name=*` — `currentThreadCount`,
  `currentThreadsBusy`, `maxThreads`, `connectionCount`. The first three are
  the classic "is the connector saturated?" triple.
- `Catalina:type=Manager,host=*,context=*` — `activeSessions`,
  `sessionCounter`, `expiredSessions`, `rejectedSessions`.
- `Catalina:type=GlobalRequestProcessor,name=*` — `requestCount`, `errorCount`,
  `processingTime`, `bytesReceived`, `bytesSent`. The processing time is
  cumulative — divide by `requestCount` for an average.

Example:

```bash
{ echo "open localhost:5000"
  echo 'get -b "Catalina:type=ThreadPool,name=\"http-nio-8080\"" currentThreadsBusy maxThreads'
  echo "close"
} | scripts/jmx.sh -n -i -
```

### HikariCP (`com.zaxxer.hikari:` domain)

- `com.zaxxer.hikari:type=Pool (<PoolName>)` — `ActiveConnections`,
  `IdleConnections`, `TotalConnections`, `ThreadsAwaitingConnection`. The
  fourth attribute is the leading indicator of a pool that's too small.
- Operation `softEvictConnections()` — marks idle connections for recycling
  at next checkout, useful when the database has rotated credentials or a
  replica has been swapped.

Example:

```bash
{ echo "open localhost:5000"
  echo 'get -b "com.zaxxer.hikari:type=Pool (HikariPool-1)" ActiveConnections IdleConnections ThreadsAwaitingConnection'
  echo "close"
} | scripts/jmx.sh -n -i -
```

### Lettuce / Redis

Lettuce does *not* publish MBeans natively. To see connection counts,
command latencies, or eviction rates, use Micrometer-backed metrics over
Spring Boot Actuator instead — see `references/actuator.md`.

### Spring Boot (`org.springframework.boot:` domain)

Only present when `spring.jmx.enabled=true` (default since Boot 2.2 is
`false`). When enabled, every Actuator endpoint is also exposed as an MBean:

- `org.springframework.boot:type=Endpoint,name=Health` — `health` attribute
  with the same JSON the HTTP endpoint returns.
- `org.springframework.boot:type=Endpoint,name=Env`, `Configprops`,
  `Loggers`, `Threaddump`, …

This is invaluable when the HTTP Actuator surface is firewalled but JMX is
reachable (e.g. an internal jump host). For the full endpoint catalogue and
HTTP equivalents, see `references/actuator.md` §6.

### Kafka client (`kafka.consumer:` / `kafka.producer:`)

The Kafka client library registers MBeans automatically when JMX is enabled
in the JVM. No additional configuration on the client side.

- `kafka.consumer:type=consumer-fetch-manager-metrics,client-id=*` —
  `records-consumed-total`, `records-consumed-rate`, `bytes-consumed-rate`,
  `fetch-latency-avg`.
- `kafka.producer:type=producer-metrics,client-id=*` — `record-send-rate`,
  `record-error-rate`, `request-latency-avg`, `outgoing-byte-rate`.

### Hibernate (`org.hibernate.core:`)

Hibernate exposes session-factory statistics under
`org.hibernate.core:type=Statistics,*` when
`hibernate.generate_statistics=true`. Rarely interesting in practice —
Micrometer / Actuator metrics give the same data with less ceremony.

## 6. Container & Kubernetes tricks

The single most common JMX failure mode is *the client connects, exchanges a
greeting, and then hangs*. The cause is always the same: RMI returned a
callback address the client cannot reach.

- **The hostname problem.** When the RMI server inside a container accepts a
  connection, it tells the client: *"call me back at hostname X"*. Hostname X
  defaults to the container's own hostname (`abc123def`), which the host or
  the developer's laptop cannot resolve. The client then tries to open a TCP
  connection to `abc123def:5000`, fails, and waits forever for a timeout.
- **The fix.** Set `-Djava.rmi.server.hostname=<address-the-client-uses>` on
  the JVM. This tells the RMI server which callback address to advertise.
- **docker compose.** Two viable patterns:
  - Set `java.rmi.server.hostname` to the host's IP (or `host.docker.internal`
    on Docker Desktop) and publish the port with `-p 5000:5000`. Reliable.
  - Set it to `127.0.0.1` and let the client connect through
    `docker compose port`. Slightly clunkier; useful when you don't want to
    bind the port on the host's main interface.
- **Kubernetes.** Use `kubectl port-forward pod/<name> 5000:5000` and set
  `java.rmi.server.hostname=127.0.0.1` on the JVM. The JVM tells the client
  to call back via `127.0.0.1:5000`, which is the local end of the forwarded
  tunnel.
- **The single-port pattern again.** Always set
  `com.sun.management.jmxremote.port == com.sun.management.jmxremote.rmi.port`.
  Otherwise the RMI server picks a random second port that's not published,
  not forwarded, and not known until the handshake completes. The hang
  reproduces 100% of the time.
- **Verification.** From inside the pod or container, run
  `ss -tlnp | grep <port>` (or `netstat -anp`). You should see exactly one
  listener on the configured port. If you see two, the second-port pin
  didn't take.

## 7. Security

JMX with default settings is *unauthenticated, plaintext remote code
execution*. Anyone who can reach the port can:

- Invoke `java.lang:type=Memory.gc()` (denial of service).
- Reload logging configuration to capture credentials in log files.
- Instantiate arbitrary classes through the `MLet` MBean (full RCE if any
  attacker-controlled URL is reachable).
- Read every system property and environment variable through
  `java.lang:type=Runtime`.

The same threat model as JDWP, in other words. Treat the port accordingly.

- **Local development.** Bind to `127.0.0.1` (or `localhost`), disable auth
  and SSL. Fine — no different from running a debugger on the same machine.
- **Production option A: password and access files.** Create a password file
  with `user password` lines and an access file with `user readonly` or
  `user readwrite` lines. Both files must be mode `0400` or `0600` and owned
  by the JVM user — the JDK refuses to start otherwise, because permissive
  modes would let other users read the credentials. The JDK ships templates
  in `$JAVA_HOME/conf/management/jmxremote.password.template` and
  `jmxremote.access`.
- **Production option B: JMX SSL.** Use a real keystore. The configuration
  surface is large (`javax.net.ssl.keyStore`, `keyStorePassword`,
  `trustStore`, `needClientAuth`, …) and the Oracle Monitoring & Management
  guide is the canonical reference. Painful to roll out; budget time.
- **Production option C: Jolokia behind Spring Security.** HTTP-layer
  authentication and TLS, managed by the same stack that protects the rest
  of the application. Easier to operate and to audit.

**Recommendation.** For modern Spring Boot stacks, prefer Actuator-over-HTTP
plus Spring Security to raw JMX exposure. Use raw JMX for local introspection
and for legacy applications. Even then, do not open the port beyond the
host's loopback unless you've configured one of the production options
above.

## 8. References

- [jmxterm GitHub](https://github.com/jiaqi/jmxterm) — sources, releases, full
  command reference.
- [Jolokia — Overview](https://jolokia.org/) — agent setup, HTTP API
  reference, protocol documentation.
- [Oracle Java Monitoring & Management Guide](https://docs.oracle.com/en/java/javase/21/management/) — JMX deep dive, including SSL setup,
  password/access file format, and the full system-property catalogue.
- [JEP 411 — Deprecation for Removal of the Security Manager](https://openjdk.org/jeps/411) — relevant if you tried to lock down JMX at the
  SecurityManager level; that lever no longer exists in modern JDKs.
- `references/actuator.md` — Spring-specific endpoint introspection over JMX
  and HTTP, including the Boot 3.x MBean naming scheme.
- `references/jfr.md` — JVM Flight Recorder, complementary to JMX:
  long-running event capture rather than point-in-time attribute reads.
