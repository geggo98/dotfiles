# Setup: JVM, HotswapAgent, nREPL

## Launch command

A JetBrains Runtime SDK 21 with HotswapAgent in `external` mode:

```bash
DEV_JAVA=/opt/dev/jbrsdk-21/bin/java
DEV_CP="$(./gradlew -q printReplClasspath)"

"$DEV_JAVA" \
  -XX:+AllowEnhancedClassRedefinition \
  -XX:HotswapAgent=external \
  -javaagent:/opt/dev/hotswap-agent-2.0.3.jar \
  -Dspring.devtools.restart.enabled=false \
  -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005 \
  -cp "$DEV_CP" \
  com.example.ReplMain \
  --spring.profiles.active=local-repl
```

- Paths, `com.example.ReplMain` and the profile `local-repl` are
  placeholders; the project defines them.
- `printReplClasspath` is a project Gradle task that prints the compiled
  class directories, resources and runtime dependencies (see below).
- Launch from the **exploded classpath**, not from the fat jar: the
  compiler must write into the directories the JVM loads from.
- The JDWP port serves `jdb` only. HA's own redefinition path uses
  `Instrumentation` and needs no port. Bind it to `127.0.0.1`.

Sources: [HotswapAgent 2.0.3 README](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/README.md).

## `hotswap-agent.properties` (first iteration)

Put it on the classpath root (for example `src/main/resources` of a
dev-only source set):

```properties
autoHotswap=false
spring.basePackagePrefix=com.example
LOGGER=info
LOGGER.org.hotswap.agent.plugin.spring=debug
```

Switch to `autoHotswap=true` only after `jdb redefine` works reliably.
**`autoHotswap` does not compile.** It watches class files and loads the
changes; the build (`./gradlew classes`, or the IDE) must still run.

Reference: [hotswap-agent.properties](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/hotswap-agent-core/src/main/resources/hotswap-agent.properties).

## Disable the DevTools restart

Spring Boot DevTools restarts the app in a new restart classloader. REPL
vars then still hold objects from the previous application world, and
classes with the same name exist twice (which also breaks `jdb redefine`,
see [redefine.md](redefine.md)). Hence
`-Dspring.devtools.restart.enabled=false`.
[Spring Boot DevTools](https://docs.spring.io/spring-boot/3.4/reference/using/devtools.html)

## Gradle: print the classpath

Untested sketch — adapt to the project's source sets:

```kotlin
tasks.register("printReplClasspath") {
    val cp = sourceSets["main"].runtimeClasspath
    inputs.files(cp)
    doLast { println(cp.asPath) }
}
```

When changing the build, run it with `--no-build-cache` (global rule).

## Embedding nREPL in the Boot process

Start nREPL in the **same process** and publish the real
`ApplicationContext` in a Clojure namespace, for example as `dev/ctx`.
The application does not have to be written in Clojure; Clojure's Java API
suffices. Dependencies on the dev classpath: `org.clojure:clojure` and
`nrepl:nrepl`.

Untested sketch of `ReplMain` (the dossier contains a full version that is
not reproduced here):

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
`lein repl :connect 7888`. Bind to `127.0.0.1` only — an nREPL port is
remote code execution by design.

Sources: [nREPL server embedding](https://docs.nrepl.org/nrepl/usage/server.html),
[Clojure Java interop](https://clojure.org/reference/java_interop).
