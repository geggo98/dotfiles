# Nix Recipes — Slimming the devenv Shell

Documentation:
- Nix recipes: https://devenv.sh/recipes/nix/
- macOS / Apple SDK: https://devenv.sh/recipes/macos/
- Cross-platform config: https://devenv.sh/recipes/cross-platform/

Goal: a shell that carries no C compiler toolchain, for projects that never compile C.
That saves **316 MiB on x86_64-linux** and **1205 MiB on aarch64-darwin** — see section 2
for why the two differ by so much. The mechanism is two independent options, `stdenv` and
`apple.sdk`; neither implies the other.

Every number in this file was measured on 2026-09-10 with devenv 2.2.2 against nixpkgs
26.11pre-git. Two independent methods were used and they agree to the byte: paths
materialised in a real store (aarch64-darwin natively, x86_64-linux in a Docker/OrbStack
container) and `nix path-info -S --store https://cache.nixos.org`, which reads closure
sizes out of the binary cache without downloading a single NAR. The aarch64-linux row is
from the cache method only. Re-measure rather than trust any of it after a major upgrade.

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

For Go, add one more line. Go does **not** disable cgo on its own here, and on Linux even
`os/user` from the standard library then fails to build — see section 5:

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

| closure | `pkgs.stdenv` | `pkgs.stdenvNoCC` | saved |
|---|---|---|---|
| aarch64-darwin | 1298.5 MiB | 93.5 MiB | **1205.0 MiB, 13.9x** |
| x86_64-linux | 394.5 MiB | 78.0 MiB | **316.5 MiB, 5.1x** |
| aarch64-linux | 396.3 MiB | 91.9 MiB | **304.4 MiB, 4.3x** |

**Linux matches the "a few hundred MB" the devenv docs quote. Darwin is the outlier, and
not for the reason that looks obvious.** Broken down by path, the 1205.0 MiB that leave on
aarch64-darwin are 829.6 MiB of LLVM/clang (69%) against 358.4 MiB of Apple SDK (30%):

```
  379.0 MiB  llvm-21.1.8-lib          99.6 MiB  llvm-21.1.8
  346.1 MiB  apple-sdk-14.4           44.4 MiB  clang-21.1.8
  287.6 MiB  clang-21.1.8-lib         12.3 MiB  libcxx-21.1.6+apple-sdk-26.5
```

So the gap is mostly that **Darwin's stdenv is clang/LLVM-based while Linux's is
GCC-based**, and LLVM's libraries are large. The SDK is the second contributor, not the
first. On x86_64-linux exactly 13 paths leave, and they are unmistakably the toolchain:
`gcc`, `gcc-wrapper`, `binutils` (+`-lib`, +`-wrapper`), `glibc-dev`, `glibc-bin`, `gmp`,
`isl`, `libmpc`, `mpfr`, `linux-headers`, `expand-response-params`.

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

| in the shell | default | only `stdenvNoCC` | `stdenvNoCC` + `apple.sdk = null` |
|---|---|---|---|
| `command -v cc` | `/nix/store/…-clang-wrapper-21.1.8/bin/cc` | `/usr/bin/cc` | `/usr/bin/cc` |
| `$CC` | `clang` | unset | unset |
| `$DEVELOPER_DIR` | `/nix/store/…-apple-sdk-14.4` | **still set** | unset |
| `$SDKROOT` | `…/MacOSX.sdk` | **still set** | unset |
| `$NIX_APPLE_SDK_VERSION` | `140400` | **still set** | unset |

The middle column is the whole argument for this section: `stdenvNoCC` takes the compiler
and leaves the SDK, because devenv re-adds the SDK through `packages`. Only the second
option removes it.

Read the `cc` row twice as well. The Nix compiler is gone, but `cc` now resolves to Apple's
own `/usr/bin/cc`, which every Mac has. Dropping the toolchain removes the *pinned*
compiler, not the possibility of compiling — see the trap in section 6.

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

## 5. Go: `CGO_ENABLED` does not auto-disable, and Linux is stricter

Go 1.20 introduced "CGO_ENABLED defaults to 0 when no C compiler is found". **That does not
apply to nixpkgs' Go on either platform.** Measured with `go 1.26.7`, no C compiler
anywhere on `PATH`, aarch64-darwin natively against x86_64-linux in the container:

| with no C compiler on PATH | aarch64-darwin | x86_64-linux |
|---|---|---|
| `go env CGO_ENABLED` | `1` | `1` |
| `go env CC` | `clang` | `gcc` |
| trivial pure-Go `main.go` | exit 0 | exit 0 |
| `go build os/user` (stdlib) | exit 0 | **fails** |
| package with `import "C"` | **fails** | **fails** |
| any of these with `CGO_ENABLED=0` | exit 0 | exit 0 |

The failure is loud on both, naming the compiler it wanted:

```
# runtime/cgo
cgo: C compiler "gcc" not found: exec: "gcc": executable file not found in $PATH
```

**Read the `os/user` row.** On darwin that package has a non-cgo implementation and builds
fine; on Linux it goes through NSS and needs cgo, so a *standard library* package fails with
the toolchain dropped. That makes `env.CGO_ENABLED = "0";` close to mandatory on Linux
rather than merely tidy — set it whenever you set `stdenvNoCC` for a Go project.

The reverse asymmetry bites too. On macOS `/usr/bin/cc`, `/usr/bin/gcc` and `/usr/bin/clang`
all exist and devenv does not scrub `PATH`, so a cgo build still succeeds — quietly, with an
unpinned Apple compiler. In the Linux container none of the three exists and `command -v cc`
finds nothing; a Linux host has no compiler unless someone installed one, and NixOS never
has `/usr/bin/cc`. So the same devenv.nix can pass on a developer's Mac and fail in Linux
CI. `CGO_ENABLED = "0"` makes both fail the same way, which is the point of setting it.

## 6. Traps

- **`stdenvNoCC` does not remove the Apple SDK.** `apple.sdk` is a separate option with
  its own default — see section 3.
- **`languages.c`, and therefore `languages.rust`, put `pkgs.stdenv` back into
  `packages`.** The `stdenv` option does not gate that path.
- **A green Mac does not mean Linux CI will pass.** macOS keeps `/usr/bin/cc` reachable and
  devenv does not scrub `PATH`, so a build needing cc still succeeds there — with an
  unpinned Apple compiler. Linux has no system compiler at all. Measured both ways in
  section 5.
- **`apple.sdk = null` trades reproducibility for size**, by design. It is not a free
  win, and it is the one change here that should be a deliberate decision.
- **Do not use `//` with `lib.optionalAttrs` to gate config per platform** — infinite
  recursion. `lib.mkMerge` + `lib.mkIf`, per the cross-platform recipe.
- **Do not measure "is there a compiler?" from inside another Nix shell.** A parent
  environment that already exports `CC`, `DEVELOPER_DIR` or `SDKROOT` is inherited
  wholesale, and the probe then reports the parent's toolchain as if devenv had provided
  it. Measure from a scrubbed environment (`env -i`).
