# Reinitialising Jackson

Applies to Jackson 2 (`com.fasterxml.jackson.*`). Jackson 3
(`tools.jackson.*`) is not covered by the HotswapAgent 2.0.3 plugin.

## What the HotswapAgent Jackson plugin does

It clears, among others:

- root deserializer caches;
- serializer and deserializer caches;
- type information and further internal caches.

That covers changes to DTOs and their annotations. It does **not** build a
new module configuration and does not replace every JSON consumer. The
plugin finds mappers through constructor instrumentation, so HA must be on
the command line from JVM start (SKILL.md, Rule 2).
[JacksonPlugin 2.0.3](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-jackson-plugin/src/main/java/org/hotswap/agent/plugin/jackson/JacksonPlugin.java)

## `ObjectMapper.copy()` is not a full reset

In Jackson 2.18, `copy()`:

- keeps the previous `TypeFactory` (and with it the type cache);
- keeps the registered module IDs. Registering a new module instance with
  the same ID is then silently ignored while duplicate detection is active.

Both were measured in the dossier on Jackson 2.18.2.
[ObjectMapper source](https://github.com/FasterXML/jackson-databind/blob/2.18/src/main/java/com/fasterxml/jackson/databind/ObjectMapper.java)

A copy with its own type cache:

```java
ObjectMapper fresh = oldMapper.copy();

LookupCache<Object, JavaType> cache =
    new LRUMap<>(16, 2_000);          // sizes are example values

fresh.setTypeFactory(
    oldMapper.getTypeFactory().withCache(cache));
```

To **replace a module configuration**, build a new mapper from a
reproducible recipe (the same `Jackson2ObjectMapperBuilder` customisation
the app uses at start-up) instead of patching a copy. Configure it
completely before its first use.
[TypeFactory](https://github.com/FasterXML/jackson-databind/blob/2.18/src/main/java/com/fasterxml/jackson/databind/type/TypeFactory.java)

## Rewire the real consumers

Spring MVC already holds the mapper inside its message converters.
Replacing the `ObjectMapper` bean does not reach them. During a coordinated
update phase:

```java
var adapter = context.getBean(RequestMappingHandlerAdapter.class);

for (var converter : adapter.getMessageConverters()) {
    if (converter instanceof MappingJackson2HttpMessageConverter json
            && json.getObjectMapper() == oldMapper) {
        json.setObjectMapper(fresh);
    }
}
```

This changes the default mapper of those converters only. Handle these
separately:

- type- or media-type-specific mappers registered on a converter;
- mappers injected directly into application beans;
- `ObjectReader` / `ObjectWriter` instances created from the old mapper;
- messaging converters (Kafka, AMQP, JMS) and WebFlux codecs;
- the `HttpMessageConverters` used by `RestTemplate`/`RestClient`.

The setter is not an atomic switch across concurrent requests.
[AbstractJackson2HttpMessageConverter](https://github.com/spring-projects/spring-framework/blob/6.2.x/spring-web/src/main/java/org/springframework/http/converter/json/AbstractJackson2HttpMessageConverter.java)

**Verify with a real HTTP round trip.** `fresh.writeValueAsString(...)`
working in the REPL does not prove that the endpoint uses `fresh`.
