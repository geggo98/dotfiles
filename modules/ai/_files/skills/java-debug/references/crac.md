Applies to: Linux, container/Kubernetes (macOS: simulation only)

# CRaC: Debugging Checkpoint and Restore

TL;DR: CRaC (Coordinated Restore at Checkpoint) saves a warmed-up JVM to disk and restores it in
milliseconds. A checkpoint fails when the JVM holds open sockets, writable files or pipes. For that
reason, listener agents (Jolokia, remote JMX, nREPL) do not belong in a JVM that you checkpoint. Debug
the same container image instead, started normally without `-XX:CRaCRestoreFrom`. JDWP and a JFR
recording do not block the checkpoint on Zulu 25.0.5 CRaC (§4). Values that the app read before the checkpoint stay old after the restore.

This file debugs a checkpoint that fails or a restore that misbehaves. To decide whether CRaC fits, and
to build, bake, deploy and verify a checkpoint, see the skill
[`java-fast-startup`](../../java-fast-startup/SKILL.md), in particular
[crac-build-and-deploy.md](../../java-fast-startup/references/crac-build-and-deploy.md) and
[security.md](../../java-fast-startup/references/security.md).

Measured lines marked "2026-11-15" ran in containers on arm64 (OrbStack, a local Docker and Kubernetes
runtime for macOS, see
[orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md); kernel 7.2) with
Azul Zulu 25.0.5 CRaC (Zulu25.38+109-CRaC-CA, warp 2.12.0, CRIU 3.17.1-crac). They used three test base
images: Ubuntu 24.04 (glibc 2.39), Ubuntu 25.10 (glibc 2.42) and Alpine 3.22 (musl 1.2.5). x86_64 was not
measured. Lines marked "2026-08" or "2026-09" ran with Zulu 25. The other details of those runs (JDK
build, engine, base image, Kubernetes runtime) are unknown. Such a line tells only what it states itself,
for example "in Kubernetes on arm64".

## Contents

- [1. Platform and engines](#1-platform-and-engines)
- [2. What blocks a checkpoint](#2-what-blocks-a-checkpoint)
- [3. What the restored process sees](#3-what-the-restored-process-sees)
- [4. Debug agents and CRaC](#4-debug-agents-and-crac)
- [5. Version traps and checkpoint images](#5-version-traps-and-checkpoint-images)

## 1. Platform and engines

CRaC needs Linux. On macOS, only a simulation engine exists (not measured for this skill): `simengine`, the macOS
default of `-XX:CRaCEngine` in the OpenJDK CRaC source. It writes no process image. A checkpoint is a no-op,
so the JVM keeps running and nothing can be restored later. It exists to develop and test the
`jdk.crac.Resource` callbacks of an app (`beforeCheckpoint` and `afterRestore`, which §2 explains under
"Resource class") on a platform without a real engine (source:
[`libsimengine/README.md`](https://github.com/openjdk/crac/blob/crac/src/java.base/share/native/libsimengine/README.md)).
The real engines run in a Linux container, also under Docker or OrbStack on Apple Silicon.

| Engine | Privileges | Notes |
|---|---|---|
| `warp` (Azul) | none extra | The default engine of Zulu 25.0.5 CRaC. Ran unprivileged in Kubernetes on arm64 (measured 2026-08, Zulu 25). Checkpoint and restore worked with all capabilities dropped, with `no-new-privileges` and as uid 1000 (measured 2026-11-15, Zulu 25.0.5 CRaC, all three test base images, in a container) |
| `criuengine` (CRIU) | fully privileged container | CRIU (Checkpoint/Restore In Userspace) is the Linux tool that dumps a process tree to image files and restores it from them. `criuengine` is the JVM's adapter to it. The lowest step that works is `--privileged`, also as uid 1000 (measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04 and Alpine 3.22, in a container). Details below |

Choose between the engines by privileges, not by architecture. CRIU works on aarch64 too, but it needs
rights that a normal pod does not have. Select the engine with `-XX:CRaCEngine=<name or path>`.
`-XX:CRaCEngineOptions=help` prints the engine's description, version and options, and exits with 0
(measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04, in a container). For warp, the options include
`direct_map`, `keep_running`, `checkpoint_exit_code` and `checkpoint_exit_signal`. The `help` output
describes each of them. §5 explains `direct_map`, the only one this file uses.

**Engine on restore:** a warp image directory holds a file `engine` (content `warp`), and a restore
without `-XX:CRaCEngine` finds it. A CRIU image needs `-XX:CRaCEngine=criuengine` on the restore
command again. Without the flag, the JVM falls back to warp and fails with misleading messages (measured
2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04, caps step of the table below, in a container):

```
[error][crac] Image format does not match; saved image with engine criuengine, restoring with warp
[error][crac] Restore failed due to wrong or missing CPU architecture (current architecture is aarch64)
```

**CRIU rights, step by step** (measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04, in a container):

| Step | uid 1000 | root |
|---|---|---|
| Unprivileged step (no capabilities, `no-new-privileges`) | Checkpoint fails: `kcmp failed: ... Operation not permitted` | not measured |
| Caps step (`CAP_SYS_PTRACE` + `CAP_CHECKPOINT_RESTORE`, with or without seccomp) | Checkpoint fails: `Can't open dir <dir>: Permission denied` | Checkpoint works. Restore fails: `Can't fork for <pid>: Read-only file system` (`/proc/sys` is read-only) |
| Privileged step (`--privileged`) | Checkpoint and restore work | Checkpoint and restore work |

`lib/criu` in the Zulu CRaC distribution ships **setuid root** (mode 4555). It is the only setuid file
beyond the distribution's defaults. Under `no-new-privileges`, it stays at the caller's uid. In the caps
step and the privileged step, it runs as euid 0. The restored JVM keeps the uid that the image records
(see §5 for what that means for a checkpoint taken as root).

**Process layout of warp:** warp is a library inside the JVM process (`lib/libwarp.so`), not a separate
engine process (measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04, in a container):

- A JVM that a shell or an init starts is one process. On the Ubuntu 24.04 and 25.10 test images
  (glibc), its process name is `exe`, not `java`, so `pgrep java` misses it.
- Only when the `java` launcher itself is PID 1 is there a second process: PID 1 is the plain launcher,
  and the JVM is its child. `jcmd 1` then times out.
- A restored JVM takes the PID of the restore command and has an empty `/proc/<pid>/cmdline`, so
  `pgrep -f` finds nothing. When the restore command is PID 1, the restored JVM is PID 1.

`pgrep -P 1 | head -1` is therefore unreliable, because it returns whatever child of PID 1 has the lowest
PID, for example a shell. Find the JVM with `jcmd -l`, which lists it by main class, also after a restore.
`VM.flags` is a harmless test that you reached the JVM:

```bash
env -u JAVA_TOOL_OPTIONS jcmd -l
env -u JAVA_TOOL_OPTIONS jcmd <pid> VM.flags
```

To trigger the checkpoint, use the same PID:

```bash
env -u JAVA_TOOL_OPTIONS jcmd <pid> JDK.checkpoint
```

> **Warning:** in a cluster, trigger a checkpoint only on the user's explicit request. The JVM stops after
> it writes the checkpoint, so the container exits. The JVM must have been started with
> `-XX:CRaCCheckpointTo=<dir>`.

**Reading the result** (measured 2026-11-15, Zulu 25.0.5 CRaC, warp, Ubuntu 24.04, in a container):
`jcmd ... JDK.checkpoint` exits with 0 whether the checkpoint worked or not. Do not test `$?`, because it
cannot tell the two cases apart. Read the output instead:

- Success: jcmd prints `0` after the PID line, the log ends with `warp: Checkpoint successful!`, and
  warp kills the JVM with SIGKILL (exit status 137, which is also the container's exit status when the
  launcher is PID 1).
- Failure: jcmd prints a `CheckpointException` with the reasons, and the JVM keeps running.
- Without `-XX:CRaCCheckpointTo`: jcmd prints `C/R is not configured`, and the JVM logs
  `CRaCCheckpointTo is not specified`.
- CRIU: a failed dump can leave `pages-*.img` files behind. Only a `core-*.img` file plus exit status 137
  show success (measured 2026-11-15, Ubuntu 25.10, privileged, in a container).

For an app without warm-up, a warp restore was about as fast as a cold start. A cold start reached app
code in 18 to 44 ms, and a restore with `direct_map=false` in 16 to 23 ms (one run up to 128 ms) (measured
2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04, unprivileged, in a container).
The gain comes from the skipped warm-up. **Open inconsistency:** [crac-engines.md](../../java-fast-startup/references/crac-engines.md) reports PetClinic restored in 43 to 62 ms with no request before the checkpoint, so the skipped work there is the framework start, not a warm-up.

## 2. What blocks a checkpoint

Every row was measured 2026-11-15 with warp (Zulu 25.0.5 CRaC, Ubuntu 24.04, unprivileged, in a
container) unless the row says otherwise.

| Blocker | Example | Fix |
|---|---|---|
| Open listener socket | `ServerSocket` (`CheckpointOpenSocketException`). Jolokia 2.6.3 (busy NIO selector plus open channel and EPoll FDs). Remote JMX, Tomcat/Netty: not measured | Run no agents in this JVM. Use a CRaC-aware server: one that closes its listener in a `Resource` `beforeCheckpoint` and reopens it in `afterRestore` (see the resource class below). No such server was measured here |
| Open client socket | Database pool, HTTP client, also a connection to another process (one `CheckpointOpenSocketException` per socket) | Close it in a `jdk.crac.Resource` `beforeCheckpoint` and reopen it in `afterRestore` (see below) |
| Writable file handle | Rolling log appenders (`CheckpointOpenFileException: <path>`) | Log to the console only, or use a resource policy (below) |
| Pipe | I/O to a child process (one `CheckpointOpenResourceException` per stream) | Close it before the checkpoint |

These are not blockers (same measurement): a JFR recording with a file, and the JDWP agent. See §4.

`-XX:CRaCAllowedOpenFilePrefixes` did NOT cover writable handles (measured 2026-08, again 2026-11-15), so
it is no way around an open log file. This matches the flag's description in the OpenJDK CRaC source
([`src/hotspot/share/runtime/globals.hpp`](https://github.com/openjdk/crac/blob/crac/src/hotspot/share/runtime/globals.hpp)):
the option applies only to files that native code opened. For files that Java code opened, use
`-Djdk.crac.resource-policies` (below).

**Resource class:** on a CRaC JDK, `jdk.crac.Resource` registered with
`jdk.crac.Core.getGlobalContext().register(...)` works without any dependency (keep a strong reference
to it). `org.crac.Resource` comes from the portable wrapper library `org.crac:crac`
([github.com/CRaC/org.crac](https://github.com/CRaC/org.crac), not measured). Portable means: on a JDK
without CRaC, registered resources are accepted but never called, and a checkpoint request throws an
exception.

> **Warning: application threads run before `afterRestore`.** Hold a lock (for example a `Semaphore`
> that the writer also takes) from `beforeCheckpoint` until `afterRestore` has reopened the resource.
> After a warp restore, the app threads resumed before the `afterRestore` callbacks and before the JDK's
> own reopen. A thread that writes to a stream that `beforeCheckpoint` closed then fails with
> `java.io.IOException: Stream Closed` (measured 2026-11-15).

Two diagnostic options are documented in the CRaC project docs
([`debugging.md`](https://github.com/CRaC/docs/blob/master/debugging.md) and
[`fd-policies.md`](https://github.com/CRaC/docs/blob/master/fd-policies.md)).
Both were measured 2026-11-15 as described:

- `-Djdk.crac.collect-fd-stacktraces=true` records where each open file descriptor was opened. The
  checkpoint error then gets a `Caused by: java.lang.Exception: This file descriptor was created by ...`
  with the stack down to the opening line. Without the flag, the JVM prints the hint
  `Use -Djdk.crac.collect-fd-stacktraces=true to find the source.`
- `-Djdk.crac.resource-policies=<file.yaml>` declares per file what to do at checkpoint time.
  According to the docs it covers sockets too, but only files were measured. The policy matches by path:

  ```yaml
  type: file
  path: /var/log/app.log
  action: reopen
  ```

  | `action` | Checkpoint | After the restore |
  |---|---|---|
  | `reopen` | passes | The JDK reopens the file. A write before the reopen fails (`Stream Closed`), see the warning above |
  | `close` | passes | The stream stays closed, and the next write throws `Stream Closed` |
  | `ignore` | passes | The descriptor is not restored, and the next write throws `Bad file descriptor` |

  The JDK warns `File <path> was not closed by the application.` To remove the warning, set
  `warn: false` in the policy. An unknown action fails the checkpoint with
  `Unknown policy action for path ...`.

## 3. What the restored process sees

- **The restore takes options from `JAVA_TOOL_OPTIONS`** (measured 2026-11-15, Zulu 25.0.5 CRaC, warp,
  Ubuntu 24.04, in a container). The restore command (`java -XX:CRaCRestoreFrom=...`) is a JVM launch
  and prints `Picked up JAVA_TOOL_OPTIONS`. Then:
  - `-D` properties reach the restored process, both from `JAVA_TOOL_OPTIONS` and from the restore
    command line.
  - Restore-settable flags are applied: `-XX:+HeapDumpOnOutOfMemoryError` from `JAVA_TOOL_OPTIONS` made
    the restored JVM write a heap dump. The OpenJDK CRaC source marks restore-settable flags
    `RESTORE_SETTABLE` in
    [`globals.hpp`](https://github.com/openjdk/crac/blob/crac/src/hotspot/share/runtime/globals.hpp),
    and every `MANAGEABLE` flag counts as restore-settable too. Manageable flags are the ones that
    `jcmd <pid> VM.set_flag` or the HotSpotDiagnostic MBean can change at run time;
    `java -XX:+PrintFlagsFinal` lists them with `{manageable}` in the kind column.
  - A flag that is not restore-settable aborts the restore:
    `Error: VM option 'ExitOnOutOfMemoryError' is not restore-settable and is not available on restore.`
    (exit 1, and the image stays usable).
  - `-Xlog:gc` was accepted, but only the restoring launcher logged. The restored process did not.

  Run a restore with `env -u JAVA_TOOL_OPTIONS`. Then a stray agent, dump path or flag neither changes
  the restored JVM nor aborts the restore.
- **Values cached at checkpoint time stay old:** Spring `@Value` fields, configuration read once at
  startup, and anything stored in a field.
- **Environment after a `warp` restore** (measured 2026-09, Zulu 25, and again 2026-11-15, Zulu 25.0.5
  CRaC, all three test base images, in a container): a fresh `System.getenv()` call returns the value of
  a variable that is set at restore. A variable that is absent at restore keeps its checkpoint value, so
  removing a secret variable does not remove it from the restored process. Cached values (a Spring
  `Environment`, `@Value` fields, static fields) stay old. CRIU was not measured, and some public sources
  report old values. **And there is a race.** In most measured restores,
  the first output of a resumed app thread still showed the old environment value, the old PID and the
  old system properties. The next output of that thread showed the new ones. An `afterRestore` callback
  already saw the new values. For that reason, read the environment in `afterRestore`, not in a thread
  that just resumed.
- **PID and output (warp):** the restored JVM runs under the PID of the restore command. It writes to the
  restore command's stdout and stderr, not to the files of the original JVM. A CRIU restore keeps the
  original PID (measured 2026-11-15, privileged, in a container).

Consequence: when the app cached a value, a changed environment variable or secret needs a new
checkpoint, not only a restore.

## 4. Debug agents and CRaC

- Do not put Jolokia, remote JMX or nREPL (a Clojure REPL server embedded in the app's JVM, see
  [spring-boot-repl](../../spring-boot-repl/SKILL.md)) into a JVM that will be checkpointed. Jolokia 2.6.3 blocks the
  checkpoint (measured 2026-11-15, Zulu 25.0.5 CRaC, warp, Ubuntu 24.04, in a container). Remote JMX and
  nREPL hold listener sockets like the measured `ServerSocket`. They were not measured themselves.
- **JDWP does not block** (same measurement). With no debugger attached, it logs
  `Exiting accept thread because of checkpoint`, and after the restore it listens on its port again. With
  `jdb` attached, the checkpoint also succeeds, and `jdb` reports `The application has been disconnected`.
  Attaching a debugger after the restore was not measured.
- **JFR with a file does not block** (same measurement). A JVM with
  `-XX:StartFlightRecording=filename=...` checkpoints and restores, and after the restore `JFR.check`
  shows a new `Recording 2`. The data from before the checkpoint ended up in a file with `.0` before the
  extension.
- Debug the same container image, started normally without `-XX:CRaCRestoreFrom`, and attach the
  tools you need ([jolokia.md](jolokia.md), [jmc.md](jmc.md), and jdb as in
  [Strategy C — JDB](../SKILL.md#strategy-c--jdb-java-debugger--jdwp)). That JVM is never
  checkpointed, so the listener sockets of the agents block nothing.
- Hot code replacement ([`spring-boot-repl`](../../spring-boot-repl/SKILL.md)) and CRaC exclude each
  other for the same JVM, because tools of that skill such as Arthas and nREPL hold listener
  sockets, and a listener socket blocks a checkpoint (§2; a plain `ServerSocket` and Jolokia were
  measured, these two tools were not). A flag in `JAVA_TOOL_OPTIONS` that is not restore-settable also
  aborts a restore (§3). See the CRaC row in
  [hotswap-in-cluster.md](../../jvm-remote-debug/references/hotswap-in-cluster.md).

## 5. Version traps and checkpoint images

**glibc >= 2.42:** glibc 2.42 installs thread stack guards as guard regions with
`madvise(MADV_GUARD_INSTALL)`. A guard region is a memory range that the kernel marks so that any access
to it faults. A dump tool must record such a range as a guard and must not read it like normal memory.
The guard regions sat on the stacks of some JVM-internal threads such as VM Thread, Reference Handler and Finalizer. The main thread and the
application threads had none. CRIU < 4.2 is reported to be unable to save them (the bound was not
measured). Support came with CRIU pull request
[checkpoint-restore/criu#2652](https://github.com/checkpoint-restore/criu/pull/2652), "Support
MADV_GUARD_INSTALL", whose commits lie between the tags v4.1 and v4.2. The bundled CRIU 3.17.1-crac fails
with `Can't splice all pages to pipe` (measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 25.10, privileged, in
a container). `warp` <= 2.9.0 is reported to crash with SIGSEGV by an earlier unpublished team measurement (2026-09).
The same earlier measurement reported (not re-measured) that no CRIU version worked on kernels 6.13 to 6.15
with glibc 2.42, that CRIU 4.2 failed intermittently, and that CRIU 4.2.1 on kernel 6.16 or later worked.
It was not re-measured, and a search of Azul's CRaC docs and the CRaC GitHub projects on 2026-11-15 found
no public source. The bundled warp 2.12.0 checkpoints and restores on glibc 2.42 with guard regions
present (measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 25.10, unprivileged, in a container). Check the
running JVM:

```bash
grep -c '^VmFlags:.* gu\b' /proc/<pid>/smaps   # > 0: guard regions are present, and CRIU 3.17.1 fails
uname -r; ldd --version | head -1                 # kernel and glibc, needed to interpret a 0
```

A `0` means "no guard regions" only on a kernel that reports the `gu` flag in `smaps`. An older kernel can
have guard regions without showing them. The glibc version is therefore the more reliable test, because
glibc is the trigger named above. Kernel 7.2 reports the flag, and the probe works with GNU grep and
busybox grep (measured 2026-11-15).

A base image with an older glibc or another libc (for example musl) avoids the problem (measured 2026-09,
and again 2026-11-15 with Ubuntu 24.04 and Alpine 3.22, both engines: 0 guard regions).

**Checkpoint directory on a noexec mount:** the default restore maps the image files directly
(`direct_map=true`), so the files must be executable. From a noexec mount, the restore fails (measured
2026-11-15, Zulu 25.0.5 CRaC, all three test base images, in a container):

- warp: `warp: error: Cannot change protection on <range> -> 7: Permission denied`, then `Aborted`
  (exit 134). This looks like a privilege problem but is not one.
- CRIU: `Can't read pages data (-1)`, `Restoring FAILED.`

Docker's `--tmpfs` and `/dev/shm` are noexec by default. There are two fixes, and both were measured:

- Keep the image on a mount without noexec. A read-only mount is enough, because the restore needs no
  write access to the image.
- Restore with `-XX:CRaCEngineOptions=direct_map=false`.

Kubernetes `emptyDir` was not measured. A CRIU restore also needs the files that the JVM had open (for
example a file that its stdout went to) at the same path.

**Checkpoint baked into an image layer** (measured 2026-11-15, Zulu 25.0.5 CRaC, Ubuntu 24.04, in a
container):

- File modes differ by engine. warp writes `core.img` with 0600, the directory with 0700 and the small
  `engine` file with 0644. CRIU writes its images with 0644, and only `dump4.log` with 0600. `dump4.log` is the log that
  CRIU writes into the checkpoint directory during the dump; the 4 is the log level.
- Keep mode 0600 on the checkpoint files, and set it explicitly for CRIU. The checkpoint is a copy of the
  heap and contains the same secrets as a heap dump (see [`heap-dumps.md`](heap-dumps.md)). Treat the
  image like a heap dump.
- With 0600 files, `COPY --chown=<jvm-user>` is required. Root-owned files that the JVM user cannot read
  make the restore fail with
  `OpenJDK 64-Bit Server VM warning: Cannot open file <dir>/engine due to Permission denied` and
  `CRaC engine failed to restore`. (Root-owned 0644 files in a 0755 directory did restore, but see the
  next point.)
- **Take the checkpoint as the JVM user.** A CRIU image keeps the credentials of the checkpointed
  process. A checkpoint taken as root restored as root, even when uid 1000 started the restore, and even
  after `chown` to uid 1000 and mode 0600 (privileged step, through the setuid `lib/criu`). A readable
  root checkpoint plus a usable setuid `lib/criu` is therefore a privilege escalation path.

