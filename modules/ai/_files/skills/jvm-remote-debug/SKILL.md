---
name: jvm-remote-debug
description: >-
  Reach and instrument a JVM that runs inside a container or a Kubernetes
  pod: attach tools to a JRE or distroless image without jcmd through
  `kubectl debug` and an ephemeral container, bring agents (Jolokia,
  OpenTelemetry, HotswapAgent, Arthas) into a pod through an initContainer,
  wire JMX, JDWP and Jolokia so that `kubectl port-forward` works, get heap
  and thread dumps out of a pod, and tell OOMKilled apart from
  OutOfMemoryError. Covers the pod-side requirements for hot swap and the
  OrbStack and Telepresence specifics on a Mac. Loads together with
  `java-debug`, which explains which diagnostic tool to use and how to
  read its output. REPL, class redefinition and hot-swap detail lives in
  `spring-boot-repl`. Triggers on: kubectl debug, ephemeral container,
  distroless, JRE image without jcmd, shareProcessNamespace, initContainer
  agent, JMX in Kubernetes, rmi.server.hostname, kubectl cp heap dump,
  OOMKilled, exit 137, JAVA_TOOL_OPTIONS in a pod, port-forward JDWP, Telepresence,
  OrbStack.
allowed-tools: >-
  Read(references/*)
dependencies: >-
  kubectl with access to the target namespace. For tools in the pod: a JDK
  image or an image that contains jattach (a small native binary that
  speaks the JVM attach protocol without a JDK), used as an ephemeral
  container.
  JDK 11+ on the workstation for jcmd, jconsole and jdb. Load the
  `java-debug` skill together with this one. Optional: OrbStack and
  Telepresence 2, only if the cluster runs there.
compatibility: >-
  Containers and Kubernetes; workstation macOS or Linux. Development and
  test clusters. Production only when the user asks and the cluster policy
  allows it.
---

# JVM remote debugging: reach a JVM in a container or pod

**TL;DR:** This skill answers one question: how do I get a diagnostic tool
to a JVM that runs in a pod? Prefer `kubectl port-forward` to a listener
bound to `127.0.0.1`. Other pods cannot reach such a listener, but
port-forward can. Use an ephemeral container when the image has no JDK
tools. Ask the user before every step that changes the pod or the JVM.
Which tool to use and how to read its output is in `java-debug`.

## When to use which access

```
What do you need?
  ├─ A thread dump, class histogram or JVM flags, image has jcmd
  │     → kubectl exec + jcmd (env -u JAVA_TOOL_OPTIONS)      references/debug-without-tools.md
  ├─ The same, image has no jcmd (JRE, distroless)
  │     → ephemeral container with a JDK or jattach            references/debug-without-tools.md
  ├─ No tools and no permission for an ephemeral container
  │     → kill -3 1 + kubectl logs, or /actuator/threaddump     references/debug-without-tools.md
  ├─ A heap dump or a JFR file on the workstation
  │     → write to a volume, copy out, verify the size           references/debug-without-tools.md
  ├─ MBeans in JConsole, JMC (JDK Mission Control) or jmxterm
  │     → JMX with rmi.server.hostname=127.0.0.1 + port-forward  references/jmx-jolokia-ports.md
  ├─ MBeans over HTTP, or a series of values into a file
  │     → Jolokia on loopback + port-forward + read-only policy  references/jmx-jolokia-ports.md
  ├─ Breakpoints (jdb, IDE remote debug)
  │     → JDWP on 127.0.0.1:5005 + port-forward                  references/jmx-jolokia-ports.md
  ├─ An agent JAR in the pod (Jolokia, OpenTelemetry, HotswapAgent)
  │     → initContainer copies it into an emptyDir                references/wiring.md
  ├─ The JVM exits before you can attach (CrashLoopBackOff)
  │     → kubectl logs --previous -c <ct>, kubectl describe pod
  │       (events, lastState), then OOMKilled or OutOfMemoryError?  references/wiring.md
  ├─ The pod restarts with exit 137
  │     → OOMKilled or OutOfMemoryError? Exit 137 without
  │       OOMKilled = SIGKILL, often a failed liveness probe       references/wiring.md
  ├─ Change code in a running pod
  │     → pod requirements here, the procedure in spring-boot-repl  references/hotswap-in-cluster.md
  └─ The cluster runs in OrbStack, or Telepresence is in use
        → only then                                               references/orbstack-telepresence.md
```

Terms in the tree:

- **`/actuator/threaddump`** returns a thread dump over HTTP. See
  `java-debug`, [actuator](../java-debug/references/actuator.md).
- **jmxterm** is a command-line JMX client. See `java-debug`,
  [jmx](../java-debug/references/jmx.md), section 3.
- **HotswapAgent** is a Java agent that reloads changed classes and
  refreshes framework state, for example Spring beans. See
  `spring-boot-repl`, [SKILL.md](../spring-boot-repl/SKILL.md).

## "Read-only at the cluster" means

When the user asks for read-only work, these commands are allowed:
`kubectl get`, `kubectl logs` (also `--previous`), `kubectl describe`,
`kubectl port-forward`, and `kubectl exec`. Use `kubectl exec` only to run
`cat /proc/1/cmdline` and the read-only attach commands listed in
[debug-without-tools](references/debug-without-tools.md).

`kill -3 1` only reads state, but the JVM writes the thread dump into the
application log. That is several thousand lines, and the log pipeline ships
them on. Tell the user before you use it.

The following steps are NOT read-only. Each one needs an explicit request
from the user first:

- Deploys, restarts, scaling, and every change to a pod spec, Deployment,
  ConfigMap or Secret.
- An ephemeral container. It stays in the pod spec until the pod is
  deleted and cannot be removed.
- A heap dump. It stops the JVM for the duration of the dump, fills a
  volume or the memory limit, and contains every secret in memory.
- `jcmd` or `jattach` commands that change the JVM (`VM.set_flag`,
  `JVMTI.agent_load`, `load`, `JFR.*`, `GC.run`), and `asprof` (the
  command-line launcher of async-profiler, see
  [profiling-and-threads, section 4](../java-debug/references/profiling-and-threads.md#4-async-profiler)),
  because async-profiler loads its agent library into the JVM through
  `load`.
  Even `JFR.check` counts, because it starts the JFR subsystem in a JVM
  that had no recording (measured 2026-11-15 on Temurin 17, 21 and 25, in
  a container).
- `jcmd <pid> JDK.checkpoint`, the checkpoint command of CRaC
  (Coordinated Restore at Checkpoint, see
  [crac](../java-debug/references/crac.md)). The JVM stops after the
  checkpoint is written, so the container exits and restarts.

Before you ask, say what the step does and what it costs.

## Security rules

1. **Bind to loopback by default.** Use JDWP `address=127.0.0.1:5005`,
   Jolokia `host=127.0.0.1`, nREPL on `127.0.0.1`, and JMX with
   `java.rmi.server.hostname=127.0.0.1`. (nREPL is a Clojure network REPL
   embedded in the JVM, see `spring-boot-repl`,
   [nrepl](../spring-boot-repl/references/nrepl.md).) Reach the port with
   `kubectl port-forward`. A loopback listener is closed to other pods,
   and port-forward still reaches it: a forwarded connection arrives in the
   pod from `127.0.0.1` (measured 2026-11-15 on OrbStack Kubernetes with
   kubectl port-forward). Port-forward does not reach a listener that is
   bound only to `::1` or only to the pod IP, because the container runtime
   connects to `localhost` over IPv4 inside the pod's network namespace
   (same measurement, Docker runtime; other runtimes were not measured). The wide forms (`address=*:5005`,
   `host=0.0.0.0`, `authenticate=false` on a non-loopback address) appear
   only as labelled variants in
   [jmx-jolokia-ports](references/jmx-jolokia-ports.md), with their
   preconditions.
2. **"Only reachable inside the cluster" is not protection.** Every pod in
   a shared cluster can reach a ClusterIP and a pod IP. JDWP, nREPL and
   unauthenticated JMX are remote code execution.
3. **Never expose a debug port through an Ingress, a NodePort or a
   LoadBalancer.** Whoever reaches JDWP, nREPL or unauthenticated JMX can
   run any code in the JVM (rule 2).
4. **No secret in argv, a URL, `JAVA_TOOL_OPTIONS` or a plain `env:`
   value.** Argv is visible in the process list, and `JAVA_TOOL_OPTIONS`
   and a plain `env:` value are visible in the pod spec (see
   [wiring](references/wiring.md)). Use a Secret mounted as a file (mode
   0600), `secretKeyRef`, or a `*_CMD` variable whose command a tool runs
   to read the secret at run time, where the tool supports it (for example
   `JOLOKIA_PASSWORD_CMD` of `java-debug`'s
   [jmx-sample.py](../java-debug/scripts/jmx-sample.py)).
   Exception: `arthas-boot`, the launcher JAR that attaches the Arthas
   diagnostic agent to a running JVM, takes its password as an argument.
   Use it only on throwaway dev JVMs with a random password per session
   (see `spring-boot-repl`,
   [arthas](../spring-boot-repl/references/arthas.md)). The
   `arthas.properties` that the Arthas 4.3.4 distribution ships
   (`arthas.localConnectionNonAuth=true`) accepts a request from
   `127.0.0.1` without any password (measured 2026-11-15 on Temurin 21 and
   25, in a container). A port-forwarded request counts as local: without
   credentials, the Arthas HTTP endpoints `/api` (the command API) and
   `/mcp` (the Model Context Protocol endpoint) both answered HTTP 200
   (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward).
   With this config, anyone who can port-forward to the pod uses Arthas
   without a password. See
   [hotswap-in-cluster](references/hotswap-in-cluster.md).
5. **Treat diagnostic output like a credential store.** A heap dump, a JFR
   recording, `VM.command_line`, system properties and the pod environment
   contain passwords and tokens. Never paste them into tickets, commits or
   the conversation. Delete them when the analysis is done.
6. **Never print a pod environment.** `telepresence list --output json`
   prints the full environment of every intercepted pod in clear text
   (measured once on a local cluster: 385 variables, passwords among them;
   date not recorded). Reduce it to variable NAMES before anything is shown
   or logged.
7. **Warn before heavy operations.**
   - A heap dump stops the world, is about as large as the live heap, and
     `emptyDir medium: Memory` counts against the memory limit.
   - `GC.class_histogram` without `-all` forces a full GC. With `-all` it
     does not (measured 2026-11-15 on Temurin 17, 21 and 25 with G1, in a
     container).
   - `kubectl debug --profile=sysadmin` starts a privileged container. Try
     `general` first, because Pod Security admission (the Kubernetes Pod
     Security Standards, enforced per namespace) may reject `sysadmin`.
     See [debug-without-tools](references/debug-without-tools.md), section
     "Ephemeral container with a JDK".

## Working rules

- **Plausibility.** A startup time or a latency far outside what you
  expect is a finding, not normal behaviour. Measure where the time goes
  before you accept it.
- **One refused port ends the whole `kubectl port-forward`.** A single
  refused connection stops the process with
  `error: lost connection to pod`, and every other port of the same
  command then answers `Connection refused` on the workstation (measured
  2026-11-15 on OrbStack Kubernetes with kubectl port-forward). Forward one port per command when you are
  not sure that every port is open. Check that the forward still runs
  before you blame the JVM.
- **On a Mac, do not forward to local port 5000 or 7000.** ControlCenter
  (the AirPlay Receiver) listens on both. After the forward dies, a client
  connects to ControlCenter instead and hangs without an error message
  (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward).
  Details are in [jmx-jolokia-ports](references/jmx-jolokia-ports.md).
- **`JAVA_TOOL_OPTIONS` is inherited.** Every JVM that you start in the
  container (jcmd, arthas-boot) reads it again and can fail on a port that
  the app already holds. Start such tools with `env -u JAVA_TOOL_OPTIONS`.
- **Plan for a sleeping laptop.** On a local cluster, a Mac that sleeps can
  pause or kill pods. Do not start long measurements before a break, and
  check the restart counters before you compare numbers.
- **Name things by placeholder** in everything you write down: `<ns>`,
  `<pod>`, `<ct>`, `<deploy>`, `<svc>.<ns>.svc.cluster.local`.

## One worked example: thread dump from a JRE-only pod

```bash
# 1. Preflight: may I do this, and as which user does the JVM run?
kubectl auth can-i patch pods/ephemeralcontainers -n <ns>
kubectl auth can-i create pods/attach -n <ns>   # needed for -it
kubectl exec -n <ns> <pod> -c <ct> -- id        # fails without `id` in the image: then read runAsUser from the spec

# 2. After the user agreed to the ephemeral container:
kubectl debug -n <ns> -it <pod> --image=<jdk-image> --target=<ct> --profile=general -- sh

# 3. Inside the debug container, as the JVM's UID (how: references/debug-without-tools.md,
#    section "Ephemeral container with a JDK", the list of ways to get the right UID):
ls -ld /proc/1/root/tmp                         # is the target's /tmp visible? The socket .java_pid1 appears after the first attach
jcmd 1 Thread.print > /tmp/threads.txt
```

The attach rules, the error messages and the way back to the workstation
are in [debug-without-tools](references/debug-without-tools.md).

## References

| File | Contents |
|---|---|
| [wiring.md](references/wiring.md) | Agents via an initContainer, order of env entries that use the Downward API, why `JAVA_TOOL_OPTIONS` is inherited, how to find the command the container really starts, memory while old and new pods run during a rolling update, Jolokia policy file, CrashLoopBackOff first steps, OOMKilled vs OutOfMemoryError |
| [jmx-jolokia-ports.md](references/jmx-jolokia-ports.md) | JMX hostname modes, JDWP, Jolokia, what port-forward reaches, labelled wide variants, Actuator over JMX, conflict with CRaC |
| [debug-without-tools.md](references/debug-without-tools.md) | Preflight, `kubectl debug`, attach rules, allowed attach commands, jattach, `kill -3`, getting files out, plain Docker |
| [hotswap-in-cluster.md](references/hotswap-in-cluster.md) | Pod requirements for JetBrains Runtime (JBR) + HotswapAgent + nREPL + Arthas: memory, JFR, rollout, secrets, probes |
| [orbstack-telepresence.md](references/orbstack-telepresence.md) | Only if OrbStack or Telepresence is in use: DNS, container paths, binaries from the Nix store that cannot reach cluster IPs, port-forward data path, IPv6, intercept pitfalls |

Related skills:

- `java-debug`: which tool to use and how to read its output. Relevant
  files: [jmx](../java-debug/references/jmx.md),
  [jolokia](../java-debug/references/jolokia.md),
  [jfr](../java-debug/references/jfr.md),
  [heap-dumps](../java-debug/references/heap-dumps.md),
  [profiling-and-threads](../java-debug/references/profiling-and-threads.md),
  [actuator](../java-debug/references/actuator.md),
  [jmc](../java-debug/references/jmc.md),
  [crac](../java-debug/references/crac.md).
- `spring-boot-repl`: hot swap, nREPL and Arthas, and its
  [Redefine.java](../spring-boot-repl/scripts/Redefine.java), which
  replaces loaded classes in a running JVM over JDWP in one call.
  Relevant files: [setup](../spring-boot-repl/references/setup.md),
  [redefine](../spring-boot-repl/references/redefine.md),
  [arthas](../spring-boot-repl/references/arthas.md),
  [nrepl](../spring-boot-repl/references/nrepl.md).
