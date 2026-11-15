Applies to: container/Kubernetes

# JMX, JDWP and Jolokia ports in a pod

**TL;DR:** Bind every debug listener to `127.0.0.1` and reach it with
`kubectl port-forward`. This applies to JMX, JDWP and Jolokia (a Java
agent that serves JMX over HTTP and JSON). Other pods cannot reach such a listener, and
port-forward can, because a forwarded connection arrives in the pod over
IPv4 loopback. For JMX, set `java.rmi.server.hostname=127.0.0.1` and
`jmxremote.port == jmxremote.rmi.port`. The hostname decides which access
works: with a service DNS name as hostname, port-forward fails. JDWP, nREPL
(the Clojure network REPL from the
[spring-boot-repl](../../spring-boot-repl/SKILL.md) skill) and
unauthenticated JMX are remote code execution.

## Contents

- [JMX over RMI: one port, two modes](#jmx-over-rmi-one-port-two-modes)
- [JDWP](#jdwp)
- [Jolokia](#jolokia)
- [What port-forward reaches](#what-port-forward-reaches)
- [Wide variants (labelled)](#wide-variants-labelled)
- [JMX and Spring Boot Actuator](#jmx-and-spring-boot-actuator)
- [Debug listeners and CRaC](#debug-listeners-and-crac)

## JMX over RMI: one port, two modes

JMX over RMI uses two ports: the RMI registry (`jmxremote.port`) and the RMI
server for the connection itself (`jmxremote.rmi.port`). If you set only the
first, the JVM picks a random second port, which no port-forward and no
Service covers. Always set both to the same value.

The registry answers with a stub that carries `java.rmi.server.hostname`.
The client then connects to exactly that host name. This setting therefore
decides the access mode:

| Mode | `java.rmi.server.hostname` | Client connects to | Needs |
|---|---|---|---|
| **port-forward mode, preferred** | `127.0.0.1` | `127.0.0.1:<p>` on the workstation | `kubectl port-forward pod/<pod> <p>:<p>`, same port number on both sides |
| direct mode | a name the client resolves, for example `<svc>.<ns>.svc.cluster.local` | that name | a Service with the JMX port, and a workstation that can route to the cluster network (for example OrbStack, a local Docker and Kubernetes VM on macOS, see [orbstack-telepresence](orbstack-telepresence.md)) |

With a service FQDN as hostname, port-forward does NOT work. The stub sends
the client to the FQDN, not to the forwarded local port.

Port-forward mode is the standard setup, because it exposes no
unauthenticated port to other pods. It works: a host JMX client read
`java.lang:type=Runtime` `Uptime` through `kubectl port-forward` on port
5000 and on port 9010, with exactly the settings below (measured 2026-11-15
on OrbStack Kubernetes with kubectl port-forward, Temurin 21.0.13 in the
pod). Direct mode was used on a local cluster, where the first connection
took about 5 s (observed once, cause not determined; cluster, date and JDK
not recorded). `java-debug`,
[jmx](../../java-debug/references/jmx.md), records a first connection of
about 5 s through port-forward on OrbStack Kubernetes on 2026-11-15, and
advises waiting at least 10 s before treating a first connection as a hang.

Port-forward mode, loopback only:

```bash
JAVA_TOOL_OPTIONS="\
 -Dcom.sun.management.jmxremote.port=9010 \
 -Dcom.sun.management.jmxremote.rmi.port=9010 \
 -Dcom.sun.management.jmxremote.host=127.0.0.1 \
 -Djava.rmi.server.hostname=127.0.0.1 \
 -Dcom.sun.management.jmxremote.authenticate=false \
 -Dcom.sun.management.jmxremote.ssl=false"
```

`jmxremote.host` binds the listener to loopback. Without it, the port
listens on all interfaces even though the stub says `127.0.0.1` (the
property exists since JDK 8u102 / 9, per the
[8u102 release notes](https://www.oracle.com/java/technologies/javase/8u102-relnotes.html);
the bind without it was not measured for this skill). Check the bind address inside the
container with `ss -ltn` or `netstat -ltn` if the image has one.

`jmxremote.host` does not keep every RMI listener of the JVM on loopback.
A JVM started with `jmxremote.host=127.0.0.1` still held a listener on an
ephemeral port bound to `[::]` (all interfaces), owned by the thread
`RMI TCP Accept-0` (measured 2026-11-15 on OrbStack Kubernetes with kubectl
port-forward). It
is probably the JDK's local JMX connector, which the JVM opens for attach
tools on the same host (jconsole by PID, `jcmd <pid>
ManagementAgent.start_local`). That connector rejects non-local clients only after it has accepted the
connection (inference, not measured).

On the workstation:

```bash
kubectl port-forward -n <ns> pod/<pod> 9010:9010
jconsole service:jmx:rmi:///jndi/rmi://127.0.0.1:9010/jmxrmi
```

On a Mac, keep 9010 and do not use 5000 or 7000 as the local port.
ControlCenter (the AirPlay Receiver) listens on `*:5000` and `*:7000`, over
IPv4 and IPv6. While the forward runs, kubectl's more specific
`127.0.0.1:5000` bind wins and the pod answers. After the forward dies, the
same JMX client connects to ControlCenter and hangs without an error
message: `gtimeout 20` killed it with exit 124 (measured 2026-11-15 on
OrbStack Kubernetes with kubectl port-forward). `gtimeout` is GNU `timeout`
under its macOS name from Homebrew or Nix, and 124 is its exit code when the
time limit expires.

JDK Mission Control (see `java-debug`, [jmc](../../java-debug/references/jmc.md)),
VisualVM and jmxterm take the same URL. More on flags and clients:
`java-debug`, [jmx](../../java-debug/references/jmx.md).

## JDWP

```bash
-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005
```

```bash
kubectl port-forward -n <ns> pod/<pod> 5005:5005
jdb -attach 127.0.0.1:5005
```

This setup works through port-forward. A host jdb from JDK 25 attached
through `15005:5005` to a JDK 21 target, and `version` and `threads`
worked (measured 2026-11-15 on OrbStack Kubernetes with kubectl
port-forward).

Measured 2026-11-15 on Temurin 11, 17 and 25, in a container:

- `address=5005` without a host also binds loopback only, but IPv4 only:
  `127.0.0.1:5005`, not `::1`. A client that tries only `::1` is refused.
  `localhost` works only because Java falls back to `127.0.0.1`. Write
  `127.0.0.1` on both sides.
- Use a fixed port. With a fixed port, attach, detach and attach again
  works. With `address=127.0.0.1:0`, the agent listens on a NEW random port
  after every detach, prints a new `Listening for transport dt_socket at
  address: <n>` line, and refuses the old port. A port-forward to the old
  port then stops working (`kubectl port-forward` itself was not tested
  with this case).

JDWP has no authentication. Whoever reaches the port can run any code in the
JVM. `suspend=y` makes the pod wait for a debugger at startup, and the
liveness probe may kill the pod meanwhile. Use `suspend=n` in a pod.

A helper JVM is any second JVM that starts in the same container, for
example `jcmd`, `arthas-boot` or a `java -version` check. It also reads
`JAVA_TOOL_OPTIONS`. Put the JDWP flag into `JAVA_TOOL_OPTIONS` only if you
also start helper JVMs with `env -u JAVA_TOOL_OPTIONS`. Otherwise every
helper JVM tries to bind port 5005 again and fails (see [wiring](wiring.md)).

## Jolokia

```bash
-javaagent:/agents/jolokia-agent.jar=host=127.0.0.1,port=8778,discoveryEnabled=false,policyLocation=file:///agents/jolokia-access.xml
```

```bash
kubectl port-forward -n <ns> pod/<pod> 8778:8778
curl -s http://127.0.0.1:8778/jolokia/version
```

`discoveryEnabled=false` turns off Jolokia's multicast discovery responder,
which answers discovery requests on the network with the agent URL. A
loopback-only agent has nothing to announce.

Bound to loopback, Jolokia is reachable only through port-forward. Through
port-forward it answers without authentication. A Jolokia 2.6.3 agent with
`host=127.0.0.1,port=8778` and no policy file answered a read with HTTP 200
and logged `No access restrictor found, access to any MBean is allowed`
(measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward).
Without a policy, anyone who can port-forward to the pod therefore has
full MBean access.

In the wide variant (bound to `0.0.0.0`, see
[Wide variants](#wide-variants-labelled)), Jolokia is reachable by pod IP
from every pod in the cluster, even without a Service. Then the access policy is the only
protection: use a read-only whitelist. Two traps, measured 2026-11-15 on
Jolokia 2.6.3, Temurin 21 and 25, in a container:

- A policy with an `<allow>` section but no `<commands>` element restricts
  nothing: read, write and exec all pass (seen on Temurin 25).
- A denied request still answers HTTP 200, with `"status":403` inside the
  JSON body.

Test the policy and check the inner status, not the HTTP status. The full
policy semantics and a commented template are in `java-debug`,
[jolokia](../../java-debug/references/jolokia.md). The policy file goes in
through the initContainer that copies the agent JARs into an `emptyDir`, see
[wiring](wiring.md).

For a series of values into a file, use `java-debug`'s
[scripts/jmx-sample.py](../../java-debug/scripts/jmx-sample.py) against the
forwarded port.

## What port-forward reaches

All results in this section were measured 2026-11-15 on OrbStack
Kubernetes with kubectl port-forward (Kubernetes 1.36.5, Docker runtime,
dual-stack pod), unless a line says otherwise.

- **The connection arrives as IPv4 loopback.** The server in the pod sees
  source `127.0.0.1` with an ephemeral port and destination
  `127.0.0.1:<port>`. Server code cannot tell it apart from a direct
  connection inside the pod to `127.0.0.1`. This also holds for a listener
  on `[::]`: the source then shows as `127.0.0.1`, not as an IPv6 address.
  Any "trust local connections" setting therefore trusts everyone who can
  port-forward to the pod. One example is the diagnostics agent Arthas (see
  `spring-boot-repl`, [arthas](../../spring-boot-repl/references/arthas.md)): its setting
  `arthas.localConnectionNonAuth=true` lets loopback clients in without a
  password, see [hotswap-in-cluster](hotswap-in-cluster.md).
- **Bind the listener to IPv4 `127.0.0.1` or to a wildcard address.**
  Port-forward reached listeners on `127.0.0.1`, on `0.0.0.0` and on
  `[::]`. It did not reach a listener bound only to `::1` or only to the
  pod IP, although both accepted connections from inside the pod. The
  reason is the data path: the container runtime on the node (here
  Docker-based) implements port-forward with socat, a relay that copies
  bytes between two sockets. It connects to
  `TCP4:localhost:<port>`, and `TCP4:` makes that IPv4 `127.0.0.1` only,
  with no IPv6 fallback.
- **A refused port shows up late and kills the forward.** On the
  workstation the client first sees the connection open, then EOF without
  data. The socat error names `127.0.0.1:<port>`, and the whole
  `kubectl port-forward` ends with `error: lost connection to pod`,
  including every other port of the same command.
- **Other runtimes may differ.** containerd and CRI-O implement
  port-forward differently. Newer containerd may try IPv4 first and then
  IPv6 (inference, not measured). The `::1` result therefore applies to
  Docker-style runtimes such as OrbStack, not to every cluster.

A Java listener bound to `0.0.0.0` was in fact dual-stack: the socket table
showed `[::]`, because the JDK maps `0.0.0.0` on its IPv6 socket to the
dual-stack wildcard. A true IPv4-only `0.0.0.0` bind
(`-Djava.net.preferIPv4Stack=true`) was not measured. It is probably also
reachable, since the forward uses IPv4 `127.0.0.1` (inference).

## Wide variants (labelled)

A wide variant is a listener bound to a non-loopback or wildcard address,
so that other pods or hosts can reach it. In the code block below, the
`#` comment above each flag is its label and names what the flag exposes.
The WIDE VARIANT box states when a wide variant is allowed.

> **WIDE VARIANT. Preconditions, all of them:** a single-user development
> cluster, or a NetworkPolicy that admits only your client; no Ingress,
> NodePort or LoadBalancer for the port; never production. "Reachable only
> inside the cluster" is not protection, because every pod in a shared
> cluster can reach a ClusterIP and a pod IP.

Use a wide variant only when port-forward cannot work, for example for
direct-mode JMX from a workstation that routes into the cluster network.

```bash
# JDWP on all interfaces: unauthenticated remote code execution
-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005

# Jolokia on all interfaces: the policy is the only protection
-javaagent:/agents/jolokia-agent.jar=host=0.0.0.0,port=8778,discoveryEnabled=false,policyLocation=file:///agents/jolokia-access.xml

# JMX direct mode: hostname = a name the client resolves, no authentication
-Dcom.sun.management.jmxremote.port=9010
-Dcom.sun.management.jmxremote.rmi.port=9010
-Djava.rmi.server.hostname=<svc>-jmx.<ns>.svc.cluster.local
-Dcom.sun.management.jmxremote.authenticate=false
-Dcom.sun.management.jmxremote.ssl=false
```

What `address=*:5005` binds depends on the JDK (measured 2026-11-15 on
Temurin 11, 17 and 25, in a container, from the socket table). JDK 11 binds
the IPv4 wildcard `0.0.0.0` only. JDK 17 and 25 bind the dual-stack
wildcard `[::]`, which also answers over IPv6. `address=0.0.0.0:5005` is
IPv4 only on all three. Reaching the port from a non-loopback interface was
not tested.

Direct mode needs a Service that carries the JMX port (and the JDWP port, if
used) and selects only the debugged pod. Its name must match the hostname
above. Keep it separate from the application Service, so that removing the
debug Service removes all access.

## JMX and Spring Boot Actuator

JMX bypasses Spring Security. The Actuator web endpoints answer 401 to an
unauthenticated request, while the same endpoints as MBeans answer without
any check. Lock down JMX on its own: loopback plus port-forward, or JMX
authentication with a password file (mode 0600, mounted from a Secret).

Exposing all Actuator endpoints with
`management.endpoints.access.default=unrestricted` also
opens `shutdown`, which is one click in JConsole. Set
`management.endpoint.shutdown.access=none`. The Spring Boot 4 flag
combinations that abort startup are in `java-debug`,
[actuator](../../java-debug/references/actuator.md).

## Debug listeners and CRaC

CRaC (Coordinated Restore at Checkpoint) starts a JVM from a saved snapshot.
An open listener socket blocks a CRaC checkpoint. Jolokia did block it
(measured 2026-11-15, Zulu 25.0.5 CRaC, in a container). Remote JMX and
nREPL hold such a socket but were not measured. JDWP did not block: it
closes its listener at the checkpoint and listens again after the restore
(same measurement). Services that start from a CRaC checkpoint therefore
get no Jolokia or remote JMX. Debug a cold-started copy of the service
instead. Details: `java-debug`, [crac](../../java-debug/references/crac.md).

