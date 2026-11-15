Applies to: container/Kubernetes

# Wiring diagnostic agents into a pod

**TL;DR:** Copy agent JARs from an initContainer into an `emptyDir` and give
them mode 0644. Define Downward-API variables before the variables that use
them. Start every extra JVM in the container with `env -u JAVA_TOOL_OPTIONS`.
Exit 137 with `reason: OOMKilled` is the container limit, not a Java
`OutOfMemoryError`.

Every change on this page is a change to the pod spec: it needs the user's
explicit request (see the section
["Read-only at the cluster" means](../SKILL.md#read-only-at-the-cluster-means)
in `SKILL.md`).

## Contents

- [Agents via an initContainer](#agents-via-an-initcontainer)
- [Downward API: order of env entries](#downward-api-order-of-env-entries)
- [JAVA_TOOL_OPTIONS is inherited](#java_tool_options-is-inherited)
- [Find the real start command](#find-the-real-start-command)
- [Jolokia policy file](#jolokia-policy-file)
- [Memory during a rolling update](#memory-during-a-rolling-update)
- [OOMKilled vs OutOfMemoryError](#oomkilled-vs-outofmemoryerror)

## Agents via an initContainer

Do not rebuild the application image to add Jolokia (JMX over HTTP, see
`java-debug`: [jolokia](../../java-debug/references/jolokia.md)), the
OpenTelemetry agent, HotswapAgent (reloads changed classes and refreshes
framework state, see the [`spring-boot-repl` skill](../../spring-boot-repl/SKILL.md))
or Arthas (inspects live objects in a running JVM, see
[arthas](../../spring-boot-repl/references/arthas.md)). An initContainer
copies the JAR into an `emptyDir`. The app container mounts the same volume
and loads the JAR with `-javaagent:`.

```yaml
spec:
  volumes:
    - name: agents
      emptyDir: {}
  initContainers:
    - name: agents
      image: <image-with-agent-jars>
      command: ["sh", "-c", "cp /dist/jolokia-agent.jar /agents/ && chmod 0644 /agents/*.jar"]
      volumeMounts:
        - { name: agents, mountPath: /agents }
  containers:
    - name: <ct>
      volumeMounts:
        - { name: agents, mountPath: /agents, readOnly: true }
```

`/dist` stands for the directory in which `<image-with-agent-jars>` holds
the agent JARs. `<ct>` is the name of the app container
(`containers[].name`), `<ns>` the namespace and `<pod>` the pod name.

Give the JAR mode **0644**. A JAR with mode 0600, owned by the initContainer's
user, cannot be read by an app that runs with another `runAsUser`. The JVM
then stops at startup with `Error opening zip file`.

Pin the agent image by digest and check the agent's checksum where you build
that image.

## Downward API: order of env entries

`$(VAR)` in an env value expands only from env entries that appear EARLIER in
the list. A later entry stays as the literal text `$(VAR)`, and no error is
reported. Define `POD_NAME` before `JAVA_TOOL_OPTIONS`:

```yaml
env:
  - name: POD_NAME
    valueFrom: { fieldRef: { fieldPath: metadata.name } }
  - name: JAVA_TOOL_OPTIONS            # after POD_NAME, so $(POD_NAME) expands
    value: >-
      -XX:+HeapDumpOnOutOfMemoryError
      -XX:HeapDumpPath=/dumps/$(POD_NAME)/
```

A directory as `HeapDumpPath` works: the JVM writes
`java_pid<pid>.hprof` into it. The JVM does NOT create a missing directory.
It prints `Unable to create <path>: No such file or directory` and writes
no dump at all, with no fallback to the working directory. The same holds
for a read-only path. Create the directory in the initContainer, and give
that container the same `POD_NAME` entry. Measured 2026-11-15 on Temurin
17, 21 and 25, in a container.

The per-pod directory matters when the volume is shared between pods. In a
container the JVM usually runs as PID 1 on every start, so neither `%p` (the
`HeapDumpPath` placeholder that the JVM replaces with its PID) nor
`java_pid<pid>` makes the name unique across container restarts. The JVM
does not overwrite an existing dump (`Unable to create <path>: File
exists`, old file unchanged; measured 2026-11-15 on Temurin 17, 21 and 25).
Move or delete the old dump, or the next `OutOfMemoryError` writes none.

Put no secret into `JAVA_TOOL_OPTIONS` or a plain `env:` value, because
both are visible in the pod spec. A `secretKeyRef` keeps the value out of
the pod spec, but the value still ends up in the process environment. Only
a Secret mounted as a file avoids that.

## JAVA_TOOL_OPTIONS is inherited

Every JVM that starts in the container reads `JAVA_TOOL_OPTIONS`: `jcmd`,
`arthas-boot` (the Arthas launcher, a JVM of its own, see
[arthas](../../spring-boot-repl/references/arthas.md)), a `java -version`
check. If the variable opens a JDWP port (see `java-debug`:
[jdwp-options](../../java-debug/references/jdwp-options.md)) or a
Jolokia port, the second JVM tries to bind the same port and fails. Start
helper JVMs without it:

```bash
kubectl exec -n <ns> <pod> -c <ct> -- env -u JAVA_TOOL_OPTIONS jcmd 1 VM.flags
```

## Find the real start command

Kubernetes `command` replaces the image's `ENTRYPOINT`, and `args` replaces
its `CMD`. If the pod spec sets only `args`, the image's `ENTRYPOINT` stays.
A wrapper script can add or drop flags on top. Read what PID 1 really runs:

```bash
kubectl exec -n <ns> <pod> -c <ct> -- cat /proc/1/cmdline | tr '\0' ' '; echo
```

`jcmd 1 VM.command_line` shows the same from the JVM's view, including the
flags that came from `JAVA_TOOL_OPTIONS`. Both outputs can contain secrets,
so do not paste them unfiltered.

## Jolokia policy file

Jolokia reads its access policy from a file (`policyLocation=file:///...`).
Let the initContainer write it into the same `emptyDir` as the agent. A
base64-encoded policy in the initContainer's command is fine, because the
policy holds no secret:

```yaml
command: ["sh", "-c", "echo '<base64-policy>' | base64 -d > /agents/jolokia-access.xml && chmod 0644 /agents/*"]
```

A commented read-only policy template and the measured policy semantics are
in `java-debug`: [jolokia](../../java-debug/references/jolokia.md).

## Memory during a rolling update

During a `RollingUpdate`, the old and the new pod run at the same time, each
with its agents. On a small node this doubles the memory need for the
duration of the rollout. Either plan memory for two pods, or use
`strategy: Recreate` (the service is down between the old and the new pod).

Agents also raise the startup peak. JBR (JetBrains Runtime, a JDK build with
enhanced class redefinition) with HotswapAgent, JFR (see `java-debug`:
[jfr](../../java-debug/references/jfr.md)) and the OpenTelemetry
agent needed more than 2 Gi: a Spring Boot 4 service with nREPL (a Clojure
network REPL embedded in the JVM, see
[nrepl](../../spring-boot-repl/references/nrepl.md)) and Arthas
was OOMKilled repeatedly in the startup peak with a 2 Gi limit, and 3 Gi
worked. Measured 2026-10 and 2026-11 on JBR 25, HotswapAgent 2.0.3 and
Arthas 4.3.4, in local Kubernetes on macOS arm64. See
[hotswap-in-cluster](hotswap-in-cluster.md), row "Memory".

## OOMKilled vs OutOfMemoryError

Two different failures look alike from outside, because in both cases the
pod restarts. If the JVM dies before anything can attach
(CrashLoopBackOff), start with the log of the previous run and the pod's
events:

```bash
kubectl logs -n <ns> <pod> -c <ct> --previous     # output of the run that died
kubectl describe pod -n <ns> <pod>                 # events, Last State, restart count
kubectl get pod -n <ns> <pod> \
  -o jsonpath='{.status.containerStatuses[*].lastState.terminated}'; echo
```

| What you see | What happened | What you get |
|---|---|---|
| `reason: OOMKilled`, `exitCode: 137` | The kernel killed the process because the container exceeded its cgroup memory limit. | No Java stack trace, no heap dump. The heap may be small, because metaspace, threads, direct buffers and native memory count too. |
| `java.lang.OutOfMemoryError` in the log, exit code from the JVM | A memory area inside the JVM (heap, metaspace, ...) was full. | `-XX:+HeapDumpOnOutOfMemoryError` writes a dump. `-XX:+ExitOnOutOfMemoryError` makes the pod restart cleanly. |

Exit 137 without `OOMKilled` means another SIGKILL, for example after a
failed liveness probe when the JVM did not stop within the grace period.

What to do about OOMKilled:

1. Let the JVM size the heap from the container limit with
   `-XX:MaxRAMPercentage=<n>` and leave room for metaspace, threads and
   native memory. Do not set the heap equal to the limit, because these
   areas count against the container limit too.
2. Check what the JVM sees: `-Xlog:os+container=trace` at startup (the
   detection lines are at trace level),
   `env -u JAVA_TOOL_OPTIONS jcmd 1 VM.info` at run time, or, as a quick
   check of the limit that the JVM sees,
   `env -u JAVA_TOOL_OPTIONS java -XshowSettings:system -version`.
   Check the GC too. In a small container (2 CPUs, 1536 MiB), the JVM
   picked SerialGC, not G1 (`-XX:+PrintFlagsFinal` showed
   `UseSerialGC = true {product} {ergonomic}`; measured 2026-11-15 on
   Temurin 21, in a container).
3. Compare the JVM's own accounting with the pod's RSS: start with
   Native Memory Tracking (NMT) on, `-XX:NativeMemoryTracking=summary`,
   then run `env -u JAVA_TOOL_OPTIONS jcmd 1 VM.native_memory summary`.
   NMT has a small overhead. Details in `java-debug`:
   [profiling-and-threads](../../java-debug/references/profiling-and-threads.md).
4. For peaks, read the cgroup directly. Kubelet statistics (`kubectl top`,
   and the kubelet Summary API `/stats/summary`, reached for example with
   `kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary`) are cached
   for about 10 s and hide short peaks
   (measured 2026-08, local Kubernetes on macOS arm64):

   ```bash
   # cgroup v2, inside the container
   cat /sys/fs/cgroup/memory.current
   grep '^inactive_file ' /sys/fs/cgroup/memory.stat
   # working set ≈ memory.current − inactive_file

   # cgroup v1 (not measured): the v2 files above do not exist there
   cat /sys/fs/cgroup/memory/memory.usage_in_bytes
   grep '^total_inactive_file ' /sys/fs/cgroup/memory/memory.stat
   ```

Some sources give `%t` as a timestamp placeholder for `HeapDumpPath`. On
Temurin 25 `%p` expands and `%t` does not: the JVM leaves `%t` in the file
name as literal text. This and the other heap-dump flags and their pitfalls
are in
`java-debug`: [heap-dumps](../../java-debug/references/heap-dumps.md).
