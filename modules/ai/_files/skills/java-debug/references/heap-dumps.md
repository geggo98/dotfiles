Applies to: everywhere (run the commands on the host or in the container where the JVM runs)

# Heap Dumps and Class Histograms

TL;DR: Start with `jcmd <pid> GC.class_histogram -all`, taken several times. It often names the leaking
class. Take a heap dump only when the histogram is not enough, because a dump pauses the JVM, is about as
large as the live heap, and contains every secret that the JVM holds in memory. For an `OutOfMemoryError`,
set the dump flags in advance, and give each dump its own file name (`%p` or a directory, see §3).

## Contents

- [1. Class histogram first](#1-class-histogram-first)
- [2. Heap dump on demand](#2-heap-dump-on-demand)
- [3. Heap dump on OutOfMemoryError](#3-heap-dump-on-outofmemoryerror)
- [4. Analysis without a GUI](#4-analysis-without-a-gui)
- [5. Where the dump goes in a container](#5-where-the-dump-goes-in-a-container)
- [6. Other JVM checks: TLS trust (`PKIX path building failed`)](#6-other-jvm-checks-tls-trust-pkix-path-building-failed)

## 1. Class histogram first

```bash
jcmd <pid> GC.class_histogram -all | head -40
```

The output lists the classes by instance count and bytes. Measured 2026-11, JDK 25, and again 2026-11-15
on Temurin 17.0.21, 21.0.13 and 25.0.5, in a container.

With `-all`, the counts include garbage that the next GC removes. A class with high churn therefore grows
between two GCs without being a leak. Compare several samples taken minutes apart, and look for growth
that survives GC cycles: check `jcmd <pid> GC.heap_info` or the GC log between the samples (to enable
the GC log, see [`profiling-and-threads.md`](profiling-and-threads.md) §2). A class whose count keeps
growing across GC cycles is the leak candidate.

> **Warning:** without `-all`, `GC.class_histogram` forces a full GC first. On a large heap, that is a long
> stop-the-world pause. With `-all`, the JVM counts all objects, including unreachable ones, and skips the
> full GC. The histogram still stops the JVM while it walks the heap, which takes seconds on a heap of
> many GiB. Measured 2026-11-15 on Temurin 17.0.21, 21.0.13 and 25.0.5 with G1 (the default collector,
> `-XX:+UseG1GC`), in a container, and also with Serial GC (`-XX:+UseSerialGC`) on
> 21.0.13: the plain histogram logged one `Pause Full (Heap Inspection Initiated GC)`, and three `-all`
> runs logged none.

When the histogram shows no growing heap class but the process memory still grows, the cause is outside
the heap (metaspace, threads, direct buffers, native code). Continue with Native Memory Tracking (NMT) in
[`profiling-and-threads.md`](profiling-and-threads.md) §2.

## 2. Heap dump on demand

```bash
mkdir -p /var/tmp/dumps && chmod 700 /var/tmp/dumps
df -h /var/tmp/dumps                                 # free space >= live heap size
jcmd <pid> GC.heap_dump /var/tmp/dumps/app.hprof
```

> **Warning:**
> - The dump is a stop-the-world pause. Do not take it on a production JVM without the owner's consent.
> - The file is about as large as the live heap, so it can fill a volume.
> - The dump holds every secret in memory: passwords, tokens, keys and session data. Handle it like a
>   credential store. Never attach it to a ticket, never commit it, and delete it after the analysis.

`GC.heap_dump` refuses an existing file. It prints `Unable to create <file>: File exists` and leaves the
file unchanged, but **`jcmd` still exits 0**. Check the message text, because the exit code is the same
in both cases. `-overwrite` (`jcmd <pid> GC.heap_dump -overwrite <file>`) replaces
the file. Measured 2026-11-15 on Temurin 17.0.21, 21.0.13 and 25.0.5, in a container.

Use an absolute path. The target JVM evaluates the path, not the shell that runs `jcmd`. A relative path
therefore lands in the working directory of the JVM, and in a container the path is inside the container.

`/actuator/heapdump` ([`../scripts/actuator.sh`](../scripts/actuator.sh) `heapdump <file>`) produces
the same HPROF file over HTTP, and the same warnings apply. Setup: [`actuator.md`](actuator.md).

## 3. Heap dump on OutOfMemoryError

```bash
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/var/tmp/dumps/app_%p.hprof
-XX:+ExitOnOutOfMemoryError
```

- **The JVM expands `%p` to the PID. It does NOT expand `%t`.** Measured 2026-11-15, Temurin 25.0.5: with
  `dump_%p_%t.hprof`, the file was named `dump_85270_%t.hprof`. Some web answers claim that `%t` works.
- `%p` was measured on Temurin 25 only. On an older JDK, check once whether the JVM expands `%p`. The form
  that works on every version is a directory: `-XX:HeapDumpPath=/var/tmp/dumps/` gives
  `java_pid<pid>.hprof` in that directory (measured 2026-11-15 on Temurin 17.0.21, 21.0.13 and 25.0.5, in
  a container).
- The JVM refuses to write the dump when the file already exists. It prints
  `Unable to create <path>: File exists`, keeps the old file and writes no other dump (measured
  2026-11-15 on Temurin 17, 21 and 25, in a container). A fixed name therefore fails on the second
  `OutOfMemoryError`, or for a second JVM on the same volume.
- In a container, the PID is the same after every restart (usually 1), so `%p` does not make the name
  unique there. Move or delete the old dump, or the next `OutOfMemoryError` writes none.
- If the JVM cannot write to `HeapDumpPath` (read-only path, missing directory), it writes no dump
  anywhere. It prints `Unable to create <path>: <error>` and has no fallback directory. Only when
  `HeapDumpPath` is not set does `java_pid<pid>.hprof` land in the working directory of the JVM.
  Measured 2026-11-15 on Temurin 17.0.21, 21.0.13 and 25.0.5, in a container.
- `-XX:+ExitOnOutOfMemoryError` ends the JVM after the dump. A container then restarts cleanly instead of
  running on in a broken state.

An `OutOfMemoryError` is not the same as a container that was OOMKilled (exit 137). OOMKilled means that
the kernel killed the process at the cgroup limit, so there is no Java stack trace and no heap dump. See
[`../../jvm-remote-debug/references/wiring.md`](../../jvm-remote-debug/references/wiring.md#oomkilled-vs-outofmemoryerror).

## 4. Analysis without a GUI

Eclipse Memory Analyzer (MAT) has a headless mode that writes HTML reports as ZIP files next to the dump.
`ParseHeapDump.sh` ships in the root directory of the MAT standalone download
(<https://eclipse.dev/mat/download/>). Run it from that directory or with its full path:

```bash
ParseHeapDump.sh /var/tmp/dumps/app_1234.hprof \
  org.eclipse.mat.api:suspects \
  org.eclipse.mat.api:overview \
  org.eclipse.mat.api:top_components
# -> one report ZIP per report ID, next to the dump
```

- As a starting point, set `-Xmx` in `MemoryAnalyzer.ini` (in the MAT installation directory, next to
  `ParseHeapDump.sh`; on macOS inside `MemoryAnalyzer.app/Contents/Eclipse/`) to about the size of the
  dump (a rule of thumb, not measured).
- MAT also writes index files next to the dump. They are as sensitive as the dump, so handle and delete
  them the same way.
- This section was not measured by this skill's author. Check the MAT documentation of the installed
  version for the report IDs.

## 5. Where the dump goes in a container

- Write to a volume with enough free space, not to the container layer, because the layer counts against
  `ephemeral-storage`.
- An `emptyDir` with `medium: Memory` counts against the container's memory limit. A dump there can get
  the pod OOMKilled in the middle of the dump.
- For getting the file out of the pod (`kubectl cp` needs `tar`, and there are alternatives without it)
  and for the size or checksum check, see
  [`../../jvm-remote-debug/references/debug-without-tools.md`](../../jvm-remote-debug/references/debug-without-tools.md).
- In a cluster, take a heap dump only on the user's explicit request, because of the pause, the size and
  the secrets (§2).

## 6. Other JVM checks: TLS trust (`PKIX path building failed`)

`PKIX path building failed` or `unable to find valid certification path` means that the JVM does not
trust the server certificate chain. The JDK uses its own trust store (`cacerts`), not the trust store of
the operating system. Updating the OS package `ca-certificates` in an image therefore does not change the
JDK's trust.

```bash
# Is the CA in the JDK trust store? Search the subject (Owner:), not the alias. Aliases look like
# cn_isrg_root_x1,o_internet_security_research_group,c_us [jdk], so 'ISRG Root X1' never matches them.
# Check the entry count too (> 0). Otherwise an empty result can just mean the wrong JDK or store.
keytool -list -cacerts -storepass changeit | grep -c 'Certificate fingerprint'
keytool -list -v -cacerts -storepass changeit | grep -i 'Owner:.*<ca-name>'
java -Djavax.net.debug=ssl:handshake -jar app.jar          # shows the chain that the server sends
```

To fix it, import the CA into the `cacerts` of the JDK that runs the app, or into a trust store that you
pass with `-Djavax.net.ssl.trustStore=<file>`.

