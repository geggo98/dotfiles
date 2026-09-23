# The Linux builder (Docker)

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### The Linux builder (Docker)

`x86_64-linux` and `aarch64-linux` derivations are built locally, in an OrbStack
container per architecture. x86_64 runs under Rosetta; aarch64 runs natively.
Mechanism: `modules/_files/linux-builder/linux-builder` (control script) and
`entrypoint.sh` (what runs inside). System wiring: `modules/linux-builder.nix`.

```bash
just linux-builder-up               # start (x86_64 by default; `aarch64` as arg)
just linux-builder-status           # state, reported system, store size vs cap
just nixos-build p-ion-berlin-xs56r6          # build a host's closure, push it to R2
just linux-build 'nixpkgs#hello'    # any flake attribute
just nixos-deploy p-ion-berlin-xs56r6         # build, push, activate over ssh (NOT agent-safe)
just linux-builder-gc               # sweep the store back under its cap
just linux-builder-destroy          # container + volume + keypair
```

**Everything built is pushed to R2, minus what cache.nixos.org already has.**
`nix-cache-push --seed` HEADs the public cache for every path in the closure and
uploads only the remainder, so R2 never pays to store a second copy of something
`cache.nixos.org` already serves. The push runs on the *workstation*, reading the
builder over `ssh-ng` — the R2 write key never enters the container. Pass
`push="false"` to keep a throwaway build out of the cache.

**State is one Docker volume per architecture, and it is capped.** Default 25 GiB
(`nix profile wipe-history` on the builder's own profile, then
`nix store gc --max <excess>`). The cap is soft on purpose: Docker's local driver
has no ext4 quota without project quotas, and a fixed-size loopback image would
turn "store full" into ENOSPC in the middle of an unrelated build.

Be precise about *when* it is enforced: **before every build that goes through
`just`** — `linux-build`, `nixos-build`, `nixos-deploy`. A build delegated
transparently by the nix-daemon through `determinateNix.buildMachines` does
**not** pass through that code and is bounded only by the container's
`min-free`/`max-free`, which govern the OrbStack VM disk rather than this volume.
If you use the transparent route, run `just linux-builder-gc` yourself.

`just gc` sweeps any *running* builder too — a launchd job could not, because the
OrbStack socket belongs to the login session and a 03:00 daemon would fail exactly
when nobody is watching. Stopped builders are skipped, and it says so rather than
exiting quietly.

**Do not copy the Macs' `nix.conf` wholesale into the container.** The two are
not the same machine and three of the tempting settings are wrong here:

- **`download-buffer-size` — leave it alone.** Neither side sets it any more; the Macs
  did set 1 GiB
  (`modules/determinate.nix`); the container's 1 MiB is *the current upstream
  default*, and since the pause-based backpressure landed in Nix 2.33 the release
  notes say raising it is no longer recommended. The Mac's value was the stale one and
  was removed on 02.09.2026 — do not reintroduce it here either.
  It is also not the cause of the slow substitution described below — that is
  per-path latency, not buffer starvation.
- **`auto-optimise-store` — no.** Measured +48 % wall clock on the store-write
  path for ~0.34 GiB saved, and with `sandbox = false` the `.links` inode sharing
  would turn one damaged path into store-wide damage — in the store whose output
  gets signed.
- **`sandbox = true` / `filter-syscalls = true` — impossible, not merely unwise.**
  Both fail outright here; see the seccomp and `pivot_root` notes below.

Six things that are load-bearing and were each measured on this machine:

- **`build-users-group` must be `nixbld`, not empty.** Leaving it empty overrides
  the image's own value, `useBuildUsers()` returns false, and every build runs as
  **root** — no uid isolation between concurrent builds, and the uid half of the
  output-ownership check never runs. Tolerable for a scratch container; not for
  one that signs into the cache serving `p-ion-berlin-xs56r6`. Verified after fixing:
  a probe derivation reports `uid=30001 gid=30000 user=nixbld1`.
- **`build-dir` must be set, and not under `/var/tmp`.** Since Nix 2.30 it no
  longer follows `$TMPDIR`; it defaults to `stateDir/builds` =
  `/nix/var/nix/builds` — *inside the size-capped volume*, where `nix store gc`
  never looks, so a killed build leaks its scratch tree permanently and the cap
  cannot see it. `/var/tmp/nix-build` is the obvious fix and Nix rejects it:
  `Path "/var/tmp" is world-writable or a symlink`. Use `/build`, directly under
  `/` (0755), on the container layer so it dies with the container.
- **`/etc/nix/nix.conf` in the image is a SYMLINK into `/nix/store`**
  (`…-base-system/etc/nix/nix.conf`). Writing to it with `cat >` follows the link
  and mutates a store path. `rm -f` it first, then write a real file.

- **`filter-syscalls = false` is mandatory, not tuning.** Nix wraps every build in
  a seccomp BPF filter and the kernel rejects it under Rosetta: `error: unable to
  load seccomp BPF program: Invalid argument`. Every build fails until it is off,
  and `sandbox = false` alone does not avoid it. The cost is real — that filter is
  what prevents setuid/setgid bits in build outputs.
- **`sandbox = false`, and `sandbox-fallback = false` beside it.** Nix's Linux
  sandbox needs `pivot_root(2)`, which does not appear in Docker's default seccomp
  profile at all — it is denied by the profile's `SCMP_ACT_ERRNO` default, and
  `--cap-add SYS_ADMIN` does *not* re-enable it. A real sandbox would need
  `--security-opt seccomp=unconfined --security-opt systempaths=unconfined
  --cap-add SYS_ADMIN`, or `--privileged`. `sandbox-fallback = false` is the
  important half: the default (`true`) disables the sandbox *silently*.
- **Never run `nix-collect-garbage -d` inside the builder.** It unroots
  `/nix/var/nix/profiles/default`, which is what holds the image's nix and
  coreutils; doing it once left the container unable to run `ls`, and the failure
  surfaced two steps later as `du: command not found`. The builder therefore
  installs its own openssh *and coreutils* into a profile it controls, and gc only
  ever wipes that profile's history.
- **The image ships `root:!` in `/etc/shadow`.** OpenSSH treats a leading `!` as a
  locked account and refuses the login before it ever reads `authorized_keys`
  (`User root not allowed because account is locked`). The entrypoint rewrites it
  to `*`, which blocks password login without meaning "locked".

Two more traps, neither specific to Docker:

- **`path=$(…)` in a zsh recipe destroys `PATH`.** `path` is zsh's array bound to
  `PATH`. The symptom appears lines later as `command not found: zsh` and points
  nowhere near the assignment. The justfile recipes use `outpath`.
- **A published Docker port is not a readiness signal.** Docker's forwarder answers
  for as long as the container runs, so `nc -z` reported the builder "up" 0.5 s
  after start, while it was still installing openssh. `up` waits for a real SSH
  handshake instead, which also proves the keypair is accepted.

**Rosetta executes AVX2 but does not advertise it.** Both halves were measured in
this container, and the pair is the whole point:

```
CPUID leaf1.ecx=0x6ed8320f  ->  avx=0  fma=1 osxsave=1 sse4_2=1
CPUID leaf7.ebx=0x00000108  ->  avx2=0 bmi1=1 bmi2=1 avx512f=0
/proc/cpuinfo flags          ->  no avx, no avx2   (agrees with CPUID)

a binary compiled -mavx2, containing  vpaddd / vpmulld / vpsllvd  on %ymm,
run with values from argv so nothing could be constant-folded:
    ((7+5)*7)<<1  ->  168 168 168 168 168 168 168 168      ✓ correct
```

`vpsllvd` exists only in AVX2, so this is genuine AVX2 execution, and it computes
the right answer. That matches Apple's documentation — Rosetta has translated
AVX/AVX2 since macOS 15 (Sequoia); AVX-512 remains unsupported.

The safety property is the *CPUID* half, not the instruction half. The worst
documented Rosetta defect is a **silent** AVX2 miscompile in `chacha20poly1305`
([golang/go#79205](https://github.com/golang/go/issues/79205), closed as not-Go),
and Go — like OpenSSL and glibc's ifunc resolvers — selects that path by querying
CPUID. CPUID here says no AVX2, so the path is never selected. Reasoning from
`/proc/cpuinfo` instead would reach the same conclusion by luck; reason from CPUID.

What is *not* covered: a package that hardcodes `-mavx2` at build time rather than
dispatching at runtime will execute AVX2 here, and carries whatever correctness
risk Rosetta's AVX2 translation has. nixpkgs targets baseline x86-64, so this is
rare; the known exceptions are `tiledb` and `arrow`/`parquet`.

Nix nonetheless auto-detects `extra-platforms = i686-linux x86_64-v1-linux
x86_64-v2-linux x86_64-v3-linux`, and **both ends of that are false**:

- `i686-linux` is added unconditionally for any x86_64-linux host. Rosetta 2
  translates x86-64 only — there is no 32-bit support.
- `x86_64-v3-linux` *requires* AVX2, which CPUID here denies. Not a Nix bug: Nix
  delegates to libcpuid, whose `decode_architecture_version_x86()` computes
  `has_all_features` and then never reads it, so the level is decided by the
  **last** element of the feature array — which for v3 is `OSXSAVE`, and Rosetta
  does set that (`leaf1.ecx` bit 27). v4 escapes only because its last element is
  `AVX512VL`.

Blast radius today is small (`x86_64-v3-linux` is not a nixpkgs system double),
but a flake requesting it would be accepted, built, **signed and pushed to R2**,
and then SIGILL on any consumer without AVX2. So the entrypoint pins
`extra-platforms` to the builder's own system. Note it is an assignment, so it
*replaces* the detected list; `extra-extra-platforms` would append.

All of this is a measurement of today's OrbStack and macOS, not a guarantee.
Re-run the probe after upgrading either.

The residual risk is not zero. An emulated build lands at the **same** store path
as a native one and is signed with the same key, so a miscompile would enter the
shared cache indistinguishably. To audit a closure, `nix build --rebuild <path>`
on the target: Nix reports differing output for identical input. There are also
open reports of compile-heavy derivations hanging under Rosetta with no known
workaround ([nix-rosetta-builder#28](https://github.com/cpick/nix-rosetta-builder/issues/28));
`nixos-anywhere --build-on remote` and `just cache-seed-remote` remain the way out.

### Why a cold closure substitutes slowly: latency per PATH, not bandwidth

The symptom looks like a bandwidth problem and is not one. Measured
concurrently, same machine, same minute:

| | throughput |
|---|---|
| `curl` inside the container | 10.7 MB/s (85 Mbit/s) |
| `curl` on the host | 10.6 MB/s (85 Mbit/s) |
| `dd` to the `/nix` volume | 961 MB/s |
| `dd` to the container layer | 1.3 GB/s |
| container CPU while substituting | 1.7 % |
| **Nix substitution** | **0.23 MB/s (1.9 Mbit/s)** |

Network, disk and CPU are all idle, so it is none of them — and it is not the
host's WiFi or cache.nixos.org either, since host and container `curl` agree.

**The 0.23 MB/s figure is a byte-rate sampled during a narinfo-heavy phase, not
a transfer ceiling.** Two measurements settle it:

```
nix copy of ONE 48 MB NAR from cache.nixos.org   6.7 s   ≈ curl's 5.2 s
cold substitution of nixpkgs#git                21 s for 84 paths / 356 MB
                                                = ~250 ms PER PATH
```

Bulk transfer runs at curl speed. What costs is the *per-path* round trip, and a
closure is thousands of paths. Narinfo latency, measured from the container:

| substituter | narinfo 200 | narinfo 404 |
|---|---|---|
| `cache.nixos.org` | 117–196 ms | 235 ms |
| R2, **before** the cache rule | 757 ms, `DYNAMIC` | **737–2122 ms** |
| R2, **after** | 115–185 ms, `HIT` | 231 ms mean, never `HIT` |

R2 *was* 4–9× slower because Cloudflare cached nothing for it: `.nar.zst` is a
cacheable extension, `.narinfo` (content-type `text/x-nix-narinfo`) is not, so
every metadata lookup went to the origin. The Cache Rule in `infra/src/index.ts`
fixes that, and R2 is now level with cache.nixos.org.

Two things about that rule are deliberate. **404s are never cached** — we push
to this bucket continuously, and a stale miss would tell every other host to
rebuild a path that already exists. And the ~17 % cost that adding R2 to
`substituters` used to carry (21.5 s → 25.2 s on the `git` closure, cold cache,
measured in both orders) was the origin round trip; it should now be gone,
though that has not been re-measured end to end.

Warm-vs-cold on the same closure isolates the narinfo phase exactly: 12.2 s warm
against 22.6 s cold, i.e. ~10 s for 84 paths ≈ 120 ms/path — which is
`cache.nixos.org`'s measured RTT. The model is self-consistent.

So the fix for "the builder is slow" is **fewer paths**, not more bandwidth. The
`neovim-server` split (modules/neovim.nix) took `p-ion-berlin-xs56r6` from ~9000 paths to
941 for exactly this reason, and that is why it now builds in minutes where the
old closure ran 1 h 37 m without finishing.

Ruled out by measurement or by source, so do not re-propose them:
`download-buffer-size` (1 MiB is the current default and raising it is
explicitly discouraged post-2.33); `http-connections` and
`max-substitution-jobs` (identical on both machines — with one HTTP/2
substituter and `CURLOPT_PIPEWAIT` set unconditionally, all 16 jobs share one
connection anyway); `stalled-download-timeout` (threshold is 1 byte/s and paused
transfers are exempt); retuning `min-free`/`max-free` (auto-GC never fires —
`/nix` has 262 GB available, and it would be deafening at default verbosity).

The R2 side of this has been dealt with (see the table above and
`infra/src/index.ts`). What remains, and is NOT explained, is the ~250 ms per
path against `cache.nixos.org` itself — which is simply a CDN round trip from
here and is not something this repo can shorten. Fewer paths is the only lever
left, which is what the `neovim-server` split was.

In practice the volume absorbs the rest: the cost is paid once per closure, and a
second `nixos-build` of the same host is nearly instant.

**Bumping the image version needs `just linux-builder-destroy` first.** Docker
seeds a named volume from the image only while the volume is empty, so a new
`IMAGE_VERSION` otherwise has no effect at all. `linux-builder-status` compares the
running Nix version against the expected tag and warns rather than staying quiet.

`modules/linux-builder.nix` additionally installs the keypair to
`/etc/nix/linux-builder-ed25519` (root-owned — `ssh` run by the root nix-daemon
rejects a key owned by anyone else) and registers both builders via
`determinateNix.buildMachines`. Like the R2 post-build-hook, that only takes
effect after one daemon restart:

```bash
just daemon-restart      # sudo launchctl kickstart -k system/systems.determinate.nix-daemon
```

After that, a plain `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
works on the Mac — **provided the container is running**. To verify delegation
itself, build something no cache can hold, and watch where the path comes from:

```console
$ just linux-builder-probe
→ building delegation-probe-20260824-135833 for x86_64-linux — watch for 'copying path … from ssh-ng://'
copying path '/nix/store/…-delegation-probe-20260824-135833' from 'ssh-ng://root@nix-linux-builder-x86_64'
/nix/store/…-delegation-probe-20260824-135833
x86_64
Linux
```

The recipe names the derivation after the current second, because an existing
output is reused and proves nothing, and prints the built file so a silent
fallback cannot pass as success. `linux-builder-status` does **not** answer this
question — it only proves the container answers ssh from your own account, not
that the root daemon delegates to it. Do **not** reach for `nix build --rebuild`
here — see the `--rebuild` note in "The IONOS VPS (NixOS)". This module starts
nothing; genuine on-demand start would need a launchd-socket-activated proxy and
was deliberately left out.

One thing is deliberately *not* claimed: whether the R2 `post-build-hook` fires
for paths produced by a **delegated** build (the transparent `nix build` route)
is untested — it has only been verified for local builds. The `just linux-build` /
`just nixos-build` route does not depend on it, because it pushes explicitly. If
you use the transparent route and want the result cached, run
`just linux-push <store-path>` after it, or check `just cache-log` to see whether
the hook ran.

