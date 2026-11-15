# Java Debugger (JDB) — Interactive Step-Debugging via JDWP

Use JDB to debug Java applications interactively from the command line. JDB can attach to a running JVM or launch a new one. In a session you set breakpoints, step through code, inspect state, analyse threads, and diagnose exceptions or deadlocks.

jdb connects to the JDWP agent in the target JVM, which you load with `-agentlib:jdwp=...` (see §3).

The `scripts/...` paths in this file are relative to the root of the java-debug skill, that is `../scripts/` from this file.

> For Scala on the JVM, [`scala-jvm.md`](scala-jvm.md) describes the Scala-specific name mangling that affects breakpoints. If the JVM hangs, the JFR view `contention-by-thread` often finds the cause faster than a JDB session (see [`jfr.md`](jfr.md)).

## Contents

- [1. Decision tree](#1-decision-tree)
- [2. Quick start](#2-quick-start)
- [3. Enabling JDWP on a running application](#3-enabling-jdwp-on-a-running-application)
- [4. Interactive JDB session — command catalogue](#4-interactive-jdb-session--command-catalogue)
- [5. Debugging workflow patterns](#5-debugging-workflow-patterns)
- [6. Important notes and pitfalls](#6-important-notes-and-pitfalls)
- [7. Reference files](#7-reference-files)

## 1. Decision tree

```
User wants to debug a Java app →
  ├─ App is already running with the JDWP agent?
  │   ├─ Yes → Attach:   scripts/jdb-attach.sh --port <port>
  │   └─ No  → Can you restart it with JDWP?
  │       ├─ Yes → Launch: scripts/jdb-launch.sh <mainclass> [args]
  │       └─ No  → Suggest adding the JDWP agent to the JVM flags (see §3)
  │
  ├─ What does the user need?
  │   ├─ Step through code, inspect locals → interactive session via the scripts above
  │   ├─ Thread dumps and deadlock detection → scripts/jdb-diagnostics.sh
  │   └─ Catch a specific exception → use `catch` (§4) or the --bp flag in scripts/jdb-breakpoints.sh
  │
  └─ Done debugging → detach cleanly with `quit` or Ctrl+C
```

`quit` detaches only. The target JVM keeps running, and the agent accepts the next attach (see §6, "Re-attach after `quit`").

## 2. Quick start

jdb works in one of two modes. In **launch mode**, jdb starts the target JVM itself, with `scripts/jdb-launch.sh` or `jdb <mainclass>`, and the JVM waits before `main` until you type `run`. In **attach mode**, jdb connects to a JVM that already runs, with `scripts/jdb-attach.sh`.

### Launch a new JVM under JDB

```bash
scripts/jdb-launch.sh com.example.MyApp --sourcepath src/main/java
```

### Attach to a running JVM

The target JVM must run with the JDWP agent (see §3). Then attach:

```bash
scripts/jdb-attach.sh --host localhost --port 5005
```

### Collect diagnostics (thread dump + deadlock detection)

```bash
scripts/jdb-diagnostics.sh --port 5005
```

### Automated batch debugging (no workspace files!)

The golden rule of this skill: **never create files in the workspace**. Do not write a `bp.txt`, a `cmds.txt`, or a wrapper script. Use the inline flags `--bp`, `--cmd`, and `--auto-inspect` instead. The script keeps its own temporary files in `/tmp/` and deletes them afterwards, so nothing is left in the workspace:

```bash
scripts/jdb-breakpoints.sh \
  --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --bp "stop at com.example.MyClass:42" \
  --auto-inspect 20 --timeout 60
```

`--auto-inspect 20` generates `run`, then 20 cycles of `where`, `locals`, and `cont`, then `quit`. With `--timeout 60`, the session cannot hang on a deadlocked app: the script kills it after 60 s and writes a `TIMEOUT:` marker to the output.

## 3. Enabling JDWP on a running application

If the target JVM runs without JDWP, restart it with the agent. Whether you pass a flag or use `JAVA_TOOL_OPTIONS` depends on whether a build tool starts the JVM.

```bash
# Direct java launch
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005 \
     -cp myapp.jar com.example.Main

# Maven Spring Boot
mvn spring-boot:run -Dspring-boot.run.jvmArguments="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"

# Gradle Spring Boot
./gradlew bootRun --jvmArgs="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"

# As env var (affects ALL Java processes in the shell — including build tools)
export JAVA_TOOL_OPTIONS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"
```

All examples bind to IPv4 loopback, because JDWP has no authentication. Anyone who reaches the port can run arbitrary code in the JVM.

The `JAVA_TOOL_OPTIONS` variant reaches every JVM that the shell starts, including Maven and Gradle themselves. If a second JVM reads the variable, it tries to bind the same port and fails (see [`../../jvm-remote-debug/references/wiring.md`](../../jvm-remote-debug/references/wiring.md), section "JAVA_TOOL_OPTIONS is inherited").

For a JVM in a pod, keep the `127.0.0.1` bind and use `kubectl port-forward` (see [`../../jvm-remote-debug/SKILL.md`](../../jvm-remote-debug/SKILL.md) and [`../../jvm-remote-debug/references/jmx-jolokia-ports.md`](../../jvm-remote-debug/references/jmx-jolokia-ports.md)). A forwarded connection arrives in the pod from `127.0.0.1`, so the loopback bind accepts it. A host jdb 25.0.5 attached through `kubectl port-forward 15005:5005` to a JDK 21.0.13 target bound to `127.0.0.1:5005`, and `version` and `threads` worked (measured 2026-11-15 on OrbStack Kubernetes, a container and Kubernetes runtime for macOS whose cluster runs Docker behind the CRI, the Container Runtime Interface of the kubelet). containerd and CRI-O implement port-forward differently, so the result applies only to clusters that run Docker through the CRI and was not measured on other clusters. For details and limits, see [`jdwp-options.md`](jdwp-options.md), section "Kubernetes", and for OrbStack itself [`../../jvm-remote-debug/references/orbstack-telepresence.md`](../../jvm-remote-debug/references/orbstack-telepresence.md).

For all JDWP agent options (suspend, onthrow, security implications, the JDK 9+ change of the default bind, listening on all interfaces with `address=*:5005`), see [`jdwp-options.md`](jdwp-options.md).

## 4. Interactive JDB session — command catalogue

In a JDB session, send one command at a time and read its output before you send the next. JDB is line-oriented, so do not pipe a stream of commands into it without delays (the batch scripts insert them, see §6).

### Breakpoints

```
stop at com.example.MyClass:42          # break at line 42
stop in com.example.MyClass.myMethod    # break at method entry
stop in com.example.MyClass.<init>      # break at constructor
stop in com.example.MyClass.<clinit>    # break at static initialiser
stop in com.example.MyClass.process(int,java.lang.String)   # overloaded method: give the parameter types
```

### Running and stepping

```
run                  # start the application (launch mode only; no-op when attached)
cont                 # resume after a breakpoint
step                 # step into the next line (enters method calls)
next                 # step over (does not enter method calls)
step up              # run until the current method returns
```

### Inspecting state

```
locals               # all local variables in the current frame
print myVariable     # value of a variable or an expression
print myObj.getX()   # evaluates a method call
dump myObject        # all fields of an object
eval 2 + 2           # arbitrary expression
```

> `print` and `eval` call methods on live objects: `print order.getTotal()` really invokes `getTotal()`, and its side effects apply. Do not use them on production state unless you know what the method does.

### Call stack navigation

```
where                # current thread's call stack
where all            # call stacks for all threads
up                   # one frame up
down                 # one frame down
up 3                 # three frames up
```

### Threads

```
threads              # list all threads with state
thread main          # switch to the "main" thread
thread 0x1a3         # switch by hex thread ID
suspend 0x1a3        # suspend a specific thread
resume 0x1a3         # resume a specific thread
```

### Exceptions

```
catch java.lang.NullPointerException    # break on NPE
catch java.lang.Exception               # break on any Exception
catch all                               # break on all throwables
ignore java.lang.NullPointerException   # stop catching NPE
```

### Classes and methods

```
classes                          # list all loaded classes
class com.example.MyClass        # show details of a class
methods com.example.MyClass      # list methods
fields com.example.MyClass       # list fields
```

### Managing breakpoints

```
clear                                       # list all breakpoints
clear com.example.MyClass:42                # remove a line breakpoint
clear com.example.MyClass.myMethod          # remove a method breakpoint
```

### Source code

```
list                  # source around the current line
list 50               # source around line 50
use /path/to/sources  # set the source path
sourcepath            # show the current source path
classpath             # show the current classpath
```

### Exit

```
quit                  # detach and exit JDB
exit                  # same as quit
```

The full alphabetical command reference is in [`jdb-commands.md`](jdb-commands.md).

## 5. Debugging workflow patterns

### Pattern 1 — Investigate a NullPointerException (batch mode)

```bash
scripts/jdb-breakpoints.sh \
  --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --bp "stop at com.example.MyClass:42" \
  --bp "stop in com.example.MyClass.processMessage" \
  --auto-inspect 20
```

With `--auto-inspect` (see §2), the captured output contains the full stack, all local variables, and the exception details.

If the app can hang, add a timeout:

```bash
scripts/jdb-breakpoints.sh --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --auto-inspect 10 --timeout 60
```

For your own command sequence instead of `--auto-inspect`, use `--cmd`:

```bash
scripts/jdb-breakpoints.sh --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --cmd "run" --cmd "where" --cmd "locals" --cmd "print myVar" \
  --cmd "cont" --cmd "where" --cmd "locals" --cmd "cont" --cmd "quit"
```

### Pattern 2 — Watch a method's behaviour interactively

```
stop in com.example.Service.processOrder
cont
locals
next
print result
next
print result
```

### Pattern 3 — Diagnose a deadlock

```
threads
where all
thread <blocked-thread-id>
where
```

JDB shows the deadlocked threads in the MONITOR state, each holding a different lock. For a long-running or production deadlock, the JFR reports `jfr view contention-by-thread` and `contention-by-site` are usually more efficient (see the view table in [`jfr.md`](jfr.md#52-predefined-views-jdk-21--most-important-for-agents)).

### Pattern 4 — Inspect values at a specific line

```
stop at com.example.DataProcessor:128
cont
locals
print config.getTimeout()
dump dataMap
```

## 6. Important notes and pitfalls

- **Never create files in the workspace.** Use the inline flags `--bp`, `--cmd`, `--auto-inspect`, and `--timeout` of `jdb-breakpoints.sh` (see §2).
- **Use `--timeout` if the app can hang.** An app that deadlocks or loops forever blocks JDB forever. `--timeout 60` (or longer) kills the session at a fixed time (see §2).
- **Compile with `-g` for full debug info.** Without it, `locals` reports "Local variable information not available". Run `javac -g -d out src/main/java/com/example/MyClass.java`. Gradle and Maven already do this by default: Gradle sets `compileJava { options.debug = true }` in every Java build, and the `maven-compiler-plugin` of Maven defaults to `debug=true`.
- **JDB is line-oriented** (see §4). The batch scripts insert configurable delays: `JDB_BP_DELAY` (2 s), `JDB_RUN_DELAY` (3 s), `JDB_CMD_DELAY` (0.5 s), and `JDB_CONT_DELAY` (1 s).
- **Set the source path.** Use `-sourcepath` on the command line or `use` in a session. Without it, `list` cannot show source.
- **Set the classpath.** `print obj.method()` and `dump` find only classes that are on the classpath.
- **Mind the thread context.** Many commands operate on the "current thread". Switch it with `thread <id>`.
- **Re-attach after `quit`.** `quit` detaches, the target JVM keeps running, and the agent listens again. With a fixed port, you attach to the same port again. With `address=...:0`, the agent picks a NEW port after every detach and refuses the old one. Read the newest `Listening for transport dt_socket at address: N` line (measured 2026-11-15 on Temurin 11.0.33, 17.0.21 and 25.0.5, in a container). Details are in [`jdwp-options.md`](jdwp-options.md).
- **Attach to `127.0.0.1`, not `::1`.** `address=5005` and `address=127.0.0.1:5005` bind IPv4 loopback only, so an attach to `::1` is refused (measured 2026-11-15 on Temurin 11.0.33, 17.0.21 and 25.0.5, in a container).
- **In a pod, bind IPv4 `127.0.0.1` or a wildcard, never `::1` or the pod IP.** `kubectl port-forward` connects only to IPv4 `127.0.0.1` in the pod, so it cannot reach a listener on `::1` or on the pod IP. A refused forwarded connection also ends the whole port-forward process, including every other port in it (measured 2026-11-15 on OrbStack Kubernetes with kubectl port-forward; details in [`jdwp-options.md`](jdwp-options.md), section "Kubernetes").
- **Choose the suspend mode.** With `suspend=y`, the JVM pauses until JDB connects, which catches startup bugs. With `suspend=n`, the JVM does not wait, which suits an attach to a production-like process.
- **Expression evaluation calls methods** and their side effects apply (see §4, "Inspecting state").

## 7. Reference files

- [`jdb-commands.md`](jdb-commands.md): the complete alphabetical command reference.
- [`jdwp-options.md`](jdwp-options.md): every JDWP agent flag (transport, server, suspend, address, onthrow, onuncaught) and the defaults that depend on the JDK version.
- [`jfr.md`](jfr.md): JVM-internal observation (GC, allocation, locks, custom events). JFR and JDB answer different questions.
- [`scala-jvm.md`](scala-jvm.md): the Scala-specific name mangling that you meet when you step through bytecode.
