Applies to: CRaC checkpoints of Spring, Spring Boot, JPA, logging and connection-pool code on a CRaC JDK; some points also apply to AWS Lambda SnapStart

# CRaC and Frameworks: What to Close, What Breaks, How to Write a Resource

TL;DR: Spring stops and restarts its lifecycle beans around a checkpoint when `org.crac` is on the class
path, but it closes only what it knows. Enable pool suspension in HikariCP before the pool starts,
create Lettuce clients as beans, and keep HTTP and OAuth2 clients idle until after the checkpoint. With
Log4j2, remove the file appender definitions, not only their references. Pools that Spring does not
manage, such as the EclipseLink session, need your own `Resource` with a lock. Deadlines computed once
and fixed-rate schedules misbehave after a restore. An app with about 140 to 200 mixed file descriptors and no
close hooks for them is not a CRaC candidate. The generic list of blockers and the behaviour of the
restored process are in [java-debug crac.md §2 and §3](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint);
this file adds the framework delta.

## Contents

- [1. Reading this file](#1-reading-this-file)
- [2. Spring and Spring Boot](#2-spring-and-spring-boot)
- [3. JPA, Hibernate and HikariCP](#3-jpa-hibernate-and-hikaricp)
- [4. Logging](#4-logging)
- [5. EclipseLink](#5-eclipselink)
- [6. Clocks, deadlines, schedules and random numbers](#6-clocks-deadlines-schedules-and-random-numbers)
- [7. Apps with many file descriptors](#7-apps-with-many-file-descriptors)
- [8. Writing a Resource correctly](#8-writing-a-resource-correctly)
- [9. Other frameworks and platforms](#9-other-frameworks-and-platforms)
- [10. Claims not to believe](#10-claims-not-to-believe)

## 1. Reading this file

Evidence markers: "measured <date>, <JDK>, <setup>" means the skill's author ran it. "reported (<source
type>)" means a public source states it and nobody here repeated it. "reported, team review <date>"
marks a finding from the skill author's unpublished work, not a public source and not re-measured here;
see [measuring.md §10](measuring.md#10-team-measurements-and-third-party-numbers). "not measured" means
nobody checked. Version numbers of frameworks move fast; check the current docs of your version before
you rely on a row.

Find what blocks your checkpoint first: `-Djdk.crac.collect-fd-stacktraces=true` prints where each open
file descriptor came from ([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)).
Then look the opener up in this file.

## 2. Spring and Spring Boot

**Lifecycle around the checkpoint.** When `org.crac` is on the class path, Spring calls `stop()` on its
`Lifecycle` beans before the checkpoint and `start()` after the restore (reported, Spring Framework
docs; behaviour available since Spring Framework 6.1 and Spring Boot 3.2). The embedded web server and
other lifecycle-aware components close their sockets that way. Anything that is not a lifecycle bean
stays open.

**`org.crac` must be declared.** Add `org.crac:crac` (1.4.0 or later per the Spring docs) as a
dependency of the application. Spring Boot treats it as optional, so it is not on the class path by
default (reported, Spring docs). `org.crac` is a small portable wrapper library: on a CRaC JDK it forwards
to the JDK's `jdk.crac` API; on a JDK without CRaC, registered resources are accepted and never called,
and a checkpoint request throws an exception
([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)). The app therefore runs
unchanged on a normal JDK.

**Automatic checkpoint at refresh.** `-Dspring.context.checkpoint=onRefresh` writes the checkpoint after
the singletons exist and before the lifecycle beans start (reported, Spring docs). It suits apps without
a database. With a database, take the checkpoint on demand after a warm-up; the reason is in
[crac-build-and-deploy.md §2](crac-build-and-deploy.md#2-when-to-take-the-checkpoint).
`-Dspring.context.exit=onRefresh` exits at the same point without a checkpoint; it is a cheap test that
the context comes up, and it is also the usual training run for an AOT cache
([leyden-aot.md](leyden-aot.md)).

**Known components** (reported by a team from its own checkpoint work, 2026-08 to 2026-09, Zulu 25,
Spring Boot 3.x and 4.x on Kubernetes or Linux containers, unless the row says otherwise):

| Component | What happens | What to do |
|---|---|---|
| HikariCP | Spring Boot suspends the pool around the checkpoint, but only when pool suspension is enabled | Set `spring.datasource.hikari.allow-pool-suspension=true`. It must be set before the pool starts; HikariCP reads it at pool creation. See §3 |
| Lettuce (Redis) | Spring Boot handles the connection factory only when Boot auto-configured it. A client created with `new` in your code kept Netty epoll and `timerfd` descriptors open and blocked the checkpoint | Create the client as a Spring bean (if it must not replace the auto-configured one, declare it with `@Bean(defaultCandidate = false)`, Spring Framework 6.2 or later; reported, [Spring docs](https://docs.spring.io/spring-framework/reference/core/beans/dependencies/factory-autowire.html)), or close it in your own `Resource` |
| OAuth2 resource server | It fetches the issuer's signing keys (JWK set) eagerly at startup and keeps the HTTP connection alive; the open socket blocks the checkpoint | Use a profile for the checkpoint run that defers the fetch, or close the client before the checkpoint |
| JDK `HttpClient` | Idle keep-alive connections stay open after a call and block the checkpoint | Take the checkpoint before the first outbound call, or close the client and create a new one after the restore |
| Spring Cloud refresh scope | Reported to rebind refresh-scoped beans after a restore (Spring Cloud Commons 4.1 or later; reported, project docs) | Do not count on it for HikariCP: the pool's credentials are not refreshable. Use a credentials provider that HikariCP asks at each new connection (HikariCP's [`HikariCredentialsProvider`](https://github.com/brettwooldridge/HikariCP/blob/a4d93f4f85517f90e632b795486d7102e933d7ff/src/main/java/com/zaxxer/hikari/HikariCredentialsProvider.java) interface; measured 2026-09: 0 errors after rotation) |
| Spring Vault | Reported to contain no CRaC code (reported, team review 2026-09) | A token read at startup is in the checkpoint; see [security.md](security.md) |
| `@Scheduled(fixedRate)` | Missed runs are executed as a burst after a restore (reported, Spring docs) | See §6 |

**Values cached at startup stay old after a restore.** This includes the Spring `Environment`, `@Value`
fields and `@ConfigurationProperties` objects. Spring AOT processing goes further and fixes some
decisions at build time; see [leyden-aot.md](leyden-aot.md) and [security.md](security.md).

## 3. JPA, Hibernate and HikariCP

Little is CRaC-specific here. The evidence is narrow: open pool connections block the checkpoint, and
the JPA layer holds active connections at context refresh (measured 2026-08, Zulu 25, Spring Boot with
Hibernate, Kubernetes on arm64). Two measures solved it:

- Enable HikariCP pool suspension before the pool starts (§2).
- Take the checkpoint on demand after a warm-up, when the connections are idle, so the suspended pool
  can close them ([crac-build-and-deploy.md §2](crac-build-and-deploy.md#2-when-to-take-the-checkpoint)).

JDBC driver behaviour (Oracle, PostgreSQL, MySQL) with CRaC was not found in any primary source and was
not measured separately.

## 4. Logging

A file appender holds a writable file handle, and a writable handle blocks the checkpoint
([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)). The fix is the same for
both libraries: log to the console in the JVM that you checkpoint. The libraries differ in what you must
remove.

- **Logback:** remove the `<appender-ref>` of the file appender. Logback starts only the appenders that a
  logger references (origin unknown beyond team practice 2026-08; reason: an unreferenced appender is
  never started, so it opens no file).
- **Log4j2:** remove the file appender **definitions** (for example every `RollingFile` element), not
  only the references. Origin: in one Spring 5.3 batch app, 17 of 20 open-file blockers (85 %) were
  Log4j2 rolling-file handles, and they stayed after the references were removed (measured 2026-08,
  Zulu 25, Kubernetes on arm64). Reason: Log4j2 starts every configured appender, referenced or not.
- **Trap when you comment out XML:** `--` is not allowed inside an XML comment. A commented-out block
  that contains `--` breaks the configuration file.
- **`-XX:CRaCAllowedOpenFilePrefixes` does not help** for log files: it covers only files that native
  code opened, not writable handles opened by Java code
  ([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)). For a file you must keep,
  use a resource policy (same section).

## 5. EclipseLink

EclipseLink brings its own connection pool. Spring's lifecycle hooks and HikariCP suspension do not reach
it. In the measured app, the pool held a raw socket channel and two epoll descriptors (measured 2026-08,
Zulu 25, Spring 5.3 with EclipseLink 2.7, Kubernetes on arm64).

The working pattern, measured in the same setup:

1. Register an `org.crac.Resource` that logs the EclipseLink server session out in `beforeCheckpoint`
   and logs it in again in `afterRestore`.
2. Take a **write lock** in `beforeCheckpoint` and release it at the end of `afterRestore`. Application
   threads take the read lock at the single point where they acquire a session.
3. Release the lock when `beforeCheckpoint` throws.
4. Hold the resource in a static field.

Why the lock is needed: the hooks run on the thread that requested the checkpoint (for `jcmd`, the
Attach Listener thread), while application threads keep running. Without the lock, a worker thread used
the logged-out session after the restore and failed with `EclipseLink-7001`, and the pod went into a
crash loop. With the lock, the restore was clean.

Cost: the login took about 0.6 s of a 0.8 s restore (cold start 3.4 s). The code shape is in §8.

A Spring 5.3 application with EclipseLink 2.7, packaged as a runnable batch jar, checkpointed and
restored on a JDK 25 CRaC base. The servlet-container (WAR) case was not measured.

## 6. Clocks, deadlines, schedules and random numbers

A restore jumps forward in time: the wall clock shows the restore time, but every value that the app
computed before the checkpoint is from checkpoint time.

- **Deadlines computed once.** A worker that computes "stop after a fixed run duration" once at startup
  finds that deadline in the past after a restore. In the measured case, the worker stopped at once, the
  pod restarted, restored the same image, and stopped again: a restart loop (measured 2026-08, Zulu 25,
  Kubernetes on arm64). Fix: recompute the deadline in `afterRestore`, or compute it lazily at first use.
- **Fixed-rate schedules.** `@Scheduled(fixedRate)`, `scheduleAtFixedRate` and `java.util.Timer` with a
  fixed rate run all missed executions as a burst after the restore (reported, Spring docs). Use a
  fixed delay or a cron expression.
- **Random numbers.** A static `java.util.Random` restarts the same sequence after every restore. A
  DRBG-based (Deterministic Random Bit Generator) `SecureRandom` that was used before the checkpoint
  returned the same bytes after each restore of the same image (measured 2026-09, Zulu 25). Details and the safe variants are in
  [security.md](security.md).

## 7. Apps with many file descriptors

**Rule: an app with about 140 to 200 open file descriptors of mixed kinds and no framework hooks for them
is not a CRaC candidate.** Use an AOT cache ([leyden-aot.md](leyden-aot.md)) instead.

- Origin: two apps that the team tried to prepare (measured 2026-09, Zulu 25, Linux containers):
  - 93 epoll + 83 eventfd + 12 timerfd descriptors (188 in total);
  - 106 sockets + 24 epoll + 12 timerfd descriptors (142 in total).
  The descriptors came from several HTTP client pools, an ORM with its own pool, and Netty or NIO event
  loops.
- Reason: each descriptor needs an owner that closes it before the checkpoint and reopens it after. The
  libraries that opened them had no CRaC hooks, and their internals were not reachable from the app.
  Adding `org.crac` to such code meant changing many modules that only used the library indirectly.
- Libraries reported without CRaC integration at that time (team review 2026-09): Apache HttpClient 4 and
  5, Log4j2, Jedis. Check current releases; this changes.
- Limit: the count alone does not decide. An app with many sockets that all belong to one pool with a
  suspension hook can be fine. Count the **owners** without hooks, not the descriptors.

## 8. Writing a Resource correctly

A `Resource` is the class that the JVM calls before the checkpoint (`beforeCheckpoint`) and after the
restore (`afterRestore`). The basics, the threads-before-callbacks race and resource policies are in
[crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint). These are the rules that
the framework cases of §2 to §7 added:

1. **Keep a strong reference.** The global context (`Core.getGlobalContext()`) holds its resources
   weakly. A resource that only the context references can be garbage-collected, and its callbacks then
   silently never run (reported, team review 2026-09, Zulu 25; also stated for SnapStart in the AWS
   docs). Store it in a static field or in a long-lived bean.
2. **`afterRestore` runs even when `beforeCheckpoint` failed**, and also when the JVM refused the
   checkpoint for another reason (reported, team review 2026-09, Zulu 25). Write `afterRestore` so that
   it works when the resource was never closed.
3. **When the engine itself fails**, the JVM exits without calling `afterRestore` (reported, team
   review 2026-09, Zulu 25).
4. **Application threads resume before `afterRestore`.** Hold a lock from `beforeCheckpoint` until
   `afterRestore` has reopened the resource
   ([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint), warning box).
5. **Read new environment values in `afterRestore`.** With `warp` on Zulu 25.x, variables set at restore
   override; variables absent at restore keep the checkpoint value, so removing a secret variable does
   not remove it. Cached Spring `Environment` values, `@Value` fields and static fields stay old. CRIU was
   not measured, and some public sources report old values after a restore
   ([crac.md §3](../../java-debug/references/crac.md#3-what-the-restored-process-sees)).
6. **Cut and reconnect is a valid shape.** Close the connection in `beforeCheckpoint`, do nothing in
   `afterRestore`, and let the client reconnect on the next use. This needs a client that reconnects by
   itself, and the first call after the restore pays the connection setup.
7. **Resource policies are no replacement for code.** `-Djdk.crac.resource-policies` covers only
   descriptors that the JDK opened. With `close` or `ignore`, the next write throws an `IOException`;
   with `reopen`, the file continues at the old offset, and a write can still hit the race of rule 4
   ([crac.md §2](../../java-debug/references/crac.md#2-what-blocks-a-checkpoint)).
8. **A `WatchService` does not block** a checkpoint (reported, team review 2026-09, Zulu 25).

Code shape for rules 1 to 4 (compiled and run against a stub of the `org.crac` interfaces on Temurin
25.0.5, 2026-11-16; not run under a CRaC engine):

```java
import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.function.Function;
import org.crac.Context;
import org.crac.Core;
import org.crac.Resource;

/** Closes a pool before the checkpoint and reopens it after the restore. */
public final class PoolResource implements Resource {

    /** Rule 1: strong reference. The global context holds resources only weakly. */
    private static PoolResource instance;

    private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();
    private final Pool pool;
    private volatile boolean heldForCheckpoint;

    private PoolResource(Pool pool) {
        this.pool = pool;
    }

    public static synchronized void install(Pool pool) {
        instance = new PoolResource(pool);
        Core.getGlobalContext().register(instance);
    }

    /** The single place where application threads get the pool (rule 4: read lock). */
    public static <T> T withPool(Function<Pool, T> work) {
        PoolResource r = instance;
        r.lock.readLock().lock();
        try {
            return work.apply(r.pool);
        } finally {
            r.lock.readLock().unlock();
        }
    }

    @Override
    public void beforeCheckpoint(Context<? extends Resource> context) throws Exception {
        lock.writeLock().lock();          // waits until running work has left withPool()
        heldForCheckpoint = true;
        try {
            pool.close();
        } catch (Exception e) {
            release();                     // rule 2: do not leave the lock held
            throw e;
        }
    }

    @Override
    public void afterRestore(Context<? extends Resource> context) throws Exception {
        try {
            if (heldForCheckpoint) {       // rule 2: runs also after a failed beforeCheckpoint
                pool.open();
            }
        } finally {
            release();
        }
    }

    private void release() {
        if (heldForCheckpoint && lock.isWriteLockedByCurrentThread()) {
            heldForCheckpoint = false;
            lock.writeLock().unlock();
        }
    }

    /** Stand-in for the real pool or session. */
    public interface Pool {
        void close() throws Exception;
        void open() throws Exception;
    }
}
```

Limit of this shape: a `ReentrantReadWriteLock` belongs to the thread that locked it. The shape assumes
that `beforeCheckpoint` and `afterRestore` run on the same thread. In the measured EclipseLink case, the
callbacks ran on the thread that requested the checkpoint, and the write-lock pattern worked. Which
thread calls `afterRestore` was not checked separately. If it can be another thread, `release()` does
nothing and the lock stays held; use a lock without an owner, such as a `Semaphore`, instead.

## 9. Other frameworks and platforms

- **Quarkus, Micronaut and Helidon** are reported to offer CRaC support (Micronaut through a separate
  module; Helidon from 4.2 with `warp`; reported, vendor docs). Check the current docs of your version;
  none of them was measured here.
- **OpenJ9** has its own checkpoint mechanism (`-XX:+EnableCRIUSupport`) with its own API; this file does
  not cover it.
- **AWS Lambda SnapStart** uses the `org.crac` hook API with a context that Lambda provides;
  `afterRestore` hooks have a 10 s limit (reported, AWS docs). The rules of §8 apply.
- **GraalVM Native Image** cannot be combined with CRaC; see [native-image.md](native-image.md).

## 10. Claims not to believe

The full list is in [struck-claims.md](struck-claims.md). These lines concern frameworks:

| Claim | Verdict |
|---|---|
| Spring 5.3 with EclipseLink (or a WAR) is unsuitable for CRaC | Struck as a general rule. A Spring 5.3 + EclipseLink 2.7 batch jar checkpoints (cold 3.4 s, restore 0.8 s; measured 2026-08, Zulu 25). The WAR case was not measured |
| JFR or the OTel agent hold file descriptors, so tracing and CRaC exclude each other | JFR: struck, a JFR recording did not block (measured 2026-11-15, Zulu 25.0.5 CRaC); older builds were reported to block. OTel agent: nuanced; it blocks the checkpoint once it has exported, and works when nothing was exported before or after 330 s idle (measured 2026-11-16, Linux arm64 (OrbStack VM), n = 1 per variant). See [debug-agents.md §2.4](debug-agents.md#24-opentelemetry-java-agent) |
| `System.getenv()` is frozen after a restore | Contested. Use the wording of §8 rule 5 |
| `-D` properties are ignored on restore | Struck. `System.getProperty` returns the new value; the earlier test that suggested otherwise read a `static final` field cached at checkpoint time (measured 2026-11-15, Zulu 25.0.5 CRaC; see [struck-claims.md](struck-claims.md)) |
