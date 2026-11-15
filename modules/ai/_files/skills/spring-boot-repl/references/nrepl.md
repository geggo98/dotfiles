# Working in the nREPL

This file assumes that `dev/ctx` holds the live `ApplicationContext` (see
[setup.md](setup.md)).

## Helpers against the context

```clojure
(defn bean [name]
  (.getBean dev/ctx name))

(sort (.getBeanDefinitionNames dev/ctx))

(defn probe [anfrage]
  (.berechne (bean "preisService") anfrage))
```

The examples in this file use German placeholder names. Substitute your
own bean, class, method and argument names. Here, `preisService` ("price
service") is the bean name, `berechne` ("calculate") is its method, and
`anfrage` ("request") is the argument.

`probe` looks the bean up **on every call**. The reason: after Spring
recreates a bean, a stored raw reference (`(def svc (bean "preisService"))`)
still points to the old instance. After a redefinition that changes only
method bodies (`jdb redefine` or HotswapAgent, see
[redefine.md](redefine.md)), the stored reference is fine,
because the same instance runs the new code and keeps its state.

## Implementing a Java interface in Clojure

For calculations, policies and validation logic, this is the fastest edit-and-test
cycle: faster than redefining a Java class with `jdb redefine` or HotswapAgent. Start from a stable Java interface:

```java
public interface PreisPolicy {
    BigDecimal rabatt(BigDecimal netto);
}
```

`PreisPolicy` ("price policy") is a placeholder interface, `rabatt`
("discount") its method, and `netto` ("net amount") the argument.

Implement the interface in the REPL:

```clojure
(import '[com.example PreisPolicy])

(defn rabatt [netto]
  (.multiply netto (bigdec "0.90")))

(def neue-policy
  (reify PreisPolicy
    (rabatt [_ netto] (rabatt netto))))
```

`reify` creates an anonymous object that implements the named Java
interface. `neue-policy` ("new policy") holds that object.

Put `neue-policy` behind a stable exchange point (a
`HotSwappableTargetSource`, see [spring-beans.md](spring-beans.md)). Then
redefine only the function:

```clojure
(defn rabatt [netto]
  (.multiply netto (bigdec "0.80")))
```

The existing `reify` instance now uses the new function, because the call
`(rabatt netto)` goes through the var `#'rabatt`. A Clojure var is the
named, mutable reference that `defn` creates and a second `defn` rebinds.
Each call through the var reads its current value. `#'rabatt` is the reader
syntax for the var itself, as opposed to the function it currently holds.

Measured in the dossier, the external research report that this skill
started from: the same instance returned `90.00M`, then `80.00M`. The `M`
suffix is Clojure's literal syntax for a `BigDecimal`, not a unit. The
dossier's small runtime tests are not the skill's own measurements; see
"Provenance" in [../SKILL.md](../SKILL.md).

Two things break this indirection:

- **Direct linking** (`-Dclojure.compiler.direct-linking=true`) compiles
  calls to static invocations, so the call no longer goes through the var
  and a redefined function is not called. Keep direct linking off on the
  JVM that runs the embedded nREPL: leave `clojure.compiler.direct-linking`
  unset or `false`, its default.
- **Capturing a function value** (`(let [f rabatt] (reify … (f netto)))`)
  freezes the old function. Call the var, or use `#'rabatt` explicitly, so
  that each call looks up the current function.

Sources: [Clojure REPL workflow](https://clojure.org/guides/repl/enhancing_your_repl_workflow),
[direct linking](https://clojure.org/reference/compilation#directlinking).

## Context the REPL thread does not have

An nREPL evaluation runs on its own thread. It does not inherit a
transaction, a `SecurityContext`, a request scope, or MDC values from any
other thread (MDC is the per-thread key-value map that SLF4J and Logback
add to each log line). Establish them through the boundaries of the
application:

- Transactions: call a `@Transactional` bean method, or use the
  `TransactionTemplate` from the context.
- Security: set a `SecurityContext` explicitly around the call, and clear
  it after the call.
- Request-scoped beans: bind a `RequestAttributes`, or go through a real
  HTTP call. Spring resolves a request-scoped bean from the
  `RequestAttributes` that `RequestContextHolder` holds for the current
  thread. To bind one, call
  `RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(req))`
  before the call, where `req` is an `HttpServletRequest`, for example a
  `MockHttpServletRequest` if `spring-test` is on the classpath. Call
  `RequestContextHolder.resetRequestAttributes()` after the call, so that
  the next evaluation on the same thread does not see a stale request.

