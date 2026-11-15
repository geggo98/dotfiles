Applies to: container/Kubernetes

# Hot swap in a pod: what the pod needs

**TL;DR:** A pod that runs JetBrains Runtime (JBR) with HotswapAgent, nREPL
and Arthas needs memory for the startup peak (3 Gi worked), no JFR, an
`emptyDir` for new classes, the Arthas password from a mounted Secret with
`arthas.localConnectionNonAuth=false`, and loopback-only debug ports reached
through port-forward. Such a pod cannot also start from a CRaC (Coordinated
Restore at Checkpoint) image.

HotswapAgent is a Java agent that reloads changed classes and refreshes
framework state, such as Spring beans
([setup](../../spring-boot-repl/references/setup.md)). nREPL is a network
REPL for Clojure, embedded in the application's JVM
([setup](../../spring-boot-repl/references/setup.md#embedding-nrepl-in-the-boot-process)).
Arthas is Alibaba's diagnostic tool that attaches to a running JVM
([arthas](../../spring-boot-repl/references/arthas.md)). The startup peak
is the highest memory use of the container, against its limit, while the
JVM loads classes and agents during start.

This page covers only the pod side. The `spring-boot-repl` skill covers
the rest: the JVM flags and
`hotswap-agent.properties` in
[setup](../../spring-boot-repl/references/setup.md), the redefine procedure
in [redefine](../../spring-boot-repl/references/redefine.md), and Arthas
usage in [arthas](../../spring-boot-repl/references/arthas.md).

Measured 2026-10 and 2026-11 on JBR 25, HotswapAgent 2.0.3, nREPL, Arthas
4.3.4 and Spring Boot 4, in local Kubernetes on macOS arm64, unless a line
says otherwise. The Kubernetes distribution of these runs is not recorded.
Lines that name OrbStack were measured on OrbStack Kubernetes; OrbStack is a
local container and Kubernetes runtime for macOS (see
[orbstack-telepresence](orbstack-telepresence.md)).

## Requirements

| Topic | Requirement | Why |
|---|---|---|
| Memory | A limit that covers the startup peak; **3 Gi** worked | With JFR and the OpenTelemetry agent also in the JVM, a 2 Gi limit was OOMKilled repeatedly in the startup peak. 3 Gi worked. A 2 Gi limit without JFR was not measured. |
| Class loaders | `excludedClassLoaderPatterns` (a key in `hotswap-agent.properties`) for Clojure and Arthas loaders | Without it a service with nREPL and Clojure ran into metaspace growth and OOMKilled at 3 Gi. The properties template is in [setup](../../spring-boot-repl/references/setup.md). |
| JFR | No JFR recording in this JVM | A running recording turns `-XX:+AllowEnhancedClassRedefinition` off, and every structural change then fails. A structural change adds or removes a method, field or superclass, or changes a signature; a change to a method body only is not structural. Check with `env -u JAVA_TOOL_OPTIONS jcmd 1 VM.flags`, where `1` is the application JVM as the container's main process. Without `env -u`, `jcmd` inherits the application's agents and flags from `JAVA_TOOL_OPTIONS` (see [arthas](../../spring-boot-repl/references/arthas.md#attach)). Do not check with `JFR.check`, because it starts the JFR subsystem itself (measured 2026-11-15 on Temurin 17, 21 and 25, in a container; whether that also turns the flag off on JBR was not measured). See [redefine](../../spring-boot-repl/references/redefine.md). |
| Rollout | `strategy: Recreate`, or memory for two pods | During a rolling update the old and the new pod run side by side, both with the full startup peak. |
| New classes | An `emptyDir` mounted at the directory named by `extraClasspath` in `hotswap-agent.properties` | HotswapAgent loads new classes from there. An initContainer must create the directory tree of the application's root package (for example `com/example/app`) before the JVM starts, or HotswapAgent's file watcher never sees it. A pod restart clears the directory. A container restart keeps it. |
| Arthas password | A Secret mounted as a file, or `secretKeyRef` | Never a plain `env:` value and never text in the pod spec, because both are visible in the pod spec. Put a hash of the secret into a pod annotation, for example `example.com/arthas-pw-hash: <sha256>`, so that a new password rolls the pods. The shipped `arthas.properties`, the default configuration file at the top level of the unpacked Arthas distribution `arthas-bin` (where to get `arthas-bin.zip`: [arthas](../../spring-boot-repl/references/arthas.md#get-it)), sets `arthas.localConnectionNonAuth=true`. Then a request from `127.0.0.1` without any password gets HTTP 200 and runs commands, so the password only stops non-loopback clients. A port-forwarded request arrives as loopback. Through `kubectl port-forward` to the Arthas HTTP port 8563, the HTTP command endpoint `/api` ran `version` without credentials with HTTP 200, and the MCP (Model Context Protocol) endpoint `/mcp` answered `initialize`, the first request of the MCP handshake, with HTTP 200, so an unauthenticated client could open an MCP session (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward). [arthas](../../spring-boot-repl/references/arthas.md#run-commands-over-http) describes both endpoints. Anyone who can port-forward to the pod therefore uses Arthas without a password. Set the property to `false` in that `arthas.properties` before the attach (see [arthas](../../spring-boot-repl/references/arthas.md#attach)). With `false`, the same forwarded requests got 401 without credentials, 401 with a wrong password and 200 with the right one, and `/mcp` got 401 without credentials (same measurement). Never pass an empty password, and never leave `--password` out. With `--username`, authentication stays on with a password nobody knows: no client can log in with a password, and with `false` not even `stop` gets through. `stop` is the Arthas command that shuts down the Arthas server in the JVM ([arthas](../../spring-boot-repl/references/arthas.md#commands-that-instrument-or-change-classes)); without it, only a JVM restart removes Arthas. Without `--username`, authentication is off, even with `false`. Guard the attach command (`java -jar arthas-boot.jar --attach-only ...`, shown in [arthas](../../spring-boot-repl/references/arthas.md#attach)) with `[ -s <pw-file> ] &&`, where `<pw-file>` is the password file that the mounted Secret provides. Measured 2026-11-15 on Arthas 4.3.4, Temurin 21 and 25, in a container, unless stated otherwise. |
| Second Arthas in the pod | A free telnet port of its own, for example `--telnet-port 3659` | A second Arthas runs when, for example, Arthas is attached to the JVM of another container in the same pod while the first Arthas still runs in the app container. All containers of a pod share one network namespace, so the second Arthas cannot take the default telnet port 3658. `--telnet-port -1` is no way out. `--attach-only` makes `arthas-boot` (the launcher JAR) attach without starting its interactive telnet client (see [arthas](../../spring-boot-repl/references/arthas.md#attach)), and with it arthas-boot 4.3.4 fails before the attach with `port out of range:-1` and exit 1 (measured 2026-11-15 with `kubectl exec` in a pod on OrbStack Kubernetes). |
| Exposure | No Ingress, NodePort or LoadBalancer for nREPL, JDWP or Arthas | All three run code in the JVM. nREPL and JDWP have no authentication. |
| Redefine tool (`jdb redefine` or `spring-boot-repl`'s [`scripts/Redefine.java`](../../spring-boot-repl/scripts/Redefine.java)) | Reaches JDWP through `kubectl port-forward` | JDWP listens on `127.0.0.1:5005`, which other pods cannot reach. A host jdb attached to such a JDWP port through port-forward (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward). See [jmx-jolokia-ports](jmx-jolokia-ports.md). |
| CRaC | Not together with hot swap | A checkpoint refuses open listener sockets, such as Arthas or nREPL (a plain `ServerSocket` and Jolokia, the JMX-over-HTTP agent from [jmx-jolokia-ports](jmx-jolokia-ports.md), were measured; these two were not). A restore aborts on a flag from `JAVA_TOOL_OPTIONS` that the CRaC JDK does not allow to change at restore time (measured 2026-11-15, Zulu 25.0.5 CRaC, in a container). See `java-debug`, [crac, section 4 "Debug agents and CRaC"](../../java-debug/references/crac.md#4-debug-agents-and-crac). |

A broken class in the `extraClasspath` directory can stop the next start
of the container (`CrashLoopBackOff`), because an `emptyDir` survives a container
restart. Delete the pod to clear it.

## Swap without downtime: readiness probe and preStop

When hot swap is not enough and the pod must be replaced, two settings
decide whether requests fail during the swap. Measured 2026-08 on a
Spring Boot service in local Kubernetes on macOS arm64 (distribution not
recorded):

1. **A real readiness probe.** Without a probe, Kubernetes reports the pod
   ready as soon as the process runs: 2.0 s after start, while the first
   real answer came after 11.2 s. A rolling update then removes the old pod
   too early. Point an HTTP readiness probe at a real health path, for
   example `/actuator/health/readiness`.
2. **A `preStop` sleep.** Kubernetes removes the pod from the endpoints and
   sends SIGTERM at the same time, and an ingress controller still routes
   to the old pod for a moment. Without a hook, 12 requests failed with 502
   within about 600 ms, even with `maxUnavailable: 0`. A `preStop` of
   `sleep 5` avoided them.

```yaml
readinessProbe:
  httpGet: { path: /actuator/health/readiness, port: 8080 }
lifecycle:
  preStop:
    exec: { command: ["sleep", "5"] }
```

`sleep` must exist in the image. `terminationGracePeriodSeconds` must be
longer than the sleep plus the app's own shutdown time. Otherwise the
container gets a SIGKILL before the JVM has stopped, and it ends with exit
137 (see [wiring](wiring.md)).

## Related

- `spring-boot-repl`: [setup](../../spring-boot-repl/references/setup.md)
  (flags, properties, `extraClasspath`),
  [redefine](../../spring-boot-repl/references/redefine.md) (procedure and
  pitfalls), [arthas](../../spring-boot-repl/references/arthas.md)
  (attach, password, read-only commands).
- [wiring](wiring.md): agents via initContainer, OOMKilled vs
  OutOfMemoryError.
