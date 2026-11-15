Applies to: local JVMs, containers and Kubernetes pods alike.

# Jolokia — Safe Start and a Read-Only Access Policy

**TL;DR:** Start the Jolokia agent (an HTTP+JSON bridge to JMX) on loopback with a policy file. The policy only becomes a real whitelist when `<commands>` grants nothing but `version`, `list` and `search`, and every readable attribute and operation is listed under `<allow>`. Measured 2026-11 on Jolokia 2.6.3 and re-measured 2026-11-15 on Temurin 21.0.13 and 25.0.5, in a container: with `read` and `exec` in `<commands>`, `<allow>` did not restrict any read or exec. A denial comes back as HTTP 200 with `"status":403` in the JSON body, so check that field. Prove the policy with negative tests against a throwaway JVM after every upgrade. The loopback bind does not replace the policy in a pod: a connection through `kubectl port-forward` arrives from `127.0.0.1`, and an agent without a policy answered it without authentication (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward). OrbStack is a local Docker and Kubernetes runtime for macOS; its port-forward details are in [orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md) of the `jvm-remote-debug` skill.

## Contents

- [1. Safe start](#1-safe-start)
- [2. Policy semantics (measured)](#2-policy-semantics-measured)
- [3. Template: read-only policy](#3-template-read-only-policy)
- [4. What stays closed](#4-what-stays-closed)
- [5. Negative tests](#5-negative-tests)
- [6. Reading values in a series](#6-reading-values-in-a-series)

The Jolokia basics (request types, `curl` examples) are in [jmx.md](jmx.md) §4.

## 1. Safe start

```bash
java -javaagent:/path/jolokia-agent-jvm-<version>-javaagent.jar=host=127.0.0.1,port=8778,discoveryEnabled=false,policyLocation=file:///path/jolokia-access.xml \
  -jar app.jar
```

- The JAR is the Maven artifact `org.jolokia:jolokia-agent-jvm` with classifier `javaagent`.
- `host=127.0.0.1` binds to loopback. Reach it from another machine through an SSH tunnel or `kubectl port-forward`. Port-forward works with this bind: the forwarded connection arrives as an IPv4 loopback connection from `127.0.0.1`, and the agent cannot tell it apart from a local one. Keep the IPv4 address. Port-forward did not reach a listener bound only to `::1`, because the container runtime connects with IPv4 only. On OrbStack's Docker runtime the forward runs through `socat` on the runtime side, and its error text names the target `TCP4:localhost:<port>` (details in [orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md)). Both results were measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward (Kubernetes 1.36.5, Docker runtime). containerd and CRI-O implement port-forward differently, and their behaviour was not measured.
- `discoveryEnabled=false` stops the agent from answering multicast discovery.
- `policyLocation=file:///...` loads the access policy. Without a policy, every request type is allowed, including `exec` and `write`. The agent then logs `No access restrictor found, access to any MBean is allowed`, and Jolokia 2.6.3 answered a read through port-forward without authentication (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward). Check that the policy loaded: the agent log prints `I> Using policy access restrictor file:///...` with your file.
- A wide bind (`host=0.0.0.0`) belongs only in a single-user dev setup with network isolation. The preconditions are in `jvm-remote-debug` (file `references/jmx-jolokia-ports.md`). In a shared cluster every pod can reach a ClusterIP or a pod IP, so "only cluster-internal" is no protection: the policy is then the only guard.

Check the Jolokia release page (https://jolokia.org) for the current agent version. The facts below were measured on 2.6.3.

## 2. Policy semantics (measured)

Measured 2026-11 on Jolokia 2.6.3, in a throwaway JVM and in a Kubernetes pod running a Spring Boot app. Re-measured 2026-11-15 with Jolokia 2.6.3 on Temurin 21.0.13 and 25.0.5, in a container, with identical results on both JDKs. Re-run the negative tests (§5) after any upgrade.

- **A denial is HTTP 200.** Every denied request, over POST and GET, answered HTTP 200 with `"status":403` and an `error` such as `Writing attribute Verbose forbidden for MBean java.lang:type=Memory` in the JSON body. A check that reads only the HTTP status misses every denial.
- **`<commands>` grants commands globally.** A command listed there is allowed for every MBean. With only `exec` listed, every read tested returned 403; with only `read` listed, `write` and `exec` returned 403.
- **`<allow>` adds grants per MBean. It is not a whitelist for the commands in `<commands>`.** With `read` and `exec` in `<commands>`, an `exec` of `java.lang:type=Memory` operation `gc` and a read of `HeapMemoryUsage` both succeeded, although `<allow>` listed neither. A `write` on `java.lang:type=Memory` attribute `Verbose` returned 403, because `write` was not in `<commands>` and `<allow>` did not match. This matches the [Jolokia manual, security chapter](https://jolokia.org/reference/html/manual/security.html) and the 2.6.3 class [`org.jolokia.server.core.restrictor.policy.MBeanAccessChecker`](https://github.com/jolokia/jolokia/blob/v2.6.3/server/core/src/main/java/org/jolokia/server/core/restrictor/policy/MBeanAccessChecker.java). In one 2026-11 run this write returned status 200; that did not reproduce, and the cause was not found. If this write returns status 200, check for one of the two setups that allow it: a policy without `<commands>` (next point) and a policy that did not load (§1).
- **A policy without a `<commands>` element restricts nothing.** With only an `<allow>` section, `read`, `write` and `exec` all succeeded (measured 2026-11-15 on Temurin 25.0.5).
- **`<allow>` grants a command that `<commands>` lacks, for that MBean and operation.** With `<commands>` holding only `read`, an `<allow>` entry with `<operation>gc</operation>` on `java.lang:type=Memory` allowed that `exec`; operations on `java.lang:type=Threading` stayed 403. Other operations on the same MBean were not tested.
- **`mode="read"` only works while `write` is not in `<commands>`.** With `<commands>` holding `version` or `read`, an attribute listed with `mode="read"` is readable and a write returns 403. With `write` in `<commands>`, the write succeeds despite `mode="read"`. An `<allow>` attribute without a mode grants both read and write. To block a write while `write` stays in `<commands>`, use `<deny>`.
- **`<deny>` is the reverse of `<allow>`:** it rejects the listed attributes and operations even when `<commands>` grants the command (measured for attributes only). A `<deny>` on an attribute blocks both its read and its write; other attributes of the same MBean stay readable. Gotcha: a read of the whole MBean (no attribute given) then fails completely with 403; it does not leave out the denied attribute. The same happens when `<allow>` lists only some attributes.
- **A real whitelist** needs two parts: `<commands>` with only `version`, `list` and `search`, and every allowed attribute and operation listed under `<allow>`. Everything else then returns 403.
- **One `<mbean>` entry per MBean name.** A second entry for the same name overwrites the first; it does not merge. Measured: with an attribute grant in the first entry and an operation grant in the second, only the operation worked, and the other way round only the attribute.
- **Operation names carry the signature.** Write `dumpAllThreads*` to match all overloads. `dumpAllThreads` is overloaded, so a request must name the signature: `dumpAllThreads(boolean,boolean)`. Measured: `<operation>dumpAllThreads*</operation>` allowed that request; `<operation>dumpAllThreads</operation>` without the star returned 403.
- **XML-escape names.** MBean names with quotes, `&` or `<` must be escaped in the XML.

**Spring Boot side note.** When you open an Actuator endpoint for Jolokia or JMX and the app's own config already sets `management.endpoint.env.enabled`, use `management.endpoint.env.enabled=true`, not `management.endpoint.env.access`. Setting `management.endpoint.env.access` next to an existing `management.endpoint.env.enabled` is "mutually exclusive" and stops the app at startup (measured 2026-11, Spring Boot 4). More in [actuator.md](actuator.md) §3.1.

## 3. Template: read-only policy

Copy this, remove what you do not need, and keep one `<mbean>` per name, because a second entry for the same name overwrites the first (§2).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Read-only Jolokia policy (template).
  Rule: <commands> holds ONLY version/list/search. Every readable attribute
  and every allowed operation is listed under <allow>. Anything not listed
  answers 403. Verified semantics: Jolokia 2.6.3 (measured 2026-11,
  re-measured 2026-11-15 on Temurin 21 and 25).
  mode="read" on each attribute: without it, an <allow> attribute entry
  also permits writes (measured). mode="read" only blocks writes while
  "write" is not in <commands>.
  Re-run the negative tests after every upgrade.
-->
<restrict>

  <!-- Global commands: nothing that reads values, writes or executes. -->
  <commands>
    <command>version</command>
    <command>list</command>
    <command>search</command>
  </commands>

  <allow>
    <!-- Heap and non-heap usage. Not "Verbose": that one is writable. -->
    <mbean>
      <name>java.lang:type=Memory</name>
      <attribute mode="read">HeapMemoryUsage</attribute>
      <attribute mode="read">NonHeapMemoryUsage</attribute>
      <attribute mode="read">ObjectPendingFinalizationCount</attribute>
    </mbean>

    <!-- All memory pools (wildcard in the name). -->
    <mbean>
      <name>java.lang:type=MemoryPool,*</name>
      <attribute mode="read">Usage</attribute>
      <attribute mode="read">PeakUsage</attribute>
      <attribute mode="read">CollectionUsage</attribute>
      <attribute mode="read">Name</attribute>
    </mbean>

    <!-- All collectors. -->
    <mbean>
      <name>java.lang:type=GarbageCollector,*</name>
      <attribute mode="read">CollectionCount</attribute>
      <attribute mode="read">CollectionTime</attribute>
      <attribute mode="read">LastGcInfo</attribute>
      <attribute mode="read">Name</attribute>
    </mbean>

    <mbean>
      <name>java.lang:type=ClassLoading</name>
      <attribute mode="read">LoadedClassCount</attribute>
      <attribute mode="read">UnloadedClassCount</attribute>
      <attribute mode="read">TotalLoadedClassCount</attribute>
    </mbean>

    <!-- Runtime: selected attributes only. NOT SystemProperties, NOT
         InputArguments: both can hold passwords and tokens. -->
    <mbean>
      <name>java.lang:type=Runtime</name>
      <attribute mode="read">Uptime</attribute>
      <attribute mode="read">StartTime</attribute>
      <attribute mode="read">VmName</attribute>
      <attribute mode="read">VmVersion</attribute>
    </mbean>

    <mbean>
      <name>java.lang:type=OperatingSystem</name>
      <attribute mode="read">ProcessCpuLoad</attribute>
      <attribute mode="read">SystemLoadAverage</attribute>
      <attribute mode="read">AvailableProcessors</attribute>
      <attribute mode="read">OpenFileDescriptorCount</attribute>
      <attribute mode="read">MaxFileDescriptorCount</attribute>
    </mbean>

    <!-- Threads, including a read-only thread dump. The operation name
         carries the signature; the request must send dumpAllThreads(boolean,boolean). -->
    <mbean>
      <name>java.lang:type=Threading</name>
      <attribute mode="read">ThreadCount</attribute>
      <attribute mode="read">DaemonThreadCount</attribute>
      <attribute mode="read">PeakThreadCount</attribute>
      <attribute mode="read">TotalStartedThreadCount</attribute>
      <operation>dumpAllThreads*</operation>
      <operation>findDeadlockedThreads*</operation>
    </mbean>
  </allow>

</restrict>
```

`mode="read"` and the `dumpAllThreads*` wildcard were measured on 2.6.3 (§2). Two parts of this template go beyond what was measured: the `findDeadlockedThreads*` grant (a read-only operation; `dumpAllThreads*` does not cover it, it returned 403) and the `*` wildcards in MBean names (documented in the [Jolokia manual, section "Allow and deny access to certain MBeans"](https://jolokia.org/reference/html/manual/security.html#_allow_and_deny_access_to_certain_mbeans), not tested). Both only narrow or keep read access; the negative tests in §5 show whether they behave as intended on your version.

## 4. What stays closed

Do not add any of these to `<allow>`:

| MBean or endpoint | Why it stays closed |
|---|---|
| `com.sun.management:type=DiagnosticCommand` | Runs any `jcmd` command, including agent loading and flag changes. |
| `com.sun.management:type=HotSpotDiagnostic` | `dumpHeap` writes a heap dump: a stop-the-world pause, a large file, and every secret in memory. Also sets VM flags. |
| `jdk.management.jfr:type=FlightRecorder` | Starts recordings and writes files; on JetBrains Runtime a recording turns off enhanced class redefinition (the mode that also allows new fields and methods, used by HotswapAgent); see [spring-boot-repl/SKILL.md](../../spring-boot-repl/SKILL.md), Rule 1. |
| Any MBean of class `javax.management.loading.MLet` (the ObjectName is chosen by whoever registers it) | Loads classes from a URL: remote code execution. The class is deprecated for removal since JDK 20 and no longer in the JDK 23 API documentation (removal release not verified), so this matters on older JDKs. |
| Spring Boot `org.springframework.boot:type=Endpoint,name=Shutdown`, `…name=Heapdump`, `…name=Logfile` | Stop the app, dump the heap, read logs with secrets. |
| `java.lang:type=Runtime` `SystemProperties`, `InputArguments` | Hold passwords, tokens and keys passed as `-D` or in `JAVA_TOOL_OPTIONS`. |
| `java.lang:type=Memory` operation `gc`, attribute `Verbose` (write) | Forces a full GC; changes JVM logging. |

## 5. Negative tests

Run these **only against a throwaway JVM**, because a probe that the policy fails to block really runs: test 3 then writes a heap dump that holds every secret of that JVM. Start it without `-verbose:gc`, with the same agent version and the same policy file as the real one. Read the `status` field of the JSON body, not the HTTP status line, because a denial answers HTTP 200 with `"status":403` (measured 2026-11-15, Jolokia 2.6.3, §2).

```bash
J=http://127.0.0.1:8778/jolokia/
post() { curl -s -H 'Content-Type: application/json' -d "$1" "$J" | jq '.status, .error'; }

# 1. Write probe. In a JVM started without -verbose:gc, Memory.Verbose is
#    false, so writing false back changes nothing even if it were allowed.
#    Do not use "exec gc" as a probe: that forces a full GC when it works.
post '{"type":"write","mbean":"java.lang:type=Memory","attribute":"Verbose","value":false}'   # expect 403

# 2. Exec on DiagnosticCommand (vmVersion only prints the version)
post '{"type":"exec","mbean":"com.sun.management:type=DiagnosticCommand","operation":"vmVersion"}'   # expect 403

# 3. Heap dump (403 means nothing was written)
post '{"type":"exec","mbean":"com.sun.management:type=HotSpotDiagnostic","operation":"dumpHeap","arguments":["/tmp/probe.hprof",true]}'   # expect 403

# 4. Positive control: an allowed read must work
post '{"type":"read","mbean":"java.lang:type=Memory","attribute":"HeapMemoryUsage"}'   # expect 200

# 5. Allowed thread dump with the signature
post '{"type":"exec","mbean":"java.lang:type=Threading","operation":"dumpAllThreads(boolean,boolean)","arguments":[false,false]}'   # expect 200
```

If any of tests 1 to 3 shows `status` 200, the policy is not a whitelist: check `<commands>` first, and check that the policy loaded (§1). If test 3 answered 200, delete `/tmp/probe.hprof` at once; it holds every secret of that JVM.

The measured results in §2 came from requests of this kind. On 2026-11-15 the JSON bodies of tests 1, 4 and 5 were sent as HTTP POST requests from a small throwaway Java program, not with `curl`. The program was not kept. It only POSTed the same JSON bodies with `Content-Type: application/json` to the same URL, so the `curl` commands above send the same requests. Tests 2 and 3 were not run.

## 6. Reading values in a series

To write a time series of allowed attributes into a JSONL or CSV file, use [`scripts/jmx-sample.py`](../scripts/jmx-sample.py) in the `java-debug` skill directory. It sends only `read` requests and stops on the first item that answers 403 or 404, so a too-strict policy shows up at once. Details in [metrics-export.md](metrics-export.md).

For a JVM in a pod (agent via initContainer, port-forward, policy file in an `emptyDir`), load `jvm-remote-debug` (files `references/wiring.md` and `references/jmx-jolokia-ports.md`). Forward the Jolokia port in its own `kubectl port-forward` process when another port in the same forward can refuse: one refused connection ends the whole process (`error: lost connection to pod`), with every port that it forwards (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward).

