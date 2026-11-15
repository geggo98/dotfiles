Applies to: everywhere (local JVMs on macOS and Linux hosts, containers and
pods alike)

# Symptom index

Find the symptom or the error text, then read the linked section. The
explanations are in the topic files. This table only points to them.

Paths such as `scripts/Redefine.java` are relative to the skill directory
(`${CLAUDE_SKILL_DIR}/scripts/Redefine.java`, that is `spring-boot-repl/scripts/`),
not to this file in `references/`. Claude Code sets `CLAUDE_SKILL_DIR` to the
directory of this skill. Other readers replace `${CLAUDE_SKILL_DIR}` with the
path of that directory.

Most rows concern HotswapAgent and its configuration file
`hotswap-agent.properties`, which [setup.md](setup.md#hotswap-agentproperties)
describes. `jdb redefine` and `scripts/Redefine.java` connect to the JDWP
port of the target JVM.

| Symptom or error text | Cause, in short | Where |
|---|---|---|
| `UnsupportedOperationException: add method not implemented` on a new method or field | A JFR recording runs and turned enhanced redefinition off | [redefine.md](redefine.md#a-jfr-turns-off-enhanced-redefinition-on-jbr) |
| `add method not implemented` on a class with a static initialiser (Lombok `@Slf4j`), even for a body change | HotswapAgent's `ClassInitPlugin` adds the synthetic method `$$ha$clinit` to every class with a static initialiser, which turns the redefine into a structural change. `disabledPlugins=ClassInitPlugin` in `hotswap-agent.properties` turns the plugin off. | [redefine.md](redefine.md#b-classinitplugin-and-static-initialisers) |
| `jcmd <pid> VM.flags` shows `-XX:-AllowEnhancedClassRedefinition` | JFR running, or not a JetBrains Runtime (JBR) | [redefine.md](redefine.md#a-jfr-turns-off-enhanced-redefinition-on-jbr), [jbr-hotswap-install.md](jbr-hotswap-install.md#check) |
| "2 class loaders load the class" on the second redefine of an entity | Spring Data loads the entity again in its short-lived `InspectionClassLoader` and keeps that copy | [redefine.md](redefine.md#c-throwaway-class-loaders-2-class-loaders-load-the-class) |
| `scripts/Redefine.java` exits with 4 | None of the classes is loaded, a class file is missing, or several real class loaders (not short-lived inspection loaders, see the row above) hold the class | [redefine.md](redefine.md#procedure-with-scriptsredefinejava) |
| A class "does not change" although redefined, or is reported as not loaded (also `scripts/Redefine.java --apply` with exit 5 and the class under `notLoaded`) | Not loaded yet: its first load takes the version on the JVM's class path (in an image or jar: the old one) | [redefine.md](redefine.md#new-classes-and-new-component), [redefine.md](redefine.md#procedure-with-scriptsredefinejava) |
| New `@Component` or `@RestController` does not appear | Not in `extraClasspath`, or base-package directory created too late. `extraClasspath` is the HotswapAgent directory for new classes, set in `hotswap-agent.properties`. The base-package directory is the package path of the application below that directory (for `com.example`: `com/example`); it must exist before HotswapAgent starts its watcher. | [redefine.md](redefine.md#new-classes-and-new-component) |
| `CrashLoopBackOff` after placing a class in `extraClasspath` | Broken class survives container restarts: the `extraClasspath` directory lies on an `emptyDir` volume, which survives a container restart but not a pod restart | [redefine.md](redefine.md#new-classes-and-new-component) |
| `NoClassDefFoundError: org/slf4j/LoggerFactory` at startup with `extraClasspath` | `extraClasspath` set as `-D` property instead of in `hotswap-agent.properties` | [setup.md](setup.md#hotswap-agentproperties) |
| `chmod` on the extra-classes directory fails with `EPERM` | Mount root of an `emptyDir` | [redefine.md](redefine.md#new-classes-and-new-component) |
| OOMKilled or metaspace growing fast with nREPL / Clojure | Missing `excludedClassLoaderPatterns` entry that keeps HotswapAgent out of Clojure's `DynamicClassLoader`s | [setup.md](setup.md#hotswap-agentproperties) |
| OOMKilled during startup at a 2 GiB limit | JBR + HotswapAgent + JFR + an OpenTelemetry Java agent need more memory | [setup.md](setup.md#memory) |
| `InaccessibleObjectException` on every class-loader initialisation | Missing `--add-opens` | [setup.md](setup.md#launch-command) |
| `no such class: org.hotswap.agent.config.PluginManager` with a stack trace | The Arthas class loader (`com.taobao.arthas.*`) is missing from `excludedClassLoaderPatterns` | [setup.md](setup.md#hotswap-agentproperties), [arthas.md](arthas.md#exclude-the-arthas-loader-from-hotswapagent) |
| Tens of thousands of `ProxyReplacer` INFO lines per start | HotswapAgent's Spring `ProxyReplacer` logs one INFO line per bean outside the base package; set `LOGGER.org.hotswap.agent.plugin.spring.getbean.ProxyReplacer=warning` | [setup.md](setup.md#hotswap-agentproperties) |
| JSON shape stays old after a DTO redefine (Jackson 3) | HotswapAgent's built-in Jackson plugin supports only Jackson 2 | [jackson.md](jackson.md#jackson-3-a-custom-hotswapagent-plugin) |
| `Unknown column` after an entity redefine | Column not created yet; works after `ALTER TABLE` | [hibernate.md](hibernate.md#hibernate-7-with-the-hibernatejakarta-plugin) |
| EclipseLink ignores a changed mapping | EclipseLink builds its descriptors (mapping metadata) at login, when its session connects to the database, normally once at application start, not on redefine. | [hibernate.md](hibernate.md#eclipselink) |
| Arthas attach "hangs" at `Try to attach process` | Missing `--attach-only` | [arthas.md](arthas.md#attach) |
| Arthas HTTP 401 | User name or password does not match the running agent (after `stop` and a new attach, only the new password works) | [arthas.md](arthas.md#run-commands-over-http) |
| Arthas HTTP API (also `/mcp`, the built-in Model Context Protocol endpoint of Arthas 4.x on the same HTTP port) answers 200 without any credentials, from `127.0.0.1` or through `kubectl port-forward` | The shipped `arthas.properties` sets `arthas.localConnectionNonAuth=true`, which lets loopback clients in without a password. A port-forward counts as loopback. | [arthas.md](arthas.md#attach) |
| `arthas-boot` fails before the attach with `IllegalArgumentException: port out of range:-1` | `--telnet-port -1` together with `--attach-only` | [arthas.md](arthas.md#attach) |
| Through `kubectl port-forward`, the client sees the connection open and then EOF without data, and the port-forward ends with `error: lost connection to pod` | The listener in the pod is bound to `::1` or to the pod IP. Port-forward connects only to IPv4 `127.0.0.1`. | [setup.md](setup.md#launch-command) |
| Every port of one `kubectl port-forward` answers `Connection refused` | One refused forwarded connection ended the whole port-forward process | [setup.md](setup.md#launch-command) |
| Arthas answers 401 to every password right after the attach | Attached with `--username` and an empty password | [arthas.md](arthas.md#attach) |
| `scripts/Redefine.java` exits with 3 on the second run | JDWP on an ephemeral port (`address=127.0.0.1:0`) moved to a new port after the detach | [redefine.md](redefine.md#procedure-with-scriptsredefinejava) |
| `jcmd` or `arthas-boot` fails on an address already in use | The tool inherits the target's `JAVA_TOOL_OPTIONS` with the JDWP agent and tries to bind the same debug port. Start it with `env -u JAVA_TOOL_OPTIONS`. | [setup.md](setup.md#launch-command), [arthas.md](arthas.md#attach) |
| Arthas `retransform` changes the body but Spring/Jackson state stays old | HotswapAgent's plugins (Spring and Jackson refresh) react only to a redefine, not to a retransform | [arthas.md](arthas.md#commands-that-instrument-or-change-classes) |
| New endpoint answers 401, so "it exists" | 401 also for unknown paths behind Spring Security | [verification.md](verification.md#checks-that-mislead) |

For a JVM in a pod (port-forward, Secrets, memory limits, rollout
strategy), see the [jvm-remote-debug](../../jvm-remote-debug/SKILL.md) skill.
