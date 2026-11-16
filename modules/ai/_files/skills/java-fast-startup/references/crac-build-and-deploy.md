Applies to: CRaC with the `warp` engine in containers and Kubernetes on Linux; most points also hold for `criuengine`

# CRaC: Build, Bake and Deploy a Checkpoint

TL;DR: Start the app with a wrapper that restores when a checkpoint exists and starts cold otherwise.
Take the checkpoint on demand after a warm-up, not at context refresh, when the app uses a database.
Restore it once as a self-test before you bake it into an image layer with `COPY --chown` and mode 0600.
Name the image by everything the checkpoint froze: image, environment, command and configuration. Then
prove that it is really used: read the text of `jcmd`, never its exit code, and log which branch the
wrapper took. A failed checkpoint step is harmless; a failed restore is not: with `exec` it ends in a
crash loop, not a cold start (§1). The rollback is the plain image without the checkpoint layer.
Debugging a checkpoint that does not work is the job of
[java-debug crac.md](../../java-debug/references/crac.md).

## Contents

- [1. The wrapper](#1-the-wrapper)
- [2. When to take the checkpoint](#2-when-to-take-the-checkpoint)
- [3. Self-test restore, then harvest](#3-self-test-restore-then-harvest)
- [4. Bake the checkpoint into an image layer](#4-bake-the-checkpoint-into-an-image-layer)
- [5. Identity of a checkpoint](#5-identity-of-a-checkpoint)
- [6. The stale-variant trap](#6-the-stale-variant-trap)
- [7. Rollout, readiness and sidecars](#7-rollout-readiness-and-sidecars)
- [8. Memory, heap, CPU and PIDs](#8-memory-heap-cpu-and-pids)
- [9. Verify that the restore really happens](#9-verify-that-the-restore-really-happens)
- [10. Rollback](#10-rollback)
- [11. Where this is going](#11-where-this-is-going)

CRaC (Coordinated Restore at Checkpoint) writes a running JVM to files and later restores it from them.
`warp` and `criuengine` are the two engines that write and read those files; see
[crac-engines.md §2](crac-engines.md#2-engines).

Evidence markers: "measured <date>, <JDK>, <setup>" means the skill's author ran it. "reported (<source
type>)" means a public source states it. "team practice" and "reported, team <date>" mark findings from
the skill author's unpublished work, not a public source and not re-measured here; see
[measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers). "not measured" means
nobody checked. Engines, privileges and CPU features are
in [crac-engines.md](crac-engines.md). What lands in the checkpoint file is in [security.md](security.md).

## 1. The wrapper

One container image serves two modes: it writes a checkpoint when none exists, and it restores when one
exists. A small entrypoint script decides.

```sh
#!/bin/sh
# Entrypoint: restore when a checkpoint exists, else start cold with checkpointing enabled.
CRAC_DIR=/crac
if ls "$CRAC_DIR"/core*.img >/dev/null 2>&1; then
  echo "crac-wrapper: restore from $CRAC_DIR" >&2
  exec env -u JAVA_TOOL_OPTIONS java -XX:CRaCEngine=warp -XX:CRaCRestoreFrom="$CRAC_DIR"
fi
echo "crac-wrapper: cold start, checkpoint target $CRAC_DIR" >&2
exec java -XX:CRaCEngine=warp -XX:CRaCCheckpointTo="$CRAC_DIR" \
  -XX:+UseG1GC -Xmx1g -jar /app/app.jar
```

- **A failed restore does not fall back to a cold start.** The restore branch ends in `exec`, so the
  shell is gone when the restore fails (a damaged image, other CPU features, a noexec mount). The
  container exits, and the orchestrator restarts it into the same restore: a crash loop. Choose one of
  two behaviours:
  - (a) Keep the `exec` and accept the crash loop as a loud failure. Nothing serves until you deploy
    the plain image (§10), but nobody can miss the broken image.
  - (b) Run the restore without `exec`, log a loud line on a non-zero exit, and fall through to the
    cold branch. The pod serves, slowly. Trade-off: the cold start hides the broken image, so alert on
    that log line (§9). The script also catches a crash of the restored app hours later, and the shell
    must pass SIGTERM on. A sketch (not measured):

    ```sh
    if ls "$CRAC_DIR"/core*.img >/dev/null 2>&1; then
      echo "crac-wrapper: restore from $CRAC_DIR" >&2
      env -u JAVA_TOOL_OPTIONS java -XX:CRaCEngine=warp -XX:CRaCRestoreFrom="$CRAC_DIR" &
      pid=$!
      trap 'kill -TERM "$pid"; wait "$pid"; exit 143' TERM INT
      wait "$pid"; rc=$?
      [ "$rc" -eq 0 ] && exit 0
      echo "crac-wrapper: RESTORE FAILED (exit $rc), starting cold; the checkpoint image is broken" >&2
    fi
    ```

- **Test for an image file, not for a non-empty directory.** `warp` writes `core.img`, CRIU writes
  `core-<pid>.img`. A failed CRIU dump can leave `pages-*.img` files behind
  ([crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)), so "the directory has files"
  is not proof of a usable image.
- **Do not put a marker file of your own into the checkpoint directory.** Origin: team practice
  (2026-08). Reason not recorded; plausible reason: a marker says "a checkpoint was attempted", not
  "the engine finished one", and it is baked into the image layer together with the real files. Let the
  engine's own files decide. Limit: the plausible reason holds only when the wrapper or the bake step
  reads the marker as proof of a checkpoint.
- **`env -u JAVA_TOOL_OPTIONS` on the restore branch.** The restore command is a JVM launch and reads
  `JAVA_TOOL_OPTIONS`. A flag in it that is not restore-settable aborts the restore, and a stray agent
  path can change the restored JVM
  ([crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees)). Limit:
  `JDK_JAVA_OPTIONS` survives `env -u JAVA_TOOL_OPTIONS`, so keep it empty too, or unset it as well.
- **Keep agents out of the checkpoint branch.** Listener agents in `JAVA_TOOL_OPTIONS` block the
  checkpoint ([crac.md §4](../../java-debug/references/crac.md#4-debug-agents-and-crac);
  [debug-agents.md](debug-agents.md)).
- **Set GC and heap explicitly in the cold branch.** The heap size and the CPU count are fixed when the
  checkpoint is written (§8). Without explicit flags, the JVM sizes them from the container that happened
  to run the checkpoint.
- **PID 1:** with `exec`, the `java` launcher becomes PID 1 when the script is PID 1, and `warp` then
  runs the JVM as a child process. Find it with `jcmd -l`, not `jcmd 1`
  ([crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)).
- **Write location while producing:** a Kubernetes `emptyDir` is enough. A `ReadWriteOnce` volume
  forces the `Recreate` rollout strategy, because a second pod cannot mount it. A pre-created directory
  keeps its mode (an `emptyDir` is 0777); the JVM makes the directory 0700 only when it creates it itself
  (measured 2026-09, Zulu 25). See [security.md](security.md).

## 2. When to take the checkpoint

**Rule: when the app uses a database, take the checkpoint on demand after a warm-up, not with
`-Dspring.context.checkpoint=onRefresh`.**

- Origin: an `onRefresh` checkpoint of a Spring Boot app with Hibernate failed with
  `CheckpointOpenSocketException` on the database port (measured 2026-08, Zulu 25, Kubernetes on arm64).
  A public issue reports the same failure after early database use such as schema init scripts
  (reported, Spring Boot issue tracker; issue number not recorded).
- Reason: `onRefresh` fires after the singletons are created and before the lifecycle beans start
  (reported, Spring docs). At that moment the JPA layer still holds active connections. After a warm-up,
  the pool's connections are idle, and a pool that supports suspension closes them cleanly in its
  checkpoint hook (see [frameworks.md §2](frameworks.md#2-spring-and-spring-boot)).
- Second reason: `onRefresh` happens before any request, so the JIT has compiled almost nothing. The
  Spring docs say the automatic mode "does not allow a fully warmed-up JVM" (reported). One vendor
  reports a PetClinic restore of 392 ms with the automatic checkpoint and 75 ms with a manual checkpoint
  after warm-up (reported, vendor docs, source not recorded; different setup from every table in this
  skill).
- Limit: for an app without a database or other outbound connections, `onRefresh` is fine and needs no
  trigger.

How to do it:

1. Start the cold branch of the wrapper.
2. Send representative traffic: the endpoints, payloads and outbound calls that production uses, with
   test credentials against test endpoints (see below). A few hundred requests per endpoint is a common
   start; measure whether more helps.
3. Stop the traffic and wait until the pools are idle.
4. Trigger: `env -u JAVA_TOOL_OPTIONS jcmd <pid> JDK.checkpoint` with the PID from `jcmd -l`.
5. Read the result from the text (§9).

> **Warning:** the JVM exits after a successful checkpoint (exit status 137). In a cluster, trigger it
> only on a pod that serves no users, for example a dedicated producer pod.

**Secrets during the warm-up.** The outbound calls of step 2 need credentials, and every value the JVM
holds at checkpoint time lands in the image, together with the whole process environment
([security.md](security.md)). Warm up with test credentials against test endpoints, and load the real
credentials in `afterRestore` ([frameworks.md §8](frameworks.md#8-writing-a-resource-correctly)). Then
the checkpoint JVM starts without production secrets, as the [safety rules](../SKILL.md#safety-rules)
of this skill require. When the warm-up cannot work without production credentials, the image **is** a
secret: keep it on the producing node only, with mode 0600, never push it to a registry, and delete old
images soon.

Outbound connections opened during the warm-up must be closed before the checkpoint. Frameworks do part
of this; the rest is in [frameworks.md](frameworks.md).

## 3. Self-test restore, then harvest

**A failed checkpoint is harmless.** The JVM prints a `CheckpointException` and keeps running, so the
cold-started pod keeps serving
([crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)). Limit: a failed CRIU dump
can leave world-readable partial images (see [security.md](security.md)); delete them.

**Restore once before you bake.** After a successful checkpoint the container exits, the orchestrator
restarts it, and the wrapper takes the restore branch. Wait until the restored app is ready, then bake.

- Origin: team practice (2026-08). The team waited up to 180 s for readiness and baked only a
  checkpoint that passed.
- Reason: a checkpoint that does not restore would otherwise end up in every pod of the next rollout.
  The self-test catches noexec mounts, missing `/tmp`, root-owned files and engine errors before users
  see them.
- With the fall-through wrapper of §1 (b), readiness proves nothing: a failed restore also becomes
  ready, only later. Check the wrapper's log for the restore branch and the absence of `RESTORE FAILED`.
- Limit: the self-test runs on the producing node. It does not prove the image restores on a node with
  other CPU features ([crac-engines.md §6](crac-engines.md#6-cpu-features)).

**Harvest** (copy the checkpoint files out of the pod) **with `tar` over `kubectl exec`, straight into
the build context:**

```bash
umask 077                     # everything created locally is owner-only
mkdir crac                    # the directory that the COPY in §4 reads
kubectl exec <pod> -- tar -C <checkpoint-dir> -cf - . | tar -C crac -xpf -
ls -l crac/                   # check modes: core.img must be -rw-------
docker build -t <checkpoint-image> .   # §4
rm -rf crac                   # the directory holds a plaintext copy of the heap
```

Origin: team practice (2026-08). The `tar` stream keeps the file modes (`-p` on the extracting side),
and you can check them before baking. Why the team avoided `kubectl cp` was not recorded. Reason for the
pipe and the `umask`: an intermediate archive file would be a second heap copy on disk, created with the
default umask (often 0644, readable by every local user). Delete the build context after the build for
the same reason.

## 4. Bake the checkpoint into an image layer

```dockerfile
FROM <your-app-image-with-crac-jdk>
COPY --chown=<jvm-uid>:<jvm-gid> crac/ /crac/
```

- **`COPY --chown` is required.** `COPY` writes files as root. `core.img` has mode 0600, so the JVM user
  cannot read it, and the restore fails with `warp: error: Cannot open /crac/core.img: Permission denied`
  (measured 2026-08, Zulu 25, Kubernetes on arm64). The engine-file variant of this error is in
  [crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images).
- **Keep mode 0600.** The checkpoint is a copy of the heap and holds the same secrets as a heap dump.
  Do not `chmod` it to make the error go away. See [security.md](security.md).
- **Take the checkpoint as the JVM user, not as root**
  ([crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images)).
- **Keep the image local.** Build it on the node that wrote the checkpoint and do not push it to a shared
  registry ([crac-engines.md §7](crac-engines.md#7-platforms-and-emulation)). Consequence: the kubelet's
  image garbage collection under disk pressure can delete a local-only image, and the pod then fails with
  `ErrImagePull` or `ImagePullBackOff`. Watch disk pressure on such nodes.
- **`docker image rm` fails while a container uses the image** ("conflict ... must force"). Scale the
  workload down before you replace the image. Do not ignore the error: a script that swallows it reports
  success and keeps the old image.

Numbers from one real service (measured 2026-08, Zulu 25, Kubernetes on arm64): checkpoint 169 MB,
container image 592 MB without and 768 MB with the checkpoint layer, checkpoint plus bake 9.3 s. Restore
from the image layer 69 to 126 ms, 540 ms with a cold page cache; restore from a volume 73 to 118 ms.

## 5. Identity of a checkpoint

A checkpoint freezes more than the code. It holds the heap, so it holds every value the app read at
startup: environment variables, configuration files, command-line properties, values that Spring injected
([crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees)). A restore with new
environment variables does not update values that the app cached.

**Rule: name the checkpoint image by a hash over everything it froze:** the application image ID, the
environment (`env` and `envFrom`), the command and arguments, and a checksum of the mounted configuration.

- Origin: a team ran old code and old configuration after a change, because the checkpoint survived both
  an image rebuild and an environment change (measured 2026-08, Zulu 25, Kubernetes on arm64).
- Reason: a new image or a new environment then gives a new name, no checkpoint exists for it, and the
  wrapper starts cold. A cold start is slow but correct; a restore of an outdated checkpoint is fast and
  wrong.
- Limit: secrets need care. The environment (`env`, `envFrom`) and the mounted configuration can hold
  secrets, and then the hash inputs hold them too. For every secret input, hash only a version ID of the
  secret, or an HMAC with a key that is not in the image
  ([security.md §3](security.md#3-mitigations)). A hash over the secret *reference* does not change when
  the secret rotates, so the old value comes back with every restore. A plain hash over the secret
  *content* can be brute-forced when the value is short: a 6-digit PIN fell in 1.3 s (measured 2026-09).

**Rule: compute the name in one place only.** Compute it at deploy time, store it with the pod (for
example as a pod annotation), and let the bake step read it back from the pod.

- Origin: team practice (2026-08). A second implementation that recomputed the hash differed in a small
  detail, and produced an image that matched no deployment.
- Reason: a mismatched name fails silently: the deployment never finds its checkpoint and starts cold
  every time.
- Never feed the checkpoint image name back into the hash. The name would then change the hash that
  produced it.

## 6. The stale-variant trap

The CRaC image is usually a variant built on top of the plain application image. When the build
rebuilds the plain image and not the variant, the variant still contains the old application.

- Origin: a base image rebuild did not trigger a rebuild of the CRaC variant, and the old code ran
  (measured 2026-08, Zulu 25, Kubernetes on arm64). Nothing failed; the service simply ran last week's
  code.
- Reason: the variant's build step had no dependency on the new plain image.
- Fix: build both in one chain, and stop the deploy when the variant is older than the plain image or
  was built from another source revision.
- **Prove which code runs.** Copy the application jar out of the running pod and compare its checksum
  with the build output, or read a source-revision label from the image (for example
  `org.opencontainers.image.revision`) and compare it with the commit you meant to deploy. A green
  rollout proves nothing about the code version.

## 7. Rollout, readiness and sidecars

| Strategy | Gap | Extra RAM | Measured |
|---|---|---|---|
| `Recreate` | sub-second gap without a ready pod | none | measured 2026-08, Zulu 25, Kubernetes on arm64 |
| `RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` | none: 1,522 of 1,522 requests answered during the swap (100 %) | two pods for a short time | same |

- **A rolling swap needs a real readiness probe.** Without one, Kubernetes marked a pod ready 2.0 s
  after the start, while the first real answer came after 11.2 s (cold start; same setup). The rollout
  then removed the old pod too early.
- **Add a `preStop` hook that sleeps about 5 s.** Kubernetes removes the pod from the endpoints and sends
  SIGTERM at the same time, and an ingress controller can keep the old pod in its upstream list for a
  moment. Without the hook, a rollout with `maxUnavailable: 0` still produced 12 HTTP 502 answers over
  about 600 ms (same setup).
- A pod keeps the lifecycle hooks it was created with. A new `preStop` value takes effect only in new
  pods.
- **Sidecars gate pod readiness.** A JVM restored in 153 ms, but the pod became ready after about 20 s,
  because sidecar containers were still starting (measured 2026-08, Zulu 25, Kubernetes on arm64).
  Measure pod readiness, not only the JVM. See [measuring.md](measuring.md).
- **After a restore, connection pools and TLS sessions start empty.** The first calls to remote services
  pay the connection setup again. After a scale from 0 to 1, the first business call returned 0 results
  and the third call 16 (measured 2026-08, Zulu 25, Kubernetes on arm64; the service queried remote
  partners with short timeouts). Send a few warm-up calls after the restore, or accept a slow first
  minute.

## 8. Memory, heap, CPU and PIDs

**Restored memory stays mapped to the image file.** With `warp`'s default `direct_map=true` (a `warp`
option, see [crac-engines.md §2](crac-engines.md#2-engines)), the restored JVM maps the pages of
`core.img` instead of copying them (measured 2026-09, Zulu 25, Linux container). `RssAnon` and
`RssShmem` are the fields of `/proc/<pid>/status` for resident anonymous and resident shared memory:

| `direct_map` | RSS split after restoring a 91 MB image |
|---|---|
| `true` (default) | RssAnon 15.7 MB + RssShmem 13.1 MB; `core.img` appeared 136 to 193 times in `/proc/<pid>/maps` |
| `false` | RssAnon 97.7 MB |

- Deleting the image does not free the memory until the process ends.
- **Never overwrite or truncate an image in place while a JVM restored from it runs.** That can corrupt
  the running process (measured 2026-09). Write a new directory and switch to it.
- A noexec mount breaks the default restore; the fixes are in
  [crac.md §5](../../java-debug/references/crac.md#5-version-traps-and-checkpoint-images).

**A writable `/tmp` is required for the restore.** `warp` creates `/tmp/crac_<pid>` during the restore.
With a read-only root file system and no writable `/tmp`, 7 of 7 restores failed; with an `emptyDir` on
`/tmp`, 9 of 9 worked (measured 2026-09, Zulu 25, Kubernetes with containerd). Mount an `emptyDir` on
`/tmp` when you set `readOnlyRootFilesystem: true`.

**Heap size and CPU count are fixed at checkpoint time.**

- Set `-Xmx` or `-XX:MaxRAMPercentage` explicitly in the cold branch, and keep the container limits of
  the producing pod and the restoring pods the same (origin: team practice 2026-09; reason: the restored
  JVM keeps the heap geometry and the CPU count of the checkpoint JVM, and CPU options are not
  restore-settable, see [crac-engines.md §6](crac-engines.md#6-cpu-features)).
- Set the GC explicitly. On JDK 26 and older, the JVM picks Serial GC in a small container; JDK 27 uses
  G1 everywhere ([JEP 523](https://openjdk.org/jeps/523), reported). One service with a hard-coded ZGC
  and a small container limit was OOMKilled: a container sizing problem, not a CRaC problem. See
  [gc-cpu-ram-throughput.md](gc-cpu-ram-throughput.md).
- Azul documents `-XX:CRaCMaxHeapSizeBeforeCheckpoint` to shrink the heap before the image is written
  (reported, vendor docs; not measured).
- A restore avoids the CPU and RAM spike of a cold start. This matters when many JVMs start at once, for
  example after a node failure.

**PIDs with CRIU: set `-XX:CRaCMinPid`.** A CRIU restore recreates the original PIDs of the JVM threads.
When another process already uses one of them, the restore fails with
`Unable to create a thread: -17` (measured 2026-09, Zulu 25, `criuengine`, Linux container). Start the
checkpointing JVM with `-XX:CRaCMinPid=<n>` so that its PIDs lie above the range that the container's
other processes use. `warp` gives new PIDs and does not need this.

## 9. Verify that the restore really happens

A missed restore does not fail: the wrapper starts cold, and the app works, only slowly. This silent
fallback is the central risk of every technique in this skill. Check every link of the chain:

1. **Checkpoint:** read the text of `jcmd ... JDK.checkpoint`. The exit code is 0 for success and for
   failure. Success prints `0` after the PID line, and the log ends with `warp: Checkpoint successful!`
   ([crac.md §1](../../java-debug/references/crac.md#1-platform-and-engines)).
2. **Harvest:** `core.img` (or `core-*.img` for CRIU) is in the harvested directory with mode 0600 (§3).
3. **Restore:** the wrapper logs which branch it took (§1). Alert on the cold branch in a pod that
   should restore.
4. **Speed:** measure time to ready on every rollout. A restored app is ready in hundreds of
   milliseconds; a cold one needs seconds. See [measuring.md](measuring.md).
5. **Code version:** §6.

## 10. Rollback

- **Deploy the plain (non-checkpoint) image,** or empty the checkpoint directory where it is a mounted
  volume (a baked image layer cannot be emptied): the wrapper takes the cold branch. With the
  checkpoint flag still set, the JVM writes a checkpoint only when someone triggers it, so the cold
  branch is safe in production. Exception: `-Dspring.context.checkpoint=onRefresh` triggers it at every
  start; remove that property for the rollback.
- **Drop the CRaC flags** and use a JDK without CRaC when you leave CRaC entirely. Remove `org.crac`
  `Resource` code only after that: on a JDK without CRaC, registered resources are accepted and never
  called ([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)).

## 11. Where this is going

Status 2026-11 (reported, Kubernetes enhancement page):
[KEP-5823](https://www.kubernetes.dev/resources/keps/5823/), pod-level checkpoint and restore, is
planned as alpha for Kubernetes 1.38 and leaves encryption of checkpoint data out of scope. It does not
replace the image-layer approach of this file; see
[crac-engines.md §8](crac-engines.md#8-container-level-checkpoints).
