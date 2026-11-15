Applies to: everywhere (local JVMs on macOS and Linux hosts, containers and
pods alike), but only on dev JVMs

# Arthas: inspect a running JVM

**TL;DR:** attach Arthas on demand with `--attach-only`, bound to
`127.0.0.1`, with a random password for this session and
`arthas.localConnectionNonAuth=false`. Use it to read
(`sc`, `sm`, `jad`, `vmtool`, `ognl`). Do not use it to change classes:
that is the job of `scripts/Redefine.java` ([redefine.md](redefine.md)),
because Arthas `retransform` skips the HotswapAgent refresh (see
[below](#commands-that-instrument-or-change-classes)).

Measured 2026-10/11 with Arthas 4.3.4 on JBR 25.0.4.1 with HotswapAgent
2.0.3, Spring Boot 4, in Kubernetes on a Mac. JBR is the JetBrains Runtime,
a JDK build with enhanced class redefinition
([jbr-hotswap-install.md](jbr-hotswap-install.md)). The password, `stop` and
re-attach behaviour was measured 2026-11-15 with Arthas 4.3.4 on Temurin
21.0.13 and 25.0.5, in a container (same result on both); this page calls
it the container measurement. The behaviour through `kubectl port-forward`
was measured 2026-11-15 on OrbStack Kubernetes (Kubernetes 1.36.5, Docker
runtime, Arthas 4.3.4 on Temurin 21.0.13); this page calls it the
port-forward measurement. OrbStack is a container and VM runtime for macOS
with a built-in single-node Kubernetes
([orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md)).

## Get it

Download `arthas-bin.zip` from the Arthas GitHub releases page
(<https://github.com/alibaba/arthas/releases>) and check
the version there. The skill pins no checksum. Take the checksum from the
release page or compute it on the first download (`shasum -a 256` on
macOS, `sha256sum` on Linux), and pin it yourself.

## Attach

```bash
umask 077
openssl rand -hex 16 > ~/.arthas-session-pw        # random, per session, mode 0600

# Guard: never attach with an empty password (openssl missing or failed).
# The attach still succeeds. With --username, no password works (with
# localConnectionNonAuth=false nobody gets in, not even for `stop`).
# Without --username, authentication is off.
[ -s ~/.arthas-session-pw ] &&
env -u JAVA_TOOL_OPTIONS java -jar arthas-boot.jar \
  --attach-only \
  --target-ip 127.0.0.1 --http-port 8563 \
  --username arthas --password "$(cat ~/.arthas-session-pw)" \
  <pid>
```

- **`env -u JAVA_TOOL_OPTIONS`:** this applies when the application JVM
  was started with `-agentlib:jdwp=...` in `JAVA_TOOL_OPTIONS`, as in
  [setup.md](setup.md#launch-command). `arthas-boot` is a JVM too. It
  inherits `JAVA_TOOL_OPTIONS` and with it the JDWP agent. That agent then
  fails on the port that the application already holds
  ([wiring.md](../../jvm-remote-debug/references/wiring.md#java_tool_options-is-inherited)
  describes the inheritance).
- **`--attach-only`:** without it, `arthas-boot` attaches and then starts
  its interactive telnet client, which waits for input. In a non-interactive
  shell the attach then seems to hang at `Try to attach process`.
- **`--target-ip 127.0.0.1`:** the HTTP and telnet listeners bind to
  loopback. For a JVM in a pod, run the command inside the container
  (`kubectl exec <pod> -c <container> -- env -u JAVA_TOOL_OPTIONS java -jar ...`,
  where `<container>` is the name of the application container in the pod)
  and reach it with `kubectl port-forward pod/<pod> 8563:8563`. The
  forwarded connection arrives in the pod as an IPv4 connection from
  `127.0.0.1` to `127.0.0.1:8563`, so the loopback listener is reachable
  (measured 2026-11-15, port-forward measurement).
  The `jvm-remote-debug` skill describes how to put the password into the
  pod as a mounted Secret: rule 4 in
  [its security rules](../../jvm-remote-debug/SKILL.md#security-rules) and
  [wiring.md](../../jvm-remote-debug/references/wiring.md#downward-api-order-of-env-entries).
- **Telnet port:** the command above passes no telnet option, so Arthas
  uses its default telnet port 3658. A second Arthas in the same pod shares
  the pod's network namespace, so it needs a different free telnet port,
  for example `--telnet-port 3659`. Do not pass `--telnet-port -1`. With
  `--attach-only`, `arthas-boot` 4.3.4 then fails before the attach with
  `IllegalArgumentException: port out of range:-1` and exit code 1
  (measured 2026-11-15 with `kubectl exec` in a pod on OrbStack
  Kubernetes).
- Run it as the same OS user as the target JVM.
- **`arthas.localConnectionNonAuth=false`:** set it in
  `<arthas-bin>/arthas.properties` before the attach. `<arthas-bin>` is the
  directory into which you unpacked `arthas-bin.zip`, next to
  `arthas-boot.jar`. For a JVM in a pod, this directory must be inside the
  container (for example copied in with `kubectl cp`), because `arthas-boot`
  runs there. The shipped file sets it to `true`. Then a request from
  `127.0.0.1` without any credentials gets HTTP 200 and runs commands, and
  the password protects only against clients that do not come from
  loopback. A `kubectl port-forward` counts as loopback, so with the
  shipped `true`, anyone who may run a port-forward to the pod gets Arthas
  without a password. Arthas 4.x has a built-in Model Context Protocol
  (MCP) server at the HTTP path `/mcp`, and `initialize` is the first
  request of that protocol. `POST /api` ran `version`, and `/mcp` answered
  `initialize`, both with HTTP 200 and no credentials. With `false`, a
  request without credentials gets 401, also through the port-forward and
  also on `/mcp`. In both modes Arthas checks credentials that a client
  sends: a wrong password gets 401, the right one 200 (measured 2026-11-15,
  port-forward measurement). The measurements passed `--arthas-home` with
  the edited directory to `arthas-boot`. This option tells `arthas-boot`
  which Arthas distribution directory to load the agent from, and with it
  which `arthas.properties`. The attach command above does not pass it, and
  an attach without it was not measured. Add `--arthas-home <arthas-bin>`
  to the command, so that the agent reads the file that you edited.

**Known leak:** `arthas-boot` takes the password as a command-line
argument. The password is therefore visible in the process list of the host
or the pod while `arthas-boot` runs. Whether a configuration file of Arthas
avoids this was not checked. Because of this leak, use Arthas only on
throwaway dev JVMs, create a new random password for each session, and
never use a password that is used anywhere else. Never print the password,
and never write it into a log, a ticket or a command shown to someone.

## Run commands over HTTP

Keep the password out of `argv` on the client side too: put it into a netrc
file with mode 0600 and let `curl` read it.

```bash
umask 077
printf 'machine 127.0.0.1 login arthas password %s\n' "$(cat ~/.arthas-session-pw)" > ~/.arthas-netrc

curl --netrc-file ~/.arthas-netrc -s http://127.0.0.1:8563/api \
  -H 'Content-Type: application/json' \
  -d '{"action":"exec","command":"sc -d com.example.PriceService"}'
```

`printf` is a shell builtin, so the password does not appear in the process
list there. HTTP 401 means one of two things. Either the user name or the
password does not match the running agent, or no credentials arrived (with
`localConnectionNonAuth=false`). The agent keeps the password it was
attached with while its server runs. A new attach after the Arthas `stop`
command takes a new password: the new one gets 200, the old one 401
(measured 2026-11-15, container measurement at the top of this page). A JVM restart also resets the password.

## Read-only commands

In the table, `<fqcn>` is a fully qualified class name. `ognl` evaluates
an expression in OGNL (Object-Graph Navigation Language), the expression
language of Arthas
([Arthas documentation for `ognl`](https://arthas.aliyun.com/en/doc/ognl.html)).

| Command | Use |
|---|---|
| `sc -d <fqcn>` | Which class loaders hold the class (one per class is the goal), code source. |
| `sm <fqcn>` | Methods of the loaded class: did a new method arrive? |
| `jad <fqcn>` | Decompile the loaded version: is the new body active? |
| `vmtool --action getInstances --className <fqcn> --limit 5` | Live instances, for example the bean or the `ObjectMapper`s. |
| `ognl '<expression>'` | Read a static field or call a getter. |
| `classloader` | Loader count; should not grow from reload to reload. |

`ognl` can also call any method, including methods that change state.
Treat an `ognl` call that is not a getter as a change.

## Commands that instrument or change classes

- **`retransform` and `redefine`: do not use them for class changes.**
  HotswapAgent registers its transformer as not retransformation-capable.
  A `ClassFileTransformer` registered with
  `Instrumentation.addTransformer(t, false)` is called when a class loads
  and on `redefineClasses`, but not on `retransformClasses`. As a result,
  `retransform` delivers a new body, but HotswapAgent's follow-up work (the Spring, Hibernate and Jackson refresh) does not
  happen ([SKILL.md, Rule 1](../SKILL.md#rule-1-one-path-for-class-changes--redefine-never-retransform)).
  Arthas `redefine` would add a second change path, and the
  [Arthas documentation for `redefine`](https://arthas.aliyun.com/en/doc/redefine.html)
  warns that it conflicts with other Arthas instrumentation. Use only
  `scripts/Redefine.java` (or `jdb redefine`) for class changes.
- **`watch`, `trace`, `tt`, `monitor`, `stack`** instrument classes
  themselves. `tt` is the Arthas "time tunnel": it records method
  invocations so that you can inspect them later. Use these commands
  deliberately and for a short time, and run `reset` afterwards to remove
  the "enhancement", the Arthas name for the bytecode that these commands
  weave into the classes.

The Arthas server runs until you send the `stop` command or the JVM
restarts. `stop` shuts the server down and disconnects all clients
([Arthas documentation for `stop`](https://arthas.aliyun.com/en/doc/stop.html)). `quit` closes only your own client. `stop` does
not reset classes that `redefine` or `retransform` changed. A `stop` sent
through `/api` gets no HTTP response, because the server closes the
connection. After that, the HTTP and telnet ports are closed, and the
Arthas threads end within about 2 s. The loaded agent classes stay in the
JVM: after `stop` and `jcmd <pid> GC.run`, the Arthas class loader still
held about 2600 to 2700 classes (measured 2026-11-15, container
measurement at the top of this page). If you need a JVM
without any trace of Arthas, plan a restart.

## Exclude the Arthas loader from HotswapAgent

Without `com[.]taobao[.]arthas[.].*` in `excludedClassLoaderPatterns`,
HotswapAgent's Jackson 2 plugin tries to patch the `ObjectMapper` inside
the Arthas loader. On attach it then logs `no such class:
org.hotswap.agent.config.PluginManager` with a stack trace.
Template: [setup.md](setup.md#hotswap-agentproperties).
