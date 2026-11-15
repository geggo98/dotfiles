# JDWP Agent Options Reference

The JDWP agent lets a debugger connect to a JVM. To activate it, pass the `-agentlib:jdwp` option when you start the JVM.

## Syntax

```
java -agentlib:jdwp=<option1>=<value1>,<option2>=<value2>,... MyApp
```

## Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `transport` | `dt_socket`, `dt_shmem` | (required) | Transport mechanism. `dt_socket` is TCP/IP. `dt_shmem` is shared memory (Windows only). |
| `server` | `y`, `n` | `n` | With `y`, the JVM listens for debugger connections. With `n`, the JVM connects to a debugger. |
| `address` | `host:port` or `port` | (required if `server=n`) | With `server=y`: the port (or `host:port`) to listen on. With `server=n`: the address to connect to. `*:port` listens on all interfaces (the wide variant, see below). |
| `suspend` | `y`, `n` | `y` | With `y`, the JVM suspends until a debugger attaches. With `n`, the JVM runs immediately. |
| `timeout` | milliseconds | (none) | Timeout for the debugger connection, in milliseconds. |
| `onthrow` | exception class | (none) | Start the JDWP agent when the specified exception is thrown. |
| `onuncaught` | `y`, `n` | `n` | Start the JDWP agent on an uncaught exception. |
| `launch` | command | (none) | Command to run when a JDWP event occurs (used with `onthrow` or `onuncaught`). |
| `quiet` | `y`, `n` | `n` | Suppress the "Listening for transport..." message. |

## Common Configurations

### Development (local debugging)

Listen on port 5005 and suspend until a debugger connects:
```bash
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005 MyApp
```

### Development (non-blocking)

Listen on port 5005 and run immediately:
```bash
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005 MyApp
```

### Remote debugging (listen on all interfaces)

The wide variant gives unauthenticated code execution to everyone who reaches the port. Use it only when all of these conditions are true:

- The machine or cluster has a single user, or a NetworkPolicy limits access to the port.
- No Ingress, NodePort, or LoadBalancer exposes the port.
- The JVM is not in production.

"Only reachable inside the cluster" is no protection, because every pod in a shared cluster can reach a ClusterIP. The preconditions are in [jmx-jolokia-ports.md, section "Wide variants (labelled)"](../../jvm-remote-debug/references/jmx-jolokia-ports.md#wide-variants-labelled). Prefer the loopback bind plus a tunnel (SSH or `kubectl port-forward`), because the port then stays on loopback, where other pods and hosts cannot reach it.

```bash
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005 MyApp
```

### Production-safe (trigger on exception)

Enable debugging only when a specific exception is thrown. Until then, no agent listens, so nobody can connect:
```bash
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=y,onthrow=java.lang.OutOfMemoryError,address=127.0.0.1:5005 MyApp
```

### Kubernetes

Keep the loopback bind and reach the port with `kubectl port-forward`. A forwarded connection arrives in the pod as an IPv4 loopback connection, from `127.0.0.1` to `127.0.0.1:<port>`, so no `containerPort` and no Service are needed:
```bash
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005 -jar /app/app.jar
kubectl port-forward pod/<pod> 5005:5005    # on the workstation, then attach to 127.0.0.1:5005
```

Measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward (Kubernetes server v1.36.5, Docker runtime), in a first run and an independent second run. OrbStack is a macOS tool for containers and Linux VMs with a built-in single-node Kubernetes cluster, see [orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md#orbstack).

- A host jdb 25.0.5 attached through `kubectl port-forward 15005:5005` to a JDK 21.0.13 target with `address=127.0.0.1:5005`. `version` and `threads` worked. A jdb in a second container of the pod attached to `127.0.0.1:5005` with the same result.
- The server code in the pod cannot tell a forwarded connection from a direct connection to `127.0.0.1` in the pod. A connection from the pod IP, by contrast, showed the pod IP as its source.
- The forward connects only over IPv4 to `127.0.0.1` in the pod and never tries `::1`. On this runtime the forward runs through `socat` in the container runtime on the node, not in a process in the pod. When the connection is refused, `kubectl port-forward` prints the socat error text in its own error output, and that text names the target `TCP4:localhost:<port>` (see [jmx-jolokia-ports.md, section "What port-forward reaches"](../../jvm-remote-debug/references/jmx-jolokia-ports.md#what-port-forward-reaches)). A listener on `127.0.0.1`, on `0.0.0.0`, or on dual-stack `[::]` was reachable. A listener on `::1` only or on the pod IP only was not reachable. The client on the host saw the connection open and then end without data.
- A refused forwarded connection ends the whole `kubectl port-forward` process (`error: lost connection to pod`). If one command forwards several ports, every other port in it then also refuses connections. Forward one port per command when you are not sure that every port is open.

Limits of this measurement:

- It ran on one runtime, Docker through the CRI (the Container Runtime Interface of the kubelet) on OrbStack. containerd and CRI-O implement port-forward differently, and newer containerd may try IPv4 first and then IPv6 (inference, not measured). The `::1` result therefore applies only to this runtime, where the forward connects through socat to `TCP4:localhost`, not to every cluster.
- The `0.0.0.0` listener in the test was a Java listener, and the JDK maps `0.0.0.0` to dual-stack `[::]` on its sockets. A true IPv4-only wildcard, such as the `*:5005` bind of JDK 11 (see "JDK Version Differences"), was not measured. It should be reachable as well, because the forward connects to IPv4 `127.0.0.1` (inference).

Pod wiring is in the sibling skill `jvm-remote-debug`: `JAVA_TOOL_OPTIONS` and agents in [wiring.md](../../jvm-remote-debug/references/wiring.md), Services for the wide variant in [jmx-jolokia-ports.md, section "Wide variants (labelled)"](../../jvm-remote-debug/references/jmx-jolokia-ports.md#wide-variants-labelled).

### Docker

This is standard Docker behaviour, not measured for this skill: a published port (`docker run -p`) forwards to the network interface of the container, not to its loopback. A loopback bind inside the container is therefore not reachable through `-p`, and this case needs the wide variant (`address=*:5005`) inside the container. Publish the port on the loopback of the host only:
```bash
docker run -p 127.0.0.1:5005:5005 <image> \
  java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005 -jar /app/app.jar
```

Without `127.0.0.1:` in `-p`, Docker publishes the port on all interfaces of the host. Other containers on the same Docker network can still reach the port, so the same conditions as for the wide variant apply.

## Security Considerations

- **Never expose JDWP on public interfaces in production.** JDWP has no authentication and allows arbitrary code execution.
- Use `address=127.0.0.1:5005` to bind to IPv4 loopback only.
- Use an SSH tunnel for remote debugging: `ssh -L 5005:127.0.0.1:5005 user@remote-host`. With the tunnel, the agent can keep its loopback bind. Write and attach to `127.0.0.1`, not `localhost` or `::1`, because the agent does not listen on `::1`.
- Use `address=*:5005` only as the wide variant described above, with its conditions.
- Consider the `onthrow` or `onuncaught` options, so that the agent is active only when it is needed and cannot be reached before.

## JDK Version Differences

| JDK Version | Default `address` Behavior |
|-------------|---------------------------|
| JDK 8 and earlier | `address=5005` listens on all interfaces |
| JDK 9+ | `address=5005` listens on IPv4 loopback only: `127.0.0.1:5005`, not `::1`. `address=*:5005` listens on all interfaces (the wide variant, see above; IPv4 only on JDK 11, see below). |

Measured 2026-11-15 on Temurin 11.0.33, 17.0.21 and 25.0.5, in a container (other JDKs, including 8 and 21, not measured):

- `address=5005` binds `127.0.0.1:5005` on all three. An attach to `::1` is refused. `localhost` works only because the Java client falls back to `127.0.0.1` after `::1`. A client that tries only `::1` is refused.
- `address=*:5005` differs per JDK. JDK 11 binds the IPv4 wildcard `0.0.0.0:5005`, so an attach over `::1` is refused. JDK 17 and 25 bind the dual-stack wildcard `[::]:5005`, so an attach over `127.0.0.1` and over `::1` works. `address=0.0.0.0:5005` binds IPv4 only on all three.
- The wildcard bind was read from the socket table. A connection from a non-loopback interface was NOT tested, because the container had only `lo`.

## Re-attaching after a detach

Measured 2026-11-15 on Temurin 11.0.33, 17.0.21 and 25.0.5, in a container: after each detach (jdb `quit`, or a client that simply closes the socket), the agent listens again and prints a new `Listening for transport dt_socket at address: N` line. The target JVM keeps running.

- Fixed port (`address=127.0.0.1:5005`): the agent listens on the same port again. Five attaches in a row worked.
- Ephemeral port (`address=127.0.0.1:0`): the agent listens on a NEW port after every detach, and the old port is refused. Read the newest `Listening` line, or use a fixed port.

## Environment Variable Alternative

Set JDWP for all Java processes in the shell:
```bash
export JAVA_TOOL_OPTIONS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"
```

**Warning**: This affects ALL Java processes started in that shell, including build tools like Maven and Gradle. Every JVM that reads the variable tries to bind the same port, and every JVM after the first one fails there (see [wiring.md, section "JAVA_TOOL_OPTIONS is inherited"](../../jvm-remote-debug/references/wiring.md#java_tool_options-is-inherited)).

