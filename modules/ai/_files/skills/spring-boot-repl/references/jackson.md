Applies to: everywhere (local JVMs on macOS and Linux hosts, containers and
pods alike)

# Reinitialising Jackson

The built-in HotswapAgent 2.0.3 plugin covers Jackson 2
(`com.fasterxml.jackson.*`). Jackson 3 (`tools.jackson.*`, the default in
Spring Boot 4) needs a custom plugin. See
[Jackson 3](#jackson-3-a-custom-hotswapagent-plugin) below. The sections
on `copy()` and on rewiring converters describe Jackson 2 APIs.

## Jackson 3: a custom HotswapAgent plugin

**Symptom:** after a redefine of a DTO (new getter, new `@JsonProperty`),
the HTTP response keeps the old JSON shape. Jackson 3 holds serializers,
deserializers and resolved types in caches. The built-in plugin does not
know the `tools.jackson` classes, so nothing clears these caches.

**Measured fix:** a custom HotswapAgent plugin, written in Java and
compiled into the agent jar. After each redefine, the plugin clears these
caches in **all** `ObjectMapper` instances:

- the serializer and deserializer caches
- `_rootDeserializers`
- `TypeFactory._typeCache`

In jackson-databind 3.1.7 (checked with `javap -p` on 2026-11-15), these
caches sit in the following fields:

| Cache | Field | Owning class |
|---|---|---|
| serializer cache | `_serializationContexts` → `_cache` → `_sharedMap` | `ObjectMapper` → `cfg.SerializationContexts` → `ser.SerializerCache` |
| deserializer cache | `_deserializationContexts` → `_cache` → `_cachedDeserializers` | `ObjectMapper` → `cfg.DeserializationContexts` → `deser.DeserializerCache` |
| root deserializers | `_rootDeserializers` | `ObjectMapper` |
| resolved types | `_typeCache` | `type.TypeFactory` |

All classes are in the package `tools.jackson.databind`.

Measured 2026-10/11 on JetBrains Runtime (JBR, see
[jbr-hotswap-install.md](jbr-hotswap-install.md)) 25.0.4.1, HotswapAgent 2.0.3, Spring Boot 4 and
Jackson 3: the plugin found 16 mappers in one service and 90 in another.
A new getter in a DTO appeared in the HTTP response without a manual
flush. When the change was reverted, the old shape came back.

How to build such a plugin. No reference implementation is available:
the source of the measured plugin is not part of this skill, so the
following list is the full specification.

- Put it in a package below `org.hotswap.agent.plugin.*`. The startup scan
  of the agent finds it there and treats it like a built-in plugin. Do not
  put it on the application class path through `pluginPackages=` (a key in
  [`hotswap-agent.properties`](setup.md#hotswap-agentproperties) that names
  extra packages to scan for plugins), because that
  location is unreliable with Spring Boot fat jars (nested `jar:` URLs).
- Let it depend on the JDK and HotswapAgent only. The plugin runs in the
  class loader of the agent and cannot see application or Jackson classes
  as types. It refers to them by name and patches them with Javassist (a
  library that edits bytecode). HotswapAgent ships its own repackaged copy
  in the package `org.hotswap.agent.javassist`.
- Use this pattern. In the HotswapAgent plugin API, both hooks are
  `@OnClassLoadEvent` methods, with `events = LoadEvent.DEFINE` and
  `events = LoadEvent.REDEFINE`. A hook on the class **define** event patches the
  `ObjectMapper` constructor, so that every new mapper registers itself and
  gets a cache-clearing method. A handler on the **redefine** event of any
  class schedules the clearing a short time later (500 ms in the measured
  setup), so that the redefine finishes first.
- Add it to the jar with `jar uf hotswap-agent.jar -C <compiled-classes> .`.

A Clojure function in the embedded nREPL ([nrepl.md](nrepl.md),
[setup.md](setup.md#embedding-nrepl-in-the-boot-process)) cannot do this job. Clojure has neither
`java.lang.instrument.Instrumentation` nor the `ClassFileTransformer` of
the agent. Only code that holds one of them is called on every redefine,
so Clojure cannot react to a redefine event. The function would run only
when someone calls it, and a redefine from the IDE over JDWP or from
Arthas ([arthas.md](arthas.md)) would have no effect
on the caches. A plugin sees these redefine paths:
[`scripts/Redefine.java`](../scripts/Redefine.java) (the JDI client from
[redefine.md](redefine.md)), `jdb`,
the IDE over JDWP, and Arthas `redefine`. Arthas `retransform` does not
trigger HotswapAgent plugins ([SKILL.md, Rule 1: one path for class changes](../SKILL.md#rule-1-one-path-for-class-changes--redefine-never-retransform),
[arthas.md](arthas.md)).

**Maintenance:** the plugin reads the internal Jackson 3 fields in the
table above. Check the field names with `javap -p`
after every Jackson upgrade, because a renamed field breaks the plugin.

With Jackson 3, Spring Framework 7 uses converter classes other than
`MappingJackson2HttpMessageConverter`: in spring-web 7.0.10 the JSON
converter is
`org.springframework.http.converter.json.JacksonJsonHttpMessageConverter`,
which extends
`org.springframework.http.converter.AbstractJacksonHttpMessageConverter`
([source](https://github.com/spring-projects/spring-framework/blob/main/spring-web/src/main/java/org/springframework/http/converter/json/JacksonJsonHttpMessageConverter.java)).
Check the class names in your
version before you adapt the rewiring below, because the example uses the
Jackson 2 class. That rewiring was not measured with Jackson 3. With the
cache-clearing plugin, DTO changes did not need it.

## What the HotswapAgent Jackson 2 plugin does

Among other things, the plugin clears:

- the root deserializer caches
- the serializer and deserializer caches
- type information and further internal caches

That covers changes to DTOs and their annotations. The plugin does **not**
build a new module configuration and does not replace every JSON consumer.
It finds mappers through constructor instrumentation, so HotswapAgent
must be on the command line from JVM start ([SKILL.md, Rule 2: start the JVM with HotswapAgent from the beginning](../SKILL.md#rule-2-start-the-jvm-with-hotswapagent-from-the-beginning)). A mapper
created before the agent is active is never instrumented.

The same plugin also tries to patch the `ObjectMapper` inside the Arthas
class loader and fails with `no such class:
org.hotswap.agent.config.PluginManager`. To avoid this error, exclude the
Arthas loader with `excludedClassLoaderPatterns`
([setup.md](setup.md#hotswap-agentproperties)).
[JacksonPlugin 2.0.3](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-jackson-plugin/src/main/java/org/hotswap/agent/plugin/jackson/JacksonPlugin.java)

## `ObjectMapper.copy()` is not a full reset

In Jackson 2.18, `copy()` has two effects:

- It keeps the previous `TypeFactory`, and with it the type cache.
- It keeps the registered module IDs. While duplicate detection
  (`MapperFeature.IGNORE_DUPLICATE_MODULE_REGISTRATIONS`, enabled by
  default) is active, Jackson then silently ignores a new module instance with the same ID.

The dossier, the unpublished external research report that this skill
started from and holds no copy of (see **Provenance** in [SKILL.md](../SKILL.md)), measured both
effects on Jackson 2.18.2.
[ObjectMapper source](https://github.com/FasterXML/jackson-databind/blob/2.18/src/main/java/com/fasterxml/jackson/databind/ObjectMapper.java)

A copy with its own type cache:

```java
ObjectMapper fresh = oldMapper.copy();

LookupCache<Object, JavaType> cache =
    new LRUMap<>(16, 2_000);          // the sizes are example values

fresh.setTypeFactory(
    oldMapper.getTypeFactory().withCache(cache));
```

To **replace a module configuration**, build a new mapper from a
reproducible recipe instead of patching a copy. The recipe is the same
`Jackson2ObjectMapperBuilder` customisation that the app uses at start-up,
because a patched copy ignores a new module with an old ID (see above).
Configure the new mapper completely before its first use.
[TypeFactory](https://github.com/FasterXML/jackson-databind/blob/2.18/src/main/java/com/fasterxml/jackson/databind/type/TypeFactory.java)

## Rewire the real consumers

Spring MVC already holds the mapper inside its message converters, so a
replacement of the `ObjectMapper` bean does not reach them. Rewire them
during a coordinated update phase: pause the affected traffic, change,
verify, and resume
([spring-beans.md](spring-beans.md#autowirecapablebeanfactory-and-the-singleton-registry)):

```java
var adapter = context.getBean(RequestMappingHandlerAdapter.class);

for (var converter : adapter.getMessageConverters()) {
    if (converter instanceof MappingJackson2HttpMessageConverter json
            && json.getObjectMapper() == oldMapper) {
        json.setObjectMapper(fresh);
    }
}
```

This code changes the default mapper of those converters only. Handle
these consumers separately:

- type-specific or media-type-specific mappers registered on a converter
- mappers injected directly into application beans
- `ObjectReader` and `ObjectWriter` instances created from the old mapper
- messaging converters (Kafka, AMQP, JMS) and WebFlux codecs
- the `HttpMessageConverters` that `RestTemplate` and `RestClient` use

The setter is not an atomic switch across concurrent requests.
[AbstractJackson2HttpMessageConverter](https://github.com/spring-projects/spring-framework/blob/6.2.x/spring-web/src/main/java/org/springframework/http/converter/json/AbstractJackson2HttpMessageConverter.java)

**Verify with a real HTTP round trip.** A successful
`fresh.writeValueAsString(...)` in the REPL does not prove that the
endpoint uses `fresh`.
