Applies to: CDS/AppCDS archives, Leyden AOT caches (JDK 24+), CRaC (warp and criuengine), container checkpoints, GraalVM Native Image

# Security: Can Secrets in RAM End Up on Disk?

TL;DR: Yes, for every checkpoint technique. A CRaC image or a container checkpoint is a plaintext copy of
the process memory, and it holds every credential the JVM had in memory, including environment variables
that the app never read. A CDS archive or an AOT cache held no environment or `-D` values in the
measurement, but it holds string literals and absolute paths, and a search with 0 hits never proves that a
file is clean. Take a checkpoint before the first secret loads, keep the files owner-only, never push them
to a registry, and scan them with [`checkpoint-secret-scan.py`](../scripts/checkpoint-secret-scan.py)
with a control string (section 5).

Evidence markers in this file:

- "measured 2026-11-16" = bare-metal macOS, Apple M2 Max, Temurin 25.0.5, Spring Boot 4.1.2 demo app
  (web and actuator, 7,958 loaded classes; not published). A canary is a unique dummy secret value that
  you plant in the training run or the checkpointed JVM and then search for in the files.
- "measured 2026-11-15" = Azul Zulu 25.0.5 CRaC (warp 2.12.0, CRIU 3.17.1-crac) in Linux containers on
  arm64, as described in [java-debug crac.md](../../java-debug/references/crac.md).
- "measured 2026-09" = earlier unpublished measurements by the skill's author with Azul Zulu 25 CRaC in
  Linux containers (an arm64 VM, and an x86 KVM host with 2 CPUs), see
  [measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers). The exact JDK build of
  each line was not recorded (**open inconsistency:** [crac-engines.md](crac-engines.md) Table A gives Zulu 25.0.4.1 for one of them, and the x86 KVM guest has 4 vCPUs with containers limited to 2 CPUs, see [measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers)).
- "measured 2026-11-16, Linux arm64 (OrbStack VM)" = Zulu CRaC 25.0.5 in Linux containers on arm64
  inside OrbStack, a Linux VM on macOS, demo app, canaries made fresh per run
  ([measuring.md §11](measuring.md#11-linux-vm-measurements)).
- warp is Azul's default CRaC engine, a library inside the JVM; criuengine is the alternative engine
  that uses CRIU (Checkpoint/Restore In Userspace). See [crac-engines.md](crac-engines.md).
- Training run, assembly step, one-step and two-step mode are the steps that create an AOT cache; see
  [leyden-aot.md](leyden-aot.md).
- "reported" = a public source; the kind of source follows in brackets.

## Contents

- [1. Disk-leak matrix per technique](#1-disk-leak-matrix-per-technique)
- [2. What a CRaC image holds](#2-what-a-crac-image-holds)
- [3. Mitigations](#3-mitigations)
- [4. CDS archives and AOT caches](#4-cds-archives-and-aot-caches)
- [5. Rule: 0 hits does not mean clean](#5-rule-0-hits-does-not-mean-clean)
- [6. Do not believe](#6-do-not-believe)

## 1. Disk-leak matrix per technique

"Who can read" assumes the default umask 022 unless the row says otherwise.

| Technique | What lands in the file | File modes | Who can read it | Evidence |
|---|---|---|---|---|
| JIT only (no cache, no checkpoint) | Nothing by default. A heap dump, a core dump or a JFR recording holds the heap, the environment and system properties | Heap dump: see [heap-dumps.md](../../java-debug/references/heap-dumps.md). JFR chunks: 0644, not changeable ([jfr.md §10](../../java-debug/references/jfr.md#10-pitfalls-measured-in-containers-and-on-network-file-systems)) | Everyone who can enter the directory | as linked |
| CDS / AppCDS archive (`.jsa`) | Class metadata, string literals of loaded classes. Absolute class-path entries. No environment or `-D` value found | Created with the umask: 0644 | Everyone who can enter the directory | measured 2026-11-16 |
| Leyden AOT cache (`.aot`, `.aotconf`) | Same as CDS, plus method profiles and archived heap objects (strings, class mirrors) of loaded classes. No environment or `-D` value found | Created with the umask: 0644 | Everyone who can enter the directory | measured 2026-11-16 |
| CRaC, warp engine | The whole process memory: heap, native memory, thread stacks. Every credential the JVM holds, also environment variables that the app never read | `core.img` 0600; the directory 0700 only if the JVM creates it; the small `engine` file 0644 | The JVM user. A directory that existed before (an `emptyDir`, a mounted volume) keeps its mode; one created with `mkdir` was 0755 | measured 2026-11-15, 2026-09, and 2026-11-16, Linux arm64 (OrbStack VM) |
| CRaC, criuengine | Same content as warp, split into many files | `pages-*.img` and the other images (`core-*.img`) 0644, only `dump4.log` 0600. A failed checkpoint leaves partial 0644 images | Everyone who can enter the directory | measured 2026-11-15, 2026-09, and 2026-11-16, Linux arm64 (OrbStack VM) |
| Container checkpoint (CRIU through runc or crun; Podman, CRI-O, containerd, kubelet) | Process memory, the container's tmpfs, deleted but open files (CRIU "ghost files"), the runtime's metadata files `spec.dump`/`config.dump` with the full process environment as plaintext JSON, and the container logs | not measured | not measured | measured 2026-09; Kubernetes pod checkpoint proposal: encryption at rest out of scope, reported ([KEP-5823](https://www.kubernetes.dev/resources/keps/5823/)) |
| GraalVM Native Image | Every value that a build-time initializer read: environment variables and secret mounts of the build, baked into the image heap of the executable | The executable and its image layer, often pushed to a registry | Everyone who can pull the image | reported (docs) for the mechanism; a build-time `Cipher` that reused the same IV in every run was measured 2026-09 |

Container checkpoints: the kubelet never cleaned up its checkpoint archives (measured 2026-09).

## 2. What a CRaC image holds

Both engines write the heap in plaintext (measured 2026-09). The following rows tell what survives and
what does not.

| Item | Result | Evidence |
|---|---|---|
| Environment variable, read by the app | 3 hits in the image | measured 2026-09 |
| Environment variable, never read (no `getenv` call) | 1 hit (2026-09); 3 hits with warp and with criuengine (2026-11-16, table below). The process environment block is part of the process memory, whether or not Java code reads it | measured 2026-09; measured 2026-11-16, Linux arm64 (OrbStack VM) |
| Secret file, never read | 0 hits | measured 2026-09 |
| Secret file, read into a `String` | 1 hit | measured 2026-09 |
| Buffer zeroed with `Arrays.fill` in `beforeCheckpoint` | Works only for buffers that the app owns. A `String` cannot be zeroed, and copies inside libraries stay | measured 2026-09 |
| NIO temporary direct buffer (the per-thread cache that the JDK uses for heap-buffer I/O) | Not zeroed. `-Djdk.nio.maxCachedBufferSize=0` did not protect it: 31 % of the planted copies survived | measured 2026-09 |
| Garbage (unreachable copies) | The full GC before the checkpoint shrinks the image. It does not wipe freed memory. Found copies, young / promoted: G1 0 % / about 14 %; Serial 0 % / about 28 %; Parallel 0 % / 0.01 %; Shenandoah 100 % / 100 %; ZGC 0-100 % / 35-97 %. G1 with `-Xms` equal to `-Xmx` (Zulu 26): 100 %. Epsilon frees nothing. Soft references were not cleared | measured 2026-09 |
| Memory marked `MADV_DONTDUMP` (an `madvise` flag that excludes a range from core dumps) | No protection. The engines ignore the flag | measured 2026-09 |
| `memfd_secret` memory (a Linux system call for memory that the kernel removes from its own direct mapping) | CRIU aborts the dump, so the secret costs availability. warp refuses the checkpoint while the descriptor is open (unless `-XX:CRaCAllowedOpenFilePrefixes` covers it, see [crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)) and writes the content in plaintext once the descriptor is closed | measured 2026-09 |
| Kernel keyring | Stays out of the image. After a restore in a fresh container, the key is gone (`ENOKEY`), and the app must fetch it again | measured 2026-09 |
| `AF_ALG` kernel crypto socket (the Linux socket family that exposes the kernel crypto API) | Blocks a CRIU dump. warp: not measured | measured 2026-09 |
| Kernel TLS (kTLS, TLS encryption done by the kernel) | A CRIU restore with established TCP connections silently sends plaintext | measured 2026-09 |

**Scan with the skill's scanner** (measured 2026-11-16, Linux arm64 (OrbStack VM), Zulu CRaC 25.0.5,
demo app, G1). Three canaries were planted: an environment variable that the app never reads, a
`-Dcanary.prop` value, and an HTTP header sent in 300 warm-up requests. A fourth canary was never given
to the process, as a negative control. Scanner call:
`checkpoint-secret-scan.py --control org.springframework`.

| Engine | Files and modes | Hits: env / `-D` / header / never given | Control string |
|---|---|---|---|
| warp | `core.img` 0600, `engine` 0644, directory (created with `mkdir`) 0755 | 3 / 9 / 3 / 0 | 9,324 times in `core.img` |
| criuengine (`--privileged`) | 49 files; `pages-1.img` and every `core-*.img` 0644, `dump4.log` 0600 | 3 / 9 / 3 / 0 | 9,053 times in `pages-1.img`; the saved output has no per-file count for the other 48 files |

The negative control at 0 shows that the hits are not chance matches. The control string was counted in
`core.img` and `pages-1.img` only; a file without the control proves nothing either way, which is why
§5 asks you to read the per-file control count.

**Environment after a restore** (warp, Zulu 25.x): variables set at restore override the checkpoint
values. Variables absent at restore keep the checkpoint value, so removing a secret variable does not
remove it from the restored process. Cached values (a Spring `Environment`, `@Value` fields, static
fields) stay old. CRIU was not measured, and some public sources report old values for all variables
(reported,
[cloud vendor blog](https://aws.amazon.com/blogs/containers/using-crac-to-reduce-java-startup-times-on-amazon-eks/)).
Evidence: measured 2026-09 and 2026-11-15. The race between resumed threads and `afterRestore` is in [crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees).

**A checkpoint taken as root restores as root** with CRIU, even after `chown`. See
[crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images).

## 3. Mitigations

| Mitigation | How | Why, and its limits |
|---|---|---|
| Checkpoint before the first secret | Checkpoint after warm-up with test data, then load credentials in `afterRestore` | Only memory that existed at checkpoint time reaches the image. Limit: an environment variable that exists at checkpoint time is in the image even if the app never reads it (section 2), so start the checkpoint JVM without production secrets in its environment. Origin: reported ([Spring docs](https://docs.spring.io/spring-framework/reference/integration/checkpoint-restore.html), [blog post "The Future of Java Performance in Cloud Run: Native Java, CRaC and Project Leyden"](https://medium.com/google-cloud/test-publish-da169b797515)) |
| Owner-only modes | `chmod -R go-rwx` on the checkpoint directory; create it yourself with 0700; `COPY --chown=<jvm-user>` when you bake it into an image layer | criuengine writes 0644, failed dumps leave 0644 files, a pre-created directory keeps its mode, and a copy through object storage came back as 0644 (measured 2026-09, 2026-11-15) |
| Memory-backed volume | Keep images in an `emptyDir` with `medium: Memory` or a tmpfs | Nothing reaches a persistent disk. Limit: warp maps the image files directly, so a `noexec` mount fails the restore (exit 134) unless you set `direct_map=false` ([crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images)) |
| Never push checkpoint images | Build the checkpoint on the target host; do not push the image layer to a shared registry | The image holds the full environment and heap, and it is bound to the CPU it was taken on. Origin: measured 2026-09 |
| Rotation-aware checkpoint identity | Key the checkpoint by the secret's version id, or by an HMAC of the secret with a key that is not in the image | A key over the secret *reference* (the name of the secret object) does not change on rotation, so a restore brings back the old credential. A plain hash over the *content* can be brute-forced for short secrets: a 6-digit PIN fell in 1.3 s (measured 2026-09) |
| Dynamic credentials with revoke | Fetch short-lived database credentials in `afterRestore`, revoke the old lease (the time-limited grant that a secrets store such as Vault attaches to dynamic credentials), and hold a lock from `beforeCheckpoint` until the new credentials are in place | A revoke blocked new logins within 38-152 ms, but open sessions survived it (measured 2026-09). A self-revoked login token stayed 2-3 times in the image, but invalid. Operators that sync secrets into Kubernetes did not revoke on rotation. A connection pool with a credentials provider and pool suspension saw 0 errors (measured 2026-09). |
| Fresh randomness after restore | Reseed or re-create every random source in `afterRestore`, and rotate TLS session-ticket keys | Restored copies share state: a used DRBG (Deterministic Random Bit Generator, the JDK `SecureRandom` algorithm `DRBG`) `SecureRandom` produced the same bytes after every restore; a static `java.util.Random` repeated its sequence; the TLS 1.3 session-ticket key was shared until it expired after 3600 s. `NativePRNG` and an unseeded `SHA1PRNG` reseeded themselves (measured 2026-09) |
| Encryption at rest | warp encryption exists only in a commercially supported vendor build (AES-CTR or CBC, no MAC); the freely available build rejects the encryption engine option. Upstream CRIU and the OpenJDK CRaC project have none. Ad hoc `tar` plus `age` (an open-source file-encryption tool with authenticated encryption): restore 0.66 s instead of 0.12 s (x86, 2 CPUs) | Unauthenticated modes let an attacker change the image without detection: one flipped byte in an `openssl enc` CBC file decrypted with exit 0 and 17 wrong bytes (measured 2026-09). Use an authenticated format such as `age` |

**Object storage (S3) notes** (measured 2026-09): the free warp build has no S3 code. An in-memory S3
server cost 1.4 to 6.1 times the image size in RAM and was only 8-13 % faster. The recommended path is an
init container that copies the image into an `emptyDir` with `medium: Memory`, mounted without `noexec`.
`rclone crypt` was the best free encrypting proxy but does not detect truncation; an S3 proxy that used
AES-CFB was malleable.

## 4. CDS archives and AOT caches

**Canary search** (measured 2026-11-16): the training run had an environment variable and a `-D` property
with canary values. A byte search over 8 files (two `.jsa`, four `.aot`, two `.aotconf`) found 0 hits for
both values, for their common prefix and for the variable and property names. A control string from
Spring's own code (`spring.context.exit`, also passed as `-D` in training) appeared 1-2 times per file,
so the search could see strings.

What the result covers, and what it does not:

- The search covered UTF-8 and Latin-1 bytes only, not UTF-16.
- The demo app never read the canary values into its own objects. A value that a bean reads at training
  time and stores where the cache archives it was not tested.
- The files hold JDK flag names (for example `-XX:SharedArchiveFile=`) as string literals. Whether they
  record the training command line itself was not settled; the canary `-D` value was not in them. Treat
  training flags as possibly stored, and keep secrets off the training command line.
- The files embed absolute class-path entries (the JVM names them in its mismatch messages). A cache
  reveals your build layout.
- The files hold string literals and archived strings of loaded classes. A secret that is a literal in
  your code is in the cache.
- `-Xlog:aot*=info` writes archived strings to the log (measured 2026-09). Do not ship that log level
  from a training run to a shared log store.
- Cache files are created with the umask (0644 in these measurements), and the JDK trusts them fully:
  a changed cache can run code with the app's rights (reported,
  [OpenJDK leyden-dev mailing list, 2022](https://mail.openjdk.org/pipermail/leyden-dev/2022-June/000042.html)).

**Spring AOT processing** (the build step that generates bean definitions, separate from the JVM cache):
it bakes placeholder values that a `BeanFactoryPostProcessor` resolves at build time into generated code,
and it freezes `@ConditionalOnProperty` decisions (reported, Spring docs). Build with the same property values
as production, but without production secrets.

**Native Image build time:** a class initialized at build time stores what it read, including environment
variables and secret mounts of the build, in the image heap (reported, docs). Run the build without
secrets.

**One-step AOT training leaks options:** the one-step mode (`-XX:AOTCacheOutput`, JDK 25) starts a child
JVM for the assembly step and passes the training options through `JAVA_TOOL_OPTIONS`. The child prints
`Picked up JAVA_TOOL_OPTIONS: ...` with every option, including a `-Dsecret=...`, to stderr, so the value
lands in the build log (measured 2026-09). Use the two-step mode or keep secrets out of the training
options. The Paketo buildpacks (Cloud Native Buildpacks for Java) offer
`TRAINING_RUN_JAVA_TOOL_OPTIONS`, which applies options to training only (reported,
[README](https://github.com/paketo-buildpacks/spring-boot)).

## 5. Rule: 0 hits does not mean clean

Report "0 hits for these encodings", never "clean".

Origin: the canary search in section 4 found 0 hits, and that result has three blind spots at once
(encodings not searched, values the app never read, values the cache could hold in another form).
Reason: a scan that structurally cannot find a value reports the same as a clean file. Only a control
string that the scan does find shows that it could see anything. Limits: 0 hits proves nothing for
values that the app never read, for compressed or encrypted images, or for encodings the scanner does not
search.

Plant a canary of at least 8 bytes in the same way that production delivers the real secret, make the app
read it the same way, create the cache or checkpoint, then scan. The scanner path is relative to the
skill directory (`java-fast-startup/`):

```bash
export CANARY_DB='canary-db-7f3a9c'      # the value never appears on the command line
scripts/checkpoint-secret-scan.py --canary-env CANARY_DB --control 'spring.context.exit' /path/to/checkpoint-or-cache-dir
```

The scanner reads the canary values from the named environment variables, never prints them, follows no
symlinks, reports directory and file modes and flags group-readable and world-readable entries. It
searches UTF-8, Latin-1, UTF-16LE and UTF-16BE. Pick a control string that is known to be in the files,
for example a literal from your own code or a framework literal such as `spring.context.exit`.

The control count is printed per file, and a file without the control is marked `NO-CONTROL`. Read
those lines: one text file that holds the control does not show that the scan sees into an opaque
file beside it, such as a compressed image. The exit code stays 0 for such a file, because a file can
lack the control legitimately.

| Exit code | Meaning |
|---|---|
| 0 | No canary hit for the searched encodings |
| 1 | At least one hit |
| 2 | Usage error (also a canary shorter than 8 bytes) |
| 3 | Blind: the control string was not found, or a file was unreadable |
| 4 | Internal error |

## 6. Do not believe

| Claim | Verdict | Corrected wording |
|---|---|---|
| `System.getenv` is frozen after a restore | contested | warp, Zulu 25.x: variables set at restore override; variables absent at restore keep the checkpoint value, so removing a secret variable does not remove it; cached Spring `Environment`, `@Value` and static fields stay old; CRIU not measured; some public sources report old values (section 2) |
| A Leyden cache holds no heap data | struck | It holds archived strings and literals; no environment or `-D` values were found (measured 2026-11-16) |
| Only CRIU writes world-readable checkpoint files | struck | criuengine writes 0644 too; warp writes `core.img` with 0600 (measured 2026-11-15; again 2026-11-16, Linux arm64 (OrbStack VM), section 2) |
| A read-only mapping does not protect a file from a container checkpoint | struck for bind-mounted files | 0 hits for a read-only mapping of a bind-mounted file; the container's tmpfs is archived (measured 2026-09) |

All struck claims: [struck-claims.md](struck-claims.md).
