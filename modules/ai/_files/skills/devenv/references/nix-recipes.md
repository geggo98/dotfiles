# Nix Recipes — Slimming the devenv Shell

Documentation:
- Nix recipes: https://devenv.sh/recipes/nix/
- macOS / Apple SDK: https://devenv.sh/recipes/macos/
- Cross-platform config: https://devenv.sh/recipes/cross-platform/

Goal: a shell that carries no C compiler toolchain, for projects that never compile C.
On aarch64-darwin that is the difference between a **1298.5 MiB** and a **93.5 MiB**
stdenv closure. The mechanism is two independent options, `stdenv` and `apple.sdk`;
neither implies the other.

Every number in this file was measured on 2026-09-10 with devenv 2.2.2 on
aarch64-darwin against nixpkgs 26.11pre-git. Re-measure rather than trust them after a
major upgrade.

## 1. The recipe

```nix
# devenv.nix
{ pkgs, ... }:
{
  stdenv = pkgs.stdenvNoCC;   # drop the C compiler toolchain
  apple.sdk = null;           # macOS: also drop the pinned Apple SDK (see section 3)

  languages.java.enable = true;
}
```

For Go, add one more line — Go does **not** disable cgo on its own here, see section 5:

```nix
  env.CGO_ENABLED = "0";
```

## 2. What `stdenv = pkgs.stdenvNoCC` actually changes

`stdenv` is a top-level option (`src/modules/top-level.nix`), `types.package`, default
`pkgs.stdenv`, and devenv reads it in exactly one place:

```nix
(pkgs.mkShell.override { stdenv = config.stdenv; })
```

So the doc's "equivalent to using nixpkgs' `mkShellNoCC`" is literal, not an analogy.
`stdenvNoCC` keeps the usual unix tools (coreutils, gnused, gnugrep, gnumake, patch, …);
what goes is the compiler wrapper — `hasCC` is `false` and `cc` is `null`.

| closure on aarch64-darwin | measured |
|---|---|
| `pkgs.stdenv` | 1298.5 MiB |
| `pkgs.stdenvNoCC` | 93.5 MiB |

That is far more than the "a few hundred MB" the devenv docs quote, because on Darwin
the Apple SDK sits inside the default stdenv closure. On Linux expect a smaller delta.

Setting it on macOS is safe even though devenv runs an `apply` over the value that calls
`stdenv.override (prev: { extraBuildInputs = …; })` on Darwin: verified against nixpkgs
26.11pre-git, `stdenvNoCC ? override` is true and that override evaluates without error.

## 3. macOS: `apple.sdk` is a separate switch

`apple.sdk` is its own option, defaulting to `pkgs.apple-sdk` on Darwin and `null`
everywhere else. devenv strips the SDK out of the stdenv it was given
(`filter (x: !(x ? sdkroot))`) and re-adds it through `packages`:

```nix
++ lib.optional (config.apple.sdk != null) config.apple.sdk;
```

**So `stdenvNoCC` alone does not remove the Apple SDK** — the two options are
orthogonal, and a macOS project that wants neither has to set both.

What `apple.sdk = null` removes is proven by devenv's own test
(`tests/macos-no-default-sdk/devenv.nix`), which asserts that `DEVELOPER_DIR`,
`DEVELOPER_DIR_FOR_BUILD`, `SDKROOT` and `NIX_APPLE_SDK_VERSION` are all unset
afterwards.

Measured end to end, same project (`languages.java.enable` only), `devenv shell` entered
from a scrubbed environment (`env -i`) so nothing could be inherited:

| in the shell | default | `stdenvNoCC` + `apple.sdk = null` |
|---|---|---|
| `command -v cc` | `/nix/store/…-clang-wrapper-21.1.8/bin/cc` | `/usr/bin/cc` |
| `$CC` | `clang` | unset |
| `$DEVELOPER_DIR` | `/nix/store/…-apple-sdk-14.4` | unset |
| `$SDKROOT` | `…/MacOSX.sdk` | unset |
| `$NIX_APPLE_SDK_VERSION` | `140400` | unset |

Read the first row twice: the Nix compiler is gone, and `cc` now resolves to Apple's own
`/usr/bin/cc`, which every Mac has. Dropping the toolchain removes the *pinned* compiler,
not the possibility of compiling — see the trap in section 6.

**It costs reproducibility, and that is the point of the option**, not a side effect.
The option's own description: "If set to `null`, the system SDK can be used if the shell
allows access to external environment variables." Weigh that before making it a default.

No platform guard is needed for `apple.sdk = null`, because the option is already `null`
off Darwin. A guard becomes necessary only when setting a real SDK, since
`pkgs.apple-sdk_15` does not exist on Linux:

```nix
# devenv.nix — only when you set an actual SDK
{ pkgs, lib, ... }:
{
  apple.sdk = if pkgs.stdenv.isDarwin then pkgs.apple-sdk_15 else null;
}
```

For gating whole config blocks, use `lib.mkMerge` with `lib.mkIf`. The cross-platform
recipe warns explicitly against `//` with `lib.optionalAttrs` — it causes infinite
recursion.

## 4. Which languages can drop the toolchain

Grepped across all 58 `src/modules/languages/*.nix` at devenv v2.2.2, so this is what
the modules themselves pull in — not a rule of thumb:

| Language module | Needs a C toolchain? | Evidence in devenv's source |
|---|---|---|
| java, kotlin, scala, clojure | no | no reference to cc, clang or `languages.c` |
| go | no, without cgo | ditto — but see section 5 |
| dotnet, deno, elm, terraform, opentofu | no | ditto (`dotnet`/`terraform` name `stdenv` only for platform detection) |
| rust | **yes** | `languages.c.enable = lib.mkDefault true` + `pkgs.clang` |
| ruby, crystal | **yes** | `languages.c.enable = lib.mkDefault true` |
| swift | **yes** | `pkgs.clang` |
| python | **yes** | references `stdenv.cc` |

`languages.c.enable = true` puts **`pkgs.stdenv` itself** into `packages`
(`languages/c.nix`). That is a second, independent lever: enabling Rust drags the
compiler back in through `packages` no matter what `stdenv` is set to. `stdenvNoCC` is
then pointless there, not broken.

**The module is only half the question.** These need a C toolchain because of a
*dependency*, not because of the language, and no grep can find them for you:

- JVM: JNI-backed libraries, GraalVM `native-image`, Scala Native, Kotlin/Native, and
  `node-gyp` pulled in by a frontend Maven/Gradle plugin
- Go: any module using cgo (sqlite drivers, librdkafka bindings, …)
- Python: `pip` installing an sdist with no wheel for this platform
- .NET: `PublishAot` — NativeAOT shells out to clang and a linker
- Ruby: native gems; Erlang/Elixir: NIFs

Rule of thumb that follows: set it, then run the project's real build once. The failure
is loud (section 5), so it will not slip through.

## 5. Go: `CGO_ENABLED` does not auto-disable here

Go 1.20 introduced "CGO_ENABLED defaults to 0 when no C compiler is found". **That does
not apply to nixpkgs' Go.** Measured with `go 1.26.7` from the store:

| test | result |
|---|---|
| `go env CGO_ENABLED`, PATH holding only go | **`1`** — no auto-disable |
| `go build os/user` (has a pure-Go fallback), no cc on PATH | exit 0 |
| `go build` of a package with `import "C"`, no cc on PATH | **fails**: `cgo: C compiler "clang" not found: exec: "clang": executable file not found in $PATH` |
| the same build with `/usr/bin` on PATH | **exit 0 — built with Apple's clang** |

Two things follow. Set `env.CGO_ENABLED = "0";` alongside `stdenvNoCC` so a cgo
dependency fails at `go build` rather than at whatever it links against later. And note
the last row: on macOS, dropping the Nix toolchain does not remove *a* C compiler.

## 6. Traps

- **`stdenvNoCC` does not remove the Apple SDK.** `apple.sdk` is a separate option with
  its own default — see section 3.
- **`languages.c`, and therefore `languages.rust`, put `pkgs.stdenv` back into
  `packages`.** The `stdenv` option does not gate that path.
- **On macOS a C compiler stays reachable anyway.** `/usr/bin/cc` ships with the Xcode
  command line tools and devenv does not scrub `PATH`, so after this change `cc` resolves
  to Apple's unpinned compiler rather than to nothing. Measured — see section 3. A build
  that needs cc therefore may still succeed, just not reproducibly.
- **`apple.sdk = null` trades reproducibility for size**, by design. It is not a free
  win, and it is the one change here that should be a deliberate decision.
- **Do not use `//` with `lib.optionalAttrs` to gate config per platform** — infinite
  recursion. `lib.mkMerge` + `lib.mkIf`, per the cross-platform recipe.
- **Do not measure "is there a compiler?" from inside another Nix shell.** A parent
  environment that already exports `CC`, `DEVELOPER_DIR` or `SDKROOT` is inherited
  wholesale, and the probe then reports the parent's toolchain as if devenv had provided
  it. Measure from a scrubbed environment (`env -i`).
