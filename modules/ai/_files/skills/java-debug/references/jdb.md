# Java Debugger (JDB) — Interactive Step-Debugging via JDWP

Debug Java applications interactively from the command line: attach to a running JVM or launch a new one under JDB, set breakpoints, step through code, inspect state, analyse threads, and diagnose exceptions or deadlocks.

> For step-debugging Scala-on-JVM, see `scala-jvm.md` for Scala-specific name-mangling caveats. For "JVM is hung" diagnosis, the JFR view `contention-by-thread` is often faster than a JDB session — see `jfr.md`.

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
  │   └─ Catch a specific exception → use `catch` (§4) or the --bp flag in jdb-breakpoints.sh
  │
  └─ Done debugging → detach cleanly with `quit` or Ctrl+C
```

## 2. Quick start

### Launch a new JVM under JDB

```bash
scripts/jdb-launch.sh com.example.MyApp --sourcepath src/main/java
```

### Attach to a running JVM

The target JVM must have been started with the JDWP agent (see §3). Then:

```bash
scripts/jdb-attach.sh --host localhost --port 5005
```

### Collect diagnostics (thread dump + deadlock detection)

```bash
scripts/jdb-diagnostics.sh --port 5005
```

### Automated batch debugging (no workspace files!)

The skill's golden rule: **never create files in the workspace** (no `bp.txt`, no `cmds.txt`, no wrapper scripts). Use inline `--bp` / `--cmd` / `--auto-inspect` instead:

```bash
scripts/jdb-breakpoints.sh \
  --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --bp "stop at com.example.MyClass:42" \
  --auto-inspect 20 --timeout 60
```

`--auto-inspect 20` generates `run` + 20 cycles of `where`, `locals`, `cont`, then `quit`. Combined with `--timeout 60` it cannot hang on a deadlocked app — the session is killed after 60 s with a `TIMEOUT:` marker in the output.

## 3. Enabling JDWP on a running application

If the target JVM was not started with JDWP, the simplest mitigation is to restart with the agent. The choice between flags and `JAVA_TOOL_OPTIONS` depends on whether the build tool is in the picture.

```bash
# Direct java launch
java -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005 \
     -cp myapp.jar com.example.Main

# Maven Spring Boot
mvn spring-boot:run -Dspring-boot.run.jvmArguments="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005"

# Gradle Spring Boot
./gradlew bootRun --jvmArgs="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005"

# As env var (affects ALL Java processes in the shell — including build tools)
export JAVA_TOOL_OPTIONS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005"
```

For all JDWP agent options (suspend, onthrow, security implications, JDK 9+ default-bind change), see [`jdwp-options.md`](jdwp-options.md).

## 4. Interactive JDB session — command catalogue

Once inside a JDB session, use these commands one at a time and read the output before the next. JDB is line-oriented; don't pipe a stream of commands without delays.

### Breakpoints

```
stop at com.example.MyClass:42          # break at line 42
stop in com.example.MyClass.myMethod    # break at method entry
stop in com.example.MyClass.<init>      # break at constructor
stop in com.example.MyClass.<clinit>    # break at static initialiser
stop in com.example.MyClass.process(int,java.lang.String)   # overloaded — specify param types
```

### Running and stepping

```
run                  # start the application (launch mode only; no-op when attached)
cont                 # resume after a breakpoint
step                 # step into the next line (enters method calls)
next                 # step over (does not enter method calls)
step up              # run until current method returns
```

### Inspecting state

```
locals               # all local variables in the current frame
print myVariable     # value of variable or expression
print myObj.getX()   # evaluates a method call
dump myObject        # all fields of an object
eval 2 + 2           # arbitrary expression
```

> `print` and `eval` can call methods on live objects — use carefully on production state.

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
clear com.example.MyClass:42                # remove line breakpoint
clear com.example.MyClass.myMethod          # remove method breakpoint
```

### Source code

```
list                  # source around current line
list 50               # source around line 50
use /path/to/sources  # set source path
sourcepath            # show current source path
classpath             # show current classpath
```

### Exit

```
quit                  # detach and exit JDB
exit                  # same as quit
```

The full alphabetical command reference lives in [`jdb-commands.md`](jdb-commands.md).

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

The `--auto-inspect 20` flag runs `run` + 20 cycles of `where` + `locals` + `cont`, then `quit`. The captured output contains the full stack, all locals, and exception details — ready for analysis.

For potentially hanging apps add a timeout:

```bash
scripts/jdb-breakpoints.sh --mainclass com.example.MyClass \
  --bp "catch java.lang.NullPointerException" \
  --auto-inspect 10 --timeout 60
```

For custom command sequences instead of `--auto-inspect`:

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

JDB shows threads in MONITOR state holding different locks. For sustained or production deadlock analysis JFR's `jfr view contention-by-thread` / `contention-by-site` reports are typically more efficient — see `jfr.md`.

### Pattern 4 — Inspect values at a specific line

```
stop at com.example.DataProcessor:128
cont
locals
print config.getTimeout()
dump dataMap
```

## 6. Important notes and pitfalls

- **Never create files in the workspace.** Use inline `--bp` / `--cmd` / `--auto-inspect` / `--timeout` on `jdb-breakpoints.sh`. The script handles all temp files internally in `/tmp/` and cleans up.
- **Use `--timeout` for potentially hanging apps.** Apps that deadlock or loop indefinitely block JDB forever. `--timeout 60` (or longer) kills the session deterministically, with a `TIMEOUT:` marker in the output.
- **Compile with `-g` for full debug info.** Without it `locals` reports "Local variable information not available". Run `javac -g -d out src/main/java/com/example/MyClass.java` (Gradle: `compileJava { options.debug = true }` — default in `application` builds anyway).
- **JDB is line-oriented.** Send one command at a time, read the output, then continue. The batch scripts insert configurable delays via `JDB_BP_DELAY` (2 s), `JDB_RUN_DELAY` (3 s), `JDB_CMD_DELAY` (0.5 s), `JDB_CONT_DELAY` (1 s).
- **Source path matters.** Use `-sourcepath` (CLI) or `use` (interactive) so `list` can show source.
- **Classpath matters.** Compiled classes must be reachable so `print obj.method()` and `dump` can find them.
- **Thread context.** Many commands operate on the "current thread". Switch with `thread <id>`.
- **Suspend mode.** With `suspend=y` the JVM pauses until JDB connects — good for catching startup bugs. `suspend=n` is non-blocking, good for production-like attachment.
- **Expression evaluation calls methods.** `print order.getTotal()` actually invokes `getTotal()` on a live object. Side effects apply — don't use on production state without understanding what runs.

## 7. Reference files

- [`jdb-commands.md`](jdb-commands.md) — complete alphabetical command reference.
- [`jdwp-options.md`](jdwp-options.md) — every JDWP agent flag (transport, server, suspend, address, onthrow, onuncaught, JDK-version-dependent defaults).
- [`jfr.md`](jfr.md) — when you need JVM-internal observation (GC, allocation, locks, custom events) — orthogonal to JDB.
- [`scala-jvm.md`](scala-jvm.md) — Scala-specific name-mangling caveats when stepping through bytecode.
