Applies to: everywhere (local JVMs on macOS and Linux hosts, containers and
Kubernetes pods alike)

# Hibernate at runtime

## Measured: entity redefines with Hibernate 7 and EclipseLink

Measured 2026-11 on JBR 25.0.4.1, HotswapAgent 2.0.3 and Spring Boot 4, in
Kubernetes on a Mac. This file does not record which local Kubernetes
runtime ran the cluster. For OrbStack (a local Docker and Kubernetes runtime
for macOS), see
[orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md)
of the `jvm-remote-debug` skill. JBR is the JetBrains Runtime, a JDK build with enhanced
class redefinition; [jbr-hotswap-install.md](jbr-hotswap-install.md) says how
to get it. The tests ran against local throwaway databases (MySQL and
Oracle), were mostly read-only, and were reverted afterwards.

### Hibernate 7 with the `HibernateJakarta` plugin

The built-in `HibernateJakarta` plugin of HotswapAgent 2.0.3 works with
Hibernate 7, although the `testedVersions` list in its `@Plugin` annotation
names older versions (source:
[`hotswap-agent-hibernate-jakarta-plugin`](https://github.com/HotswapProjects/HotswapAgent/tree/RELEASE-2.0.3/plugin/hotswap-agent-hibernate-jakarta-plugin),
tag `RELEASE-2.0.3`). On each
redefine of an `@Entity`, the plugin rebuilds the `EntityManagerFactory`
(EMF). This is the model that "Mapping changes need a new factory" below
describes.

| Change | Result |
|---|---|
| New method on an entity | Arrives. |
| New field mapped to an **existing** column | Arrives. JPQL finds the new attribute, and the value matched the column. |
| New field mapped to a column that does **not exist yet** | The redefine works before the DDL. The JPQL query fails with `Unknown column` only when it runs. After `ALTER TABLE ... ADD COLUMN`, the query works without further action. |
| 10 EMF rebuilds in a row | About 30 more small class loaders. Metaspace stayed unchanged. |

Every entity redefine costs a full EMF rebuild. After that
rebuild, Spring Data keeps a copy of the entity in a throwaway loader. See
[redefine.md](redefine.md), Pitfall (c).

If you add a test column on MySQL/InnoDB and drop it later, the
`AUTO_INCREMENT` counter does not roll back. The counter values that the
test inserts used stay used.

### EclipseLink

Three EclipseLink terms appear below:

- A **descriptor** (`ClassDescriptor`) is EclipseLink's mapping metadata for
  one entity class.
- The **project** (`org.eclipse.persistence.sessions.Project`) is the object
  that holds all descriptors. In the Spring Boot 4 service measured here,
  the project class came precompiled from a library jar.
- **Login** is the moment the EclipseLink session connects to the database.
  This usually happens when the `EntityManagerFactory` is created.

The **shared cache** is EclipseLink's shared (second-level) object cache.
EclipseLink calls its per-class store the **identity map**, so the code below
that clears the identity map clears this cache.

| Change | Result |
|---|---|
| New method or new field on an entity | Works without a dedicated plugin. The descriptor stays, and reflection access keeps working. |
| Instances in the shared cache | Run the new code at once. Constructors and field initialisers do not run for them. |
| Newly read instances | Get the new field. |
| Change of a **mapping** | Not possible by redefine. EclipseLink builds its descriptors from the project class at login and does not rebuild them. |

To get fresh instances, clear the identity map of the entity. You need
fresh instances, for example, when a new field initialiser must run:

```java
em.unwrap(org.eclipse.persistence.jpa.JpaEntityManager.class)
  .getServerSession()
  .getIdentityMapAccessor()
  .initializeIdentityMap(com.example.Customer.class);
```

`com.example.Customer` is a placeholder. Run this call only against a dev
database, because other sessions lose their cached state too.

## Changes the public APIs allow directly

- Enable or reset statistics.
- Evict the second-level cache and the query caches.
- Change session filters, the flush mode and read-only settings.
- Add or replace named queries with `EntityManagerFactory.addNamedQuery(...)`.
- Add named entity graphs.

These are real runtime operations. Two things they do **not** do:

- **Cache eviction does not change entity mappings.**
- A change to the map from `EntityManagerFactory.getProperties()` does not
  change the active factory configuration.

Sources: [Hibernate Cache](https://docs.jboss.org/hibernate/orm/6.6/javadocs/org/hibernate/Cache.html),
[Hibernate Session](https://docs.jboss.org/hibernate/orm/6.6/javadocs/org/hibernate/Session.html),
[JPA EntityManagerFactory](https://jakarta.ee/specifications/persistence/3.1/apidocs/jakarta.persistence/jakarta/persistence/EntityManagerFactory.html).

## Mapping changes need a new factory

Hibernate fixes the runtime metamodel of a `SessionFactory` when it builds
the factory. HotswapAgent's Hibernate plugin therefore uses one model: **a
stable outer factory reference delegates to a replaceable current
factory**, and a reload rebuilds the current factory.
[SessionFactory](https://docs.jboss.org/hibernate/orm/6.6/javadocs/org/hibernate/SessionFactory.html),
[HotswapAgent EntityManagerFactoryProxy](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-hibernate-jakarta-plugin/src/main/java/org/hotswap/agent/plugin/hibernate_jakarta/proxy/EntityManagerFactoryProxy.java)

New `EntityManager`s then see the new metamodel. Existing `EntityManager`s
and running transactions stay with their old generation. A generation is one
built instance of the factory together with everything that depends on it;
the next section describes it.

## Own implementation: a generation in a child context

Keep these parts together as one replaceable generation:

- the `EntityManagerFactory`
- the transaction infrastructure
- the repository metadata and the repository instances
- the business services that depend on them

Rebuild that subgraph in a child context and publish it behind a stable
facade (see [spring-beans.md](spring-beans.md), "generation behind one
facade"). Keep the shared `DataSource` pool **outside** the generation.

Three limits apply:

- **A child context does not isolate bytecode.** If both generations load
  their classes from the same classloader, a redefinition changes the old
  generation too.
- **Building a child context can already do work.** Initialisers,
  schedulers, message consumers and schema actions run while the child
  context is built, so they must not run unchecked before you switch the
  facade to the new generation. Schema actions are
  `spring.jpa.hibernate.ddl-auto` (`hibernate.hbm2ddl.auto`), Flyway
  migrations and Liquibase changesets.
- **Post-processors do not carry over.** The parent context's
  `BeanPostProcessor` and `BeanFactoryPostProcessor` beans do not apply to
  beans in the child context, because each context runs only its own
  post-processors. Register the post-processors that the child beans need in
  the child context again.
  [Spring container extension points](https://docs.spring.io/spring-framework/reference/core/beans/factory-extension.html)

## Experimental: re-run `afterPropertiesSet()`

This section comes from reading the Spring Framework 6.2.12 source, not
from a measurement. The measurements at the top of this file used Spring
Boot 4, which is built on Spring Framework 7; this section was not checked
on Spring Framework 7.

In Spring 6.2.12, the EMF proxy of `AbstractEntityManagerFactoryBean` asks
for the current native factory on each call. A second call to
`afterPropertiesSet()` on the same factory bean can therefore lead existing
proxies to a newly built target.

This call does not handle the lifetime of the old factory, open
`EntityManager`s, or repository caches. It also does not switch all
dependent beans (repositories, services) to the new factory at the same
moment, as the facade above does. Treat it as an **encapsulated dev helper,
checked against the exact Spring version**: wrap the call in one
project-specific method that checks the Spring version before it runs. This
belongs to the "Own dev helpers" layer in [SKILL.md](../SKILL.md), section
"The stack".
[AbstractEntityManagerFactoryBean 6.2.12](https://github.com/spring-projects/spring-framework/blob/v6.2.12/spring-orm/src/main/java/org/springframework/orm/jpa/AbstractEntityManagerFactoryBean.java)
