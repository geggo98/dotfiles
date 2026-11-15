Applies to: macOS, Linux. The JMC GUI is for the human; the headless rules report is for the agent.

# JDK Mission Control (JMC) — GUI for People, Rules Report for Agents

**TL;DR:** JMC is the graphical client for JFR recordings and JMX. An agent cannot drive the GUI, but it can run JMC's rule engine without it: `scripts/jfr-rules-report.sh <recording.jfr>` writes the same "Automated Analysis" findings as an HTML file. Use `scripts/jfr-summary.sh` for a quick look first, and the rules report when you need to know what is wrong.

Paths that start with `scripts/` are relative to the root of the `java-debug` skill, not to this file. For example, `scripts/jfr-rules-report.sh` is the file `java-debug/scripts/jfr-rules-report.sh`. Plain links such as [jmx.md](jmx.md) point to files in this `references/` folder.

## Contents

- [1. Install](#1-install)
- [2. Connect to a JVM](#2-connect-to-a-jvm)
- [3. Record JFR from JMC](#3-record-jfr-from-jmc)
- [4. Headless rules report (agent path)](#4-headless-rules-report-agent-path)
- [5. JSON instead of HTML](#5-json-instead-of-html)
- [6. Which JFR tool when](#6-which-jfr-tool-when)
- [7. Things JMC does not do](#7-things-jmc-does-not-do)

## 1. Install

```bash
brew install --cask jdk-mission-control      # macOS
```

- Measured 2026-11, macOS arm64: version 9.1.1 installed, the cask offered 9.1.2. Check the JMC release page (for example https://jdk.java.net/jmc/ or your JDK vendor's download page) for the version you get.
- The JMC GUI needs a JDK 21 or newer as its own host JVM. A native arm64 build exists. The headless rules report (§4) also ran on JDK 17.
- On Linux, unpack the release tarball. The plugin directory is then `<jmc>/plugins`.

## 2. Connect to a JVM

**JMX over RMI.** The connection URL is:

```
service:jmx:rmi:///jndi/rmi://<host>:<port>/jmxrmi
```

The target JVM must report a callback address that the client can reach. Set `java.rmi.server.hostname` and make `com.sun.management.jmxremote.port` equal to `com.sun.management.jmxremote.rmi.port`. The two Kubernetes modes (port-forward and direct) are in [jmx.md](jmx.md) §6.

With `kubectl port-forward`, this setup works when the JMX port is bound to 127.0.0.1 and `java.rmi.server.hostname=127.0.0.1`. Measured 2026-11-15 on OrbStack Kubernetes (Kubernetes 1.36.5, Docker runtime): a JMX client on the host read `java.lang:type=Runtime` through the forward. OrbStack is a local Docker and Kubernetes environment for macOS; its setup is in the `jvm-remote-debug` skill, file [references/orbstack-telepresence.md](../../jvm-remote-debug/references/orbstack-telepresence.md). A listener on `::1` only or on the pod IP only was not reachable, because this runtime connects only over IPv4 to `localhost` in the pod. These results apply to the Docker runtime. containerd and CRI-O implement port-forward differently, and their behaviour was not measured.

**Jolokia (HTTP).** Since JMC 9.1, the Jolokia connector is built in. There is no plugin to install. This was checked in the JARs of JMC 9.1.1 (measured 2026-11, macOS arm64): the app's plugin directory holds `org.openjdk.jmc.jolokia` and `org.jolokia.client-jmx-adapter` 2.0.2. The connector's URL format is:

```
service:jmx:jolokia://<host>:<port>/<path>
```

The format string `service:jmx:jolokia://%s:%s%s` is in the JAR. The settings are under Preferences (on macOS: Settings) > JDK Mission Control > **JVM Browser > Jolokia**, according to Oracle's JDK Mission Control User Guide, appendix "New features" for JMC 9.1 (https://docs.oracle.com/en/java/java-components/jdk-mission-control/9/user-guide/jdk-mission-control-users-guide.pdf). The JVM Browser is the JMC panel that lists local and remote JVMs. Nobody clicked through this menu path. Guides written before JMC 9.1 say to install a separate Jolokia plugin, because JMC 8 needed one. JMC 9.1 does not need one.

How to start the Jolokia agent safely (loopback bind, read-only policy): [jolokia.md](jolokia.md). The loopback bind alone does not protect the agent from users who may port-forward to the pod. Measured 2026-11-15 in the same OrbStack setup: a forwarded connection arrives with the source address 127.0.0.1, and a Jolokia 2.6.3 agent with `host=127.0.0.1` and no policy file answered reads through the forward without authentication. The read-only policy is what limits such a user.

## 3. Record JFR from JMC

In the JVM Browser panel, open the JVM, then **Start Flight Recording**:

- **Fixed** recording (stops after a duration) or **continuous** recording (ring buffer).
- Templates: **Continuous** (about 1 % overhead) and **Profiling** (about 2 %). These are the `default.jfc` and `profile.jfc` settings from [jfr.md](jfr.md).
- **Dump** writes the `.jfr` file to the machine that runs JMC.

> **Warning: JetBrains Runtime with enhanced class redefinition.** If you hot-swap code in a JVM, do not record JFR in it. When JMC starts or controls a recording on a JetBrains Runtime that runs with `-XX:+AllowEnhancedClassRedefinition`, the JVM turns that flag off. After that, structural hot swaps (new method, new field) fail. See `spring-boot-repl`, file `references/redefine.md`.

## 4. Headless rules report (agent path)

```bash
scripts/jfr-rules-report.sh <recording.jfr> [report.html]
```

The script runs JMC's rule engine on a recording and writes the "Automated Analysis Result Overview" as HTML. Without a second argument the report goes next to the recording as `<name>-rules.html`. On success it prints the report path on stdout.

| Option | Meaning |
|---|---|
| `--jmc-plugins DIR` or `$JMC_PLUGINS` | JMC plugin directory. Without it, the script checks these locations in this order: the Homebrew Caskroom (`/opt/homebrew` first, then `/usr/local`; versions sorted numerically only within each of the two roots, so the highest version comes last within a root and any version under `/usr/local` beats every version under `/opt/homebrew`), then `/Applications`, then `~/Applications`. The last existing location in this order wins: a JMC in `/Applications` or `~/Applications` beats every Caskroom version. With several installations, pass `--jmc-plugins`, because this search order may not pick the version you expect. On Linux, pass `<jmc>/plugins`. |
| `--java BIN` or `$JAVA_BIN` | The `java` that runs the rules (default: `java` on `PATH`). |

| Exit code | Meaning |
|---|---|
| 0 | Report written. |
| 1 | Failure: recording not found, JMC plugin directory not found, a required JAR missing or ambiguous, `java` not found, or no report written. |
| 2 | Usage error. |

**How it works.** The script calls the class `org.openjdk.jmc.flightrecorder.rules.report.html.JfrHtmlRulesReport` from the installed JMC. It puts exactly one JAR per pattern from the plugin directory on the class path:

- `org.openjdk.jmc.common`
- `org.openjdk.jmc.flightrecorder`
- `org.openjdk.jmc.flightrecorder.rules`
- `org.openjdk.jmc.flightrecorder.rules.jdk`
- `lz4-java`
- `org.owasp.encoder`

Without the last two the JVM fails with `ClassNotFoundException`. This dependency is not documented.

**Measured** 2026-11-15 with JMC 9.1.1 on macOS arm64, run with Temurin 17 and with Temurin 25: a 3.7 MB recording gave a 125 KB HTML report. For recordings from JDK 25, JMC prints `Could not find field with name 'virtual' in reader for 'thread'` on stderr. That warning is harmless.

**Limits.**

- The class is internal to JMC. It is not a supported command line and can change with any JMC release.
- The Linux plugin layout is not measured.

**The report is sensitive.** It quotes JVM arguments and system properties, which can hold passwords and tokens. For this reason the script writes it with mode 0600. Treat the report like the recording itself: do not put it in a ticket, a commit, or a chat without a review.

**How to read it.** Open the HTML file and look at the rules with the highest score first. JMC gives each rule a score from 0 to 100 and shows it as a severity: OK, Info, or Warning. A higher score means a more severe finding. Each rule names the problem (for example GC pressure, lock contention, or a hot allocation site) and points to the event type that shows it. Confirm a finding with `scripts/jfr-view.sh` or `scripts/jfr-events.sh` before you act on it.

## 5. JSON instead of HTML

JMC has no official command for a JSON report. You can write a small wrapper over `org.openjdk.jmc.flightrecorder.JfrLoaderToolkit.loadEvents` (in the `org.openjdk.jmc.flightrecorder` JAR) and `org.openjdk.jmc.flightrecorder.rules.RuleRegistry.getRules()` (in the `org.openjdk.jmc.flightrecorder.rules` JAR). The signature of `org.openjdk.jmc.flightrecorder.rules.IRule.evaluate` differs between JMC versions: check it against the JARs of your installed JMC. This approach is not measured.

## 6. Which JFR tool when

| Question | Tool |
|---|---|
| What is in the recording at all? | `scripts/jfr-summary.sh` (the `jfr` CLI) |
| A specific table (hot methods, GC pauses, allocations) | `scripts/jfr-view.sh` |
| Raw events as JSON, capped | `scripts/jfr-events.sh` |
| What is wrong with this JVM? | `scripts/jfr-rules-report.sh` (JMC rules) |
| Interactive drill-down by a person | JMC GUI |

Start with the summary. Run the rules report when the summary does not show an obvious cause.

## 7. Things JMC does not do

- **CSV export of MBean values from the JMX console is not confirmed.** No "Export to CSV" command for MBean values is documented, so do not promise it. For a time series of MBean values use `scripts/jmx-sample.py`, see [metrics-export.md](metrics-export.md).
- JMC does not reach a JVM in a pod by itself. To get the JMX or Jolokia port to your machine, load `jvm-remote-debug` (file `references/jmx-jolokia-ports.md`).
