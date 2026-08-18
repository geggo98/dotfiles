# Repository Guidelines

This file provides guidance to AI coding agents when working with code in this repository.

## Repository Overview

This is a Nix-darwin configuration repository for managing macOS systems (Stefan Schwetschke's personal dotfiles). It uses Nix flakes, flake-parts, nix-darwin, Home Manager, and Determinate Nix for declarative system configuration on Apple Silicon Macs.

The repository follows the **Dendritic Pattern** for Nix flake structure — use the `/nix-dendritic-pattern` skill for detailed guidance on creating and modifying modules.

**Current Hosts:**
- `FCX19GT9XR` - Personal Mac (user: `stefan`)
- `DKL6GDJ7X1` - Work Mac (user: `stefan.schwetschke`)
- `p-ion-berlin-xs56r6` - IONOS Core VPS, `x86_64-linux` (NixOS). Named per
  `infra/Naming.md`; was `ionos-vps` until 2026-08-18. Not a darwin host: it is
  selected by name rather than hardware serial and is **not** applied with
  `just switch`. See "The IONOS VPS (NixOS)" below.

## Build, Test, and Development Commands

A `justfile` provides safe, pre-approved commands that agents can run without user approval. Raw `nix` and `darwin-rebuild` commands require user approval. The **only** exceptions in the justfile are `just switch` / `just switch-host`, which apply the system config with `sudo` — these are for the user to run interactively, not agents. `just switch` is also the *only* supported way to apply the config: it selects the flake attribute by hardware serial, which a bare `darwin-rebuild switch --flake .` cannot do reliably (see "Applying the configuration").

### Safe commands (via justfile, no approval needed)

| Command | Description |
|---|---|
| `just build` | Build current host configuration without applying |
| `just build-host <host>` | Build a specific host (e.g. `just build-host DKL6GDJ7X1`) |
| `just check` | Run `nix flake check` |
| `just fmt` | Format all Nix files with `nixpkgs-fmt` |
| `just fmt-check` | Check formatting without modifying files |
| `just update` | Update all flake inputs |
| `just update-input <input>` | Update a single flake input |
| `just diff` | Build and show package delta vs. current system |
| `just verify-no-diff` | Build and assert no package delta (useful after refactoring) |
| `just deps` | Show flake dependency tree |
| `just eval` | Evaluate flake outputs (fast syntax check) |
| `just show-derivation` | Show derivation of current host build |
| `just gc` | Collect user-level garbage (7 days) and sweep any running Linux builder |
| `just optimise` | Deduplicate the store (hard-link identical files) |
| `just linux-builder-up [arch]` | Start the Docker Linux builder (`x86_64` default, or `aarch64`) |
| `just linux-builder-status [arch]` | Builder state, reported system, store size against its cap |
| `just linux-builder-gc [arch] [gb]` | Sweep the builder's store back under its cap |
| `just linux-builder-down [arch]` | Remove the container, keep the store volume |
| `just linux-build <attr> [arch] false` | Build a flake attribute for Linux — the trailing `false` skips the R2 push |

Four Linux-builder recipes are deliberately **absent** from that list, and the
reason is not that they need sudo:

- `just linux-build` / `nixos-build` **without** `push="false"`, and
  `just linux-push`, read the SOPS R2 write credentials and publish **signed**
  artifacts into the cache both Macs and the VPS substitute from. Combined with
  the fact that an emulated build lands at the same store path as a native one
  (see below), an agent should not push there unsupervised. Build with
  `push="false"` and let a human do the push.
- `just linux-builder-destroy` deletes a Docker volume and the keypair, and
  leaves a stale entry that needs a root `ssh-keygen -R` to clear.
- `just nixos-deploy <host>` activates a production system over ssh. Print it for
  the user instead, like `just switch`.

### New files: stage them before building

**Nix flakes only see git-tracked files.** Newly created files (modules, skill
files, references, templates, secrets — anything under the flake source) are
**invisible** to `nix build`, `just build`, `just eval`, and `darwin-rebuild`
until at least intent-to-added with `git add -N <paths>` (or fully staged with
`git add <paths>`). The flake build silently skips untracked files; the only
hint is the `warning: Git tree '…' has uncommitted changes` line, which fires
even when nothing is wrong.

After creating any new file, run:

```bash
git add -N <new-paths>      # intent-to-add is enough for flake to see them
just build                  # now picks up the new files
```

If a build seems to "ignore" your changes (a new module isn't applied, a new
skill doesn't appear, a new file referenced from a tracked module fails to
load) — check `git status` first. Untracked files are the most common cause.

### Commands requiring user approval

These cannot run inside the agent sandbox or need explicit confirmation:

```bash
# Apply configuration (requires sudo) — see "Applying the configuration" below
just switch

# Dry-run switch (extra args are forwarded to darwin-rebuild)
just switch --dry-run

# Build for a specific host directly
nix build .#darwinConfigurations.DKL6GDJ7X1.system
nix build .#darwinConfigurations.FCX19GT9XR.system

# Show package delta between current and new system
nix store diff-closures /run/current-system result

# Full system-wide garbage collection (prunes the system profile too). Runs
# automatically every week via modules/nix-gc.nix; this is the manual one-off.
sudo nix-collect-garbage --delete-older-than 7d
```

### Applying the configuration

Always apply via **`just switch`**, never a bare `sudo darwin-rebuild switch
--flake .`. A bare `--flake .` lets darwin-rebuild pick the flake attribute from
the current hostname, and macOS transiently renames the host — it appends a `-2`
Bonjour suffix on a name collision — at which point attribute selection breaks
with a confusing "no such attribute" error mid-switch. `just switch` reads the
hardware serial (`IOPlatformSerialNumber`) instead and passes `.#<serial>`
explicitly, which is exactly how host attributes are named. Extra arguments are
forwarded, so `just switch --dry-run` works.

```bash
just switch                       # this host, by serial (drift-safe)
just switch --dry-run             # same, without applying
just switch-host DKL6GDJ7X1       # a specific host, by name
```

Outside the repo directory, the fish function `+darwin-rebuild-switch`
(`modules/shells.nix`) does the same serial lookup against
`~/.config/nix-darwin`.

Agents must not run these — they need `sudo` and are interactive. Print the
command for the user instead.

### The IONOS VPS (NixOS)

`p-ion-berlin-xs56r6` (`87.106.149.208` / `2a01:239:485:8d00::1`, 4 vCore / 4 GB / 120 GB)
is the first non-darwin host.

**Four ways in, and knowing which one you are using matters when something
breaks:**

| Route | Address | Notes |
|---|---|---|
| Public SSH | `87.106.149.208` | real sshd; `deployTarget`, so the only route `just nixos-deploy` uses |
| WireGuard from home | `10.2.0.203` | real sshd; transparent from the home LAN, no client software |
| Tailscale SSH | `100.79.162.28`, MagicDNS `p-ion-berlin-xs56r6.great-fiordland.ts.net` | **not** sshd — userspace, login shell; usable but deliberately not `deployTarget`, see below |
| KVM console | Cloud Panel | GRUB only; root's password is locked |

Each of the first three has a name under the scheme in `infra/Naming.md`, and the
name says which route it is:
`p-ion-berlin-xs56r6.pub.0xf1a5c0.net`, `.muenchen.` and `.tailnet.`.

The MagicDNS name is **not** ours: Tailscale derives it from the OS hostname, so it
moves when the host is renamed, and anything still pointing at the old one resolves to
nothing.

That it moves at all took two lines, because **`networking.hostName` does not rename a
running system.** nixpkgs writes `/etc/hostname` and stops there (the option exists
"for hostnamectl and the org.freedesktop.hostname1 dbus service"), and systemd reads
that file only at boot — so a deployed rename reports success while `hostname` and
tailscaled still answer with the old name. Measured immediately after deploying exactly
that: `hostnamectl` showed `Transient hostname: ionos-vps` beside
`Static hostname: p-ion-berlin-xs56r6`. `modules/nixos-base.nix` therefore also sets
`boot.kernel.sysctl."kernel.hostname"` (nixpkgs' own documented workaround, which
applies on `switch` because `systemd-sysctl.service` has a restartTrigger on the
generated file), and `modules/nixos-tailscale.nix` gives `tailscaled` a restartTrigger
on the hostname so the tailnet follows in the same activation.

The modules: `nixos-base` (sshd, keys, the lockout assertions), `nixos-tailscale`,
`nixos-wireguard-home`, `nixos-secrets` (sops on the NixOS class), composed in
`modules/hosts/p-ion-berlin-xs56r6.nix`, with `configurations.nixos.<host>.deployTarget`
defined by `modules/nixos-wiring.nix`.

**Tailscale SSH is not sshd, and `deployTarget` deliberately does not use it.**
`tailscaled` answers TCP/22 on the tailnet address in userspace, so the kernel
firewall can neither gate nor disable it (`--ssh` is the only control), and it
runs commands through a **login shell** — which means anything that shell prints
lands in the channel.

That last point is what tailscale/tailscale#14093 and #14167 are actually about,
both still open: their logs show `setlocale: … cannot change locale (de_DE.UTF-8)`
warnings immediately before `'nix-store --serve' protocol mismatch`. The shell
spoke into the protocol's channel. Tailscale injects nothing.

Measured here on 2026-08-18, where the locale is generated and the shell is
quiet: `ssh <tailnet-name> /bin/true` returns 0 bytes on stdout,
`nix store info --store ssh-ng://…` succeeds, and a real two-path `nix copy`
completes with exit 0. **So it is a fragility, not an incompatibility** — an
earlier version of this section said the latter and was wrong.

`deployTarget` stays on the public IP for reasons that survive that correction:
nothing enforces that the channel stays quiet, so a future motd, rc file or
ungenerated locale would break deploys with an error pointing at nix rather than
at the cause; and the route used to rescue a host should not depend on a remote
control plane.

**Deploys roll back by themselves.** `just nixos-deploy` arms a transient timer
on the target before switching and disarms it over a second, fresh ssh
connection; if that connection fails, the host restores its previous generation
within `NIXOS_DEPLOY_ROLLBACK_DELAY` (300 s). A failing activation is covered
too. It has fired for real. Two limits: transient units do not survive a reboot,
so a config that only breaks at boot needs the GRUB generation list instead; and
if the deploying machine dies between switch and disarm, the target rolls back
although nothing was wrong.

Four facts about the machine are load-bearing and were each measured on it, not
assumed — get any of them wrong and the box comes back unreachable, with the
Cloud Panel KVM console as the only way in.

- **It boots legacy BIOS, not UEFI.** An ESP exists and Ubuntu mounted it at
  `/boot/efi`, which reads like UEFI — but `/sys/firmware/efi` is absent. The
  disko layout therefore uses a `bios_grub` (EF02) partition and GRUB, and
  **systemd-boot would install cleanly and then never boot**.
- **Do not set `boot.loader.grub.devices`.** disko derives it from the EF02
  partition; setting it too produces `[ "/dev/vda" "/dev/vda" ]` and the grub
  module fails with "You cannot have duplicated devices in mirroredBoots".
- **Networking is DHCP for both families, deliberately.** IPv4 arrives as a
  `/32` with an on-link route to the gateway and IPv6 comes from router
  advertisements. Hand-writing that static layout is the likeliest way to lock
  yourself out, and gains nothing — IONOS assigns the addresses either way.
- **`virtio_*` must be in `boot.initrd.availableKernelModules`.** Root is on
  `/dev/vda` (virtio_blk) on QEMU/KVM; without them the initrd cannot find its
  own root filesystem.

`modules/nixos-base.nix` holds `root`'s authorized SSH keys, copied verbatim
from the Ubuntu install. They are the machine's only remote door — password
authentication is off — so an assertion fails the *build* if the list is ever
emptied, rather than letting the outage happen at reboot. A serial getty on
`ttyS0` is enabled as a second, network-independent route.

**A bare Mac cannot build this host. A Mac with the Docker Linux builder can** —
see "The Linux builder (Docker)" below. `just nixos-build p-ion-berlin-xs56r6` and
`just nixos-deploy p-ion-berlin-xs56r6` are the everyday commands; the rest of this section
is why they are needed at all.

The distinction that causes confusion: these Macs can *substitute* any
x86_64-linux path that exists in a cache, so `nix build
nixpkgs#legacyPackages.x86_64-linux.ponysay` succeeds and looks like a build. It
is not one — check the output, every line is `copying path … from`. Force an
actual build and, with no builder configured, the truth appears:

```console
$ nix build --rebuild nixpkgs#legacyPackages.x86_64-linux.ponysay
error: Cannot build '…-ponysay-….drv'.
       Reason: platform mismatch
       Required system: 'x86_64-linux'
       Current system: 'aarch64-darwin'
```

The two obvious remedies are still closed:

- **nix-darwin's `nix.linux-builder`** requires `nix.enable`, which this repo
  sets to `false` because Determinate manages Nix
  ([nix-darwin#1505](https://github.com/nix-darwin/nix-darwin/issues/1505)).
  Under `nix.enable = false`, reading a `nix.*` **default** throws, and — worse —
  an explicitly *set* `nix.buildMachines` does not throw at all: nix-darwin's
  whole `managedConfig` block, `environment.etc."nix/machines"` included, sits
  under `mkIf cfg.enable`, so the setting is **silently dropped**. That is also
  why `nix-rosetta-builder` cannot be used unmodified — it would appear to work.
- **Determinate's own Linux builder** is declared in `modules/determinate.nix`
  but inert. Measured on FCX19GT9XR: `determinate-nixd version` lists only
  `lazy-trees` as enabled, while the binary's feature list is `lazy-trees
  parallel-evaluation provenance native-linux-builder`, and it carries the
  refusal in plain text — *"The Native Linux Builder is not currently available.
  Contact support@determinate.systems"*. `determinate-nixd status` says
  `Authentication: logged-out` and `/nix/var/determinate/netrc` is 1 byte.
  `builder.state = "enabled"` in `/etc/determinate/config.json` is the request,
  not the grant.

What is *open* is the third door: **`determinateNix.buildMachines`**. Determinate's
nix-darwin module defines it as a full submodule and writes `/etc/nix/machines`,
and Nix's `builders` default is already `@/etc/nix/machines`. That is the hook
`modules/linux-builder.nix` hangs on. Note `determinateNix.distributedBuilds`
must also be `true` — its default is `false`, and then the module only warns
("build machines aren't configured") while delegating nothing.

Fallbacks remain and are not deprecated: installs still use `nixos-anywhere
--build-on remote`, and `just cache-seed-remote root@<host>` still adopts
whatever a host built on its own — the workstation reads the paths out of the
server's store, signs them locally and uploads, so the R2 *write* key never
leaves the Mac.

An option still not taken: registering the VPS itself as a remote builder. That
would work, but it makes a production host into build infrastructure — decide
deliberately rather than by drift.

`nix flake check` is unaffected by any of this: it reports x86_64-linux as an
"incompatible system" and skips it, so `just check` still passes on a Mac.

Initial install (destroys the disk). Done on 2026-08-17; kept because it is also
the recovery procedure:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#p-ion-berlin-xs56r6 --build-on remote --target-host root@87.106.149.208
```

Deliberately *not* preceded by a Cloud Panel Image: image storage on this tariff
costs more than the server, and "Image neu installieren" restores a stock distro
for free — which is all a snapshot of this machine would have preserved anyway.

#### The SSH key lives in 1Password, and its agent config is not in this repo

`modules/nixos-base.nix` authorises `SHA256:YEUc7NtEQhufJSJroPQqWBvEULURYRJSiC9cKWJKgiE`,
whose private half never touches a disk: 1Password holds it in the vault
**`Homelab`** and releases it through its SSH agent behind Touch ID.

**That only works if the agent is told to expose that vault.** The file saying
so is **`~/.config/1Password/ssh/agent.toml`**, and it is now generated by
`modules/onepassword.nix` (imported from `home-manager-base`, so both
workstations get it):

```toml
[[ssh-keys]]
vault = "Persönlich"

[[ssh-keys]]
vault = "Homelab"
```

**To add a vault, edit the `vaults` list in `modules/onepassword.nix`** and
`just switch` — not the file, which is a `/nix/store` symlink and is replaced on
every activation (`force = true`, because both Macs had a hand-written file
there first).

Why it is worth managing at all: **without this file the agent offers keys from
the personal vault ONLY.** A key kept anywhere else is never offered, and the
resulting failure looks like a server problem. 1Password does not sync this
file, so every new Mac starts without it. Three things were checked before
putting a read-only symlink there: 1Password only reads the file (its mtime
survived half an hour of the agent loading keys and signing), changes are picked
up with no restart, and nothing documents a requirement on permissions or on it
being a real file. If 1Password ever gains a UI that *writes* it, this module
has to go — the symptom would be settings silently reverting on activation.

The failure mode to recognise: **SSH to the VPS suddenly stops working, on a
machine where nothing about the VPS changed** — after a 1Password update, a
reinstall, a new Mac, or a vault rename (the names above are display names).
The server is fine; the agent is not offering the key. Diagnose on the client,
not the host:

```bash
# What is the agent actually offering?
SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock ssh-add -l
# Expect: SHA256:YEUc7NtEQhufJSJroPQqWBvEULURYRJSiC9cKWJKgiE  p-ion-berlin-xs56r6 SSH-Key (ED25519)
# Match on the fingerprint, not the title — the title is a 1Password item name that
# nothing keeps in step with this repo (it read p-ion-ber-xs56r6 until 2026-08-18).

# Is the key even being offered to the server?
ssh -v root@87.106.149.208 true 2>&1 | grep -E 'Offering|Server accepts'
```

**A different symptom, with a misleading message.** If the key IS offered but
authentication still fails:

```
sign_and_send_pubkey: signing failed for ED25519 "p-ion-berlin-xs56r6 SSH-Key"
                      from agent: communication with agent failed
```

the agent is not broken. It offered the key and then refused to *sign*, which
with a 1Password-held key almost always means **a Touch ID prompt nobody
answered**. Measured afterwards: once authorised, signing takes 0.6–1.2 s and is
reliable over both the public address and the tunnel, so a failure here is about
the prompt, not about speed or configuration.

`BatchMode=yes` does NOT cause this and does not suppress the prompt — verified
directly. The dialog comes from the 1Password app, out of band; ssh never sees it.

This is why `just nixos-deploy` opens a throwaway `ssh … true` **before** the
build rather than only after it. The first signature used to be requested
minutes in, once the build and the R2 upload had finished and attention had
moved elsewhere — precisely when a dialog gets missed. The preflight also turns
"host is down" and "wrong key" into 15-second failures instead of failures after
a full build.

If the key is missing from `ssh-add -l`, fix `agent.toml` — 1Password picks the
change up immediately, no restart needed (measured). Two adjacent traps:

- **`~/.ssh/config` is hand-maintained too** and carries the global
  `IdentityAgent` line pointing at that socket. home-manager's `programs.ssh`
  would overwrite the whole file, which is why it is deliberately not used here.
- **`MaxAuthTries` is 6**, counting file-based identities. The vaults are offered
  in `agent.toml` order; if `Homelab` grows, a host can start failing because the
  right key is never reached. The fix is a per-host block with `IdentityFile` +
  `IdentitiesOnly`, not reordering the vaults.

Until the pre-existing `stefan@FCX19GT9XR` file key is removed from
`rootAuthorizedKeys`, a broken agent is merely an annoyance — ssh falls through
to `~/.ssh/id_ed25519`. After that removal it is the difference between logging
in and reaching for Tailscale SSH or the KVM console.

#### Getting back in when SSH is gone

`root`'s password is **locked** (`passwd -S root` → `L`) and
`PasswordAuthentication` is off. That is deliberate, and it means **the KVM
console cannot be logged into**: it will show a login prompt that no password
satisfies. The console is still the way back, but only through GRUB:

1. Cloud Panel → server → *Aktionen* → *Remotekonsole öffnen*.
2. Reboot the machine (*Aktionen* → *Neu starten*) and catch the GRUB menu.
3. Press `e` on the NixOS entry, append `init=/bin/sh` to the `linux` line,
   `Ctrl-X` to boot. That yields a root shell with no authentication.
4. `mount -o remount,rw /` then repair — usually
   `/nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch`
   to roll back to a previous generation, which GRUB also offers directly under
   "NixOS - All configurations".

Rolling back via the GRUB generation list is the quicker fix for a bad config
and needs no shell at all. `init=/bin/sh` is for the cases where the filesystem
or the bootloader itself is the problem.

**Tested end to end on 2026-08-17**: booted generation 1 from the submenu via
the KVM console and confirmed it (root's shell was `bash`, fish and nvim
absent), then a plain reboot returned to the default. Selecting an entry is a
one-shot boot — `/nix/var/nix/profiles/system` is not repointed — so the dry run
is harmless and worth repeating after any change to the bootloader.

Two things that dry run established, both non-obvious:

- **The console does deliver arrow keys.** Worth knowing, because the first
  attempts looked like it did not: the keys arrived *after* boot and showed up
  as a row of `^[[B` at the login prompt.
- **`boot.loader.timeout` had to be raised to 30 s** (`modules/hosts/p-ion-berlin-xs56r6.nix`).
  NixOS' 5 s default does not survive the console's round-trip latency — by the
  time a screenshot comes back and a keypress goes out, the menu is gone. Send
  keypresses *blind* on a timer rather than reacting to what you see: any
  arrow key stops the countdown, and once stopped the menu waits indefinitely,
  so navigate deliberately only after that.

Third route if both fail: *Aktionen* → *Image neu installieren*, or booting one
of the ISO rescue systems (Grml, Gparted, Clonezilla) to inspect the disk
without wiping it.

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

- **`download-buffer-size` — leave it alone.** The Macs set 1 GiB
  (`modules/determinate.nix`); the container's 1 MiB is *the current upstream
  default*, and since the pause-based backpressure landed in Nix 2.33 the release
  notes say raising it is no longer recommended. The Mac's value is the stale one.
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
sudo launchctl kickstart -k system/systems.determinate.nix-daemon
```

After that, a plain `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
works on the Mac — **provided the container is running**. This module starts
nothing; genuine on-demand start would need a launchd-socket-activated proxy and
was deliberately left out.

One thing is deliberately *not* claimed: whether the R2 `post-build-hook` fires
for paths produced by a **delegated** build (the transparent `nix build` route)
is untested — it has only been verified for local builds. The `just linux-build` /
`just nixos-build` route does not depend on it, because it pushes explicitly. If
you use the transparent route and want the result cached, run
`just linux-push <store-path>` after it, or check `just cache-log` to see whether
the hook ran.

## Architecture

### Dendritic Pattern with flake-parts

This repository uses the **Dendritic Pattern**: every file in `./modules/` is a flake-parts module organized by feature (aspect), not by configuration class. The `/nix-dendritic-pattern` skill provides full documentation on this pattern.

### Entry Point
- **`flake.nix`** - Uses `flake-parts.lib.mkFlake` and auto-imports all modules via `import-tree ./modules`

### Module Structure (`modules/`)

Each module defines a single aspect across all relevant configuration classes (darwin, homeManager, etc.) using `flake.modules.<class>.<name>`.

| Module | Description |
|---|---|
| `flake-parts.nix` | Registers `flake-parts.flakeModules.modules`, sets target systems |
| `darwin-wiring.nix` | Defines `configurations.darwin` option and wires it to `flake.darwinConfigurations` |
| `macos.nix` | macOS-specific defaults (dock, finder, trackpad, system preferences) via `flake.modules.darwin.macos` |
| `determinate.nix` | Determinate Nix module settings (`nix.enable = false`) via `flake.modules.darwin.determinate` |
| `nix-cache.nix` | Shared Cloudflare R2 Nix binary cache — substituter + signed `post-build-hook` push — via `flake.modules.darwin.nix-cache`. Bucket/domain provisioned in `infra/`; details in `infra/README.md` |
| `linux-builder.nix` | Registers the Docker Linux builders with the daemon via `determinateNix.buildMachines` + an `ssh_config` alias, and installs the root-owned builder key. See "The Linux builder (Docker)" |
| `homebrew-common.nix` | Shared Homebrew configuration via `flake.modules.darwin.homebrew` |
| `shells.nix` | Shell configuration (Fish, Zsh, Bash) via `flake.modules.homeManager.shell` |
| `git.nix` | Git configuration via `flake.modules.homeManager.git` |
| `neovim.nix` | Neovim (nvf) in two variants: `homeManager.neovim` (workstation, every `languages.*` enabled) and `homeManager.neovim-server` (same editor, no language toolchains). See "Neovim: why there are two variants" |
| `packages.nix` | Common packages via `flake.modules.homeManager.packages` |
| `mcp-servers.nix` | Claude Code MCP server wrappers via `flake.modules.homeManager.mcp-servers` |
| `secrets.nix` | SOPS secret declarations and per-host secret merging (**home-manager only** — servers use `nixos-secrets.nix`) |
| `nixos-wiring.nix` | Defines `configurations.nixos` (module + `deployTarget`) and wires it to `flake.nixosConfigurations` and `flake.deployTargets` |
| `nixos-base.nix` | Baseline for every NixOS host: sshd, root's authorized keys, the lockout assertions, serial getty, nix settings, GC |
| `nixos-tailscale.nix` | Tailscale with Tailscale SSH via `flake.modules.nixos.tailscale`. Answers :22 in userspace, so not sshd and not firewall-gateable — see "The IONOS VPS" |
| `nixos-wireguard-home.nix` | WireGuard to the home FRITZ!Box via `flake.modules.nixos.wireguard-home`. Proxy-ARP addressing, so the LAN reaches the host without NAT |
| `nixos-secrets.nix` | sops-nix on the **nixos** class — decrypts to `/run/secrets/` with a key generated on the host itself |
| `misc.nix` | Key remapping, Hammerspoon, misc home config |
| `onepassword.nix` | Generates `~/.config/1Password/ssh/agent.toml` — which vaults the SSH agent may offer keys from. Without it, personal vault only |
| `aichat.nix` | AI chat tool configuration |
| `ai-tools.nix` | AI tool packages and configuration |
| `boundary.nix` | HashiCorp Boundary PM2-managed proxies (work host) |
| `vault.nix` | HashiCorp Vault configuration |
| `overlays.nix` | Nixpkgs overlays |
| `formatter.nix` | `nix fmt` formatter configuration |

### Host Definitions (`modules/hosts/`)

Each host is a flake-parts module that composes aspect modules:

- **`modules/hosts/FCX19GT9XR.nix`** - Personal Mac: imports `darwin.{macos,determinate,homebrew}` and `homeManager.{shell,git,neovim,mcp-servers,aichat,ai-tools,packages,misc,secrets-FCX19GT9XR}`
- **`modules/hosts/DKL6GDJ7X1.nix`** - Work Mac: same pattern plus `homeManager.{boundary,vault}`

Host-specific secrets declarations live in **`hosts/<serial>/secrets.nix`**.

### Key Architectural Decisions

- **Value sharing:** Through `let` bindings and `config.flake.modules` — never through `specialArgs`
- **Module type:** Uses `deferredModule` type for beneficial merge semantics
- **Auto-import:** `import-tree ./modules` auto-discovers all module files
- **Nix management:** Determinate Nix manages the Nix installation, not nix-darwin's built-in `nix.enable`
- **SIP restriction:** `launchd.envVariables` is blocked by macOS System Integrity Protection. To set environment variables for GUI apps (e.g. PATH), use a `launchd.user.agents` entry that runs `/bin/launchctl setenv` at login instead
- **launchd jobs get no shell environment:** the converse of the SIP restriction above. An agent or daemon inherits only `PATH`, `SSH_AUTH_SOCK` and the XPC keys — never what `programs.fish.interactiveShellInit`, `home.sessionVariables`, or a hand-edited rc file exports (verify with `launchctl print gui/$(id -u)/<label>`). Anything scheduled must therefore bake its inputs in at build time or receive them through `launchd.agents.<name>.config.EnvironmentVariables`, and must never fall back **silently** when one is missing. Worked example: `modules/nix-tarball-cache-repack.nix` resolves `${XDG_CACHE_HOME:-$HOME/.cache}/nix/tarball-cache-v2` exactly as Nix's `getCacheDir()` does, so exporting that variable from the shell alone would leave Nix writing to one directory while the agent repacks another — and its miss branch exits 0, which reads exactly like success. It forwards the variable when `xdg.enable` is set (the same condition home-manager uses to export it) and warns loudly, naming the variable, when the resolved directory is empty. `modules/nix-cache.nix` sidesteps the same class of bug for the root `post-build-hook` by passing `NIX_CACHE_SECRETS_DIR` and an explicit `PATH`
- **Binary cache (R2):** both hosts share a Cloudflare R2 cache (`modules/nix-cache.nix`). Pull is a public custom-domain substituter; push is a signed `nix copy` (root `post-build-hook`, or `just cache-seed`/`cache-push`). The hook is referenced by the **stable** `/run/current-system/sw/bin` path, but Determinate's `nix-daemon` reads the hook setting only at startup and `darwin-rebuild switch` does **not** restart it — after first enabling the cache, run `sudo launchctl kickstart -k system/systems.determinate.nix-daemon` (or reboot) once. Push credentials: `r2_secret_access_key` stores a Cloudflare API token (`cfat_…`) whose SHA-256 the push script derives as the S3 secret

## Coding Style & Naming Conventions

- **Indentation:** 2 spaces
- **Attribute sets:** Keep alphabetized within logical groups
- **Host naming:** see "Host and DNS naming" below — Macs mirror their serial exactly
  (`FCX19GT9XR`, `DKL6GDJ7X1`), everything else follows the scheme in `infra/Naming.md`
- **Format before committing:** `just fmt` or `nix run nixpkgs#nixpkgs-fmt -- <files>`
- **Module pattern:** Each module file exports `flake.modules.<class>.<name>` — see `/nix-dendritic-pattern` skill

### Host and DNS naming

The full rule, with the evidence behind each part of it, is **`infra/Naming.md`**. It is
enforced by `infra/src/inventory.ts`, which validates every name when the module loads —
a malformed name breaks `tsc` and `pulumi preview` rather than reaching a zone file.

```
p-<provider>-<site>-<rand6>     physical    p-ion-berlin-xs56r6, p-own-muenchen-j5jghb
[vc]-<arch>-<rand6>             VM / container   v-amd64-k9y25p, c-arm64-h6pedq
<SERIAL>                        Macs, exempt     FCX19GT9XR, DKL6GDJ7X1
```

Physical machines carry where they stand; virtual ones carry the only thing migration
cannot change. The **virtualization ecosystem is deliberately absent** from names —
`virt-v2v` moves guests between VMware/Xen/Hyper-V and KVM, and Proxmox, libvirt and
Incus VMs are all QEMU/KVM, so it is the most movable layer there is. It lives in the
inventory instead. The type letter carries VM-vs-container because *that* is the
boundary with no conversion path: a container supplies a root filesystem, a VM needs a
bootable disk.

DNS puts the network in the label, so a name never means "it depends where you ask":

```
<name>.pub.0xf1a5c0.net        <name>.tailnet.0xf1a5c0.net        <name>.muenchen.0xf1a5c0.net
```

Services are CNAMEs onto machine names, one per realm — so a role moving costs one line,
not a rename. **`0xf1a5c0.net` is the machine domain, `schwetschke.dev` the published
one.** That split is technical: the FRITZ!Box strips private addresses out of public DNS
answers (measured — `dig @10.2.0.1 10.2.0.203.nip.io` is empty where `@1.1.1.1` answers),
and the rebind exception that re-enables them is granted per domain. Measured against
the live records, the FRITZ!Box answered **NXDOMAIN** for the whole name while the `pub`
name on the same path resolved — and **MagicDNS was not an escape**: it forwards to the
system's other resolvers, the FRITZ!Box among them, and returned the AAAA but not the A.
A half-answer is worse than none, because the failure then depends on whether the caller
can use IPv6.

The exception is entered under *Heimnetz → Netzwerk → Netzwerkeinstellungen →
DNS-Rebind-Schutz*, and **the bare domain covers the whole subtree** — AVM's text asks
for the "vollständigen Hostnamen", but `0xf1a5c0.net` alone was measured to cover
`<name>.<realm>.0xf1a5c0.net`. It does not take effect immediately: the box serves its
earlier denial until the zone's negative TTL expires (1800 s here). `just infra-verify`
checks this against the LAN resolver directly and reads the remaining TTL out of the
SOA, so a cache is never reported as a missing exception.

Both `0xf1a5c0.net` and `schwetschke.dev` are listed there, on purpose, and the list is
recorded in `infra/src/inventory.ts` under the Munich site because a factory reset takes
it with it. What makes an exception safe is who may publish names in the zone, not what
else the zone carries — rebind protection exists to stop a name *someone else* controls
from resolving into the LAN, and neither of these is such a zone.

Two exceptions, both deliberate: `nix-cache.pub.schwetschke.dev` does not move (its
signing key is named after it, and that name is in every narinfo signature already
shipped), and `pub` stays short for the same reason.

### Script style (shell, Python, regex)

macOS ships a BSD userland. GNU tools exist only inside the devenv shell or under
`g`-prefixed names, and are on `PATH` only if someone installed them. Anything that
runs outside a Nix wrapper must not assume either flavour.

- **Short scripts → zsh** (`#!/bin/zsh`), not bash. zsh is the macOS default login
  shell and a current release; `/bin/bash` is frozen at 3.2 (2007), so no associative
  arrays, `${var@Q}`, `readarray`, or `wait -n`. zsh also does not word-split
  unquoted parameters, which removes a whole class of quoting bugs.
- **Longer scripts → `python3` with a PEP-723 `uv` header**, stdlib-preferred. Once a
  script grows argument parsing, JSON handling, or more than a couple of branches, the
  shell version stops being readable or testable. See "uv-based skill scripts" below
  for the `--frozen` and lockfile rules.
- **Prefer a `perl` one-liner to `sed` / `awk` / `grep` / `cut` / `tr`** wherever
  performance allows. Perl is in the macOS base system, implements `-i`, `-n`, `-p`
  and PCRE itself, and behaves identically on macOS and Linux. The alternatives all
  diverge between BSD and GNU. Reach for the GNU tool only when data volume makes
  Perl's throughput or startup the bottleneck.

  | Instead of | Write |
  |---|---|
  | `grep -o` / `sed -n 's/…/\1/p'` | `perl -ne 'print $+{x} if /(?<x>…)/'` |
  | `sed -i'' -e 's/a/b/'` | `perl -i -pe 's/a/b/'` |
  | `awk -F'\t' '{print $4}'` | `perl -F'\t' -lane 'print $F[3]'` |
  | `grep -c` | `perl -ne '$n++ if /…/; END { print $n // 0 }'` |

  The `sed` row is not hypothetical: BSD `sed` reads `-i'' -e` as "backup extension
  `-e`" and silently leaves a stale `file-e` beside the real one. Perl implements
  `-i` itself, so the divergence is gone at the root rather than worked around. See
  the comment on the `brew-bump` recipe in the `justfile`.

- **Regex: named capture groups** wherever the syntax supports them — `(?<name>…)`
  with `$+{name}` in Perl, `(?P<name>…)` with `m["name"]` in Python. The name is free
  documentation, and the pattern keeps working when someone inserts a group ahead of
  it. Fall back to positional `$1`/`\1` only where there is no named form (POSIX
  BRE/ERE, `sed`, bash's `BASH_REMATCH`).
- **Regex: complex patterns go multi-line and commented** — `/x` in Perl,
  `re.VERBOSE` in Python — once a pattern carries more than one capture, a
  lookaround, or an alternation that no longer fits on one readable line.
- **Regex: always show a concrete example** of a line the pattern must match, in a
  comment directly above it. It lets the next reader check the pattern without
  running it, and it is the first thing to update when the input format drifts.

  ```perl
  # matches:     url = "github:Homebrew/brew/6.0.17";   ->  $+{tag} eq "6.0.17"
  m{^ \s* url \s* = \s* "github:Homebrew/brew/(?<tag>[^"]+)"; \s* $}x
  ```

- **Carve-out — `pkgs.writeShellApplication` stays bash.** It is a bash-only
  nixpkgs builder with no zsh counterpart, and what it buys is worth the exception:
  `shellcheck` runs over the source, `set -euo pipefail` is injected, and every tool
  in `runtimeInputs` resolves to a pinned store path, so the BSD/GNU question is
  settled at build time. ~20 call sites (`modules/mcp-servers.nix`,
  `modules/vault.nix`, `modules/nix-tarball-cache-repack.nix`, …) rely on this.
- **Other Nix-built scripts use zsh.** `writeShellScriptBin` hardcodes bash and gives
  none of the above, so prefer `writeTextFile` with an explicit
  `#!${pkgs.zsh}/bin/zsh` — pinned, not `/bin/zsh`, so the interpreter is fixed like
  every other tool. See `mkZshScript` in `modules/nix-cache.nix`.
- **`justfile` shebang recipes use `#!/bin/zsh`** + `set -euo pipefail` (zsh accepts
  it verbatim), and follow the perl and regex rules above for text processing.
  Non-shebang recipes still run under just's default `sh -cu`.

  **When converting bash → zsh, the trap is word splitting.** zsh does *not* split
  unquoted parameters — the property this whole section praises it for — so any code
  that relied on `$VAR` expanding to several arguments silently collapses to one.
  Use `${=VAR}` there. It bit the R2 post-build hook, whose `$OUT_PATHS` is a
  space-separated path list; measured, `V="x y z"; set -- $V` gives `argc=1` under
  zsh against `3` under bash. Everything else in this repo converted unchanged —
  `read -r a b c <<<`, arrays with spaces, `"${arr[@]}"`, empty arrays under
  `set -u`, globs in `[[ ]]`, and `[[ =~ ^[0-9a-f]{64}$ ]]`.

## Commit & Pull Request Guidelines

Use Conventional Commits: `type(scope): subject` (imperative present tense, ≤72 chars)

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Common scopes:** `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`

**Examples:**
- `feat(home): Add Claude Code MCP servers for Atlassian and Context7`
- `fix(darwin): Correct Emoji & Symbols keyboard shortcut`
- `chore(flake): Update nixpkgs to 25.11`

Include host IDs and commands executed in commit body when relevant. Iterate with fixups (`git commit -m "fixup! …"`); run `git push --dry-run` and wait for explicit approval before pushing.

**`Co-Authored-By` trailer (Claude Code):** Use only the generic form — `Co-Authored-By: Claude <noreply@anthropic.com>`. Do **not** embed a specific model name, version, or context label (e.g. `Claude Opus 4.7 (1M context)`): Claude's content-integrity guardrail may block such trailers as impersonation of a "fabricated model". The block is non-deterministic (observed: the same string passed in one turn and was rejected in another), so even "it worked last time" is not a safe signal. The generic form always passes.

## Secrets & Configuration Tips

- **Location:** `secrets/secrets.enc.yaml` (global), `hosts/<serial>/secrets.enc.yaml` (per-host)
- **Decryption keys:** SSH Ed25519 key at `~/.ssh/id_ed25519_sops_nopw` (passwordless)
- **Secrets declaration:** In `modules/secrets.nix` and `hosts/<serial>/secrets.nix`
- **Critical note:** SOPS does not work in the agent sandbox — ask the user to edit secrets manually
- **Edit command:** `sops edit secrets/secrets.enc.yaml` — **no `env` prefix.**
  `SOPS_AGE_SSH_PRIVATE_KEY_FILE` is already exported from `home.sessionVariables`
  (`modules/shells.nix`), so sops finds the identity on its own. The
  `env SOPS_AGE_KEY=$(ssh-to-age …)` form this file used to prescribe was not
  merely redundant, it was broken: it passed the literal `{/Users/stefan}/.ssh/…`.
  See the comment on the `+sops-*` abbreviations in `modules/shells.nix`, which
  has been correct about this for longer than this section has.
- **Changing recipients:** after editing a rule in `.sops.yaml`, existing files
  are NOT re-encrypted automatically — `sops updatekeys -y <file>`. Without `-y`
  it asks `Is this okay? (y/n)` and dies on `EOF` when run without a terminal.
- Ensure new secrets are declared with explicit paths and modes; avoid committing derived plaintext files
- When provisioning a new machine, confirm the correct host serial directory under `hosts/` before switching

## Common Patterns

### Adding a New Module

Use the `/nix-dendritic-pattern` skill for guidance. In short:

1. Create `modules/<aspect>.nix`
2. Export `flake.modules.<class>.<name>` (e.g. `flake.modules.homeManager.my-feature`)
3. Import the module in the relevant host file(s) under `modules/hosts/<serial>.nix`

### Adding a New Host

1. Create `modules/hosts/<serial>.nix` composing existing aspect modules
2. Create `hosts/<serial>/secrets.nix` for host-specific secret declarations
3. The host is auto-discovered via `import-tree`

### Adding a New Secret

1. User edits secrets with `sops edit secrets/secrets.enc.yaml` (no `env` prefix —
   see "Secrets & Configuration Tips" above)
2. Add secret declaration in `modules/secrets.nix` or `hosts/<serial>/secrets.nix`
3. Access via `config.sops.secrets.<name>.path` in configurations

**On the NixOS class it is a different module and a different identity.**
`modules/secrets.nix` is home-manager only. Servers use
`modules/nixos-secrets.nix`, which decrypts to `/run/secrets/<name>` for system
services rather than into a home directory, and authenticates with a dedicated
key generated *on the host* (`/var/lib/sops-nix/ssh_ed25519_sops`) rather than
the SSH host key — the host key is regenerated by a reinstall, which would make
every secret unreadable exactly when things are already going wrong.

Two traps, both paid for once:

- **List the `age1…` conversion in `.sops.yaml`, not just the `ssh-ed25519`
  form.** sops-nix converts the SSH key to an age X25519 identity, and that
  cannot open an `ssh-ed25519` recipient stanza. Symptom at activation:
  `failed to decrypt …: Error getting data key: 0 successful groups required,
  got 0`. The conversion is printed in the same log
  (`Imported … as age key with fingerprint age1…`), so read it there rather than
  deriving it. Every rule in `.sops.yaml` carries both forms for this reason.
- **`just nixos-eval` does not catch a missing secret.** sops-nix validates that
  a declared key exists in the encrypted file at *activation*, not at evaluation,
  so a configuration referencing a secret nobody encrypted evaluates perfectly
  and then fails the deploy. To check before deploying, compare the declarations
  in `hosts/<host>/secrets.nix` against the top-level keys of
  `hosts/<host>/secrets.enc.yaml`.

### Adding an MCP Server

1. Add shell wrapper and server entry in `modules/mcp-servers.nix` (follow existing patterns)
2. Ensure secret loading logic uses `$XDG_CONFIG_HOME/sops-nix/secrets`

### Updating flake inputs

- **nvf variants:** `modules/neovim.nix` exports `neovim` *and* `neovim-server`,
  built from a shared `common` plus a `workstation` overlay. When adding a
  plugin, decide which of the two it belongs in — anything with a language
  toolchain, a second editor, or a desktop assumption behind it goes in
  `workstation`. `common` must never gain anything of its own, or both hosts
  change at once. The header comment in that file gives the two commands that
  verify the workstation is unaffected (compare *content*, not the system
  `drvPath` — splitting the module shifts one entry in `home.packages` and moves
  the hash without changing what is installed).

- **nvf (Neovim):** Before bumping the `nvf` input (`modules/neovim.nix`), **check
  the nvf release notes** for breaking option renames/removals:
  <https://github.com/NotAShelf/nvf/tree/main/docs/manual/release-notes> (e.g.
  `rl-0.9.md`). nvf changes `vim.*` option paths between releases (language
  modules, `lsp.presets.*`, removed plugins), and these surface as eval errors.
  Cross-reference `programs.nvf.settings` in `modules/neovim.nix` against the
  notes before building.

- **Pulumi provider SDKs (`infra/package.json`):** pinned in **two** places, and npm is
  not the authority. Nix's `pulumi-bin` ships a fixed set of provider *plugins* in its
  `bin/` directory, and those are what actually talk to the cloud API — the npm
  `@pulumi/<provider>` package is only the typed client. Taking npm `latest` therefore
  desynchronises them and Pulumi warns: `resource plugin cloudflare is expected to have
  version >=6.19.0, but has 6.17.0`. Pin each provider SDK with `~` to the plugin
  version Nix provides, so patches are allowed but the minor cannot drift:

  ```bash
  # the authority — read the versions Nix actually ships, then match package.json
  for f in "$(dirname "$(readlink -f "$(command -v pulumi)")")"/pulumi-resource-*; do
    printf '%-34s %s\n' "$(basename "$f")" "$("$f" --version 2>/dev/null | head -1)"
  done
  ```

  To move a provider forward, bump `nixpkgs-unstable` (which carries `pulumi-bin`)
  first, re-read the plugin versions, then raise `infra/package.json` to match. Note
  `@pulumi/pulumi` itself is the core SDK, not a plugin, and is not part of this
  coupling.

- **agent-browser:** pinned in **two** places. Bump the `agent-browser-src` tag in
  `flake.nix` (that tag is also where the version comes from — it is read out of the
  input's `package.json`), then run `just agent-browser-hashes <version>` and paste the
  printed `assets` attrset into `modules/agent-browser.nix`, then `just build`. Do
  **not** switch back to `nixpkgs-llm-agents.agent-browser` or `nixpkgs.agent-browser`
  without re-checking the pnpm dashboard FOD: it resolves time-dependently (pnpm
  `minimumReleaseAge`) and drifts off its pinned hash on its own. The release binary
  carries no skill bodies, so `modules/agent-browser.nix` points
  `AGENT_BROWSER_SKILLS_DIR` at `$out/skill-data` copied from the same tag — keep those
  two in sync or `agent-browser skills get` breaks.

- **Gram editor — cask, deliberately not nixpkgs.** Gram (Zed fork, replaced the `zed`
  cask) comes from the `gram` homebrew cask. nixpkgs *does* ship a working
  aarch64-darwin `gram`, and it is cached — but its darwin build symlinks a full `git`
  into the app bundle, which drags `python3 → clang → llvm → apple-sdk` and yields a
  **1.8 GiB closure** for a ~130 MiB app. `gram.override { git = gitMinimal; }` would
  cut ~1.3 GiB of that, but changes the store path and so forces a source build of a
  Zed-sized Rust tree (hours). Re-check this trade-off before moving Gram to nixpkgs.
  The theme in `modules/_files/gram/turbo-vision.json` *is* Nix-managed
  (`modules/gram.nix`) — a port of the VS Code theme
  (`modules/_files/vscode/turbo-vision-color-theme.json`); Gram consumes Zed's
  `zed.dev/schema/themes/v0.2.0.json` format verbatim. Gram's `settings.jsonc` is
  intentionally left unmanaged — Gram writes UI settings back to it.

### uv-based skill scripts (lockfiles + the read-only Nix store)

Some skill helpers under `modules/ai/_files/skills/*/scripts/` are self-contained
`uv` scripts (PEP-723 `# /// script` header) invoked from a thin zsh wrapper via
`gtimeout … script.py`. Two rules keep them working once deployed:

- **Always run with `--frozen`.** The shebang must be
  `#!/usr/bin/env -S uv --quiet run --frozen --script`. Deployed skill files land
  in `/nix/store` (**read-only**), so any attempt by `uv` to *update* the lockfile
  at runtime fails. `--frozen` reads the lock without writing it.
- **Commit the lockfile.** Each such script ships a sibling `script.py.lock`
  (generated with `uv lock --script script.py`). Regenerate and commit it whenever
  you change the PEP-723 `dependencies`. Like any new file, `git add -N` it so the
  flake build picks it up (see "New files: stage them before building").

Reference example: `modules/ai/_files/skills/grafana/scripts/grafana.py` (+`.lock`),
also `bitbucket-pr/scripts/bitbucket_pr_reviewers.py`.

### Closing a dependency advisory in `infra/`

`infra/` is the only npm tree in this repo (Pulumi, pnpm 11). GitHub Dependabot
watches `infra/pnpm-lock.yaml`; `just pulumi-audit` asks the same question
independently against OSV and additionally flags anything published inside the
cooldown window. Its script (`infra/scripts/osv-audit.py`) is stdlib-only on
purpose — an auditing tool that installs dependencies to run has a supply chain of
its own. Exit codes: `0` clean, `1` advisories found, `2` tool/network error.

**Work the ladder top-down and stop at the first rung that applies.**

1. **The fixed version fits the parent's declared semver range → lockfile only.**
   `cd infra && pnpm update <pkg> --depth Infinity`. `package.json` and
   `pnpm-workspace.yaml` stay untouched; `git diff --stat infra/` must show
   `pnpm-lock.yaml` alone. Check the range against the registry *before* editing —
   `curl -fsSL https://registry.npmjs.org/<parent>/<version>` and read
   `.dependencies`. This is the common case: `1c3d7cd` (tar, brace-expansion),
   `7dd7121` (seven advisories at once).
2. **It does not fit → bump the direct dependency** in `infra/package.json` so the
   floor is encoded where a human will see it (`^3.0.0` → `^3.252.0`). Example:
   `7902ef9`.
3. **`pnpm.overrides` / `resolutions`: no.** Never used here, and rejected once on
   evidence — pinning a transitive Pulumi dependency broke the SDK at load, because
   the 1.x OTel siblings import symbols removed in core 2.x. Bump the coordinated
   parent instead.
4. **The fix is younger than the cooldown** (`minimumReleaseAge: 4320`, three days,
   `infra/pnpm-workspace.yaml`) → exempt that one `package@version` via
   `minimumReleaseAgeExclude`. Never lower the floor itself, which would exempt
   everything. **This rung has a hard precondition — see below.**

#### Undercutting a cooldown: research first, fetch second

Not negotiable, and not a matter of taste. The cooldown *is* the control that
catches a compromised release, so exempting a package removes exactly that control
for exactly that package. "Just bump it and see if anything breaks" is not
available: `pnpm update` downloads and unpacks the tarball, and `tsc`/Pulumi then
import it. By the time a test could fail, the code has already run on a machine
holding this repo's SOPS secrets and its Cloudflare and AWS credentials. Research
that starts after the install starts too late.

1. **Research while fetching nothing.** Establish that this specific
   `package@version` is not part of a live supply-chain incident: read the upstream
   fix commit and the advisory; inspect the maintainer set, publish provenance and
   signatures through registry *metadata* only (`npm view <pkg>@<ver> --json`, or
   `curl -fsSL https://registry.npmjs.org/<pkg>`); check GitHub Security Advisories,
   the project's issue tracker, and current incident reporting (Socket,
   StepSecurity, Snyk, OpenSSF) for the **package and its maintainers** — a
   maintainer-account compromise shows up there before it shows up in the package.
   If anything looks off, diff the published tarball against the tagged source.
2. Only then add the `minimumReleaseAgeExclude` entry, run the update, and verify.
3. If the research cannot conclude cleanly, **wait out the cooldown** and mitigate
   another way: route around the vulnerable code path, disable the feature, or
   accept the risk explicitly and say so in the commit. Waiting is by far the
   cheaper failure mode.

The same rule governs every other cooldown here — the uv `exclude-newer-package`
overrides in `modules/ai/_files/skills/browser-use/scripts/browser-use.py` and the
global `exclude-newer` / `min-release-age` floors in
`modules/supply-chain-hardening.nix`. Any cooldown, same precondition.

#### Verifying and recording

Before committing: `just pulumi-audit` clean, `cd infra && pnpm audit` clean,
`pnpm exec tsc --noEmit` green.

Commit bodies here double as the runbook, so write them accordingly: the advisory
(severity, GHSA, CVSS vector), the dependency path that pulls the package in, which
rung you used and why the ones above it did not apply, and the publish age of the
version you moved to.
