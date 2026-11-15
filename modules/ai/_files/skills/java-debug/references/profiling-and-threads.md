Applies to: macOS, Linux, container/Kubernetes (platform limits are marked per section)

# Profiling, Thread Dumps, GC and Native Memory

TL;DR: For a hang, take a thread dump (`jcmd <pid> Thread.print`). For memory outside the heap, use
Native Memory Tracking (NMT) and compare it with the process RSS. For CPU, use JFR first
([`../scripts/jfr-record.sh`](../scripts/jfr-record.sh)), because async-profiler loads an agent into
the JVM (§4). Use async-profiler when you need flame graphs or wall-clock profiles. All `jcmd` commands need the same OS user as the JVM.
With another user, the attach fails (§3).

## Contents

- [1. Thread dumps](#1-thread-dumps)
- [2. GC log, native memory and JVM flags](#2-gc-log-native-memory-and-jvm-flags)
- [3. Attach rules for jcmd and jattach](#3-attach-rules-for-jcmd-and-jattach)
- [4. async-profiler](#4-async-profiler)

## 1. Thread dumps

| Command | Use | Status |
|---|---|---|
| `jcmd <pid> Thread.print` | Hang, deadlock (a deadlock is reported at the end) | standard |
| `jcmd <pid> Thread.dump_to_file -format=json <abs-file>` | Machine-readable dump that also lists virtual threads | JDK 21+, measured 2026-11-15 on Temurin 21.0.13 and 25.0.5, in a container. Temurin 17.0.21 answers `Unknown diagnostic command` (exit 1). On older JDKs, use `Thread.print`. |
| `kill -3 <pid>` | No `jcmd` available: the JVM writes the dump to its console output, that is its log (container: `kubectl logs`). Needs the JVM's UID or root. | standard |
| JFR event `jdk.VirtualThreadPinned` | Virtual threads pinned to their carrier thread | not measured for this skill |

In the Status column, `standard` means that the command works on every supported JDK and does not depend on
the JDK version. The supported JDKs are JDK 11 and later, the range that the `dependencies` field of
[`../SKILL.md`](../SKILL.md) sets.

A virtual thread is *pinned* when it cannot unmount from its carrier thread (the platform thread that
runs it), for example inside a `synchronized` block or during a native call. The carrier thread then stays
blocked as long as the virtual thread blocks. For how to record a JFR event such as
`jdk.VirtualThreadPinned`, see [`jfr.md`](jfr.md).

Take two or three dumps a few seconds apart. A thread that shows the same stack in every dump is stuck,
and a thread that moves is busy. Give each `Thread.dump_to_file` call a new file name, because the JVM
refuses an existing file with `<file> exists, use -overwrite to overwrite`, and **`jcmd` still exits 0**
(measured 2026-11-15 on Temurin 21 and 25, in a container). Check the output for `Created <file>`,
because the exit code is the same in both cases.

```bash
jcmd <pid> Thread.dump_to_file -format=json /var/tmp/threads-$(date -u +%Y%m%dT%H%M%SZ).json
jfr print --events jdk.VirtualThreadPinned recording.jfr      # JDK 21+, needs a recording with the event
```

## 2. GC log, native memory and JVM flags

**GC log** (unified logging, JDK 9+, not measured for this skill):

```bash
-Xlog:gc*:file=/var/tmp/gc.log:time,uptime
```

**Native memory** (NMT): the heap is only one part of the process memory. Metaspace, thread stacks, code
cache, GC structures and direct buffers come on top. Start the JVM with NMT, then compare its total with
the RSS of the process:

```bash
-XX:NativeMemoryTracking=summary                     # startup flag, costs a little CPU and memory
jcmd <pid> VM.native_memory summary                  # committed memory per area
ps -o rss= -p <pid>                                  # RSS in KiB, to compare
```

If the committed total of NMT is far below the RSS, the extra memory comes from code that NMT does not
track (native libraries, `malloc` from JNI). If one NMT area grows (often `Class`, which is metaspace, or
`Thread`), that area is where to look.

**Configuration and class loaders:**

| Command | Shows |
|---|---|
| `jcmd <pid> VM.flags` | Effective JVM flags, including the HotSpot ergonomics: the defaults that the JVM picks at startup from the CPU count and memory it detects (heap size, GC, thread counts). Do not assume G1: in a small container (2 CPUs, 1536 MiB) the ergonomics chose `UseSerialGC` (measured 2026-11-15 on Temurin 21.0.13, in a container) |
| `jcmd <pid> VM.command_line` | The real command line, including `JAVA_TOOL_OPTIONS` effects |
| `jcmd <pid> VM.classloader_stats` | Class loaders with class count and metaspace size. Measured useful to find class-loader leaks (thousands of loaders of one type) |
| `jcmd <pid> PerfCounter.print` | JVM performance counters. Needs no JMX port (measured 2026-11 on JDK 25, see [`metrics-export.md`](metrics-export.md)) |

For a series of values written to a file, see [`metrics-export.md`](metrics-export.md).

## 3. Attach rules for jcmd and jattach

`jcmd` and `jattach` talk to the JVM through a UNIX socket, not over the network. `jattach` is a small native
binary that speaks the JVM attach protocol without a JDK (see
[debug-without-tools.md, section jattach](../../jvm-remote-debug/references/debug-without-tools.md#jattach)).

- Run them as the **same OS user** as the JVM. With a different user, the attach fails with
  `Unable to open socket file /tmp/.java_pid<pid>` or `Operation not permitted` (see the typical errors
  below).
- The socket is `/tmp/.java_pid<pid>`. If the target JVM has a different `/tmp` (container, systemd
  `PrivateTmp`), the tool must see the target's `/tmp`.
- **Linux, not measured:** `jcmd` and `jattach` use the attach socket and SIGQUIT, not ptrace.
  The sysctl `kernel.yama.ptrace_scope` matters only for ptrace-based tools (`jhsdb`, gdb). It restricts
  which processes may ptrace another process; at `1`, only a parent may trace its children. For
  `Operation not permitted`, check the UID first, then whether `/proc/<pid>/root` is readable from the debug container. The debug
  container is an ephemeral container added to the pod with `kubectl debug --target=<container>` (see
  [debug-without-tools.md, section "Ephemeral container with a JDK"](../../jvm-remote-debug/references/debug-without-tools.md#ephemeral-container-with-a-jdk)).
- **Container:** `jcmd` is itself a Java program and starts its own JVM. A `jcmd` started inside the
  container therefore inherits `JAVA_TOOL_OPTIONS`. If those options open a port (JDWP, see
  [`jdwp-options.md`](jdwp-options.md); JMX, see [`jmx.md`](jmx.md)), the `jcmd` JVM
  tries to open the same port and fails, because the app already holds that port. The fix removes the
  variable for `jcmd` only (see also
  [debug-without-tools.md](../../jvm-remote-debug/references/debug-without-tools.md)):

  ```bash
  env -u JAVA_TOOL_OPTIONS jcmd <pid> Thread.print
  ```

- Typical errors: `Unable to open socket file /tmp/.java_pid<pid>` (wrong user or a different `/tmp`),
  `Operation not permitted` (a different user, or `/proc/<pid>/root` not readable from the debug container).

Image without `jcmd` (JRE, distroless), ephemeral containers and `jattach` in a pod: see the
`jvm-remote-debug` skill, [debug-without-tools.md](../../jvm-remote-debug/references/debug-without-tools.md).

## 4. async-profiler

async-profiler is a sampling profiler that sees Java and native frames and writes flame graphs. Check the
[release page](https://github.com/async-profiler/async-profiler/releases) for the current version. The facts
below come from web sources, mainly the project README at
[github.com/async-profiler/async-profiler](https://github.com/async-profiler/async-profiler). This skill's
author has not measured async-profiler.

> **Warning:** `asprof`, the command-line launcher of async-profiler, loads an agent library into the target
> JVM through the attach command `load`. This changes the JVM, so it is not a read-only command. Ask the
> user first. JDK 21+ is said to print a warning for a dynamically loaded agent (not measured). For CPU in a pod, prefer a JFR recording
> that already runs, because reading it loads no new agent into the JVM.

```bash
asprof -d 30 -e wall -t -f /var/tmp/wall.html <pid>     # 30 s wall-clock, per thread, HTML flame graph
asprof -d 30 -e cpu -f /var/tmp/cpu.jfr <pid>           # CPU profile as JFR output
```

| Platform | `cpu` event | Fallback |
|---|---|---|
| Linux host | uses `perf_events` | `ctimer`, `itimer` if `perf_event_paranoid` blocks it |
| macOS (arm64) | no `perf_events` | `itimer`, `wall` |
| Container | seccomp and `perf_event_paranoid` usually block `perf_events` | `ctimer`, `itimer`, `wall` |

`perf_event_paranoid` is the sysctl `kernel.perf_event_paranoid`. The async-profiler documentation recommends
`1` for full stacks; higher values restrict or block `perf_events` for unprivileged users (not measured). The
fallback events:

- `ctimer`: per-thread CPU timers created with `timer_create`. Needs no `perf_events`.
- `itimer`: one process-wide CPU timer set with `setitimer`, which delivers a signal.
- `wall`: wall-clock sampling, described below.

Notes:

- Relax seccomp or add `CAP_SYS_ADMIN` only on a throwaway dev host, never in a shared cluster.
- `wall` samples all threads, also the sleeping and waiting ones. For that reason, use `wall` for latency
  ("where does the request wait?") and `cpu` for CPU load.
- `ap-loader` packages the native library in a JAR, so the profiler can ship with the dependencies of the
  application. Project: [github.com/jvm-profiling-tools/ap-loader](https://github.com/jvm-profiling-tools/ap-loader),
  Maven artifact `me.bechberger:ap-loader-all`. Use it as a library dependency or as a `-javaagent` (not
  measured).
- The same attach rules as in §3 apply (same user, shared `/tmp`).
- **Pod or container, not measured:** the target JVM opens the library in its own mount namespace, so a
  library that exists only in an ephemeral debug container is not found. The `-f` output path is also
  written by the target JVM. Put the library and the output path where the app container sees them, for
  example in an `emptyDir` mounted into the app container (see the `jvm-remote-debug` skill,
  [wiring.md, section "Agents via an initContainer"](../../jvm-remote-debug/references/wiring.md#agents-via-an-initcontainer))
  or, from the debug container, under `/proc/<pid>/root/tmp`. Here `<pid>` is the PID of the app JVM as
  the debug container sees it. The path is `/proc/1/root/tmp` only when the JVM is PID 1 in the shared
  PID namespace.

