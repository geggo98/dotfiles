Applies to: everywhere (macOS, Linux, containers and Kubernetes pods). Run the commands on the host or in the container where the JVM runs.

# JVM Metrics to a File, and Continuous Export

**TL;DR:** To get a series of JVM values into a file, use [`scripts/jmx-sample.py`](../scripts/jmx-sample.py) against a Jolokia agent. Jolokia is an HTTP and JSON bridge to JMX that runs as a Java agent inside the JVM (see [jolokia.md](jolokia.md)). The script writes JSONL or CSV and fails loudly when any single value cannot be read. On the same host without any port, use `jcmd`. Part 2 sketches continuous export to a metrics backend. That part is not measured.

## Contents

- [Part 1: values as a file](#part-1-values-as-a-file)
  - [jmx-sample.py](#jmx-samplepy)
  - [Alternatives without Jolokia](#alternatives-without-jolokia)
  - [Which tool when](#which-tool-when)
- [Part 2: continuous export (not measured)](#part-2-continuous-export-not-measured)

## Part 1: values as a file

### jmx-sample.py

[`scripts/jmx-sample.py`](../scripts/jmx-sample.py) sends Jolokia bulk `read` requests at a fixed interval and writes one row per sample. A bulk request is one HTTP POST whose JSON body is an array of requests, and the answer is an array with one `status` per item. All `scripts/` paths on this page, including those in the commands, are relative to the `java-debug` skill directory.

```bash
# Five JVM values every 5 s, 60 samples, as CSV
scripts/jmx-sample.py --url http://127.0.0.1:8778/jolokia/ --preset jvm \
  --interval 5 --count 60 --format csv --out jvm.csv

# Your own attributes, until Ctrl-C, as JSONL on stdout
scripts/jmx-sample.py --url http://127.0.0.1:8778/jolokia/ \
  --read java.lang:type=Memory HeapMemoryUsage \
  --read 'java.lang:type=GarbageCollector,name=G1 Young Generation' CollectionCount
```

| Option | Meaning |
|---|---|
| `--url URL` | Jolokia endpoint (required), `http://` or `https://`. |
| `--read MBEAN ATTRIBUTE` | One attribute. Repeat the option for more. Wildcards are refused because they make the column set unstable. |
| `--preset jvm` | Heap and non-heap usage, thread count, process CPU load, loaded class count. |
| `--interval S` | Seconds between samples (default 5). |
| `--count N` | Number of samples. 0 (default) runs until interrupted. |
| `--format jsonl\|csv` | Default `jsonl`. |
| `--out FILE` | Output file, or `-` for stdout (default). Appends to an existing file. For CSV, see the safety rules below. |
| `--timeout S` | Timeout per request (default 10). |
| `--insecure-http` | Allow HTTP Basic over plain `http://` to a non-loopback host. |

**Output shape.** Each row carries a UTC timestamp `time`. Composite values are flattened to one column per key, named `MBean/Attribute.key`, for example `java.lang:type=Memory/HeapMemoryUsage.used`.

**Credentials.** Never pass them as an argument and never put them in the URL. Set `JOLOKIA_USER` plus `JOLOKIA_PASSWORD`, or `JOLOKIA_USER` plus `JOLOKIA_PASSWORD_CMD` (a command whose stdout is the password).

**Safety rules that the script enforces:**

- It sends only `read` requests, never `write`, `exec` or `search`.
- A bulk request answers HTTP 200 even when single items fail (403 from the Jolokia access policy, see [jolokia.md](jolokia.md); 404 for an unknown MBean). Jolokia 2.6.3 answers HTTP 200 with `"status":403` even for a single denied request (measured 2026-11-15 on Temurin 21.0.13 and 25.0.5, in a container). For that reason, the script checks the `status` of every item. One failed item stops the run with exit 1 and names the MBean and the attribute.
- It refuses `user:pass@host` in the URL.
- It refuses HTTP Basic over plain `http://` to a non-loopback host unless you pass `--insecure-http`.
- It never follows redirects, because the `Authorization` header would travel with them. It also ignores proxy settings, because a proxy would see the credentials.
- It creates the output file with mode 0600 and tightens an existing file to 0600.
- In CSV mode, it stops with exit 1 if the set of columns changes between samples.
- In CSV mode with `--out FILE`, when the file exists and is not empty, it compares the first line of the file with the new header. It exits with code 2 when the header differs, and it writes no second header when the header matches.

| Exit code | Meaning |
|---|---|
| 0 | All requested samples written. |
| 1 | A sample failed (the message names the item and how many samples were written before). |
| 2 | Usage error, including incomplete credentials, a refused URL, or an existing CSV file with a different header. |
| 130 / 143 | Stopped by SIGINT / SIGTERM. The samples so far stay in the file. |

The output can hold secrets: system properties, JVM arguments, and the Spring environment MBean (`org.springframework.boot:type=Endpoint,name=Env`). Treat the file like a heap dump ([heap-dumps.md](heap-dumps.md)).

To start a Jolokia agent safely (loopback, read-only policy), see [jolokia.md](jolokia.md). In a pod, the loopback bind alone does not protect the agent. A connection through `kubectl port-forward` arrives from `127.0.0.1`, and a Jolokia 2.6.3 agent without a policy file answered reads through it without authentication (measured 2026-11-15 on OrbStack Kubernetes). OrbStack is a local Docker and Kubernetes runtime for macOS; its port-forward details are in [orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md) of the `jvm-remote-debug` skill.

### Alternatives without Jolokia

All of these run on the same host as the JVM.

- **`jcmd <pid> PerfCounter.print`** prints the internal performance counters of the JVM. It needs no JMX port. It works (measured 2026-11, JDK 25).
- **A JFR recording, then JSON.** JFR creates its files with mode 0644, and a recording holds JVM arguments and system properties. For that reason, write into a 0700 directory, not into the shared `/tmp`:

  ```bash
  mkdir -p /var/tmp/jfr && chmod 700 /var/tmp/jfr
  jcmd <pid> JFR.start duration=60s filename=/var/tmp/jfr/m.jfr
  jfr print --json --events jdk.CPULoad,jdk.GCHeapSummary /var/tmp/jfr/m.jfr > /var/tmp/jfr/m.json
  ```

  Filter with `--events`, because an unfiltered print is very large. Starting a recording changes the JVM. In a pod, start one only on the user's request. Never start one on a JetBrains Runtime JVM that you hot-swap, because a running recording turns enhanced class redefinition off (see [jfr.md](jfr.md)). Enhanced class redefinition is the JetBrains Runtime mode (`-XX:+AllowEnhancedClassRedefinition`) that lets a hot swap also add fields and methods. HotswapAgent uses it; see [spring-boot-repl/SKILL.md](../../spring-boot-repl/SKILL.md), Rule 1. This exact pipeline was not measured for this page.
- **`jdk.jfr.consumer.EventStream.openRepository(Path)`** reads the JFR repository of another JVM, as long as the repository is on the same file system. The JFR repository is the directory where a running disk recording writes its chunk files. By default it is a new directory below `java.io.tmpdir`; set it with `-XX:FlightRecorderOptions=repository=<dir>` (see the glossary in [jfr.md](jfr.md)). The class exists in the JDK (checked 2026-11, JDK 25). A full stream was not measured.
- **`jdk.management.jfr.RemoteRecordingStream`** streams JFR events from another JVM over a JMX connection (module `jdk.management.jfr`). The class exists (checked 2026-11, JDK 25). It was not measured end to end.
- **`ProcessRecordingStream` does not exist.** `javap` on JDK 25 finds no such class, although it is sometimes cited.

**Timestamps in shell loops.** BSD `date` (macOS) has no `--iso-8601`. Use `date -u +%Y-%m-%dT%H:%M:%SZ`, which works with both BSD and GNU `date`, or use perl.

### Which tool when

| Need | Tool |
|---|---|
| One value, now, over RMI | [`scripts/jmx.sh`](../scripts/jmx.sh) (see [jmx.md](jmx.md)) |
| A series of values over HTTP into a file | [`scripts/jmx-sample.py`](../scripts/jmx-sample.py) |
| Same host, no port open | `jcmd <pid> PerfCounter.print` or a JFR recording |
| Events with stack traces | JFR, see [jfr.md](jfr.md) |

## Part 2: continuous export (not measured)

**Status: not measured by this skill's author.** Check each property name against the documentation of the version that you install.

- **Prometheus jmx_exporter** (https://github.com/prometheus/jmx_exporter) runs as a Java agent: `-javaagent:<jar>=<port>:<config.yaml>`. The YAML rules select MBeans and turn them into metrics.
- **OpenTelemetry (OTel) Java agent** (https://github.com/open-telemetry/opentelemetry-java-instrumentation, JMX metrics instrumentation): `otel.jmx.target.system` selects built-in MBean sets, and `otel.jmx.config` points to your own YAML rules. The agent turns JVM runtime metrics on by default, so adding `jvm` to the target systems duplicates them. The agent can also collect runtime metrics from JFR events. The property names for that differ between agent versions, so look them up in the documentation of the agent that you install. An agent configured with `OTEL_METRICS_EXPORTER=none` exports no metrics at all, which is a deliberate choice when volume matters.
- **Micrometer** is the usual way to publish application metrics in Spring Boot (exposed through Actuator, see [actuator.md](actuator.md)).

Rules for any of them:

- List only the MBeans that you need. In a shared cluster, never use a jmx_exporter rule with `pattern: ".*"`, because that regular expression matches every MBean attribute, so the exporter exports all of them.
- Do not use unbounded label values: pod name, thread name, session ID, URL.
- Do not export the same metric through Micrometer, the JMX metrics instrumentation of the OTel Java agent, and jmx_exporter at once.

This page does not cover capturing full HTTP request and response bodies (for example with mitmproxy running as a reverse proxy in front of the app), or OpenTelemetry logs. Both are possible. For traces, see [otel.md](otel.md).
