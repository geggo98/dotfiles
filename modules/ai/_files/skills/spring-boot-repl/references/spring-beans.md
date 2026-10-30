# Changing Spring beans at runtime

The public Spring APIs support real runtime changes. Each operation has a
narrow scope; know it before you use it.

## `AutowireCapableBeanFactory` and the singleton registry

| Operation | Effect |
|---|---|
| `registerSingleton(name, obj)` | Registers an already initialised object. No full automatic bean lifecycle. |
| `createBean(Class)` | Creates an instance with injection, initialisation and post-processors. Not automatically a named, managed singleton. |
| `autowireBean(obj)` | Injects fields and methods into an existing object. |
| `initializeBean(obj, name)` | Runs initialisation and post-processors. **Use the returned object** — it may be a proxy. |
| `configureBean(obj, name)` | Applies an existing bean definition, including property values and initialisation. |
| `destroySingleton(name)` | Destroys the bean and, where registered, its dependent beans (dependents first). |

Get the factory with
`(.getAutowireCapableBeanFactory dev/ctx)` in Clojure, or
`ctx.getAutowireCapableBeanFactory()`; `registerSingleton` and
`destroySingleton` need the `DefaultListableBeanFactory`
(`((ConfigurableApplicationContext) ctx).getBeanFactory()`).

Sources: [AutowireCapableBeanFactory](https://docs.spring.io/spring-framework/docs/6.2.x/javadoc-api/org/springframework/beans/factory/config/AutowireCapableBeanFactory.html),
[DefaultSingletonBeanRegistry](https://github.com/spring-projects/spring-framework/blob/6.2.x/spring-beans/src/main/java/org/springframework/beans/factory/support/DefaultSingletonBeanRegistry.java).

**Changing the registry does not redirect existing Java references.** A
consumer keeps its old dependency, even after that dependency's destroy
callback ran. Measured in the dossier on Spring 6.2.12: dependents were
destroyed first, old consumer references stayed old, a new lookup returned
the new instance.

Spring also restricts general bean registration while the factory is
accessed concurrently. For larger changes, plan a **coordinated update
phase**: pause the affected traffic, change, verify, resume.
[Spring bean definitions](https://docs.spring.io/spring-framework/reference/core/beans/definition.html)

## Stable exchange points: `HotSwappableTargetSource`

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

Consumers keep the same outer reference; later calls reach the new target.
Measured in the dossier: new calls reached the new delegate, and the
delegate's existing advice chain stayed effective.
[HotSwappableTargetSource](https://docs.spring.io/spring-framework/docs/6.2.x/javadoc-api/org/springframework/aop/target/HotSwappableTargetSource.html)

Three conditions:

- The new delegate must already be initialised and, where needed, advised.
  `swap` creates **no** transaction advisors — run it through
  `initializeBean` first, or swap a delegate that is itself a Spring bean.
- Consumers must have received the stable proxy **from the start**. Define
  it as the bean they inject.
- Close the old target only after calls in flight on it have finished.

For several tightly coupled services, swap a **whole generation behind one
stable facade**. Each operation reads its generation once and stays with it
until it ends, so no call ever mixes service A of generation 2 with service
B of generation 1.

## What HotswapAgent's Spring plugin already does

On a class change, the plugin clears caches, processes changed
definitions, destroys affected beans, reruns selected post-processors,
recreates beans and refreshes, among others, the MVC mappings. It can
also re-run injection on surviving singletons and treat certain proxies so
that they fetch their target through `getBean` again after a reload.

So "old references always stay old under HA" is too broad. Arbitrary
external raw references and closures — including REPL vars — are still not
replaced universally.

Sources: [SpringBeanReload](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-spring-plugin/src/main/java/org/hotswap/agent/plugin/spring/reload/SpringBeanReload.java),
[ProxyReplacer](https://github.com/HotswapProjects/HotswapAgent/blob/RELEASE-2.0.3/plugin/hotswap-agent-spring-plugin/src/main/java/org/hotswap/agent/plugin/spring/getbean/ProxyReplacer.java).
