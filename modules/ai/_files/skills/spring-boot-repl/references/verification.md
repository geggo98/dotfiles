Applies to: everywhere (local JVMs on macOS and Linux hosts, containers and
Kubernetes pods alike)

# Compatibility and verification

## Plugin compatibility (HotswapAgent 2.0.3)

HotswapAgent's sources of information show partly different historical
states: its public website ([hotswapagent.org](https://hotswapagent.org)),
the version metadata of its plugins (the `@Plugin` annotations in the
plugin classes linked below) and the test scripts in its
[repository](https://github.com/HotswapProjects/HotswapAgent). The
dossier, an external research report that this skill started from (see
Provenance in [SKILL.md](../SKILL.md)), therefore checked the
capabilities in the source of the **released 2.0.3**, separate from newer
development builds. The "Measured" column comes from runs on JetBrains
Runtime (JBR) 25.0.4.1,
HotswapAgent 2.0.3, Spring Boot 4 (Spring Framework 7), Hibernate 7 and
Jackson 3, in Kubernetes on a Mac, 2026-10/11.

| Framework | Finding from the source (dossier) | Measured 2026-10/11 |
|---|---|---|
| **Spring 6 / 7** | Adaptations exist in the release and the code. There is no promise for every Boot and Spring combination. | Spring Framework 7: a new `@Component`, a new `@RestController` and injection into an existing bean worked ([redefine.md](redefine.md)). |
| **Hibernate 6.6 / 7** | The version metadata (`testedVersions` in `@Plugin`) and the matchers (the class-name and version checks that decide whether the plugin activates) contradict each other. Even when these checks do not match, other code paths in `HibernateJakartaPlugin.java` can still activate the plugin. "Loaded" does not mean "correctly integrated". | Hibernate 7: `HibernateJakarta` rebuilds the `EntityManagerFactory` (EMF) per entity redefine. A new method and a new field arrive ([hibernate.md](hibernate.md)). |
| **EclipseLink** | Not covered by the dossier. | Method and field changes work without a plugin. Mappings cannot change ([hibernate.md](hibernate.md)). |
| **Jackson 2** | The plugin accesses concrete internals, so check the version in use. | Not measured. |
| **Jackson 3** | The plugin targets `com.fasterxml.jackson.*`. It does not cover `tools.jackson.*`. | Confirmed: the caches stay stale. A custom plugin fixes this ([jackson.md](jackson.md)). |

Sources: [Release 2.0.3](https://github.com/HotswapProjects/HotswapAgent/releases/tag/RELEASE-2.0.3),
[HibernateJakartaPlugin](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-hibernate-jakarta-plugin/src/main/java/org/hotswap/agent/plugin/hibernate_jakarta/HibernateJakartaPlugin.java),
[JacksonPlugin](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-jackson-plugin/src/main/java/org/hotswap/agent/plugin/jackson/JacksonPlugin.java).

Before you trust a plugin, read its startup log line and check the version
that it reports against the version on the classpath. The reason: the
plugin metadata contradicts itself, and a loaded plugin is not necessarily
correctly integrated. To get that log line, add
`LOGGER.org.hotswap.agent.plugin.<name>=debug` to `hotswap-agent.properties`
([setup.md](setup.md#hotswap-agentproperties) has the commented example
`LOGGER.org.hotswap.agent.plugin.spring=debug`).

## The spike

Run the spike once per project and version set, before you rely on the
[workflow in SKILL.md](../SKILL.md#workflow). The table above shows that the plugins behave differently per
framework version, so only a run on your stack tells what works there.
Pick **one service, one JSON endpoint and one entity**. For each of them,
change and reload in the running JVM:

1. **Service:** change a method body, then add a method, and apply both
   with `jdb redefine`. Call the method through the REPL **and** through
   HTTP.
2. **JSON endpoint:** add a DTO field with an annotation. Then check the
   serialised output in a real HTTP response.
3. **Entity:** add a mapped column, and apply the schema change
   separately. Then open a **new** persistence context, and read and write
   the column.

Acceptance criteria:

- All three changes are visible through **real HTTP processing**, not only
  in the REPL.
- The entity change is visible in a **newly started** persistence context.
- A **second and a third reload** in the same session still work: no stale
  caches, and no growing classloader count in the Arthas command `classloader`
  ([arthas.md](arthas.md)).
- The HotswapAgent (HA) log shows no exceptions, and the Arthas command `sc -d <fqcn>`
  ([arthas.md](arthas.md)) shows a single classloader per changed class.

The result shows which changes HA handles reliably on this stack, and
where your own API helpers ([spring-beans.md](spring-beans.md),
[jackson.md](jackson.md), [hibernate.md](hibernate.md)) are worth writing.

## Checks that mislead

Three checks looked like proof in the measured setup and were not:

1. **An HTTP 401 does not prove that a mapping exists.** Behind Spring
   Security, an unknown path also answers 401. Check the mapping registry
   instead, for example in the REPL:
   `(.getHandlerMethods (.getBean dev/ctx org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerMapping))`.
   `dev/ctx` is the Clojure var that holds the live `ApplicationContext`
   ([nrepl.md](nrepl.md)).
   If there is more than one `RequestMappingHandlerMapping` bean, look the
   bean up by name.
2. **A baseline must not load the class under test.** An `eval` or an
   Arthas command that touches the class loads it. The "not loaded yet"
   case (a new class through `extraClasspath`, the HotswapAgent setting
   for a directory that new classes are loaded from, see
   [setup.md](setup.md#hotswap-agentproperties)) is then spoiled for the
   rest of the life of the JVM. Run `scripts/Redefine.java` without
   `--apply` first. In this default probe mode it only asks the JVM which
   classes are loaded, and loads nothing
   ([redefine.md](redefine.md#procedure-with-scriptsredefinejava)).
3. **Check the redefinition flag before a structural-change test.**
   `jcmd <pid> VM.flags` must show `-XX:+AllowEnhancedClassRedefinition`.
   A running JFR recording turns the flag off, and a failed "add a method"
   test then says nothing about HotswapAgent
   ([redefine.md](redefine.md#a-jfr-turns-off-enhanced-redefinition-on-jbr), Pitfall (a)).

## Runtime tests on the measured stack

Measured 2026-10/11 on JBR 25.0.4.1, HotswapAgent 2.0.3, Arthas 4.3.4,
Spring Boot 4, Hibernate 7 and Jackson 3, in Kubernetes on a Mac:

| Test | Observed result |
|---|---|
| Method body change in a running service | The same JVM and the same bean instance ran the new code. The change reverted cleanly. |
| HTTP path change in a `@RestController` | The mapping registry followed: old path 404, new path 200. |
| New getter or new `@JsonProperty` in a DTO (Jackson 3, custom plugin) | New JSON shape in the HTTP response without a manual flush. |
| New `@Component` or `@RestController` through `extraClasspath` ([redefine.md](redefine.md#new-classes-and-new-component)) | Bean registered after about 1 s. `@PostConstruct` ran, and the mapping appeared. |
| Entity: new method, new field on an existing column (Hibernate 7) | Arrived after the EMF rebuild. |
| Entity: field on a missing column | `Unknown column` at query time. Works after `ALTER TABLE`. |
| Structural change while JFR runs | `add method not implemented`. `jcmd <pid> VM.flags` showed `-XX:-AllowEnhancedClassRedefinition`. |
| Class with a static initialiser while `ClassInitPlugin` is on ([redefine.md](redefine.md#b-classinitplugin-and-static-initialisers)) | `add method not implemented` (4 of 4 `@Slf4j` classes, 100 %). |
| nREPL and Clojure without `excludedClassLoaderPatterns` for Clojure's `DynamicClassLoader`s ([setup.md](setup.md#hotswap-agentproperties)) | Metaspace 1.2 GB, OOMKilled at 3 GiB. With the exclusion: 180 MB. |
| `scripts/Redefine.java` on a throwaway JVM (2026-11-15) | Method body changed from v1 to v2, the unloaded class was reported, and the error exit codes matched the exit-code table in [redefine.md](redefine.md#procedure-with-scriptsredefinejava). |

Not measured on this stack:

- `autoHotswap=true`, the setting in `hotswap-agent.properties` that
  redefines a class automatically when its class file changes
  ([setup.md](setup.md#hotswap-agentproperties))
- Jackson 2
- the `ObjectMapper` replacement and the converter rewiring in
  [jackson.md](jackson.md)
- a new EMF generation in a child context
  ([hibernate.md, "Own implementation: a generation in a child context"](hibernate.md#own-implementation-a-generation-in-a-child-context))
  and re-running `afterPropertiesSet()` on the existing factory bean
  ([hibernate.md, "Experimental: re-run `afterPropertiesSet()`"](hibernate.md#experimental-re-run-afterpropertiesset))
- the `HotSwappableTargetSource` recipes in [spring-beans.md](spring-beans.md)
- the Clojure `reify` pattern in [nrepl.md](nrepl.md)

For these, only the tests of the dossier below exist.

## Runtime tests from the dossier

The author of the dossier ran these tests, not on the measured stack
described above (JBR 25.0.4.1 in Kubernetes on a Mac):

| Test | Observed result |
|---|---|
| `jdb redefine` on OpenJDK 17.0.20 without a breakpoint | The same process switched from `old:17` to `new:17`: the new method code ran, but the changed field initialiser `99` did not run afterwards for the existing instance ([redefine.md](redefine.md#what-redefinition-does-and-does-not-do)). |
| Spring 6.2.12 bean destruction and recreation (`destroySingleton` and `registerSingleton`, [spring-beans.md](spring-beans.md#autowirecapablebeanfactory-and-the-singleton-registry)) | Registered dependents were destroyed first. Old consumer references stayed old, and a new lookup returned the new instance. |
| Stable Spring AOP proxy with a swappable target (`HotSwappableTargetSource`, [spring-beans.md](spring-beans.md#stable-exchange-points-hotswappabletargetsource)) | New calls reached the new delegate. Its existing advice chain stayed effective. |
| Clojure `reify` with var redefinition | The same instance switched from `90.00M` to `80.00M`, the result of the pricing function `rabatt` before and after the var was redefined ([nrepl.md](nrepl.md#implementing-a-java-interface-in-clojure)). |
| Jackson 2.18.2 mapper and type cache | The copied mapper (`ObjectMapper.copy()`) shared the `TypeFactory` at first. The explicit replacement, a `TypeFactory` with its own cache set through `setTypeFactory(...withCache(...))`, created its own type cache ([jackson.md](jackson.md#objectmappercopy-is-not-a-full-reset)). |
| Jackson module with the same ID after `copy()` | With duplicate detection (`MapperFeature.IGNORE_DUPLICATE_MODULE_REGISTRATIONS`) active, the re-registration did not set the module up again ([jackson.md](jackson.md#objectmappercopy-is-not-a-full-reset)). |

These tests confirm the single mechanisms. The full combination of the
real Boot application, JBR, HotswapAgent, Hibernate and Jackson remains an
integration test for the concrete project.

