Applies to: container/Kubernetes

# Debugging a JVM in an image without tools

**TL;DR:** JRE and distroless images often lack `jcmd`, a shell and `tar`.
Check permissions and the JVM's UID first. Then attach from an ephemeral
container with a JDK or [jattach](#jattach), as the same UID, with the target's `/tmp`
visible. Run only read-only attach commands unless the user asks for more.
Verify the size of every file you copy out.

An ephemeral container is a change to the pod spec. It stays until the pod
is deleted and cannot be removed. Ask the user before you create one.

"Measured" on this page means that the authors tested the claim on the
stated versions and setup. "Not measured" means that the claim comes from
documentation and was not tested.

## Contents

- [Preflight](#preflight)
- [Ephemeral container with a JDK](#ephemeral-container-with-a-jdk)
- [Attach rules](#attach-rules)
- [Allowed attach commands](#allowed-attach-commands)
- [jattach](#jattach)
- [No tools at all](#no-tools-at-all)
- [Getting files out](#getting-files-out)
- [Docker or Compose without Kubernetes](#docker-or-compose-without-kubernetes)

## Preflight

```bash
# kubectl debug adds the container with a PATCH on the subresource (RBAC verbs not measured for this skill:
# if a check answers "no" but kubectl debug works, trust kubectl debug)
kubectl auth can-i patch pods/ephemeralcontainers -n <ns>
kubectl auth can-i create pods/attach -n <ns>   # needed for kubectl debug -it
kubectl auth can-i create pods/exec -n <ns>

# Which UID runs the JVM? (needs `id` in the image)
kubectl exec -n <ns> <pod> -c <ct> -- id
# Without `id`: read the security context
kubectl get pod -n <ns> <pod> -o jsonpath='{.spec.securityContext}{"\n"}{.spec.containers[?(@.name=="<ct>")].securityContext}{"\n"}'

# Does the container have tar (needed by kubectl cp) or a shell?
kubectl exec -n <ns> <pod> -c <ct> -- tar --version
kubectl exec -n <ns> <pod> -c <ct> -- sh -c 'echo ok'
```

Also find out whether `/tmp` is a volume shared with other containers, and
where a large file could go (see [Getting files out](#getting-files-out)).

## Ephemeral container with a JDK

```bash
kubectl debug -n <ns> -it <pod> --image=<jdk-image> --target=<ct> --profile=general -- sh
```

- `--target=<ct>` puts the debug container into the process namespace of
  the app container, so the JVM is visible (usually as PID 1 of that
  container). The container runtime must support it. The alternative is
  `shareProcessNamespace: true` in the pod spec, which needs a new pod.
- Start with `--profile=general`. `--profile=sysadmin` starts a
  **privileged** container, so use it only if `general` fails and the user
  agrees. Pod Security admission may also reject it: this built-in
  admission controller enforces the Pod Security Standards (`privileged`,
  `baseline`, `restricted`) per namespace, and under `baseline` or
  `restricted` it rejects a privileged container.
- Pick a JDK image with the same major version as the app's JVM.
- If the debug container runs as root and the JVM does not, run the tool
  as the JVM's UID. `kubectl debug` has no flag for the container UID:
  `--user` is kubectl's global option that picks a user entry from the
  kubeconfig file. A JDK image
  usually starts as root, and a pod-level `runAsNonRoot: true` then rejects
  the ephemeral container. Ways to get the right UID (all three not
  measured):
  1. A pod-level `spec.securityContext.runAsUser` also applies to the
     ephemeral container: nothing to do.
  2. If the UID is set only on the app container, pass a partial container
     spec: `kubectl debug ... --profile=general --custom=uid.json` with
     `{"securityContext":{"runAsUser":<uid>,"runAsGroup":<gid>}}`. Check
     `kubectl debug --help` for `--custom`, because older kubectl versions lack it.
  3. Without `--custom`: use jattach, which switches to the target's UID
     itself, or `setpriv --reuid <uid> --regid <gid> --clear-groups jcmd 1 ...`
     if the image has `setpriv`.

## Attach rules

`jcmd` and `jattach` talk to the JVM through a Unix socket
`/tmp/.java_pid<pid>`, which the JVM creates on the first attach request.

- **Same UID as the JVM.** Otherwise the tool gets `Operation not
  permitted`, or the JVM ignores the request.
- **The JVM's `/tmp` must be visible.** From the debug container it lies
  under `/proc/<pid>/root/tmp`:

  ```bash
  ls -ld /proc/1/root/tmp     # the socket .java_pid1 appears only after the first attach
  ```

  jattach and recent `jcmd` versions look there themselves when the target
  runs in another mount namespace (not measured per JDK version). If `jcmd`
  does not find the socket, use jattach.
- Not measured: `jcmd` and `jattach` use the attach socket and SIGQUIT, not
  ptrace. The Yama sysctl `kernel.yama.ptrace_scope`, which limits which
  processes may ptrace others, matters only for ptrace-based tools such as
  gdb and `jhsdb` (the HotSpot Serviceability Agent debugger, which reads
  the JVM's memory through ptrace). For `Operation not permitted` check the UID first, then
  whether `/proc/<pid>/root` is readable from the debug container.

Typical errors:

| Message | Usual cause |
|---|---|
| `Unable to open socket file /tmp/.java_pid1: target process 1 doesn't respond` | Wrong UID, or the target's `/tmp` is not visible to the tool. After a failed attempt, `ls -la /proc/1/root/tmp/.java_pid*` shows whether the JVM created the socket. |
| `Operation not permitted` | Wrong UID, or `/proc/<pid>/root` not readable from the debug container. |
| A port bind error when `jcmd` starts | `jcmd` inherited `JAVA_TOOL_OPTIONS`. This variable often loads an agent that opens a port: JDWP, JMX, or Jolokia (an agent that serves JMX over HTTP and JSON, see [jolokia](../../java-debug/references/jolokia.md)). Every JVM started with it, `jcmd` included, tries to bind the same port as the app and fails. Use `env -u JAVA_TOOL_OPTIONS jcmd ...`. For these ports in a pod, see [JMX, JDWP and Jolokia ports in a pod](jmx-jolokia-ports.md). |

## Allowed attach commands

These only read. An agent may run them once the user has agreed to the
access itself:

| jcmd | Purpose |
|---|---|
| `Thread.print` | Thread dump (jattach: `threaddump`) |
| `GC.class_histogram -all` | Object counts per class. `-all` avoids the forced full GC (without `-all`: one `Pause Full (Heap Inspection Initiated GC)`; measured 2026-11-15 on Temurin 17, 21 and 25 with G1, in a container). The histogram still stops the JVM while it walks the heap: seconds on a heap of many GiB |
| `VM.flags` | Effective JVM flags |
| `VM.command_line` | Full command line (can contain secrets: do not paste) |
| `VM.native_memory summary` | Native memory, only if Native Memory Tracking (`-XX:NativeMemoryTracking=summary`) was enabled at startup |
| `VM.classloader_stats` | Class loaders and their class counts (class-loader leaks) |

A passthrough is any call that forwards an arbitrary command string to the
JVM, for example a raw `jcmd <pid> <command>` or `jattach 1 jcmd <command>`.
Do NOT run these through a passthrough, because they change the JVM:

- the jcmd commands `load`, `VM.set_flag`, `JVMTI.agent_load`, `JFR.*` and
  `GC.run`
- `asprof`, the launcher of async-profiler. It is not a jcmd command, but
  async-profiler loads its agent library through `load`. See
  [async-profiler](../../java-debug/references/profiling-and-threads.md#4-async-profiler).
- `JDK.checkpoint`, the checkpoint command of CRaC (Coordinated Restore at
  Checkpoint). It exists only in a JVM with CRaC support. The JVM stops after
  the checkpoint is written, so the container exits. See
  [crac](../../java-debug/references/crac.md).

`JFR.*` includes `JFR.check`: in a JVM without a recording it starts the JFR threads and loads the JFR classes (measured
2026-11-15 on Temurin 17, 21 and 25, in a container). For CPU in a pod,
prefer a JFR recording that already runs, because starting a new one
changes the JVM (see [jfr](../../java-debug/references/jfr.md)).

`GC.heap_dump` only on the user's explicit request, after a free-space
check, and into a fixed target directory on a volume. A heap dump stops the
JVM for its duration, is about as large as the live heap, and contains every
secret in memory. If the target file exists, `GC.heap_dump` writes nothing
and prints `Unable to create <file>: File exists`, but `jcmd` still exits
0. Check the message, not the exit code. `-overwrite` replaces the file
(measured 2026-11-15 on Temurin 17, 21 and 25, in a container). The sibling
skill `java-debug` (`../../java-debug/SKILL.md`) covers heap dumps in
detail, see
[Heap dump on demand](../../java-debug/references/heap-dumps.md#2-heap-dump-on-demand)
and
[Where the dump goes in a container](../../java-debug/references/heap-dumps.md#5-where-the-dump-goes-in-a-container).

## jattach

jattach is a small native binary that speaks the attach protocol without a
JDK. Its source and release binaries are at
<https://github.com/jattach/jattach>. For `<image-with-jattach>`, use an
image that contains this binary, for example one you build from a small base
image plus a jattach release binary. A thread dump through jattach in an
ephemeral container, as a documented one-liner (there is no script for it):

```bash
kubectl debug -n <ns> pod/<pod> --image=<image-with-jattach> --target=<ct> \
  --profile=general --container=jattach-1 -- jattach 1 threaddump
kubectl logs -n <ns> <pod> -c jattach-1
```

The output goes to the debug container's log. Each call adds a new
ephemeral container to the pod spec, and a container name can be used only
once per pod: count up (`jattach-2`, ...).

A heap dump through jattach (`jattach 1 dumpheap <path>`) wrote 479 MB in
2.6 s (measured 2026-10, local Kubernetes on macOS arm64; the
distribution was not recorded, so treat the figure only as an order of
magnitude for other clusters). For a cluster in
OrbStack, see [OrbStack and Telepresence specifics](orbstack-telepresence.md).
A heap dump through jattach needs the same explicit request as
`GC.heap_dump`.

## No tools at all

- `kill -3 1` from any container that shares the process namespace (or
  `kubectl exec ... -- kill -3 1` if the image has `kill`) makes the JVM
  print a thread dump to its stdout. Read it with
  `kubectl logs -n <ns> <pod> -c <ct>`. The JVM keeps running. Tell the
  user before you send the signal, because the dump lands in the
  application log: several thousand lines that the log pipeline ships on.
- Spring Boot Actuator: `kubectl port-forward pod/<pod> <p>:<p>`, then
  `curl -s http://127.0.0.1:<p>/actuator/threaddump`. The endpoint must be
  exposed. How to expose it is in `java-debug`,
  [Spring Boot Actuator](../../java-debug/references/actuator.md), sections
  "Endpoint catalogue" and "The Spring management.* property catalogue".

## Getting files out

`kubectl cp` needs `tar` in the container:

```bash
kubectl cp -c <ct> <ns>/<pod>:/dumps/app.hprof ./app.hprof
```

Without `tar`:

```bash
# Stream the file (binary-safe; no TTY, so no -t)
kubectl exec -n <ns> <pod> -c <ct> -- cat /dumps/app.hprof > app.hprof

# From an ephemeral container, through the target's root
kubectl exec -n <ns> <pod> -c <debug-container-name> -- cat /proc/1/root/dumps/app.hprof > app.hprof
```

Rules:

1. **Verify the size or checksum.** Compare `ls -l` or `sha256sum` in the
   pod with the local file. A truncated dump must fail loudly, not be
   analysed.
2. **Write the dump to a volume with enough space.** An `emptyDir` with
   `medium: Memory` counts against the container's memory limit and can get
   the pod OOMKilled. Files in the container layer count against
   ephemeral-storage and can get the pod evicted.
3. **Delete the dump in the pod and locally** when the analysis is done.
   Until then, keep the local copy in a directory with mode 0700. A heap
   dump contains every secret that was in memory.

## Docker or Compose without Kubernetes

```bash
docker exec <container> jcmd 1 Thread.print                    # needs jcmd in the image
docker run --rm --pid=container:<id> --net=container:<id> \
  --user <uid> <jdk-image> jcmd 1 Thread.print                 # tools from another image
docker cp <container>:/dumps/app.hprof ./app.hprof
```

The same attach rules apply: same UID, and the target's `/tmp` must be
visible (with `--pid=container:` use `/proc/1/root/tmp`).

