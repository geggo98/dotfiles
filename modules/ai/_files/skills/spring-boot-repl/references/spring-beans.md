# Changing Spring beans at runtime

The public Spring APIs support real runtime changes. Each operation has a
narrow scope. Know that scope before you use the operation.

## `AutowireCapableBeanFactory` and the singleton registry

| Operation | Effect |
|---|---|
| `registerSingleton(name, obj)` | Registers an already initialised object. The object does not get the full bean lifecycle automatically. |
| `createBean(Class)` | Creates an instance with injection, initialisation and post-processors. The instance is not automatically a named, managed singleton. |
| `autowireBean(obj)` | Injects fields and methods into an existing object. |
| `initializeBean(obj, name)` | Runs initialisation and post-processors. **Use the returned object**, because it can be a proxy. |
| `configureBean(obj, name)` | Applies an existing bean definition, including property values and initialisation. |
| `destroySingleton(name)` | Destroys the bean and, where registered, its dependent beans (dependents first). |

Get the factory with `(.getAutowireCapableBeanFactory dev/ctx)` in
Clojure. `dev/ctx` is a Clojure var that holds the live
`ApplicationContext`; [setup.md](setup.md) ("Embedding nREPL in the Boot
process") shows where it is defined. In Java, get the factory with `ctx.getAutowireCapableBeanFactory()`.
`registerSingleton` is on the `ConfigurableListableBeanFactory` from
`((ConfigurableApplicationContext) ctx).getBeanFactory()`.
`destroySingleton(name)` is not on that interface, so cast the result to
`DefaultListableBeanFactory`.

Sources: [AutowireCapableBeanFactory](https://docs.spring.io/spring-framework/docs/6.2.x/javadoc-api/org/springframework/beans/factory/config/AutowireCapableBeanFactory.html),
[DefaultSingletonBeanRegistry](https://github.com/spring-projects/spring-framework/blob/6.2.x/spring-beans/src/main/java/org/springframework/beans/factory/support/DefaultSingletonBeanRegistry.java).

**A change to the registry does not redirect existing Java references.** A
consumer keeps its old dependency, even after the destroy callback of that
dependency ran. Measured in the dossier (the unpublished external research
report that this skill started from; see "Provenance" in
[../SKILL.md](../SKILL.md)) on Spring 6.2.12: the dependents were destroyed
first, old consumer references stayed old, and a new lookup returned the
new instance.

The measurements made for this skill in October and November 2026, on the
stack named under "Provenance", did not repeat this test or the proxy test
below. Treat both results as dossier claims; see also the table "Runtime
tests from the dossier" in [verification.md](verification.md).

Spring also restricts general bean registration while code accesses the
factory concurrently. For larger changes, plan a **coordinated update
phase**: pause the affected traffic, change, verify, and resume.
[Spring bean definitions](https://docs.spring.io/spring-framework/reference/core/beans/definition.html)

## Stable exchange points: `HotSwappableTargetSource`

In this example, `PreisPolicy` (German for "price policy") is a placeholder
for any interface of the application. `initialDelegate` and `nextDelegate`
are two implementations of that interface.

```java
var targets = new HotSwappableTargetSource(initialDelegate);

var factory = new ProxyFactory();
factory.setInterfaces(PreisPolicy.class);
factory.setTargetSource(targets);

PreisPolicy stable = (PreisPolicy) factory.getProxy(
    PreisPolicy.class.getClassLoader());

// Consumers get `stable` from the start.
Object previous = targets.swap(nextDelegate);
```

Consumers keep the same outer reference, and later calls reach the new
target. Measured in the dossier: new calls reached the new delegate, and
the existing advice chain of the delegate (the interceptors of its own
Spring AOP proxy, for example the transaction handling of
`@Transactional`) stayed effective. No Spring version is recorded for this
test, and this skill did not measure it.
[HotSwappableTargetSource](https://docs.spring.io/spring-framework/docs/6.2.x/javadoc-api/org/springframework/aop/target/HotSwappableTargetSource.html)

Three conditions apply:

- The new delegate must already be initialised and, where needed,
  wrapped in its AOP proxy, because `swap` creates **no** transaction
  advisors. Run the delegate through `initializeBean` first, or swap a
  delegate that is itself a Spring bean.
- Consumers must receive the stable proxy **from the start**. A consumer
  that holds the raw delegate keeps it, because a registry change does not
  redirect existing references. Define the proxy as the bean that the
  consumers inject.
- Close the old target only after the calls in flight on it have finished.

For several tightly coupled services, swap a **whole generation behind one
stable facade**. A *generation* is one object that holds a delegate for
each of the coupled services; all of them are created and initialised
together, and a swap replaces the whole object at once. The facade keeps
the current generation in one field, for example an `AtomicReference`.
Each operation reads that field once at the start of the call and stays
with that generation until the operation ends. As a result, no call ever mixes service A
of generation 2 with service B of generation 1.

## What HotswapAgent's Spring plugin already does

On a class change, the plugin clears caches, processes changed
definitions, destroys affected beans, re-runs selected post-processors,
recreates beans, and refreshes, among other things, the MVC mappings. It
can also re-run injection on surviving singletons. It can treat certain
proxies so that they fetch their target through `getBean` again after a
reload.

So do not assume that old references always stay old under HotswapAgent.
The plugin still does not replace arbitrary external raw
references and closures, including REPL vars, in every case.

Sources: [SpringBeanReload](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-spring-plugin/src/main/java/org/hotswap/agent/plugin/spring/reload/SpringBeanReload.java),
[ProxyReplacer](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-spring-plugin/src/main/java/org/hotswap/agent/plugin/spring/getbean/ProxyReplacer.java).
