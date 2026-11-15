---
name: spring-boot-repl
description: >-
  Live development in a running Spring Boot JVM: nREPL for Clojure access
  to beans, class redefinition on JetBrains Runtime / DCEVM, HotswapAgent
  plugins for Spring, Hibernate and Jackson state, and Arthas to read
  live objects. Covers Spring API bean swaps, HotSwappableTargetSource
  facades, rebuilding a Jackson ObjectMapper (with MVC converters) or
  a Hibernate EntityManagerFactory. Triggers on: hot swap, hotswap,
  HotswapAgent, autoHotswap, DCEVM, JBR, JBR install,
  AllowEnhancedClassRedefinition, redefine class, retransform, jdb
  redefine, Redefine.java, Arthas, vmtool, ognl, nREPL in Spring Boot,
  Clojure REPL against a Java app, live reload without restart, swap a
  bean at runtime, registerSingleton, destroySingleton, reinitialise
  Jackson, Jackson 3 hot swap, reload Hibernate mappings, EclipseLink
  redefine, ClassInitPlugin, excludedClassLoaderPatterns, extraClasspath,
  add method not implemented. For diagnostics only (JFR, OTel, JMX,
  Actuator, breakpoints): java-debug. For a JVM in a pod, use
  jvm-remote-debug.
allowed-tools: >-
  Read(references/*)
  Bash(jdb:*) Bash(java:*) Bash(jcmd:*) Bash(curl:*)
  Read
dependencies: >-
  JetBrains Runtime (JBR) SDK 21 or newer (measured with 25.0.4.1) or
  another JVM with enhanced class redefinition; hotswap-agent jar
  (measured with 2.0.3); nREPL + Clojure on the dev classpath; optionally
  Arthas (measured with 4.3.4). jdb ships with the JDK.
  scripts/Redefine.java needs a full JDK (module jdk.jdi).
compatibility: >-
  macOS, Linux. Development JVMs only — never production.
---

# Spring Boot REPL — live development in a running JVM

**Goal:** change code, beans, and framework state in a running Spring Boot
JVM and see the effect at once. "Without restart" means that the JVM keeps
running, and the root `ApplicationContext` keeps running where possible.
Individual beans, an `EntityManagerFactory`, an `ObjectMapper`, or a
bounded child context may be rebuilt.

**Provenance.** This skill started from an unpublished external research
report, called "the dossier" in this skill and its references. No copy is
stored with the skill, so do not look for one. The dossier covered
HotswapAgent 2.0.3, Spring 6.2.12, Jackson 2.18, Hibernate 6.6,
JDK 21 API docs, source reading, and a few small runtime tests by its
author. Since then, the core workflow was **measured** in 2026-10/11 on
JBR 25.0.4.1, HotswapAgent 2.0.3, Arthas 4.3.4, Spring Boot 4 (Spring
Framework 7), Hibernate 7, EclipseLink and Jackson 3, in Kubernetes on a
Mac. Those statements carry "measured" with date and stack. Everything
else is taken from the dossier and was not measured, for example
`autoHotswap=true`, Jackson 2 and the bean-swapping recipes. Because the
dossier is not available, such a statement has no source that you can
check, unless a reference file names a public source next to it. The lists of
measured and not measured items are in
[verification](references/verification.md). Before you rely on the
workflow, run its spike once on the project's real version set. The spike
is a short check that changes and reloads one service, one JSON endpoint
and one entity in the running JVM
([verification, "The spike"](references/verification.md#the-spike)). Run
it because the dossier and the measurements cover only the versions named
above.

## The stack

| Component | Role |
|---|---|
| **nREPL in the Boot process** | Evaluate Clojure, call real beans, keep data, define helpers, drive Spring APIs. |
| **Regular project compiler** (Gradle/Maven) | Compile Java/Kotlin, including annotation processing, into new class files. |
| **`jdb redefine`** or `scripts/Redefine.java` (or HotswapAgent `autoHotswap`, see Rule 1: not measured, off in the `hotswap-agent.properties` template in [setup](references/setup.md)) | Load new definitions of already loaded classes into the JVM. |
| **HotswapAgent** (HA) | Refresh Spring, Hibernate, Jackson and other framework state after a class change. |
| **Arthas** | Inspect classloaders, contexts, beans and runtime behaviour; call public methods. |
| **Own dev helpers** (Clojure functions that the project defines in the nREPL session, see [nrepl](references/nrepl.md); stable facades and bean swaps through the Spring API, see [spring-beans](references/spring-beans.md)) | Coordinate project-specific changes that no plugin covers. |

Four layers must agree after every change. Check each layer explicitly:

1. **Code** — which class definition runs?
2. **Object graph** — which instances and proxies do consumers reach?
3. **Framework metadata** — which mappings, annotations, serializers are registered?
4. **State** — what happens to existing data, open transactions, resources?

Class redefinition handles layer 1. HotswapAgent mainly earns its place on
layers 2 and 3.

## Rule 1: one path for class changes — redefine, never retransform

HotswapAgent 2.0.3 registers its central transformer with
`instrumentation.addTransformer(hotswapTransformer)`, that is, **not as
retransformation-capable**
([`PluginManager.java`, line 151](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/hotswap-agent-core/src/main/java/org/hotswap/agent/config/PluginManager.java#L151)). Under the `java.lang.instrument` contract:

- On **redefinition**, the JVM calls this transformer again, so the HA
  plugins run.
- On **retransformation**, the JVM reuses the transformer's earlier output
  and does not call `transform` again, so the HA plugins do **not** run.

Consequence: **Arthas `retransform` can deliver a new method body while the
Spring, Hibernate or Jackson refresh silently does not happen.** In
addition, the Arthas transformer returns its stored replacement bytes
instead of building on the buffer that earlier transformers produced, so it
can discard other agents' instrumentation. This risk is derived from source
and contract, not observed in every combination.

So, with HotswapAgent loaded:

- Start with **`jdb redefine`** for one class, because then the moment of
  the swap is visible and controlled.
- For several classes that belong together, or an entity after its first
  redefine, use **`scripts/Redefine.java`**: all classes in one call of the
  Java Debug Interface (JDI, module `jdk.jdi`), probe by default, `--apply`
  to change, JSON output. A probe run (without `--apply`) only reports
  which of the named classes the JVM has loaded and changes nothing.
  `--apply` changes a running JVM, so ask the user before every `--apply`
  run. Ask even when no permission prompt appears, because the skill's
  `Bash(java:*)` entry covers this command. Details and exit codes are in
  [redefine](references/redefine.md).
- New classes go into the `extraClasspath` directory, not through a
  redefine, because a redefine changes only classes that are already
  loaded ([redefine](references/redefine.md), "New classes").
  `extraClasspath` is a HotswapAgent property in `hotswap-agent.properties`.
  It names a directory that HotswapAgent adds to the class path, and a
  class put there loads on first use (property table in
  [setup](references/setup.md#hotswap-agentproperties)).
- **`autoHotswap=true`** is an option once the combination has proven
  reliable. With it, HotswapAgent watches the compiled class files and
  redefines a changed class by itself. The measured setup (JBR 25.0.4.1,
  HotswapAgent 2.0.3, see [verification](references/verification.md),
  "Runtime tests on the measured stack") kept `autoHotswap=false`, so
  `autoHotswap=true` is not measured.
- Use Arthas read-only: `sc` (search loaded classes), `sm` (list the
  methods of a class), `jad` (decompile a loaded class), `vmtool` (find
  live instances on the heap), `ognl` (evaluate an OGNL expression, for
  example a getter call; see [arthas](references/arthas.md)). These
  commands read state and weave no bytecode into classes. `watch`, `trace`, `tt` (TimeTunnel, which records method
  calls) and related commands instrument classes themselves and need
  coordination. Arthas `redefine` exists, but its own documentation
  (<https://arthas.aliyun.com/en/doc/redefine.html>) warns
  about conflicts with other Arthas instrumentation: a later `watch`,
  `trace`, `tt` or `jad` on the class resets it to its earlier bytecode,
  so the redefined code silently disappears. Do not make it a second path.
- Set `arthas.localConnectionNonAuth=false`. Arthas 4.3.4 ships it as
  `true`, and then the password does not protect requests from
  `127.0.0.1` (measured 2026-11-15 on Temurin 21 and 25, in a container).
  A `kubectl port-forward` arrives as such a loopback request. With the
  shipped setting, anyone who may port-forward to the pod therefore gets
  Arthas without a password. This includes `/mcp`, the built-in Model
  Context Protocol (MCP) server of Arthas 4.x, through which a client runs
  Arthas commands (measured 2026-11-15 with kubectl port-forward on
  OrbStack Kubernetes, a local container and VM runtime for macOS, see
  [orbstack-telepresence](../jvm-remote-debug/references/orbstack-telepresence.md)).
  The attach and password rules are in [arthas](references/arthas.md).
- **No JFR in a JVM you redefine.** On JBR a running recording turns
  enhanced redefinition off, and structural changes fail with
  `add method not implemented` (measured 2026-10/11).

## Rule 2: start the JVM with HotswapAgent from the beginning

HA plugins instrument constructors and bootstrap paths, and they register
the framework objects that they see being created (the Jackson plugin, for example,
collects mapper and cache instances through constructor instrumentation).
Attaching later misses everything that was already initialised.

HotswapAgent and enhanced redefinition are **separate pieces**. A
`-javaagent` on an ordinary JVM does not allow new fields or methods. The
JVM itself must support structural redefinition: JBR with
`-XX:+AllowEnhancedClassRedefinition`, through its built-in DCEVM
(Dynamic Code Evolution VM) patch. How to install both:
[jbr-hotswap-install](references/jbr-hotswap-install.md).

The full launch command, the one `hotswap-agent.properties` template,
memory, and the Spring Boot DevTools restart are in
[setup](references/setup.md). Disable that restart with
`-Dspring.devtools.restart.enabled=false`. The template is not optional.
`excludedClassLoaderPatterns` tells HotswapAgent which class loaders to
ignore, here the dynamic class loaders of Clojure and nREPL.
Without it, HotswapAgent instrumented each of them, and nREPL and
Clojure drove the metaspace to 1.2 GB, and the JVM was OOMKilled. Without
`disabledPlugins=ClassInitPlugin`, every class with a static initialiser
refused a redefine (measured 2026-10/11), because `ClassInitPlugin` adds
a synthetic method `$$ha$clinit` to every class with a static initialiser
during the redefine. That makes every redefine of such a class a
structural change, which the JVM refuses with
`add method not implemented`
([redefine, "ClassInitPlugin"](references/redefine.md#b-classinitplugin-and-static-initialisers)).

## Rule 3: know whether you change code or swap instances

- **Method redefinition:** the same instance runs new code and keeps its
  fields. Constructors and field initialisers do **not** run again.
  Active stack frames may still run the old version; new calls use the new one.
- **Bean recreation:** a new instance exists; every raw reference held
  elsewhere (a consumer field, a REPL `def`, a closure) still points to the old one.

In the REPL, look beans up again on every call instead of `def`-ing them.
In Clojure, `def` binds a value to a global name (a var) in the REPL
namespace, so the name keeps the object it got at that moment, and after a
bean recreation that is the old instance. For stable
exchange points, put a proxy in front from the start
(`HotSwappableTargetSource`), so that consumers keep one reference while
the target behind it changes. When several related beans must change
together, swap a **generation**: a complete new set of related beans (or a
new `EntityManagerFactory` with its dependants) that replaces the old set
behind one stable facade. Details are in
[spring-beans](references/spring-beans.md).

## Workflow

```
What changed?
  ├─ Method body in a loaded class          → compile, jdb redefine (one class) or scripts/Redefine.java
  ├─ Several classes together               → scripts/Redefine.java (probe, then --apply)
  ├─ New field/method, changed signature    → same, needs JBR enhanced redefinition, no JFR
  ├─ New class / new @Component             → copy into extraClasspath (references/redefine.md)
  ├─ Pure logic you want to iterate fast    → implement the Java interface in Clojure (reify),
  │                                            redefine the fn — see references/nrepl.md
  ├─ Bean wiring / bean definition          → HA Spring plugin, or Spring API + stable facade
  ├─ DTO / JSON shape                       → Jackson 2: HA Jackson plugin clears caches;
  │                                            Jackson 3: custom HA plugin (references/jackson.md);
  │                                            module config change → new ObjectMapper + rewire
  ├─ Entity mapping                         → new EntityManagerFactory generation
  │                                            (HA Hibernate plugin, or child context + facade)
  └─ "Which version actually runs?"         → Arthas sc / vmtool / ognl
```

Always finish with a check at the real boundary: a **real HTTP round
trip**, a **newly started persistence context**, and a **second reload in
the same session**. A `mapper.writeValueAsString(...)` call that works in
the REPL proves nothing about the mapper that the endpoint uses.

## References

| File | Contents |
|---|---|
| [pitfalls-index.md](references/pitfalls-index.md) | Start here with an error text: from the symptom to the file and section |
| [jbr-hotswap-install.md](references/jbr-hotswap-install.md) | Getting JBR and HotswapAgent, checksums, minimal flags, check |
| [setup.md](references/setup.md) | JBR + HA launch command, the `hotswap-agent.properties` template, memory, DevTools, classpath, nREPL bootstrap |
| [redefine.md](references/redefine.md) | `jdb redefine` vs `scripts/Redefine.java`, measured pitfalls (JFR, `ClassInitPlugin`, short-lived class loaders such as Spring's `SimpleThrowawayClassLoader` that keep extra copies of a class), new classes via `extraClasspath` |
| [arthas.md](references/arthas.md) | On-demand attach, password handling, read-only commands, what not to use |
| [nrepl.md](references/nrepl.md) | Clojure helpers against the context, `reify` + redefinition of a var, direct linking (a Clojure compiler option that makes a redefined function invisible to its callers; keep it off) |
| [spring-beans.md](references/spring-beans.md) | `AutowireCapableBeanFactory` operations, `HotSwappableTargetSource`, generations, what HA does |
| [jackson.md](references/jackson.md) | Jackson 3 custom plugin, HA Jackson 2 plugin scope, `copy()` pitfalls, fresh `TypeFactory`, rewiring MVC converters |
| [hibernate.md](references/hibernate.md) | Measured Hibernate 7 and EclipseLink redefines, runtime-safe Hibernate APIs, rebuilding the `EntityManagerFactory`, child-context generations |
| [verification.md](references/verification.md) | Plugin compatibility per version, the spike, checks that mislead, measured and dossier test results |

Script: `scripts/Redefine.java`, a JDI client. It runs in single-file
mode, that is, `java` compiles and runs the `.java` file directly
([JEP 330](https://openjdk.org/jeps/330), "Launch Single-File Source-Code Programs"):
`java "${CLAUDE_SKILL_DIR}/scripts/Redefine.java" [--apply] 127.0.0.1 5005 build/classes/java/main <fqcn>...`.
The arguments are the JDWP host and port of the target JVM, the directory
with the compiled classes (`<classesDir>`), and the fully qualified class
names (fqcn) to redefine. The target JVM must run with a JDWP agent on
that port, for example `-agentlib:jdwp=…,address=127.0.0.1:5005` as in
[setup](references/setup.md).
Claude Code sets `CLAUDE_SKILL_DIR` to the directory of this skill. Other
readers replace `${CLAUDE_SKILL_DIR}` with the path of that directory.
Run the script from the project directory, because `<classesDir>` is
relative to it. Ask the user before every `--apply` run, even when no
permission prompt appears (Rule 1).

Related skills:

- `java-debug` for diagnosis (JFR, OTel, JDB breakpoints, JMX, Actuator)
- `jvm-remote-debug` for reaching a JVM in a pod or container
  (port-forward, Secrets, memory limits)
- `devdocs` (a separate offline API-reference skill, if installed) for Spring and JDK javadoc
