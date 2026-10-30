# Compatibility and verification

## Plugin compatibility (HotswapAgent 2.0.3)

The public website, plugin metadata and test scripts show partly different
historical states. The dossier therefore checked capabilities in the
source of the **released 2.0.3**, separate from newer development builds.

| Framework | Finding |
|---|---|
| **Spring 6** | Adaptations exist in the release and the code. No promise for every Boot/Spring combination. |
| **Hibernate 6.6** | Version metadata and matchers contradict each other; fallback mechanisms can still activate the plugin. "Loaded" does not mean "correctly integrated". |
| **Jackson 2** | The plugin accesses concrete internals; check the version in use. |
| **Jackson 3** | The plugin targets `com.fasterxml.jackson.*`; `tools.jackson.*` is not covered. |

Sources: [Release 2.0.3](https://github.com/HotswapProjects/HotswapAgent/releases/tag/RELEASE-2.0.3),
[HibernateJakartaPlugin](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-hibernate-jakarta-plugin/src/main/java/org/hotswap/agent/plugin/hibernate_jakarta/HibernateJakartaPlugin.java),
[JacksonPlugin](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-jackson-plugin/src/main/java/org/hotswap/agent/plugin/jackson/JacksonPlugin.java).

Before trusting a plugin, read its startup log line
(`LOGGER.org.hotswap.agent.plugin.<name>=debug`) and check the version
it reports against the one on the classpath.

## The spike

Run it once per project and version set, before relying on the workflow.
Pick **one service, one JSON endpoint and one entity**. For each, change
and reload in the running JVM:

1. **Service:** change a method body, then add a method → `jdb redefine`.
   Call it through the REPL **and** through HTTP.
2. **JSON endpoint:** add a DTO field with an annotation → check the
   serialised output in a real HTTP response.
3. **Entity:** add a mapped column (with the schema change applied
   separately) → open a **new** persistence context and read and write it.

Acceptance criteria:

- All three changes visible through **real HTTP processing**, not only in the REPL.
- Entity change visible in a **newly started** persistence context.
- A **second and third reload** in the same session still work (no stale
  caches, no growing classloader count in Arthas `classloader`).
- No exceptions in the HA log; Arthas `sc -d` shows a single classloader
  per changed class.

The result tells which changes HA handles reliably on this stack and where
own API helpers ([spring-beans.md](spring-beans.md),
[jackson.md](jackson.md), [hibernate.md](hibernate.md)) are worth writing.

## Runtime tests from the dossier

Run by the dossier's author, not on this machine:

| Test | Observed result |
|---|---|
| `jdb redefine` on OpenJDK 17.0.20 without a breakpoint | Same process switched from `old:17` to `new:17`. The changed field initialiser `99` did not run afterwards. |
| Spring 6.2.12 bean destruction and recreation | Registered dependents were destroyed first. Old consumer references stayed old; a new lookup returned the new instance. |
| Stable Spring proxy with a swappable target | New calls reached the new delegate; its existing advice chain stayed effective. |
| Clojure `reify` with var redefinition | Same instance switched from `90.00M` to `80.00M`. |
| Jackson 2.18.2 mapper and type cache | The copied mapper shared the `TypeFactory` at first; the explicit replacement created its own. |
| Jackson module with the same ID after `copy()` | Re-registration with duplicate detection active did not set the module up again. |

These confirm the single mechanisms. The full combination — the real Boot
application, JBR, HotswapAgent, Hibernate and Jackson — remains an
integration test of the concrete project.
