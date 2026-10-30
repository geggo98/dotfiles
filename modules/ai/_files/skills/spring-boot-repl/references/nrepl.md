# Working in the nREPL

Assumes `dev/ctx` holds the live `ApplicationContext` (see
[setup.md](setup.md)).

## Helpers against the context

```clojure
(defn bean [name]
  (.getBean dev/ctx name))

(sort (.getBeanDefinitionNames dev/ctx))

(defn probe [anfrage]
  (.berechne (bean "preisService") anfrage))
```

`probe` looks the bean up **on every call**. After a bean is recreated, a
stored raw reference (`(def svc (bean "preisService"))`) still points to the
old instance. After a pure method redefinition the stored reference is fine:
the same instance runs the new code and keeps its state.

## Implementing a Java interface in Clojure

For calculations, policies and validation logic this is the shortest loop.
Given a stable Java interface:

```java
public interface PreisPolicy {
    BigDecimal rabatt(BigDecimal netto);
}
```

implement it in the REPL:

```clojure
(import '[com.example PreisPolicy])

(defn rabatt [netto]
  (.multiply netto (bigdec "0.90")))

(def neue-policy
  (reify PreisPolicy
    (rabatt [_ netto] (rabatt netto))))
```

Put `neue-policy` behind a stable exchange point (a
`HotSwappableTargetSource`, see [spring-beans.md](spring-beans.md)). Then
redefine only the function:

```clojure
(defn rabatt [netto]
  (.multiply netto (bigdec "0.80")))
```

The existing `reify` instance now uses the new function, because the call
`(rabatt netto)` goes through the var `#'rabatt`. Measured in the dossier:
the same instance returned `90.00M`, then `80.00M`.

Two things break this indirection:

- **Direct linking** (`-Dclojure.compiler.direct-linking=true`) compiles
  calls to static invocations. Keep it off on the dev JVM.
- **Capturing a function value** (`(let [f rabatt] (reify … (f netto)))`)
  freezes the old function. Call the var, or use `#'rabatt` explicitly.

Sources: [Clojure REPL workflow](https://clojure.org/guides/repl/enhancing_your_repl_workflow),
[direct linking](https://clojure.org/reference/compilation#directlinking).

## Context the REPL thread does not have

An nREPL evaluation runs on its own thread. It does not inherit a
transaction, a `SecurityContext`, a request scope, or MDC values from any
other thread. Establish them through the application's own boundaries:

- Transactions: call a `@Transactional` bean method, or use
  `TransactionTemplate` from the context.
- Security: set a `SecurityContext` explicitly around the call and clear it after.
- Request-scoped beans: bind a `RequestAttributes` or go through a real HTTP call.
