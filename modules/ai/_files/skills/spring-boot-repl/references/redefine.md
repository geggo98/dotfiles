Applies to: everywhere (local JVMs on macOS and Linux hosts, containers and
pods alike)

# Class redefinition: `jdb redefine` and `scripts/Redefine.java`

## Which tool

| Situation | Tool |
|---|---|
| One class, one method body, and you want to watch the swap | `jdb redefine` |
| Several classes that must change together (class and helper, interface and implementation) | `scripts/Redefine.java` |
| A class can sit in more than one loader (JPA entity after the first redefine, see [Pitfall (c)](#c-throwaway-class-loaders-2-class-loaders-load-the-class)) | `scripts/Redefine.java` |
| You need machine-readable output (agent, script) | `scripts/Redefine.java` |
| The class is not loaded yet, or is new | neither: [New classes](#new-classes-and-new-component) |

Both tools go through `redefineClasses` of JDI (Java Debug Interface,
module `jdk.jdi`), so the HotswapAgent transformer runs and its plugins
refresh the framework state. For this reason, use them instead of Arthas
`retransform`, which does not trigger HotswapAgent plugins (see
[SKILL.md, "Rule 1"](../SKILL.md#rule-1-one-path-for-class-changes--redefine-never-retransform)
and [arthas.md](arthas.md)).

### The JDWP port

Both tools need the JDWP port. The `-agentlib:jdwp` options are in
[java-debug, jdwp-options.md](../../java-debug/references/jdwp-options.md).
Bind the port to `127.0.0.1`, because JDWP has no authentication: whoever
reaches the port can run code in the JVM.

- `address=5005` without a host also binds only `127.0.0.1`, IPv4 only.
  Attach to `127.0.0.1`, not to `::1`, because nothing listens on `::1`.
- Do not use `address=*:5005` here. It binds the wildcard address
  (`0.0.0.0` on JDK 11, IPv4 and IPv6 on 17 and 25), so the unauthenticated
  port listens on every interface.

Measured 2026-11-15 on Temurin 11.0.33, 17.0.21 and 25.0.5, in a container,
from the container's table of listening sockets. To repeat the check, run `ss -ltn` or `netstat -ltn` in the
container, if the image has one of them, and read the local address of
port 5005. Access from another interface was not tested.

For a pod, reach the port with `kubectl port-forward pod/<pod> 5005:5005`
(the `jvm-remote-debug` skill, [SKILL.md](../../jvm-remote-debug/SKILL.md)).
Measured 2026-11-15 on OrbStack Kubernetes (OrbStack is a local Docker and
Kubernetes runtime for macOS, see
[orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md))
with kubectl port-forward (Kubernetes 1.36.5, Docker runtime):

- A JDWP listener on `127.0.0.1:5005` is reachable through the forward. The
  host `jdb` of JDK 25.0.5 attached through `15005:5005` to a JDK 21.0.13
  target, and `version` and `threads` worked.
- The forward connects in the pod only over IPv4 to `127.0.0.1`. A listener
  bound only to `::1` or only to the pod IP is unreachable. The forward
  reaches only a listener on `127.0.0.1` or on a wildcard address, and the
  wildcard is ruled out above, so bind JDWP to `127.0.0.1`. This result holds for the Docker
  runtime. Containerd and CRI-O implement port-forward differently, and
  newer containerd can try IPv6 after IPv4 (inference, not measured).
- The forwarded connection arrives in the pod from `127.0.0.1`. A bind to
  `127.0.0.1` therefore keeps the port off the pod network, but anyone
  allowed to run `kubectl port-forward` to the pod reaches JDWP.
- One refused forwarded connection ends the whole `kubectl port-forward`
  process, including every other port in it. Forward each port with its
  own `kubectl port-forward`, so that one wrong port does not take the
  others down.

## Procedure with `jdb`

Terminal 1, attach to the running JVM:

```bash
jdb -attach 127.0.0.1:5005
```

Terminal 2, compile:

```bash
./gradlew classes
```

Back in `jdb`, give the **absolute** path of the new class file:

```text
redefine com.example.PriceService /project/build/classes/java/main/com/example/PriceService.class
```

No breakpoint has to be hit first. JDI allows redefinition on a running VM.
The dossier, the external research report that this skill started from
(see "Provenance" in [SKILL.md](../SKILL.md)), confirmed this on a running
JVM; this skill did not measure it.
[JDI `VirtualMachine.redefineClasses`](https://docs.oracle.com/en/java/javase/21/docs/api/jdk.jdi/com/sun/jdi/VirtualMachine.html)

## Procedure with `scripts/Redefine.java`

`scripts/Redefine.java` is a small JDI client in single-file mode, so it
needs no build step. It needs a full JDK (module `jdk.jdi`), not a JRE.
Run it from the project directory, because `<classesDir>` is relative to
that directory. Claude Code sets `CLAUDE_SKILL_DIR` to the directory of the
installed `spring-boot-repl` skill. A human reader replaces
`${CLAUDE_SKILL_DIR}` with the path of that directory.

```bash
./gradlew classes

# 1. Probe (default, changes nothing): which classes does the JVM have loaded?
java "${CLAUDE_SKILL_DIR}/scripts/Redefine.java" 127.0.0.1 5005 build/classes/java/main \
  com.example.PriceService com.example.PriceRules

# 2. Apply: all classes in ONE redefineClasses call.
java "${CLAUDE_SKILL_DIR}/scripts/Redefine.java" --apply 127.0.0.1 5005 build/classes/java/main \
  com.example.PriceService com.example.PriceRules
```

- **All classes in one call.** The JVM never runs a half-applied state.
  Between two `jdb` commands, it can.
- **Probe by default.** Without `--apply`, the tool only reports
  `canRedefine`, `loaded`, `notLoaded` and `ambiguous`. `ambiguous` lists
  each class that several real class loaders hold. A real loader is the
  application class loader that serves requests, as opposed to the
  throwaway loaders that Spring creates for inspection (see Pitfall (c)).
  Such a class makes `--apply` abort with exit 4, because the tool does not
  guess. The probe answers `"ok":false` when `--apply` is certain to fail
  (no redefine support, several real loaders).
- **Nested classes are added automatically** (`Name$*.class`: inner and
  anonymous classes of the same source) when the target JVM has loaded
  them. Java lambda bodies are private methods of the outer class, so a
  redefine of the outer class covers them.
- **A class that is not loaded makes the run incomplete: exit 5.** With
  `--apply`, the tool redefines the loaded classes and lists each unloaded
  one under `notLoaded`. The JSON then says `"complete":false`. The first
  load of such a class takes whatever version is on the class path of the
  JVM: in a container image or jar the old one, with a local exploded class
  path (`build/classes/...`) the new one. Exit 4 comes only when none of the
  classes is loaded. In the container case, put an unloaded class into
  `extraClasspath` (see below), so that its first load takes the new
  version.
- **Throwaway loaders are ignored** (see Pitfall (c)). The tool lists their
  copies under `ignoredCopies`, which is harmless. A class that only a
  throwaway loader holds counts as not loaded.
- **Output:** one line of JSON on stdout with `ok`, `complete`,
  `redefined`, `notLoaded`, `ignoredCopies` and `errors` (probe: `ok`,
  `canRedefine`, `loaded`, `notLoaded`, `ambiguous`). A usage error (exit 2)
  prints plain text on stderr instead.

| Exit | Meaning |
|---|---|
| 0 | ok: probe done, or all candidate classes redefined (`"complete":true`) |
| 5 | redefined, but incomplete: the classes under `notLoaded` were not redefined (see above) |
| 1 | the JVM rejected the redefinition (for example `UnsupportedOperationException` for a structural change without enhanced redefinition) |
| 2 | usage error |
| 3 | no JDWP connection |
| 4 | none of the classes is loaded, a class file is missing, or several real class loaders hold a class |

Measured 2026-11-15 on a throwaway JVM (OpenJDK 25.0.5): a method body
changed from v1 to v2 in the running process, an unloaded class was
reported under `notLoaded` with exit 5, and exits 0, 2 and 4 were
observed.

Use a fixed JDWP port. With an ephemeral port (`address=127.0.0.1:0`), JDWP
listens on a NEW port after each detach and prints a new
`Listening for transport dt_socket at address: N` line, so a second run
against the old port is refused. With a fixed port, attach, detach and
attach again works any number of times. Both behaviors were measured
2026-11-15 on Temurin 11.0.33, 17.0.21 and 25.0.5, in a container.

Ask the user before every `--apply` run, because `--apply` changes a
running JVM. Ask even when no permission prompt appears: the `Bash(java:*)`
entry in the `allowed-tools` list in the front matter of
[SKILL.md](../SKILL.md) pre-approves every `java` command, so the agent
gets no prompt. The probe changes nothing.

## What redefinition does and does not do

- Existing objects keep their field values.
- Constructors and field initialisers do **not** run again for them.
  (A dossier claim, not measured by this skill:
  a changed initialiser `99` did not appear on the existing instance. See
  [verification.md, "Runtime tests from the dossier"](verification.md#runtime-tests-from-the-dossier).)
- Static initialisers do not run again either. With
  `disabledPlugins=ClassInitPlugin`, HotswapAgent does not re-run them.
- Active stack frames can still execute the previous method version.
- New calls use the new code.
- Redefinition deletes the breakpoints in redefined classes (JDI
  contract). Set them again.
- Without enhanced redefinition, only method bodies can change. Enhanced
  redefinition is the `-XX:+AllowEnhancedClassRedefinition` mode of JBR
  (JetBrains Runtime), see [jbr-hotswap-install.md](jbr-hotswap-install.md). New
  fields, new methods or changed signatures fail with
  `UnsupportedOperationException: add method not implemented` or a similar
  message. With enhanced redefinition they work, unless a pitfall below
  turns it off.

## Pitfalls

Measured 2026-10/11 on JBR 25.0.4.1, HotswapAgent 2.0.3, Spring Boot 4 and
Hibernate 7, in Kubernetes on a Mac, unless stated otherwise.

### (a) JFR turns off enhanced redefinition on JBR

While any Flight Recording runs, `jcmd <pid> VM.flags` shows
`-XX:-AllowEnhancedClassRedefinition` instead of `+`. Every structural
change (new method, new field) then fails with
`UnsupportedOperationException: add method not implemented`. Method bodies
still swap, so the failure looks selective. G1, NMT (Native Memory Tracking),
string deduplication and the OpenTelemetry Java agent did not affect the
flag. Measured with a Docker flag matrix (one container per combination of
these JVM flags) and in a pod.

Check the flag before a structural change:

```bash
jcmd <pid> VM.flags     # must contain -XX:+AllowEnhancedClassRedefinition
```

`VM.flags` is the check. Do not run any `JFR.*` command in this JVM,
`JFR.check` included, because it is not a passive query. In a JVM without a
recording, one `JFR.check` started the `JFR Recorder Thread` and
`JFR Periodic Tasks` threads and loaded about 160 to 210 `jdk.jfr` classes
(measured 2026-11-15 on Temurin 17.0.21, 21.0.13 and 25.0.5, in a
container). Whether this also turns the flag off on JBR was not measured,
because JBR was not tested.

Do not run JFR in a JVM that you redefine, because a recording turns off
enhanced redefinition. This means no `-XX:StartFlightRecording` and no
recording started from JMC (JDK Mission Control, see
[jmc.md](../../java-debug/references/jmc.md)) or `jcmd`. Whether the flag returns after the
recording stops was not measured, so restart the JVM without JFR. For
profiling, use a second JVM without the dev stack (JBR with HotswapAgent,
nREPL and the redefine setup from [setup.md](setup.md)). See the
`java-debug` skill, [jfr.md](../../java-debug/references/jfr.md).

### (b) `ClassInitPlugin` and static initialisers

During the redefine, HotswapAgent's `ClassInitPlugin` appends a method
`$$ha$clinit` to every class with a static initialiser, for example every
class with Lombok `@Slf4j`. The loaded class lacks that method, so the JVM
refuses the redefine with `add method not implemented`. 4 of 4 `@Slf4j`
classes (100 %) failed.

Fix: set `disabledPlugins=ClassInitPlugin` in the
[`hotswap-agent.properties` template](setup.md#hotswap-agentproperties).
The cost: static initialisers do not re-run after a redefine. With the
plugin off, a real change (a changed string in an `@Slf4j` class)
redefined, was visible through Arthas `jad`, and was reverted.

To prove that the plugin is the cause, set the HotswapAgent logger to DEBUG
at runtime through Arthas:

```text
ognl '@org.hotswap.agent.logging.AgentLogger@setLevel(@org.hotswap.agent.logging.AgentLogger$Level@DEBUG)'
```

Then look in the application log for
`ClassInitPlugin - Adding $$ha$clinit to class: <fqcn>`.

### (c) Throwaway class loaders: "2 class loaders load the class"

After the first redefine of a JPA entity, HotswapAgent rebuilds the
`EntityManagerFactory`. Spring Data loads the entity again in an
`InspectionClassLoader` and keeps the copy. Spring's
`SimpleThrowawayClassLoader`, `OverridingClassLoader` and
`ShadowingClassLoader` do the same. The next redefine by name then sees two
loaders and aborts ("2 class loaders load the class").

`scripts/Redefine.java` ignores the copies in those loaders, redefines the
class in the real loader, and lists the copies under `ignoredCopies`.
Several **real** loaders still abort with exit 4. In that case, check with
Arthas `sc -d <fqcn>` which loaders hold the class. `jdb redefine` cannot
pick a loader at all.

### (d) DevTools and other restart loaders

A DevTools restart loader or a child context with its own loader produces
the same ambiguity. Disable the DevTools restart ([setup.md](setup.md)), so
that only one loader holds each application class.

## New classes and new `@Component`

JDI can only replace classes that the JVM has already loaded. For a new
class, or for one that exists in the image but was never loaded:

1. Compile the class and copy the class file (package directories
   included) into the directory configured as `extraClasspath` in the
   [template](setup.md#hotswap-agentproperties).
2. HotswapAgent puts that directory in front of the application class
   loader. Its Spring scanner registers a new bean after about 1 s.
3. In the same step, redefine the **existing** classes that use the new
   one (for example a bean that gets an `@Autowired` field for the new
   bean).

Measured: a new `@Component` (its `@PostConstruct` ran), a new
`@RestController` (the mapping appeared in
`RequestMappingHandlerMapping`), a helper class, and injection of a new
bean into an existing bean through a redefined field. A copy in
`extraClasspath` also wins over a class of the image that was never loaded
(its code source was the extra directory). An already loaded class still
needs a redefine.

Rules for the directory:

- Create the base-package directory (for `com.example`: `com/example`) in
  an init step, before HotswapAgent starts its watcher. Otherwise the
  watcher never sees the package.
- In a container, an `emptyDir` works. Do not `chmod` the mount root of an
  `emptyDir`, because the call fails with `EPERM`.
- An `emptyDir` survives a container restart but not a pod restart, so a
  pod restart removes everything that you added. That is the rollback.
- For the same reason, a broken class in the directory can stop the next
  start (`CrashLoopBackOff`). Delete the pod to empty the `emptyDir`.

Do not check a new endpoint by its HTTP status alone, because behind
Spring Security an unknown path also answers 401. See
[verification.md](verification.md), "Checks that mislead".

## Limits of the bare `jdb` client

- The client identifies the class **by name**. If several classloaders
  loaded that name (DevTools restart loader, child contexts with their own
  loader, plugin loaders, throwaway loaders), the client rejects the
  ambiguous choice. Check with Arthas `sc -d com.example.PriceService` how
  many loaders hold the class.
- One command replaces **one** class. The JDI API itself accepts several
  classes in one call, and `scripts/Redefine.java` uses that.

Source of the client behavior:
[OpenJDK `Commands.java`](https://github.com/openjdk/jdk21u/blob/master/src/jdk.jdi/share/classes/com/sun/tools/example/debug/tty/Commands.java).

For breakpoints, stepping and thread dumps, see the `java-debug` skill
([jdb.md](../../java-debug/references/jdb.md)).
