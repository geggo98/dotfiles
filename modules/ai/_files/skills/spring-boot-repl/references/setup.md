Applies to: everywhere (macOS and Linux hosts, containers)

# Setup: JVM, HotswapAgent, nREPL

This file holds the one `hotswap-agent.properties` template of the skill.
Other files link here instead of repeating it. How to get JBR and the agent
jar: [jbr-hotswap-install.md](jbr-hotswap-install.md).

## Launch command

Start a JetBrains Runtime (JBR) SDK with HotswapAgent in `external` mode.
In `external` mode, the JVM loads HotswapAgent as an ordinary `-javaagent`
jar instead of the copy bundled with JBR (see
[jbr-hotswap-install.md](jbr-hotswap-install.md)).
The external research dossier that this skill started from used JBR 21
(see [SKILL.md](../SKILL.md), "Provenance"). In this file, "the measured
setup" is the test deployment that the skill author measured in
2026-10/11: JBR 25.0.4.1, HotswapAgent 2.0.3, Arthas 4.3.4 (a JVM
diagnostics tool, see [arthas.md](arthas.md)) and Spring Boot 4, in
Kubernetes on a Mac.

```bash
DEV_JAVA=/opt/dev/jbrsdk/bin/java
DEV_CP="$(./gradlew -q printReplClasspath)"

"$DEV_JAVA" \
  -XX:+AllowEnhancedClassRedefinition \
  -XX:HotswapAgent=external \
  -javaagent:/opt/dev/hotswap-agent-2.0.3.jar \
  --add-opens java.base/java.net=ALL-UNNAMED \
  --add-opens java.base/jdk.internal.loader=ALL-UNNAMED \
  -Dspring.devtools.restart.enabled=false \
  -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005 \
  -cp "$DEV_CP" \
  com.example.ReplMain \
  --spring.profiles.active=local-repl
```

- Paths, `com.example.ReplMain` and the profile `local-repl` are
  placeholders. The project defines them.
- `printReplClasspath` is a project Gradle task that prints the compiled
  class directories, resources and runtime dependencies (see below).
- Launch from the **exploded classpath**, not from the fat jar, because
  the compiler must write into the directories that the JVM loads from. The
  measured setup also ran from a Boot fat jar (`app.jar`) in a container.
  There, new classes go through `extraClasspath` (below), and changed
  classes go through [redefine.md](redefine.md).
- The two `--add-opens` are required. Without them every class-loader
  initialisation throws `InaccessibleObjectException` once HotswapAgent
  tries to extend a loader (measured 2026-10/11, JBR 25, Spring Boot 4).
- The JDWP port serves `jdb` and
  [scripts/Redefine.java](../scripts/Redefine.java) (see
  [redefine.md](redefine.md), "Procedure with `scripts/Redefine.java`").
  HotswapAgent's own
  redefinition path uses `Instrumentation` and needs no port. Bind the JDWP
  port to `127.0.0.1`, because JDWP is unauthenticated code execution. For
  a JVM in a pod, reach it with `kubectl port-forward` (see the
  [jvm-remote-debug](../../jvm-remote-debug/SKILL.md) skill). JDWP on
  `127.0.0.1:5005` worked through
  `kubectl port-forward 15005:5005` with the host's `jdb` 25 against a
  JDK 21 target (measured 2026-11-15 on OrbStack Kubernetes, a Docker and
  Kubernetes runtime for macOS, see
  [orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md)).
  The forward arrives in the pod as a loopback connection, so the
  `127.0.0.1` binding does not keep out anyone who may run a port-forward
  to the pod.
- Bind in-pod listeners (JDWP, nREPL, Arthas) to IPv4 `127.0.0.1` or to a
  wildcard address, not to `::1` and not to the pod IP. On OrbStack
  Kubernetes with the Docker runtime, port-forward connects only through
  IPv4 to `localhost` and has no IPv6 fallback. A listener on `::1` or on
  the pod IP is unreachable: the client sees the connection open and then
  EOF without data (measured 2026-11-15 with kubectl port-forward). Whether
  containerd or CRI-O behave the same was not measured.
- One refused forwarded connection ends the whole `kubectl port-forward`
  process with `error: lost connection to pod`, including all other ports
  in that process. After that, every forwarded port answers
  `Connection refused` on the host side (measured 2026-11-15 on OrbStack
  Kubernetes). If you forward several ports at
  once, a wrong bind address on one port therefore cuts off the others.
- **No JFR in this JVM.** On JBR, a running Flight Recording turns
  `AllowEnhancedClassRedefinition` off. Details are in
  [redefine.md](redefine.md), "Pitfalls".

When the flags go into `JAVA_TOOL_OPTIONS` (container images, wrappers),
put the hotswap flags first, as in the measured setup. The hotswap flags are
`-XX:+AllowEnhancedClassRedefinition`, `-XX:HotswapAgent=external` and
`-javaagent:…/hotswap-agent-2.0.3.jar` from the launch command above. Why
the order matters is not known: the measured setup used this order, and
other orders were not measured. Every JVM started in that environment
inherits `JAVA_TOOL_OPTIONS`, including `jcmd` and `arthas-boot`, the
launcher jar of Arthas. Start those tools with `env -u JAVA_TOOL_OPTIONS`,
because otherwise they try to bind the JDWP port a second time.

Sources: [HotswapAgent 2.0.3 README](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/README.md).

## Memory

Plan more memory than for the same app without the dev stack (JBR with
HotswapAgent, nREPL, Arthas, JDWP). With JBR,
HotswapAgent, JFR and an OpenTelemetry agent in one JVM, a container with a
2 GiB limit was OOMKilled during startup, and 3 GiB worked (measured 2026-10/11,
JBR 25, Spring Boot 4, Kubernetes). JFR has to go anyway (see "No JFR in
this JVM" under [Launch command](#launch-command), and
[redefine.md, Pitfalls (a)](redefine.md#a-jfr-turns-off-enhanced-redefinition-on-jbr)). A
2 GiB limit without JFR was not measured. For pod-specific sizing, see the
[jvm-remote-debug](../../jvm-remote-debug/SKILL.md) skill, file
[hotswap-in-cluster.md](../../jvm-remote-debug/references/hotswap-in-cluster.md),
section "Requirements".

## `hotswap-agent.properties`

Put it on the classpath root (for example `src/main/resources` of a
dev-only source set). This is the template the measured setup used
(2026-10/11, JBR 25.0.4.1, HotswapAgent 2.0.3, Arthas 4.3.4, Spring Boot 4):

```properties
# Redefinition is driven explicitly (jdb redefine or scripts/Redefine.java).
autoHotswap=false

# Base package of the application: the Spring plugin only scans below it.
spring.basePackagePrefix=com.example

# Directory for NEW classes. HotswapAgent puts it in front of the
# application class loader. Must be set HERE, not as a -D property.
extraClasspath=/opt/app/extra-classes

# ClassInitPlugin adds $$ha$clinit to every class with a static initialiser.
# The JVM then rejects the redefine with "add method not implemented".
disabledPlugins=ClassInitPlugin

# Loaders that must not receive the ~350 HotswapAgent plugin classes.
# Each regex must match the WHOLE loader class name (Pattern.matches).
# An exact name works as it is. A package prefix needs a trailing .*
excludedClassLoaderPatterns=clojure[.]lang[.]DynamicClassLoader,com[.]taobao[.]arthas[.].*

LOGGER=info
# Otherwise about 48,000 INFO lines per start.
LOGGER.org.hotswap.agent.plugin.spring.getbean.ProxyReplacer=warning
# While checking the Spring plugin:
# LOGGER.org.hotswap.agent.plugin.spring=debug
```

Why each line is there:

| Key | Reason | Failure without it |
|---|---|---|
| `autoHotswap=false` | The swap happens when you run the redefine, not when a class file changes. | Half-built class sets load while the compiler still writes. |
| `spring.basePackagePrefix` | Limits the Spring plugin to the application's packages. | The plugin scans and logs far more than needed. |
| `extraClasspath` | New classes and new `@Component`s, see [redefine.md, "New classes and new `@Component`"](redefine.md#new-classes-and-new-component). | No way to add a class that the JVM has not loaded yet. |
| `disabledPlugins=ClassInitPlugin` | See [redefine.md](redefine.md), "Pitfalls". | `add method not implemented` on every class with a static initialiser, for example Lombok `@Slf4j`. In the measured setup, 4 of 4 (100 %) tested `@Slf4j` classes failed, see [verification.md](verification.md). |
| `excludedClassLoaderPatterns` | HotswapAgent copies about 350 plugin classes into every class loader. Clojure creates one `DynamicClassLoader` per compiled function. | With nREPL + Clojure: about 1,300 loaders, 460,000 classes, metaspace 1.2 GB growing by 30 MB/s, OOMKilled at a 3 GiB limit. With the pattern: metaspace 180 MB, start in 11 s. |
| Arthas in the same pattern | The built-in Jackson 2 plugin tries to patch the Arthas loader's own `ObjectMapper`. | Stack trace `no such class: org.hotswap.agent.config.PluginManager` in the log. |
| `ProxyReplacer=warning` | `ProxyReplacer` is the component of the HotswapAgent Spring plugin that wraps beans in replaceable proxies. At `info` it logs one INFO line per bean outside the base package. | About 48,000 INFO lines per start. |

All failure figures: measured 2026-10/11 on JBR 25.0.4.1, HotswapAgent
2.0.3, Arthas 4.3.4 and Spring Boot 4, in Kubernetes on a Mac.

**`extraClasspath` belongs in this file, not on the command line.** The same
setting as a `-D` system property is also seen by the Spring Boot launcher's
class loader of a fat jar. The new classes then landed in the wrong loader,
could not see `BOOT-INF/lib`, and the start failed with
`NoClassDefFoundError: org/slf4j/LoggerFactory`, and the pod went into
`CrashLoopBackOff` (measured
2026-10/11).

**Diagnose a class-loader explosion** with
`jcmd <pid> VM.classloader_stats` (count of loaders and classes per loader
type) and, when Native Memory Tracking is on
(`-XX:NativeMemoryTracking=summary`), `jcmd <pid> VM.native_memory summary`
(metaspace).

Switch to `autoHotswap=true` only after the explicit redefine works
reliably, because the measured setup kept `autoHotswap=false`, so
`autoHotswap=true` was not measured.
**`autoHotswap` does not compile.** It watches class files and loads the
changes. The build (`./gradlew classes`, or the IDE) must still run.

Reference: [hotswap-agent.properties](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/hotswap-agent-core/src/main/resources/hotswap-agent.properties).

## Disable the DevTools restart

Set `-Dspring.devtools.restart.enabled=false`. Spring Boot DevTools
restarts the app in a new restart classloader. REPL vars then still hold
objects from the previous application, and classes with the same name exist
twice. The duplicate classes also break `jdb redefine` (see
[redefine.md](redefine.md)).
[Spring Boot DevTools](https://docs.spring.io/spring-boot/reference/using/devtools.html)

## Gradle: print the classpath

The following sketch is untested. Adapt it to the project's source sets:

```kotlin
tasks.register("printReplClasspath") {
    val cp = sourceSets["main"].runtimeClasspath
    inputs.files(cp)
    doLast { println(cp.asPath) }
}
```

When you change the build, run it with `--no-build-cache`,
so that cached task outputs do not hide the effect of the change.

## Embedding nREPL in the Boot process

Start nREPL in the **same process** and publish the real
`ApplicationContext` in a Clojure namespace, for example as `dev/ctx`.
The application does not have to be written in Clojure, because
Clojure's Java API is enough. Dependencies on the dev classpath:
`org.clojure:clojure` and `nrepl:nrepl`.

With HotswapAgent in the same JVM, the `excludedClassLoaderPatterns` line
above is mandatory, because every Clojure evaluation compiles a class into
a new loader (see the table above).

The following sketch of `ReplMain` is untested. A full version exists only
in the dossier ([SKILL.md](../SKILL.md), "Provenance"), which is not
available here.

```java
package com.example;

import clojure.java.api.Clojure;
import clojure.lang.IFn;
import org.springframework.boot.SpringApplication;

public final class ReplMain {
    public static void main(String[] args) {
        var ctx = SpringApplication.run(Application.class, args);

        IFn require = Clojure.var("clojure.core", "require");
        require.invoke(Clojure.read("nrepl.server"));

        // (intern 'dev 'ctx ctx)
        Clojure.var("clojure.core", "create-ns").invoke(Clojure.read("dev"));
        Clojure.var("clojure.core", "intern")
            .invoke(Clojure.read("dev"), Clojure.read("ctx"), ctx);

        Clojure.var("nrepl.server", "start-server").invoke(
            Clojure.read(":bind"), "127.0.0.1",
            Clojure.read(":port"), 7888);
    }
}
```

Connect from the terminal with any nREPL client, for example
`lein repl :connect 7888` (`lein` is Leiningen, the Clojure build tool,
which includes an nREPL client). Bind nREPL to `127.0.0.1` only, because an
nREPL port is remote code execution by design. For a JVM in a pod, use
`kubectl port-forward pod/<pod> 7888:7888`. The forward reaches a listener
on IPv4 `127.0.0.1`, but not one on `::1` (see
[Launch command](#launch-command)).

Sources: [nREPL server embedding](https://docs.nrepl.org/nrepl/usage/server.html),
[Clojure Java interop](https://clojure.org/reference/java_interop).
