---
name: spring-boot-repl
description: >-
  REPL-driven development of a running Spring Boot application without
  restarting the JVM: nREPL embedded in the Boot process for live Clojure
  access to beans, class redefinition through `jdb redefine` or
  HotswapAgent `autoHotswap` on a JVM with enhanced class redefinition
  (JetBrains Runtime / DCEVM), HotswapAgent plugins to refresh Spring,
  Hibernate and Jackson state, and Arthas to inspect live objects.
  Covers swapping beans through the Spring API, HotSwappableTargetSource
  facades, rebuilding a Jackson ObjectMapper and rewiring the MVC
  converters, and rebuilding a Hibernate EntityManagerFactory. Triggers
  on: hot swap, hotswap, HotswapAgent, DCEVM, JBR,
  AllowEnhancedClassRedefinition, redefine class, retransform, jdb
  redefine, Arthas, vmtool, ognl, nREPL in Spring Boot, Clojure REPL
  against a Java app, live reload without restart, swap a bean at
  runtime, registerSingleton, destroySingleton, reinitialise Jackson,
  reload Hibernate mappings. For diagnostics only (JFR, OTel, JMX,
  Actuator, breakpoints) use the java-debug skill instead.
allowed-tools: >-
  Read(references/*)
  Bash(jdb:*) Bash(java:*) Bash(jcmd:*) Bash(curl:*)
  Read
dependencies: >-
  JetBrains Runtime (JBR) SDK 21 or another JVM with enhanced class
  redefinition; hotswap-agent 2.0.3 jar; nREPL + Clojure on the dev
  classpath; optionally Arthas. jdb ships with the JDK.
compatibility: >-
  macOS, Linux. Development JVMs only — never production.
---

# Spring Boot REPL — live development in a running JVM

**Goal:** change code, beans, and framework state in a running Spring Boot
JVM and see the effect at once. "Without restart" means: the JVM keeps
running, and the root `ApplicationContext` keeps running where possible.
Individual beans, an `EntityManagerFactory`, an `ObjectMapper`, or a
bounded child context may be rebuilt.

**Provenance.** This skill condenses an external research dossier
(HotswapAgent 2.0.3, Spring 6.2.12, Jackson 2.18, Hibernate 6.6,
JDK 21 API docs, source reading plus a few small runtime tests by its
author). The claims below were **not re-measured on this machine**. Treat
version-specific statements as hypotheses until the spike in
[verification](references/verification.md) passes on the project's real
version set.

## The stack

| Component | Role |
|---|---|
| **nREPL in the Boot process** | Evaluate Clojure, call real beans, keep data, define helpers, drive Spring APIs. |
| **Regular project compiler** (Gradle/Maven) | Compile Java/Kotlin, including annotation processing, into new class files. |
| **`jdb redefine`** or HotswapAgent **`autoHotswap`** | Load new definitions of already loaded classes into the JVM. |
| **HotswapAgent** (HA) | Refresh Spring, Hibernate, Jackson and other framework state after a class change. |
| **Arthas** | Inspect classloaders, contexts, beans and runtime behaviour; call public methods. |
| **Own dev helpers** | Coordinate project-specific changes that no plugin covers. |

Four layers must agree after every change. Check each one explicitly:

1. **Code** — which class definition runs?
2. **Object graph** — which instances and proxies do consumers reach?
3. **Framework metadata** — which mappings, annotations, serializers are registered?
4. **State** — what happens to existing data, open transactions, resources?

Class redefinition handles layer 1. HotswapAgent mainly earns its place on
layers 2 and 3.

## Rule 1: one path for class changes — redefine, never retransform

HotswapAgent 2.0.3 registers its central transformer with
`instrumentation.addTransformer(hotswapTransformer)`, that is, **not as
retransformation-capable**. Under the `java.lang.instrument` contract:

- On **redefinition**, the JVM calls this transformer again → HA plugins run.
- On **retransformation**, the JVM reuses the transformer's earlier output
  and does not call `transform` again → HA plugins do **not** run.

Consequence: **Arthas `retransform` can deliver a new method body while the
Spring, Hibernate or Jackson refresh silently does not happen.** In
addition, the Arthas transformer returns its stored replacement bytes
instead of building on the buffer that earlier transformers produced, so it
can discard other agents' instrumentation. This risk is derived from source
and contract, not observed in every combination.

So, with HotswapAgent loaded:

- Start with **`jdb redefine`**: the moment of the swap is visible and controlled.
- Move to **`autoHotswap=true`** once the combination has proven reliable.
- Use Arthas read-only first: `sc`, `vmtool`, `ognl`. `watch`, `trace`,
  `tt` and related commands instrument classes themselves and need
  coordination. Arthas `redefine` exists, but its own documentation warns
  about conflicts with other Arthas instrumentation and later resets — do
  not make it a second standard path.

## Rule 2: start the JVM with HotswapAgent from the beginning

HA plugins instrument constructors and bootstrap paths and register the
framework objects they see being created (the Jackson plugin, for example,
collects mapper and cache instances through constructor instrumentation).
Attaching later misses everything that was already initialised.

HotswapAgent and enhanced redefinition are **separate pieces**: a
`-javaagent` on an ordinary JVM does not allow new fields or methods. The
JVM itself must support structural redefinition (JBR with
`-XX:+AllowEnhancedClassRedefinition`).

Full launch command, `hotswap-agent.properties`, and the DevTools trap:
[setup](references/setup.md).

## Rule 3: know whether you change code or swap instances

- **Method redefinition:** the same instance runs new code and keeps its
  fields. Constructors and field initialisers do **not** run again.
  Active stack frames may still run the old version; new calls use the new one.
- **Bean recreation:** a new instance exists; every raw reference held
  elsewhere (a consumer field, a REPL `def`, a closure) still points to the old one.

In the REPL, look beans up again on every call instead of `def`-ing them.
For stable exchange points, put a proxy in front from the start
(`HotSwappableTargetSource`). Details: [spring-beans](references/spring-beans.md).

## Workflow

```
What changed?
  ├─ Method body in a loaded class          → compile, jdb redefine (or autoHotswap)
  ├─ New field/method, changed signature    → same, needs JBR enhanced redefinition
  ├─ Pure logic you want to iterate fast    → implement the Java interface in Clojure (reify),
  │                                            redefine the fn — see references/nrepl.md
  ├─ Bean wiring / bean definition          → HA Spring plugin, or Spring API + stable facade
  ├─ DTO / JSON shape                       → HA Jackson plugin clears caches; module config
  │                                            change → new ObjectMapper + rewire converters
  ├─ Entity mapping                         → new EntityManagerFactory generation
  │                                            (HA Hibernate plugin, or child context + facade)
  └─ "Which version actually runs?"         → Arthas sc / vmtool / ognl
```

Always finish with a check at the real boundary: a **real HTTP round
trip**, a **newly started persistence context**, and a **second reload in
the same session**. `mapper.writeValueAsString(...)` working in the REPL
proves nothing about what the endpoint uses.

## References

| File | Contents |
|---|---|
| [setup.md](references/setup.md) | JBR + HA launch command, properties, DevTools, classpath, nREPL bootstrap |
| [redefine.md](references/redefine.md) | `jdb redefine` procedure, limits, multi-classloader and multi-class changes |
| [nrepl.md](references/nrepl.md) | Clojure helpers against the context, `reify` + var redefinition, direct linking |
| [spring-beans.md](references/spring-beans.md) | `AutowireCapableBeanFactory` operations, `HotSwappableTargetSource`, generations, what HA does |
| [jackson.md](references/jackson.md) | HA Jackson plugin scope, `copy()` pitfalls, fresh `TypeFactory`, rewiring MVC converters |
| [hibernate.md](references/hibernate.md) | Runtime-safe Hibernate APIs, rebuilding the EMF, child-context generations |
| [verification.md](references/verification.md) | Plugin compatibility per version, the spike, acceptance criteria, dossier test results |

Related: the **java-debug** skill (JFR, OTel, JDB breakpoints, JMX,
Actuator) for diagnosis; the **devdocs** skill for Spring/JDK javadoc.
