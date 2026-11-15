// Redefines compiled classes in a running JVM through JDI (VirtualMachine.redefineClasses).
// Single-file mode, no build step:
//   java Redefine.java [--apply] <host> <jdwp-port> <classesDir> <fqcn>...
//
// Without --apply the tool only PROBES (same as the explicit --probe): it changes nothing.
// A redefine needs --apply. JDWP is unauthenticated code execution, so prefer 127.0.0.1 with
// `kubectl port-forward` over a cluster-wide address.
//
// The probe reports for each class (including nested ones) whether the JVM has
// loaded it. A redefine can only replace loaded classes. Classes that are not loaded yet have to
// be put on the target's class path instead (HotswapAgent `extraClasspath`, see
// references/redefine.md, section "New classes"); the next load then picks up the new version.
//
// Why not `jdb redefine`: jdb replaces one class per command and refuses ambiguous class loaders.
// A coherent change (class + helper, interface + implementation) would need several commands, and the
// code runs with a half-applied state in between. redefineClasses takes ALL classes in one call.
//
// Nested classes (Name$*.class: inner and anonymous classes) of the same source are added automatically
// when the target JVM has loaded them. Java lambda bodies are private methods of the outer class, so
// redefining the outer class covers them.
//
// If more than one class loader holds a class, the call does not guess (exit 4), unless the others
// are recognisable throwaway loaders (class ThrowawayLoaders below): then only the real one is redefined.
// A class held ONLY by a throwaway loader counts as not loaded.
//
// Output: ONE line of JSON on stdout (usage errors, exit 2, print plain text on stderr instead).
//   apply: ok, complete, redefined, notLoaded, ignoredCopies, errors
//   probe: ok, probe, canRedefine, loaded, notLoaded, ambiguous
// Exit: 0 ok and complete, 1 redefinition rejected, 2 usage, 3 no connection, 4 nothing to redefine (none of
// the classes is loaded), class file missing, or class loader ambiguous, 5 redefined but INCOMPLETE: the
// classes under "notLoaded" were not redefined. Their first load takes whatever version is on the JVM's
// class path (in a container image or jar: the old one).
// Probe: "ok":false when --apply is certain to fail (no redefine support, ambiguous loaders).
import com.sun.jdi.Bootstrap;
import com.sun.jdi.ReferenceType;
import com.sun.jdi.VirtualMachine;
import com.sun.jdi.connect.AttachingConnector;
import com.sun.jdi.connect.Connector;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.regex.Pattern;

// NOTE: keep the helper class at the END of the file. In single-file mode Java launches the FIRST
// class in the file, so the class with main() must come first.
public class Redefine {
    static String q(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> {
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
                }
            }
        }
        return b.append('"').toString();
    }

    static String arr(List<String> items) {
        StringBuilder b = new StringBuilder("[");
        for (int i = 0; i < items.size(); i++) b.append(i > 0 ? "," : "").append(q(items.get(i)));
        return b.append(']').toString();
    }

    static String result(boolean ok, List<String> redefined, List<String> notLoaded, List<String> ignoredCopies,
            List<String> errors) {
        return "{\"ok\":" + ok + ",\"complete\":" + (ok && notLoaded.isEmpty()) + ",\"redefined\":" + arr(redefined)
                + ",\"notLoaded\":" + arr(notLoaded) + ",\"ignoredCopies\":" + arr(ignoredCopies)
                + ",\"errors\":" + arr(errors) + "}";
    }

    static int fail(int code, List<String> redefined, List<String> notLoaded, List<String> ignoredCopies,
            List<String> errors) {
        System.out.println(result(false, redefined, notLoaded, ignoredCopies, errors));
        return code;
    }

    public static void main(String[] args) throws Exception {
        boolean apply = args.length > 0 && args[0].equals("--apply");
        if (args.length > 0 && (apply || args[0].equals("--probe"))) args = java.util.Arrays.copyOfRange(args, 1, args.length);
        boolean probe = !apply;
        if (args.length < 4) {
            System.err.println("Usage: Redefine [--apply] <host> <jdwp-port> <classesDir> <fqcn>...");
            System.exit(2);
        }
        String host = args[0];
        String port = args[1];
        Path classesDir = Path.of(args[2]);
        List<String> redefined = new ArrayList<>();
        List<String> notLoaded = new ArrayList<>();     // incomplete change: these were NOT redefined
        List<String> ignoredCopies = new ArrayList<>(); // harmless: copies in throwaway loaders
        List<String> errors = new ArrayList<>();

        // Candidates: the requested classes plus their nested siblings in the class directory.
        Map<String, Path> candidates = new LinkedHashMap<>();
        for (int i = 3; i < args.length; i++) {
            String fqcn = args[i];
            Path file = classesDir.resolve(fqcn.replace('.', '/') + ".class");
            if (!Files.isRegularFile(file)) {
                errors.add(fqcn + ": " + file + " does not exist (compile first)");
                continue;
            }
            candidates.put(fqcn, file);
            String simple = file.getFileName().toString().replaceFirst("\\.class$", "");
            try (DirectoryStream<Path> nested = Files.newDirectoryStream(file.getParent(), simple + "$*.class")) {
                TreeSet<Path> sorted = new TreeSet<>();
                nested.forEach(sorted::add);
                for (Path n : sorted) {
                    String base = n.getFileName().toString().replaceFirst("\\.class$", "");
                    String pkg = fqcn.contains(".") ? fqcn.substring(0, fqcn.lastIndexOf('.') + 1) : "";
                    candidates.putIfAbsent(pkg + base, n);
                }
            }
        }
        if (!errors.isEmpty()) System.exit(fail(4, redefined, notLoaded, ignoredCopies, errors));

        AttachingConnector socket = null;
        for (AttachingConnector c : Bootstrap.virtualMachineManager().attachingConnectors()) {
            if (c.name().equals("com.sun.jdi.SocketAttach")) socket = c;
        }
        if (socket == null) {
            errors.add("Connector com.sun.jdi.SocketAttach is not available");
            System.exit(fail(3, redefined, notLoaded, ignoredCopies, errors));
        }
        Map<String, Connector.Argument> cargs = socket.defaultArguments();
        cargs.get("hostname").setValue(host);
        cargs.get("port").setValue(port);
        cargs.get("timeout").setValue("10000");

        VirtualMachine vm;
        try {
            vm = socket.attach(cargs);
        } catch (Exception e) {
            errors.add("Attach to " + host + ":" + port + " failed: " + e);
            System.exit(fail(3, redefined, notLoaded, ignoredCopies, errors));
            return;
        }

        if (probe) {
            List<String> loaded = new ArrayList<>();
            List<String> ambiguousNames = new ArrayList<>();
            boolean canRedefine;
            try {
                canRedefine = vm.canRedefineClasses();
                for (String fqcn : candidates.keySet()) {
                    List<ReferenceType> real = ThrowawayLoaders.real(vm.classesByName(fqcn));
                    if (real.isEmpty()) notLoaded.add(fqcn);
                    else if (real.size() > 1) ambiguousNames.add(fqcn);
                    else loaded.add(fqcn);
                }
            } finally {
                vm.dispose();
            }
            boolean ok = canRedefine && ambiguousNames.isEmpty();
            System.out.println("{\"ok\":" + ok + ",\"probe\":true,\"canRedefine\":" + canRedefine + ",\"loaded\":"
                    + arr(loaded) + ",\"notLoaded\":" + arr(notLoaded) + ",\"ambiguous\":" + arr(ambiguousNames) + "}");
            return;
        }

        int code = 0;
        try {
            if (!vm.canRedefineClasses()) {
                errors.add("The target JVM does not allow class redefinition");
                code = 1;
            } else {
                Map<ReferenceType, byte[]> toRedefine = new LinkedHashMap<>();
                boolean ambiguous = false;
                for (Map.Entry<String, Path> e : candidates.entrySet()) {
                    List<ReferenceType> types = vm.classesByName(e.getKey());
                    List<ReferenceType> real = ThrowawayLoaders.real(types);
                    for (ReferenceType w : types)
                        if (!real.contains(w))
                            ignoredCopies.add(e.getKey() + ": copy in throwaway class loader " + ThrowawayLoaders.loaderName(w) + " left alone");
                    if (real.isEmpty()) {
                        // Important: a class that is NOT loaded yet loads later from the JVM's class path, which in
                        // a container image or jar holds the OLD version. Reported under notLoaded, exit 5.
                        notLoaded.add(e.getKey());
                    } else if (real.size() > 1) {
                        ambiguous = true;
                        StringBuilder b = new StringBuilder(e.getKey() + ": " + real.size() + " class loaders hold the class:");
                        for (ReferenceType t : real) b.append(' ').append(t.classLoader());
                        errors.add(b.toString());
                    } else {
                        toRedefine.put(real.get(0), Files.readAllBytes(e.getValue()));
                    }
                }
                if (ambiguous) {
                    code = 4;
                } else if (toRedefine.isEmpty()) {
                    errors.add("nothing to redefine: none of the classes is loaded in the JVM");
                    code = 4;
                } else {
                    try {
                        vm.redefineClasses(toRedefine);
                        for (ReferenceType t : toRedefine.keySet()) redefined.add(t.name());
                    } catch (Throwable t) {
                        // UnsupportedOperationException (schema change), VerifyError, ClassFormatError ...
                        errors.add(t.getClass().getSimpleName() + ": " + t.getMessage());
                        code = 1;
                    }
                }
            }
        } finally {
            vm.dispose(); // detaches and leaves the JVM running
        }

        if (code != 0) System.exit(fail(code, redefined, notLoaded, ignoredCopies, errors));
        System.out.println(result(true, redefined, notLoaded, ignoredCopies, errors));
        if (!notLoaded.isEmpty()) System.exit(5); // redefined, but incomplete
    }
}

// Throwaway class loaders: Spring Data (InspectionClassLoader) and Spring (SimpleThrowawayClassLoader,
// OverridingClassLoader, ShadowingClassLoader) load entities again for a short inspection and keep
// the copy. This happens after every EntityManagerFactory rebuild, so right after the first redefine
// of an entity. Such a copy is never used. It must not count as "ambiguous", or every further redefine
// of the same entity would fail.
final class ThrowawayLoaders {
    static final Pattern LOADER = Pattern.compile(
            ".*(InspectionClassLoader|ThrowawayClassLoader|OverridingClassLoader|ShadowingClassLoader).*");

    static String loaderName(ReferenceType t) {
        return t.classLoader() == null ? "bootstrap" : t.classLoader().referenceType().name();
    }

    static boolean isThrowaway(ReferenceType t) {
        return t.classLoader() != null && LOADER.matcher(loaderName(t)).matches();
    }

    static List<ReferenceType> real(List<ReferenceType> types) {
        List<ReferenceType> r = new ArrayList<>();
        for (ReferenceType t : types) if (!isThrowaway(t)) r.add(t);
        return r;
    }
}
