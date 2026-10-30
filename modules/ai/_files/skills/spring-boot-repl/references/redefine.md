# Class redefinition with `jdb redefine`

## Procedure

Terminal 1, attach to the running JVM:

```bash
jdb -attach 127.0.0.1:5005
```

Terminal 2, compile:

```bash
./gradlew classes
```

Back in `jdb`, with the **absolute** path of the new class file:

```text
redefine com.example.PreisService /projekt/build/classes/java/main/com/example/PreisService.class
```

No breakpoint has to be hit first: JDI allows redefinition on a running VM,
and the dossier's author confirmed this on a running JVM.
[JDI `VirtualMachine.redefineClasses`](https://docs.oracle.com/en/java/javase/21/docs/api/jdk.jdi/com/sun/jdi/VirtualMachine.html)

Redefinition goes through `redefineClasses`, so the HotswapAgent
transformer runs and its plugins refresh framework state. That is why this
is the preferred path over Arthas `retransform` (see SKILL.md, Rule 1).

## What redefinition does and does not do

- Existing objects keep their field values.
- Constructors and field initialisers do **not** run again for them.
  (Measured in the dossier: a changed initialiser `99` did not appear on
  the existing instance.)
- Active stack frames may still execute the previous method version.
- New calls use the new code.
- Breakpoints in redefined classes are deleted (JDI contract) — set them again.
- Without enhanced redefinition (JBR), only method bodies may change. New
  fields, methods or changed signatures fail with an
  `UnsupportedOperationException`-type error.

## Limits of the bare `jdb` client

- It identifies the class **by name**. If several classloaders loaded that
  name (DevTools restart loader, child contexts with their own loader,
  plugin loaders), the client rejects the ambiguous choice. Check with
  Arthas `sc -d com.example.PreisService` how many loaders hold it.
- One command replaces **one** class. The JDI API itself accepts several
  classes in one call.

For a coherent structural change across several classes (interface plus
implementations, a changed record and its users), either pause the affected
work until all classes are swapped, or use one combined JDI /
`Instrumentation.redefineClasses` call — for example a small JDI client, or
HA `autoHotswap`, which batches the class files it sees.

Source of the client behaviour:
[OpenJDK `Commands.java`](https://github.com/openjdk/jdk21u/blob/master/src/jdk.jdi/share/classes/com/sun/tools/example/debug/tty/Commands.java).

For breakpoints, stepping and thread dumps, see the **java-debug** skill
(`references/jdb.md`).
