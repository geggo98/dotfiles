Applies to: macOS, Linux

# Installing JBR and HotswapAgent

**TL;DR:** you need a JVM with enhanced class redefinition (JetBrains
Runtime, JBR) and the HotswapAgent jar. Get JBR from SDKMAN, nixpkgs or the
GitHub releases. Get HotswapAgent from its GitHub releases. Pin the
checksums yourself, because the skill pins none. Then check two things: `java -version` names JBR, and
`jcmd <pid> VM.flags` shows `-XX:+AllowEnhancedClassRedefinition`.

## Why JBR

A standard JVM can only replace method bodies. DCEVM (Dynamic Code
Evolution VM) is a patch to the HotSpot JVM that also allows structural
class changes. JBR has DCEVM built in, so it accepts
`-XX:+AllowEnhancedClassRedefinition`: new fields, new methods, changed
signatures. HotswapAgent alone does not give you that. It needs this JVM
underneath ([SKILL.md, Rule 2](../SKILL.md#rule-2-start-the-jvm-with-hotswapagent-from-the-beginning)).

Take the **JBR SDK** (with `jcmd`, `jdb`, `javac`), not only the runtime,
because the redefine tools need the JDK tools: `jdb redefine` needs `jdb`,
[`scripts/Redefine.java`](../scripts/Redefine.java) needs the JDK's
compiler (the single-file launcher compiles it in memory) and the
`jdk.jdi` module, and the
[check](#check) below needs `jcmd`.

## Getting JBR

| Source | How | Notes |
|---|---|---|
| SDKMAN | Run `sdk list java`, then `sdk install java <version>` with a version identifier that ends in `-jbr` | Check the list for the current versions. |
| nixpkgs | package `jetbrains.jdk` | Evaluated 2026-11-15: version 25.0.3-b508.4. |
| GitHub releases | JetBrains Runtime releases page (<https://github.com/JetBrains/JetBrainsRuntime/releases>), `jbrsdk-<version>-<os>-<arch>-<build>.tar.gz` | Covers Linux containers (x64 and aarch64). |

In this skill, *the measured setup* is the Spring Boot 4 application on
which these notes were measured in 2026-10/11. It used JBR 25.0.4.1 from
the release tarball and HotswapAgent 2.0.3, in a Linux arm64 container
image. The launch command is in [setup.md](setup.md#launch-command).

## Getting HotswapAgent

Download `hotswap-agent-<version>.jar` from the HotswapAgent GitHub
releases page (<https://github.com/HotswapProjects/HotswapAgent/releases>).
The [measured setup](#getting-jbr) used 2.0.3. Check the releases page for
newer versions. After an upgrade, run the spike again: the compatibility
test on one service, one JSON endpoint and one entity
([verification.md, "The spike"](verification.md#the-spike)). An upgrade
needs a new run because the compatibility of HotswapAgent's framework
plugins (Spring, Hibernate, Jackson and others) differs from version to
version.

## Checksums

The skill pins no checksums. Take the checksum from the release asset
page (JBR offers a checksum file next to the tarball) or compute it on the
first download, then pin it in your own build:

```bash
shasum -a 256 hotswap-agent-2.0.3.jar     # macOS
sha256sum hotswap-agent-2.0.3.jar         # Linux
```

Verify the checksums of all three downloads in your image build (JBR,
HotswapAgent and Arthas, the JVM diagnostic tool from
[arthas.md](arthas.md)), and fail the build on a mismatch. The image build
of the measured setup did exactly this.

## Minimal flags

```bash
java \
  -XX:+AllowEnhancedClassRedefinition \
  -XX:HotswapAgent=external \
  -javaagent:/path/hotswap-agent.jar \
  --add-opens java.base/java.net=ALL-UNNAMED \
  --add-opens java.base/jdk.internal.loader=ALL-UNNAMED \
  -jar app.jar
```

- `-XX:HotswapAgent=external`: JBR uses the HotswapAgent jar that you
  give with `-javaagent`, not a HotswapAgent built into the JVM. The other
  values of the option (`disabled`, `fatjar`, `core`) switch the agent off
  or load the built-in one. This skill uses `external` because then you
  choose the HotswapAgent version and pin its checksum yourself.
- Both `--add-opens` are required. Without them, every class-loader
  initialisation throws `InaccessibleObjectException` once HotswapAgent
  tries to extend a loader (measured 2026-10/11, see
  [setup.md](setup.md#launch-command)).
- Add `hotswap-agent.properties` from the template in
  [setup.md](setup.md#hotswap-agentproperties). For `jdb` or
  [`scripts/Redefine.java`](../scripts/Redefine.java), also add a JDWP
  agent bound to `127.0.0.1`, because JDWP has no authentication (see
  [java-debug, jdwp-options.md](../../java-debug/references/jdwp-options.md)). The exact
  `-agentlib:jdwp=...` option is in [setup.md](setup.md#launch-command).

## Check

```bash
java -version                 # the output names the JetBrains Runtime
jcmd <pid> VM.flags           # must contain -XX:+AllowEnhancedClassRedefinition
```

If the flag shows `-` although you set `+`, a JFR recording is probably
running (see
[redefine.md, Pitfall (a)](redefine.md#a-jfr-turns-off-enhanced-redefinition-on-jbr)).
A plain `jcmd <pid> JFR.check` also starts JFR's threads (measured
2026-11-15 on Eclipse Temurin 17, 21 and 25, in a container). Whether that alone turns the flag off on JBR
was not measured.
