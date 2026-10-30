# Hibernate at runtime

## Changes the public APIs allow directly

- enable or reset statistics;
- evict second-level and query caches;
- change session filters, flush mode and read-only settings;
- add or replace named queries with `EntityManagerFactory.addNamedQuery(...)`;
- add named entity graphs.

These are real runtime operations. Two things they do **not** do:

- **Cache eviction does not change entity mappings.**
- Mutating the map from `EntityManagerFactory.getProperties()` does not
  change the active factory configuration.

Sources: [Hibernate Cache](https://docs.jboss.org/hibernate/orm/6.6/javadocs/org/hibernate/Cache.html),
[Hibernate Session](https://docs.jboss.org/hibernate/orm/6.6/javadocs/org/hibernate/Session.html),
[JPA EntityManagerFactory](https://jakarta.ee/specifications/persistence/3.1/apidocs/jakarta.persistence/jakarta/persistence/EntityManagerFactory.html).

## Mapping changes need a new factory

Hibernate fixes a `SessionFactory`'s runtime metamodel when it is built.
HotswapAgent's Hibernate plugin therefore uses one model: **a stable outer
factory reference delegates to a replaceable current factory**, which a
reload rebuilds.
[SessionFactory](https://docs.jboss.org/hibernate/orm/6.6/javadocs/org/hibernate/SessionFactory.html),
[HA EntityManagerFactoryProxy](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-hibernate-jakarta-plugin/src/main/java/org/hotswap/agent/plugin/hibernate_jakarta/proxy/EntityManagerFactoryProxy.java)

New `EntityManager`s then see the new metamodel. Existing `EntityManager`s
and running transactions stay with their old generation.

## Own implementation: a generation in a child context

Keep these together as one replaceable generation:

- the `EntityManagerFactory`;
- the transaction infrastructure;
- repository metadata and repository instances;
- the business services that depend on them.

Rebuild that subgraph in a child context and publish it behind a stable
facade (see [spring-beans.md](spring-beans.md), "generation behind one
facade"). Keep the shared `DataSource` pool **outside** the generation.

Two limits:

- **A child context does not isolate bytecode.** If both generations load
  their classes from the same classloader, a redefinition hits the old
  generation too.
- **Building a child context can already do work.** Initialisers,
  schedulers, message consumers and schema actions (`ddl-auto`, Flyway,
  Liquibase) must not run unchecked before the candidate is published.
  Parent post-processors do not apply automatically to child beans.
  [Spring container extension points](https://docs.spring.io/spring-framework/reference/core/beans/factory-extension.html)

## Experimental: re-run `afterPropertiesSet()`

In Spring 6.2.12, the EMF proxy of `AbstractEntityManagerFactoryBean` asks
for the current native factory on each call. Calling `afterPropertiesSet()`
again on the same factory bean can therefore lead existing proxies to a
newly built target.

This does not solve the lifetime of the old factory, open
`EntityManager`s, repository caches, or coherent publication. Treat it as
an **encapsulated dev helper, checked against the exact Spring version**.
[AbstractEntityManagerFactoryBean 6.2.12](https://github.com/spring-projects/spring-framework/blob/v6.2.12/spring-orm/src/main/java/org/springframework/orm/jpa/AbstractEntityManagerFactoryBean.java)
