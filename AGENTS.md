# Repository Guidelines

This file provides guidance to AI coding agents when working with code in this repository.

## Repository Overview

This is a Nix-darwin configuration repository for managing macOS systems (Stefan Schwetschke's personal dotfiles). It uses Nix flakes, flake-parts, nix-darwin, Home Manager, and Determinate Nix for declarative system configuration on Apple Silicon Macs.

The repository follows the **Dendritic Pattern** for Nix flake structure — use the `/dendritic-nix` skill for detailed guidance on creating and modifying modules.

**Current Hosts:**
- `FCX19GT9XR` - Personal Mac (user: `stefan`)
- `DKL6GDJ7X1` - Work Mac (user: `stefan.schwetschke`). Holds the CHECK24 work credentials
  (`jira_*`, `confluence_*`, `absence_io_*`, `c24_bi_kfz_*`) in
  `hosts/DKL6GDJ7X1/secrets.enc.yaml`, and is the only host with
  `my.ai.atlassian.enable`
- `p-ion-berlin-xs56r6` - IONOS Core VPS, `x86_64-linux` (NixOS). Named per
  `infra/Naming.md`; was `ionos-vps` until 2026-08-18. Not a darwin host: it is
  selected by name rather than hardware serial and is **not** applied with
  `just switch`. See "The IONOS VPS (NixOS)" below.

## Build, Test, and Development Commands

A `justfile` provides safe, pre-approved commands that agents can run without user approval. Raw `nix` and `darwin-rebuild` commands require user approval. The **only** exceptions in the justfile are `just switch` / `just switch-host`, which apply the system config, and `just daemon-restart`, which restarts the nix-daemon — all three use `sudo` and are for the user to run interactively, not agents. `just switch` is also the *only* supported way to apply the config: it selects the flake attribute by hardware serial, which a bare `darwin-rebuild switch --flake .` cannot do reliably (see "Applying the configuration").

### Safe commands (via justfile, no approval needed)

| Command | Description |
|---|---|
| `just build` | Build current host configuration without applying |
| `just build-host <host>` | Build a specific host (e.g. `just build-host DKL6GDJ7X1`) |
| `just check` | Run `nix flake check` |
| `just fmt` | Format all Nix files with `nixpkgs-fmt` |
| `just fmt-check` | Check formatting without modifying files |
| `just update` | Update all flake inputs, never to code younger than the cooldown |
| `just update-preview` | Show what `just update` would do, without touching `flake.lock` |
| `just update-input <input>` | Update a single flake input, still honouring the cooldown |
| `just update-head` | Update everything to branch HEAD — **cooldown bypassed**, deliberate use only |
| `just audit` | Cooldown + withdrawal audit: input ages, npm package ages, VS Code extensions |
| `just audit-inputs` | Layer 1 only — fast, no npm or marketplace lookups |
| `just audit-extensions [ids…]` | VS Code extensions: old enough **and** still published upstream |
| `just creds-check` | Do the long-lived credentials still authenticate? (jira, confluence, bb) |
| `just vscode-settings-check` | Has VS Code been trying to write the Nix-managed settings.json? |
| `just diff` | Build and show package delta vs. current system |
| `just verify-no-diff` | Build and assert no package delta (useful after refactoring) |
| `just deps` | Show flake dependency tree |
| `just eval` | Evaluate flake outputs (fast syntax check) |
| `just show-derivation` | Show derivation of current host build |
| `just cache-queue` | What is still waiting to be pushed to R2, and how long has it waited? |
| `just gc` | Collect user-level garbage (7 days) and sweep any running Linux builder |
| `just optimise` | Deduplicate the store by hand; `modules/nix-gc.nix` also does it weekly |
| `just linux-builder-up [arch]` | Start the Docker Linux builder (`x86_64` default, or `aarch64`) |
| `just linux-builder-status [arch]` | Builder state, reported system, store size against its cap |
| `just linux-builder-probe [arch]` | Prove the daemon delegates Linux builds to the container |
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

# Restart the nix-daemon (requires sudo). Needed after a switch that first
# enables the R2 post-build-hook or the Linux builders — both are read only at
# daemon startup and fail silently until then.
just daemon-restart

# Build for a specific host directly
nix build .#darwinConfigurations.DKL6GDJ7X1.system
nix build .#darwinConfigurations.FCX19GT9XR.system

# Show package delta between current and new system
nix store diff-closures /run/current-system result

# Full system-wide garbage collection (prunes the system profile too). Runs
# automatically every week via modules/nix-gc.nix; this is the manual one-off.
sudo nix-collect-garbage --delete-older-than 7d
```

**Changing `auto-optimise-store` needs one `just daemon-restart`.** It is a daemon-side
setting, and Determinate's `nix-daemon` reads `/etc/nix/nix.custom.conf` only at startup —
the same trap as the `post-build-hook` string, and `darwin-rebuild switch` does not restart
it. Measured 02.09.2026, after a switch that wrote `auto-optimise-store = false` on a
daemon started three hours earlier: a fresh build of a derivation containing two identical
files still yielded a single inode with `nlink=3`. **`nix config show` is not evidence** —
the client parses the files itself and reports `false` while the daemon is still
deduplicating. Test it the way that cannot lie:

```bash
# two identical files in one output; nlink >= 2 means the daemon is still optimising
nix build --no-link --print-out-paths -f probe.nix   # derivation writing $out/a and $out/b
perl -e 'printf "%s nlink=%d\n", $_, (stat)[3] for @ARGV' "$out/a" "$out/b"
```

`modules/nix-gc.nix` carries a second weekly daemon, `nix-optimise`, an hour after
the GC. Store deduplication used to happen inline via `auto-optimise-store = true`
and was moved off the write path because it hard-links every new file against
`/nix/store/.links` under a global lock — measured 02.09.2026 on this machine, same
derivation of 4000 small files, two runs each: **58.8 s / 58.0 s with it against
14.0 s / 13.1 s without, i.e. 4.3x**, with 675_925 links already in that directory.
The saving it produces is real and is kept (`nix-collect-garbage` reported "hard
linking is currently saving 5.3 GiB" right after the change), it is simply
collected weekly instead of on every store write. The cost grows with the link
count, so re-measure rather than assume on a machine with a younger store.

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

**`--rebuild` proves the platform gap, never the builder.** Check builds decline
the build hook and must run locally, so this command reports `platform mismatch`
*even when a Linux builder is configured and working*. Measured 2026-08-24, twice
in the same minute against the same derivation: without `--rebuild` it built on
the container and was copied back from `ssh-ng://root@nix-linux-builder-x86_64`;
with `--rebuild` it failed with the message above. Passing `--builders` explicitly
or aiming at a private `--store` changes nothing. To check delegation, use the
probe in "The Linux builder (Docker)" instead.

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

**That removal has happened, so a stuck agent now costs the login.** Measured
2026-08-27: `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519
root@87.106.149.208` answers `Permission denied (publickey)`. The remaining
routes are the 1Password key, Tailscale SSH, and the KVM console — an earlier
version of this passage said ssh would fall through to the file key, which was
true when written and is not any more.

**Do not treat that as a defect to route around.** Biometric guarding is the
design: keys live in 1Password behind Touch ID (or Tailscale SSH behind a
passkey), and the goal is one key per host, so a leaked key costs one machine
and access can be granted individually. A key sitting on disk gives that up —
copyable unnoticed, and no confirmation per use.

So when `sign_and_send_pubkey: signing failed … communication with agent
failed` appears, the answer is to unlock 1Password, never to add a file key or
stretch the auto-lock — however often the same halt repeats. What *is* fair
game is removing the need for an interactive login: run long work as a
systemd unit on the target, and read state from somewhere reachable without it
(the R2 repository answers "how far along is the backup" without touching the
NAS at all).

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

## Architecture

### Dendritic Pattern with flake-parts

This repository uses the **Dendritic Pattern**: every file in `./modules/` is a flake-parts module organized by feature (aspect), not by configuration class. The `/dendritic-nix` skill provides full documentation on this pattern.

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
| `nix-cache.nix` | Shared Cloudflare R2 Nix binary cache — substituter, plus a `post-build-hook` that only ENQUEUES and a `nix-cache-drain` LaunchDaemon that does the signed push out of band — via `flake.modules.darwin.nix-cache`. See "The push is asynchronous, and why" below. Also carries numtide's upstream substituter (`cache.numtide.com`), because `determinateNix.customSettings` allows only one definition of `extra-substituters`. Bucket/domain provisioned in `infra/`; details in `infra/README.md` |
| `linux-builder.nix` | Registers the Docker Linux builders with the daemon via `determinateNix.buildMachines` + an `ssh_config` alias, and installs the root-owned builder key. See "The Linux builder (Docker)" |
| `homebrew-common.nix` | Shared Homebrew configuration via `flake.modules.darwin.homebrew` |
| `shells.nix` | Shell configuration (Fish, Zsh, Bash) via `flake.modules.homeManager.shell` |
| `git.nix` | Git configuration via `flake.modules.homeManager.git` |
| `neovim.nix` | Neovim (nvf) in two variants: `homeManager.neovim` (workstation, every `languages.*` enabled) and `homeManager.neovim-server` (same editor, no language toolchains). See "Neovim: why there are two variants" |
| `packages.nix` | Common packages via `flake.modules.homeManager.packages` |
| `mcp-servers.nix` | Claude Code MCP server wrappers + the deployed skill tree via `flake.modules.homeManager.mcp-servers`. `my.ai.atlassian.enable` gates the Atlassian server and the `jira`/`bitbucket-pr` skills onto the work host; `claudeMcpExclude` additionally hides a server from **Claude only** (currently `atlassian`, replaced there by the skills) |
| `secrets.nix` | SOPS secret declarations and per-host secret merging (**home-manager only** — servers use `nixos-secrets.nix`) |
| `nixos-wiring.nix` | Defines `configurations.nixos` (module + `deployTarget`) and wires it to `flake.nixosConfigurations` and `flake.deployTargets` |
| `nixos-base.nix` | Baseline for every NixOS host: sshd, root's authorized keys, the lockout assertions, serial getty, nix settings, GC |
| `nixos-tailscale.nix` | Tailscale with Tailscale SSH via `flake.modules.nixos.tailscale`. Answers :22 in userspace, so not sshd and not firewall-gateable — see "The IONOS VPS" |
| `nixos-wireguard-home.nix` | WireGuard to the home FRITZ!Box via `flake.modules.nixos.wireguard-home`. Proxy-ARP addressing, so the LAN reaches the host without NAT |
| `nixos-backup-copy.nix` | Second copy of the restic backup, R2 -> Dropbox, via `flake.modules.nixos.backup-copy`. rclone plus five manually-started units; copies ciphertext, so the VPS never holds the repository password. Verifies packs against their SHA-256 filename on either side. See `infra/machines/p-own-lengenwang-c5esve.md` |
| `nixos-secrets.nix` | sops-nix on the **nixos** class — decrypts to `/run/secrets/` with a key generated on the host itself |
| `misc.nix` | Key remapping, Hammerspoon, misc home config |
| `onepassword.nix` | Generates `~/.config/1Password/ssh/agent.toml` — which vaults the SSH agent may offer keys from. Without it, personal vault only |
| `aichat.nix` | AI chat tool configuration |
| `ai-tools.nix` | AI tool packages and configuration |
| `boundary.nix` | HashiCorp Boundary PM2-managed proxies (work host) |
| `vault.nix` | HashiCorp Vault configuration |
| `vscode.nix` | VS Code: the general extension set via `nix-vscode-extensions`, plus `settings.json` and the local Turbo Vision theme. Editor itself stays a Homebrew cask — see "VS Code extensions" below |
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
- **launchd jobs get no shell environment:** the converse of the SIP restriction above. An agent or daemon inherits only `PATH`, `SSH_AUTH_SOCK` and the XPC keys — never what `programs.fish.interactiveShellInit`, `home.sessionVariables`, or a hand-edited rc file exports (verify with `launchctl print gui/$(id -u)/<label>`). Anything scheduled must therefore bake its inputs in at build time or receive them through `launchd.agents.<name>.config.EnvironmentVariables`, and must never fall back **silently** when one is missing. Worked example: `modules/nix-tarball-cache-repack.nix` resolves `${XDG_CACHE_HOME:-$HOME/.cache}/nix/tarball-cache-v2` exactly as Nix's `getCacheDir()` does, so exporting that variable from the shell alone would leave Nix writing to one directory while the agent repacks another — and its miss branch exits 0, which reads exactly like success. It forwards the variable when `xdg.enable` is set (the same condition home-manager uses to export it) and warns loudly, naming the variable, when the resolved directory is empty. `modules/nix-cache.nix` sidesteps the same class of bug in the `nix-cache-drain` LaunchDaemon by baking **every** input — `NIX_CACHE_S3_URL`, `…_SECRETS_DIR`, `…_SPOOL`, `…_LOG`, `…_DRAIN_LOCK`, `…_MAX_CLOSURE_BYTES`, `…_PUSH`, `PATH` — into the wrapper at build time rather than passing them through launchd's `EnvironmentVariables`, so a manual run and the scheduled run cannot see different values; the python side reads each with `os.environ[...]`, never `.get(…, default)`, and exits 2 naming the missing one — a default would have it draining into the wrong spool while reporting success
- **Binary cache (R2):** both hosts share a Cloudflare R2 cache (`modules/nix-cache.nix`). Pull is a public custom-domain substituter; push is a signed `nix copy` run by the **`nix-cache-drain` LaunchDaemon**, not by the build itself — the root `post-build-hook` only drops a file into `/var/spool/nix-cache-push/queue` (`just cache-seed`/`cache-push` still push synchronously, on purpose). The hook is referenced by the **stable** `/run/current-system/sw/bin` path, but Determinate's `nix-daemon` reads the hook setting only at startup and `darwin-rebuild switch` does **not** restart it — after first enabling the cache, run `just daemon-restart` (or reboot) once. Push credentials: `r2_secret_access_key` stores a Cloudflare API token (`cfat_…`) whose SHA-256 the push script derives as the S3 secret

### The push is asynchronous, and why

Nix runs a `post-build-hook` **synchronously, blocking its own build loop**. For a long
time this repo's hook did the whole `nix copy` to R2 inline behind a `timeout 600`, so
every locally built path cost up to ten minutes of wall clock before the build that
produced it was considered finished. What that actually cost, from
`/var/log/nix-cache-push.log`:

| day | hook invocations | total hook time | worst single record |
|---|---|---|---|
| 2026-08-25 | 67 | 9040 s | 11 killed at `exit=124` |
| 2026-09-02 | 322 | 8182 s (136 min) | `dur=601s` |

(The 2026-09-02 row is a mid-afternoon snapshot — the log was read while the problem was
still happening — not a full day. Across the whole log there are 13 `exit=124` records,
10 of which name a devenv output.)

**A killed push registers nothing**, and that is the part that made it unbounded: the
`nix copy` had transferred hundreds of megabytes, the `timeout` shot it, nothing was
recorded at the destination, and the next build of the same path paid the same 601 s
again. It never amortised.

The worst case was a devenv shell — a per-project profile rebuilt on every `direnv
reload`, whose closure is **4.12 GB across 202 paths**, because a binary cache has to be
referentially complete and `nix copy` therefore expands every argument to its closure.

**The symptom pointed at the wrong thing.** The progress display showed
`Downloading … from cache.nixos.org — 11m24s` and read as a slow network. Measured the
same minute: that exact NAR is 29 MB and `curl`s in **0.69 s**; the machine had 67 MB/s
down and 40 MB/s up, and all four substituters answered `nix-cache-info` in under 0.2 s.
Nix simply keeps displaying the last open activity while the daemon blocks in the hook.
**Do not diagnose a stalled Nix from its progress line** — check
`/var/log/nix-cache-push.log` and `ps` for a `nix copy` first.

So the hook now only **enqueues**: one empty file per output path in
`/var/spool/nix-cache-push/queue`, named after the store path, and it returns in ~20 ms
(measured; the same hook previously took 2–601 s per invocation, median a few seconds).
`launchd.daemons.nix-cache-drain` runs
`nix-cache-drain` every 300 s and hands **all** waiting paths to `nix-cache-push` in one
call, so their closures deduplicate against each other instead of being re-queried per
build.

Four properties are load-bearing, and each replaces something that was broken:

- **State is the file name, nothing else** (mtime = when it was queued or last tried).
  `open(O_CREAT)` is atomic, so there is no half-written entry, and no progress file to
  be missing exactly when a run died badly — which is the case a progress file exists
  for. Resume is "what is still in the directory".
- **An interrupted drain now costs only the NAR in flight.** `nix copy` asks the
  destination what it already has, so everything uploaded before the interruption stays
  uploaded. This is the whole reason the split fixes the problem rather than moving it.
- **The timeout ESCALATES to SIGKILL.** A `nix copy` was measured still running minutes
  after its `FAIL` record was written, with a second one alongside it competing for the
  same uplink. The tempting explanation — that `timeout` had signalled only one pid — is
  **wrong**: GNU `timeout` calls `setpgid(2)` and signals the whole group unless
  `--foreground` is given. What actually happened is that `nix copy` took the SIGTERM and
  did not die promptly. So the drainer sends SIGTERM, waits 30 s, then SIGKILL; the new
  session exists so `killpg` is addressable from the drainer without signalling itself.
  It also installs a SIGTERM handler of its own, because the push runs *outside* launchd's
  job process group: without one, a `just switch` that reloads the daemon mid-drain would
  orphan the running `nix copy` and `RunAtLoad` would immediately start a second one for
  the same paths.
- **Failures back off and are eventually given up on** — `retry/1..5` at 5 min, 15 min,
  1 h, 4 h, 24 h, then `status=GIVEUP` (counted separately from errors: an earlier version
  reported "0 errors" on the very run that dropped a path for good).

  Each run pushes **two groups**: everything at level 0 in one `nix copy`, and exactly
  **one** already-failed entry, alone. That split is a bug fix, not an optimisation. The
  first version escalated the *whole run* to a single path as soon as any entry reached
  level 2 — so one transient R2 outage collapsed the drainer to one path per 300 s, and
  freshly built paths then queued behind a ladder that runs to 24 h: up to ~33 h in which
  nothing new reached the cache. Isolating the poison entry costs one extra `nix copy`,
  not the whole queue.

Two filters, both of which log what they drop (**never a silent cap**):

- **Per-project devenv outputs are not pushed at all** — everything whose name starts
  `devenv-`, except the devenv package itself (`devenv`, `devenv-<version>`,
  `devenv-wrapped-<version>`). They are rebuilt on every `direnv reload`, are specific to
  one machine and one checkout, and the other Mac can never reuse them.

  **This started as an exact list of four names and that was a disclosure bug, not a
  tuning miss.** The four were chosen because they appeared in the timeout records —
  wrong criterion, because the leaky outputs are *small* and therefore never timed out. A
  `devenv-files` output is a script containing the checkout's **absolute path**, and
  `devenv-processes-<name>` takes `<name>` verbatim from the project's own `processes.*`
  keys, which then becomes the `StorePath:` line of a world-readable narinfo in a bucket
  that is public by design. Measured in one store: `devenv-files` 58, `-files-cleanup`
  60, `-git-hooks-install` 11, `-git-hooks-run` 10, `-enterShell` 6, `-container-copy` 6,
  `-python-uv` 4, `-test` 3, `-processes-*` 3, `-flake-*` 4 — every one of them outside a
  four-name list. **When a filter exists to keep a category out of a public place, derive
  it from the category, never from the incidents that made you notice.**

  The filter lives in the **hook**, because `nix-cache-push` is also the interactive path
  (`just cache-push …-devenv-profile` must still do what it was told) and because a
  filter in the drainer would let the spool accumulate entries every run discards. The
  keep-arm is listed first because zsh takes the first matching `case` arm and
  `devenv-wrapped-2.2.3` matches both. `rust_devenv-*` and `+mcp-devenv*` do not start
  with `devenv-` once the hash is stripped, so they are unaffected.
- **Closures over 64 GiB are skipped**, logged with their size
  (`status=SKIP reason=closure-limit bytes=…`). That bound is a backstop against one
  pathological output, deliberately **not** a cost policy, and the first attempt got this
  wrong in a way worth recording: a 3 GiB cap looked reasonable and skipped
  `darwin-system` (closure 24.35 GB), `home-manager-generation` (21.63 GB) and
  `activation-<user>` (21.63 GB) — precisely the closures this shared cache exists to
  hand to the other Mac. Their real push cost, from the log, is **2–4 seconds**, because
  `nix copy` asks the destination first and uploads only what R2 lacks. **Closure size
  overestimates upload cost by three orders of magnitude here**, so do not tighten this
  number in the belief that it measures money. What bounds the genuinely expensive case
  is the drainer's 3600 s timeout, the retry backoff and `status=GIVEUP` — those measure
  the work instead of guessing at it. `NIX_CACHE_MAX_CLOSURE_BYTES=0` disables it.

Operationally:

```bash
just cache-queue      # depth per retry level + the oldest entry (no sudo)
just cache-log        # one line per enqueue and per drain that did something
sudo /run/current-system/sw/bin/nix-cache-drain   # drain now (`just cache-drain` prints it)
```

`/var/log/nix-cache-drain.log` carries `nix copy`'s own multi-line output, deliberately
apart from `/var/log/nix-cache-push.log` so that it cannot break the
one-`printf`-per-record atomicity there.

**No daemon restart is needed for any of this**, and the reason is worth keeping: the
`post-build-hook` setting still reads exactly
`/run/current-system/sw/bin/nix-cache-post-build-hook`. Determinate's `nix-daemon` caches
that *string* at startup and execs it fresh per build, so changing the script's contents
takes effect with the switch. Renaming the hook, or pointing the setting at
`${hookScript}/bin/…`, would give that up.

What the split does **not** fix: the uplink is still the uplink, so a large closure still
takes minutes — it just takes them somewhere that nobody is waiting. If the queue is
never empty, that is the signal, and `just cache-queue` is how it gets noticed instead of
growing in silence.

### The public cache mirrors system closures, including non-redistributable binaries

This is by construction, not by oversight, and it is written down so nobody reads it
as an accident and "fixes" it with something that cannot work.

`nix-cache-push` filters only the **starting set** (the large-FOD filter). `nix copy`
then expands each path to its **closure**, because a binary cache has to be
referentially complete — the script's own comment records the error you get otherwise
(`cannot add '…-etc' … because the reference '…-chfn.pam' is not valid`). Everything
in those closures that R2 lacks is uploaded and re-signed with our key, whether it was
built here or substituted from somewhere else. Measured 2026-09-02:
`bash-5.3p15` sits in R2 while `nix path-info --json` reports `ultimate: false` and its
two `cache.nixos.org` signatures — purely substituted here, then re-published by a
closure push.

So the bucket ends up holding whatever these systems use. Some of that is prebuilt
vendor binaries whose licence carries **`meta.license.redistributable = false`**. Which
ones is deliberately not written here: the mechanism is the point, and a list would be
a pointer.

**A push-side exclusion list cannot prevent it.** A home-manager-generated wrapper
around such a package carries `allowSubstitutes = ""` and `preferLocalBuild = 1`, so it
is always built locally on every host, and it *references* the package — dropping the
package from the starting set just means the wrapper's closure carries it. Dropping the
wrapper does not help either, because `home-manager-path` references the wrapper.
Fixing a substituter so the package is fetched rather than built saves the build and
the download, and changes nothing about this.

**A licence filter cannot work, and would fail in a way that reads as success.**
`meta.license` is eval-time data and is not recorded in the store, as the VS Code
passage above already states. Worse, the obvious predicate is the wrong one: one of the
flake inputs here deliberately overrides nixpkgs' unfree licence with `free = true` so
consumers need no `allowUnfree`, so its packages evaluate as `meta.unfree = false` and
`meta.license.free = true`, and only `meta.license.redistributable = false` expresses
the restriction. A filter keyed on `unfree` would report clean while publishing them.
That is a different category from VS Code, which is genuinely `meta.unfree = true`.

**Deleting objects is not a fix, and has a trap of its own.** narinfo 200s are
edge-cached for 30 days (`infra/src/index.ts`), so removing objects without purging the
Cloudflare cache leaves a 200 narinfo pointing at a missing NAR — which turns a clean
miss into a substitution *error*. And the next `just switch` re-pushes the current
version anyway.

The only durable change would be to stop serving the bucket publicly. Deliberately not
done: both Macs and `p-ion-berlin-xs56r6` substitute from it, and `just bootstrap`
depends on it being open to a machine that has no credentials yet.

Decided 2026-09-02 to document rather than remove, with one piece of perspective on the
record: the binaries this concerns are themselves served **unauthenticated** from their
vendors' own download hosts — that is where this repo fetches them — so the question is
redistribution, not secrecy. Weigh any future addition to this cache on that basis, and
keep in mind that store hashes are derivable by anyone who evaluates this public flake.


## Coding Style & Naming Conventions

- **Indentation:** 2 spaces
- **Attribute sets:** Keep alphabetized within logical groups
- **Host naming:** see "Host and DNS naming" below — Macs mirror their serial exactly
  (`FCX19GT9XR`, `DKL6GDJ7X1`), everything else follows the scheme in `infra/Naming.md`
- **Format before committing:** `just fmt` or `nix run nixpkgs#nixpkgs-fmt -- <files>`
- **Module pattern:** Each module file exports `flake.modules.<class>.<name>` — see `/dendritic-nix` skill

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

### Any script that processes a list must be resumable

Long-running batch work here gets interrupted — a quota fills, a link drops, a
deploy times out, someone hits Ctrl-C. A script that cannot be re-run without
thought turns every interruption into an investigation. Four rules, each of
which was paid for.

- **Classify every item as SUCCESS, SKIP, ERROR or CLEANUP, and never collapse
  two of them.** A skip is not a failure. Reported together they make the summary
  worthless and the resume decision impossible.

  Paid for on 2026-08-20 while decoding 204 `.otrkey` files: the wrapper treated
  any non-zero exit from the decoder as an error, so `output file "…" exists,
  skipping` — the tool correctly declining to redo finished work — was counted as
  a failure. Two consecutive runs reported "142 failed" and then "148 failed"
  while the number of finished files rose. Neither number meant anything, and the
  list of "failures" driving the next run was garbage. When wrapping a foreign
  tool, map its exit codes and messages deliberately; `|| fail` is where the
  distinction dies.

- **Derive state from the work products, not from a file the script wrote.** A
  progress file, a failed-list, a marker — all of them are missing exactly when
  the run died badly, which is the case they exist for. Ask the filesystem, the
  bucket, the database: does the output for this item exist and is it valid?

- **"The output file exists" is a weak predicate. Prefer "the output verifies".**
  An interrupted write leaves a file that looks finished. In the same incident, a
  quota hit mid-write left truncated outputs behind; the next run saw them, said
  "exists, skipping", and would have deleted the corresponding inputs had it been
  told to. Where a checksum is available — a hash in a header, a manifest, `restic
  check` — that is the resume predicate. Where none exists, at least compare size
  against the expected value.

- **Publish results atomically: write to a temporary name in the same directory,
  `fsync` if it matters, then `mv` into place.** A rename within one filesystem is
  atomic, so an interrupted run leaves a stray temp file — obvious, harmless,
  cleanable — instead of a plausible-looking corpse under the real name. This is
  what makes the previous rule work: if only complete outputs ever carry the final
  name, "exists" becomes trustworthy again. Clean stale temp files at start-up and
  count that as CLEANUP.

Two additions that follow from the same reasoning:

- **Make the summary self-describing.** Print all four counts every run, plus what
  a re-run would do. `62 ok, 142 failed` invites the wrong conclusion; `62 done,
  142 skipped (already complete), 0 errors — nothing left to do` ends the
  conversation.
- **Use exit codes to distinguish "did work" from "nothing to do" from "failed".**
  A resumable script run twice must exit 0 the second time; anything else trains
  people to ignore its exit code.

## Commit & Pull Request Guidelines

Use Conventional Commits: `type(scope): subject` (imperative present tense, ≤72 chars)

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Common scopes:** `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`

**Examples:**
- `feat(home): Add Claude Code MCP servers for Atlassian and Context7`
- `fix(darwin): Correct Emoji & Symbols keyboard shortcut`
- `chore(flake): Update nixpkgs to 25.11`

Include host IDs and commands executed in commit body when relevant. Iterate with fixups (`git commit -m "fixup! …"`); run `git push --dry-run` and wait for explicit approval before pushing.

**`git diff | grep '^+'` does not work on these machines.** `modules/git.nix` sets
`diff.external` to difftastic in `~/.config/git/config`, so `git diff` emits a structural
view rather than a unified diff and any plus-line filter silently returns nothing. Use
`git diff --no-ext-diff`, or `git grep` against the commit. `git show` and `git log -p`
are unaffected. Full rule, with measurements, in
`modules/ai/_files/rules/git-external-diff.md`, which is also installed globally to
`~/.claude/rules/`.

**`Co-Authored-By` trailer (Claude Code):** Use only the generic form — `Co-Authored-By: Claude <noreply@anthropic.com>`. Do **not** embed a specific model name, version, or context label (e.g. `Claude Opus 4.7 (1M context)`): Claude's content-integrity guardrail may block such trailers as impersonation of a "fabricated model". The block is non-deterministic (observed: the same string passed in one turn and was rejected in another), so even "it worked last time" is not a safe signal. The generic form always passes.

## This repository is PUBLIC — what needs explicit clearance

`github.com/geggo98/dotfiles` is public, and it carries work configuration. Two kinds of
content therefore need the user's **explicit** go-ahead before they are committed, every
single time. **A clearance given once does not carry over to the next occurrence.**

1. **Personal data of third parties** — names, email addresses, account ids, handles, of
   anyone other than the repository owner. They did not agree to be published here.
2. **Internal infrastructure** — hostnames, repository and product names, Jira project
   keys, cloud project ids, real ticket numbers, runbook names, workflow configuration.

**Re-question these at every review, including what is already in the tree.** That
something sits in the repo is not evidence that anyone cleared it; far more often it
means nobody looked.

**Identifiers evade keyword search.** An account id is a bare string with no company name
anywhere near it, so no search for an employer or for "internal" will ever surface it.
Grepping for suspicious words is not enough — search for the shapes: id-like strings,
ticket patterns such as `ABC-1234`, PR numbers, repo slugs, email addresses.

**Pasted example output is the usual way in**, because it carries whatever happened to be
on the line. Before committing an example, replace real ticket keys, PR numbers, repo
slugs and account ids with placeholders — **all of them on the line, not just the
conspicuous ones**. The characteristic mistake is to sanitise the branch name and the
issue id and leave the repo slug and the PR number beside them untouched.

**Validate the scan before believing "no hits".** A filter that structurally cannot match
reports the same thing as a clean result, so count how many lines it sees before treating
an empty result as a finding. See the global agent rule on `git diff` and difftastic
(`modules/ai/_files/rules/git-external-diff.md`) for a measured case where exactly that
happened during a pre-push scan.

When in doubt, ask. The cost of asking is one question; the cost of not asking is a
history rewrite and a force-push.

## Secrets & Configuration Tips

### One env name, one file — and export as few secret values as possible

**Files are the default source. An environment variable is a deliberate manual
override.** Two rules follow, and both were paid for.

**A credential chain gets exactly one env name and one file.** No generic
aliases, no cross-product fallback tiers. Measured 2026-08-24: `modules/shells.nix`
exported `ATLASSIAN_API_TOKEN` into every shell holding the *Bitbucket* token,
while the `jira` and `bitbucket-pr` skills consulted **every env name before any
file** — so the dead alias outranked the correct `jira_api_token` file and every
Jira call failed. Both skills were dead in any interactive shell for weeks.

The symptom is what makes this worth a section: **Jira answers 404, not 401**, on
an issue endpoint when the token is invalid, because it hides issue existence
from unauthenticated callers. `prs JIRA-3325` reported *"Jira resource not
found"* for a ticket that exists. Reordering the tiers would only postpone the
next instance, so the alias tier is gone; both scripts now also print **which
source** the token came from on 401/404, never the token.

**`modules/shells.nix` exports no secret VALUES at all** — only `*_PATH`. Every
consumer in this repo reads its sops-nix file through `load_from_secret`
(`modules/_files/shell/load-secrets.sh`), so the ambient copy bought nothing and
cost plenty: a globally exported secret lands in every child process, `env` dump,
crash report and agent transcript. Tools with no file-based key store of their
own (`llm`, `ollama`) get a same-named wrapper in `modules/ai-tools.nix` that
loads the key per invocation instead. Adding a secret value back to `shells.nix`
needs a reason a wrapper cannot serve.

**Atlassian tokens, specifically.** The classic `ATATT3…` tokens used here are
**unscoped** — they carry the user's full Jira/Confluence permissions — they
**expire**, and they are **not Bitbucket credentials**: the Bitbucket REST API
rejects them as a category ("API Token provided has no Bitbucket scopes" means
the wrong *kind* of credential, not a missing scope; Bitbucket goes through `bb`
and its own `config-cli.yml`). The token is opaque, so nothing can read its
expiry — `just creds-check` probes instead. Note the two products do **not**
share an auth scheme: Jira Cloud is Basic (email + token), while the
self-hosted Confluence (Data Center) needs **Bearer**. Guessing wrong
returns 401 and looks exactly like a dead credential.

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

Use the `/dendritic-nix` skill for guidance. In short:

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

**Group related secrets in the YAML with `key`, keep the attribute name flat.**
`name` and `key` are separate options: `key` addresses a value *inside* the
encrypted file, `/`-separated, while `path` defaults to a location built from
`name` and never from `key`. So a nested `key` reorganises the file without
moving a single file on disk — no consumer changes.

```nix
r2_access_key_id.key = "nix_cache/r2/access_key_id";     # file: …/r2_access_key_id
restic_r2_access_key_id.key = "restic/r2/access_key_id"; # file: …/restic_r2_access_key_id
```

Do it whenever two secrets are the same *kind* of thing with different powers.
The case that motivated it: `r2_access_key_id` (nix-cache, read+write, on both
Macs, used automatically many times a day) sat next to `restic_r2_access_key_id`
(backup, read+write, able to destroy the only copy of the data) — same provider,
same shape, told apart by a prefix. Structure beats care.

**The NixOS module's description of `key` is wrong** — it says "No tested data
structures are supported right now", a typo for "nested" and untrue regardless.
Both classes call the same `recurseSecretKey` in `sops-install-secrets`, which
splits on `/` and descends. The home-manager module documents it correctly, and
a deploy of `p-ion-berlin-xs56r6` on 2026-08-21 settled it on the NixOS class
too: activation logged `adding secrets: dropbox_client_id, …,
r2_backup_ro_secret_access_key`, all five of them nested.

Renaming or regrouping an existing key means moving the value in the encrypted
file too. On the home-manager class that is safe: the build fails until they
agree, with `manifest is not valid: … the key '<x>' cannot be found`. On the
NixOS class the same mistake surfaces only at activation — see below.

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

  **This is a NixOS-class statement and does not generalise — the home-manager
  class is stricter, and in the useful direction.** There, `sops-install-secrets`
  checks the manifest at *build* time, so `just build` fails outright:

  ```
  manifest is not valid: secret restic_password in …-secrets.enc.yaml
  is not valid: the key 'restic_password' cannot be found
  ```

  Measured on 2026-08-19 while adding `restic_password` to
  `modules/secrets.nix`. The practical consequence is an ordering constraint
  rather than a hazard: on a workstation, put the value in the encrypted file
  *before* declaring it, or the tree does not build. The comparison-by-hand above
  is only needed for servers.

### Moving a secret between SOPS files

Host-scoping a credential — global `secrets/secrets.enc.yaml` → `hosts/<serial>/secrets.enc.yaml`
— is four steps in a fixed order, and **`sops edit` is not one of them.** `sops`
has `set` and `unset`, so the whole move is scriptable and no editor opens at all:

```bash
sops -d --extract '["k"]' "$SRC" \
  | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.buffer.read().decode()))' \
  | sops set --value-stdin "$DST" '["k"]'
sops unset "$SRC" '["k"]'
```

Three details in those two commands each cost a measurement:

- **`--value-stdin` wants JSON, and says so when it doesn't get it.** Fed the raw
  value it aborts with `Value for --set is not valid JSON` — loudly, never
  truncating. Hence the `json.dumps`. `--value-file` behaves the same and both
  exist for one reason: passing the value as an *argument* would put the secret in
  the process list.
- **Pipe the value; never `v=$(sops -d …)`.** Command substitution strips trailing
  newlines, which silently corrupts any multi-line value — the
  `c24_bi_kfz_*.json` service accounts are 12 lines each.
- **`--idempotent` on both** makes the loop resumable, which the rules under *Any
  script that processes a list must be resumable* require anyway.

**The order is not stylistic.** Each step is safe to stop after:

1. **`.sops.yaml` first, then `sops updatekeys -y <dst>`.** `sops set` inherits the
   key groups of the **file**, not the creation rule, so a rule fixed afterwards
   leaves the new values encrypted to the old recipient set in the meantime.
   `-y` is required — without it sops asks `Is this okay? (y/n)` and dies on EOF.
   `updatekeys` re-encrypts only the data key; the values stay byte-identical.
2. **Copy the values.** Both files now hold them; nothing is broken, nothing is
   deployed differently yet.
3. **Flip the declarations** (`modules/secrets.nix` → `hosts/<serial>/secrets.nix`),
   atomically. The reverse order fails: the home-manager class validates the
   manifest at **build** time, so a declaration without a value breaks `just build`
   with `manifest is not valid: … the key '<x>' cannot be found`.
4. **Only then `sops unset` from the source** — and make the delete predicate
   "the destination's decrypted value hashes the same as the source's, right now",
   not "I copied it earlier". An interrupted copy fails that check.

Two things this does **not** buy, both worth stating before someone relies on them:

- **It scopes deployment, not readability.** Every rule in `.sops.yaml` carries the
  same pair of `age1…` recipients, and their private halves sit on both
  workstations — measured: `sops -d hosts/FCX19GT9XR/secrets.enc.yaml` succeeds
  from DKL6GDJ7X1, whose SSH key is not among that file's `ssh-ed25519` recipients
  and whose GPG keyring holds neither of its PGP fingerprints. What changes is
  which host writes the value into `~/.config/sops-nix/secrets`.
- **The other host keeps the stale files until it is switched.** sops-nix removes
  what it no longer manages during activation, not before.

**Watch for Nix-side references.** A secret consumed only at runtime
(`load_from_secret`, a skill reading `$SOPS_SECRETS_DIR`) moves freely. One that a
module dereferences as `config.sops.secrets.<name>.path` does not: that is an
**eval** error where it is undeclared, so a host-specific secret referenced from a
module both hosts import — `modules/shells.nix` via `homeManager.base` is the live
example — breaks the *other* host's build. Grep before moving:

```bash
grep -rn --include='*.nix' 'sops\.secrets\.' modules/
```

### Adding an MCP Server

1. Add shell wrapper and server entry in `modules/mcp-servers.nix` (follow existing patterns)
2. Ensure secret loading logic uses `$XDG_CONFIG_HOME/sops-nix/secrets`
3. If it needs a credential only one host declares, gate it rather than shipping a
   server that cannot start. `mcpServerPkgs` feeds four sinks — the claude-code,
   opencode and codex configs plus `home.packages` — so a second module cannot
   simply merge into it: the codex path bakes its TOML in one activation script.
   `atlassian` is the worked example: an option declared by a small imported
   module (`imports` may sit beside bare config attributes, `options` may not),
   `lib.optionalAttrs` on the package set, and `builtins.path` with a `filter`
   dropping the matching skill directories. Use `builtins.path`, **not**
   `lib.cleanSourceWith` — the latter returns an attrset carrying `outPath`,
   which `programs.claude-code.skills` rejects with a message naming
   `_isLibCleanSourceWith` rather than the mistake.
   `modules/hosts/DKL6GDJ7X1.nix` sets `my.ai.atlassian.enable = true`; the
   default is off.

   **That option is the HOST gate, not a per-agent one.** `mcpServerPkgs` feeds
   all three agents *and* `home.packages`, so removing an entry there also takes
   the `+mcp-<name>` wrapper off `PATH`. To hide a server from a single agent,
   subtract it from that agent's own list instead — `claudeMcpExclude` does
   exactly that for claude-code. And note home-manager renders
   `programs.claude-code.mcpServers` into a *generated plugin*
   (`claude-code-home-manager`, handed to the wrapper as `--plugin-dir`), so
   that one list governs both the MCP entry and the plugin-provided tools:
   they are the same mechanism, not two switches.

### VS Code extensions

The **general** set — useful in any repository — is pinned in `modules/vscode.nix` and
comes from `nix-vscode-extensions`. Anything with a language toolchain behind it is
project-specific and belongs in that project's `.vscode/extensions.json`. The full
inventory, the per-extension reasoning and the removal candidates are in
**`modules/_files/vscode/EXTENSIONS.md`**; what follows is only what bites.

**Open VSX is not a faithful mirror, so the registry is chosen per extension.** Measured
2026-08-26 across both: Open VSX served `christian-kohler.path-intellisense` 2.8.0 (2022)
against the marketplace's 2.10.0, `yzhang.markdown-all-in-one` 3.6.2 against 3.6.3, and
answered **404** for `deerawan.vscode-dash` outright. Picking one registry for everything
pins stale versions with no error anywhere. Use the **`-release`** attribute sets, too:
the plain `open-vsx` and `vscode-marketplace` include pre-releases, which on GitLens
means `2026.8.251013` instead of `18.3.0`.

**The input's age IS the cooldown.** `nix-vscode-extensions` carries no version strings —
each daily revision pins whatever the registries served that day, so a revision N days
old pins extension versions at least N days old. Hence
`[cooldown.per_input] nix-vscode-extensions = 14` in `scripts/supply-chain.toml`, the
extension bar rather than the 5-day input default. There are no versions to bump by
hand; `just update` moves the whole set.

`[[extensions]]` in that manifest is the separate, stricter half: it asks whether each
extension still exists and whether the version is still listed — the withdrawal signal a
date cannot give. Be precise about its limit: it resolves its **own** candidate version
from the registry, not the one `nix-vscode-extensions` pins, so a clean run means "still
healthy upstream", not "the installed version is healthy".

**VS Code itself deliberately stays on the Homebrew cask**, and `programs.vscode.package`
is `null` — a supported value, since the home-manager module gates `home.packages` on
`cfg.package != null` and takes the `.vscode` directory name from its caller, not from
the package. Three measurements argue against moving the editor into Nix: the cask serves
1.134.0 where nixpkgs 26.05 has 1.119.0 and unstable 1.133.0; `vscode` is in no binary
cache for aarch64-darwin because it is unfree; and it would therefore be built locally,
at which point the R2 `post-build-hook` would push Microsoft's non-redistributable build
into a world-readable bucket. The same reasoning excludes exactly one extension,
`ms-vscode-remote.remote-containers` — the only unfree one of the candidates. A licence
filter in the push hook is not an option: `meta.license` is eval-time data and is not
recorded in the store.

**The failure mode that looks like success.** home-manager symlinks each extension as
`~/.vscode/extensions/<publisher>.<name>`, without a version suffix; VS Code's own
installs carry one. Both can sit there at once, and VS Code loads the **higher version** —
so a leftover gallery copy silently wins and the Nix pin does nothing. That is why
`extensions.autoUpdate` and `extensions.autoCheckUpdates` are both off, why the migration
uninstalls the gallery copies first, and why the check after a switch is:

```bash
find ~/.vscode/extensions -maxdepth 1 -type l ! -name '.*' | wc -l   # expect 16
```

The `! -name '.*'` is load-bearing, not tidiness: `.nix-managed-extensions.json` — the
file whose change triggers the regeneration hook — is itself a symlink, so a plain
`-type l` counts 17 and the check fails on a correct machine. `!` rather than `-not`
because `!` is POSIX; both were verified against `/usr/bin/find`.

Use `find`, not `ls -l | grep -- '->'`. That pipeline reported **0** on a correctly
switched machine on 2026-08-26, because the interactive `ls` here renders symlinks with
`⇒` rather than `->` — a shell alias silently turned a passing check into a failing one.
`find -type l` depends on neither the alias nor the arrow, and every symlink at that
depth is a Nix one: VS Code's own installs are real directories.

**A planted symlink is not a loaded extension.** VS Code does not rescan its extension
directory — `extensions.json` is the authority, and a symlink appearing beside it changes
nothing. Measured 2026-08-26 right after a switch that planted all 16 correctly:
`code --list-extensions` listed **none** of them; deleting `extensions.json` and
re-running it listed all 16 at their pinned versions. home-manager ships an onChange hook
for exactly this, gated on `package != null` — so `package = null` switches it off.
`modules/_files/vscode/regenerate-extensions-json` replaces it, and is also on `PATH` as
`+vscode-regen-extensions`.

That script refuses rather than acting when `.obsolete` is non-empty, and the reason is
the nastier half of the same problem: uninstalling an extension only QUEUES its directory
for deletion, and a rescan run while the queue is full picks those directories up again.
Because they carry a version suffix and the Nix symlinks do not, the higher version wins.
Measured the same day: regenerating with 39 queued directories resurrected five
uninstalled extensions and pinned GitLens to the gallery's 19.0.1 over the pinned 18.3.0.
Only VS Code clears that queue, by starting once — which is why the script is on `PATH`
for a human to re-run.

Related, and the reason to check the directory rather than the exit code:
`code --uninstall-extension` reported `OK` for `jrebocho.vscode-random` while its
directory was neither deleted nor queued, and a later rescan registered it again.

`mutableExtensionsDir = true` keeps that directory real and writable, which is what lets
project-specific extensions be installed into it by hand. The alternative — a single
directory symlink — would make VS Code's own `extensions.json` unwritable.

#### settings.json is read-only, so anything that wants to write it loops forever

`programs.vscode` renders `~/Library/Application Support/Code/User/settings.json` as a
symlink into `/nix/store`. Every write therefore fails with `EACCES`, and nothing in the
UI says so beyond a toast — the evidence is one line in
`~/Library/Application Support/Code/logs/<session>/window1/renderer.log`:

```
[error] Unable to write file 'vscode-userdata:…/User/settings.json'
        (EntryWriteLocked (FileSystemError): EACCES: permission denied)
```

**A setting whose TYPE changed upstream is the usual cause, and it is invisible in the
value.** Measured 2026-08-26 against VS Code 1.134.0: `extensions.autoUpdate` was written
here as `false`, which VS Code no longer accepts — it declares
`{ type: "string", enum: ["on", "off"] }` and registers a migration beside it that rewrites
`false` to `"off"`. That migration runs at **every** start, and its result can never be
saved, so it runs again next time. The value was not wrong in meaning, only in type, and a
diff of the two files showed exactly one differing key out of 41.

Two things follow. Audit the whole class rather than the one key: VS Code 1.134.0 registers
31 configuration migrations, and `extensions.autoUpdate` was the only one intersecting this
repo's settings — worth re-checking after a major version jump, by grepping
`registerConfigurationMigrations` in `workbench.desktop.main.js`. And use
`just vscode-settings-check`, which reads the newest log session for exactly these write
attempts. It deliberately reports "inconclusive" (exit 2) when that session predates the
last switch — it compares the session name against the `lstat` mtime of the settings
symlink, which home-manager re-creates on every activation — because "VS Code has not
started since" must never be reported as "clean".

**Settings Sync is the second writer, and it is a structural conflict, not an accident.**
Both Macs get `hm.vscode` from `modules/home-manager-base.nix`, and their two files cannot
be identical: `terminal.integrated.profiles.osx` embeds
`/etc/profiles/per-user/<username>/…`. Each side therefore wants to write the other's
values into a file it may not touch. Measured on the same day: 5 of 5 syncs failed, and
the last successfully applied state (`sync/settings/lastSyncsettings.json`) was months old
— frozen precisely because a failed write is never acknowledged.

The fix is to tell Sync that Nix owns these keys, generated rather than hand-listed:

```nix
userSettings = managedSettings // {
  "settingsSync.ignoredSettings" = builtins.attrNames
    (managedSettings // { "extensions.autoCheckUpdates" = false; });
};
```

Two details in those three lines. `extensions.autoCheckUpdates` is named explicitly
because home-manager merges it in **after** this attrset (out of
`enableExtensionUpdateCheck`), so `attrNames` cannot see it. And
`settingsSync.ignoredSettings` itself is deliberately absent from its own list: the
setting carries `disallowSyncIgnore`, VS Code filters it out at runtime anyway, and naming
it would show up as "Value is not accepted" against its own enum schema. Keys of
extensions that are not installed can draw the same cosmetic hint — they are still
honoured, because the list is evaluated as plain strings.

#### The `[Theme]`-scoped colour warnings are a VS Code bug, not a bad value

VS Code 1.134.0 marks **every** property inside the theme-scoped
`workbench.colorCustomizations` block with `Property editorBracketPairGuide.background1 is
not allowed.` The colours are applied regardless, and the colour ids are registered — the
schema is at fault. A `[Theme]` block is validated against
`{ $ref: "vscode://schemas/workbench-colors", additionalProperties: false }`, and the
bundled JSON language service now follows draft-2019-09 semantics, where a `$ref` no
longer contributes the `properties` annotation that `additionalProperties` consults (only
`unevaluatedProperties` would). Every property in the block is therefore rejected, while
the same keys one level up validate — top level has no `additionalProperties: false`
anywhere in its schema chain.

Upstream is [microsoft/vscode#328165](https://github.com/microsoft/vscode/issues/328165),
closed for 1.135.0. Do not silence it by dropping the `[Theme]` scoping: that would leak
this repo's cyberpunk bracket colours into every other theme, to fix a warning that the
next cask update removes.

### The iTerm2 Web profile carries its DuckDuckGo settings in the URL

`modules/misc.nix` installs
`modules/_files/darwin/iTerm2/DynamicProfiles/50_Nix.json`, whose `Web` profile
opens a WKWebView browser session at its `Initial URL`. The search settings ride
in that URL rather than being clicked together once per machine:

```json
"Initial URL": "https://start.duckduckgo.com/?kae=t&kbi=1&kp=-2&kpsb=-1"
```

`kae` theme, `kbi` compact results, `kp` safe search, `kpsb` the "Protected"
reminder; the full list is <https://duckduckgo.com/params>. Each setting also
exists as a cookie named after the parameter minus its leading `k` — `kp` → `p`,
`kae` → `ae`.

Five facts decide what this can and cannot do. Each was measured against the live
site on 2026-08-24; DuckDuckGo ships continuously, so re-measure rather than trust
the list.

- **Mind the domain: the settings cookies are host-only on `duckduckgo.com`, and
  `start.duckduckgo.com` therefore never receives them.** The parsed cookie jar
  shows `duckduckgo.com` with no leading dot, so it is not a domain cookie. A
  machine whose settings are configured by hand still opens the start page with
  DuckDuckGo's defaults, and only picks the settings up once a search lands on
  `duckduckgo.com`. Everything the profile needs on the start page must be in the
  URL.
- **The search form forwards the search settings but drops the theme.** Typing a
  query on the start page produces
  `duckduckgo.com/?…&kp=-2&kpsb=-1&kbi=1&q=…` — `kl`, `k1` and `kaf` travel too,
  and they survive follow-up searches. `kae` does not, on either start page. The
  results page therefore themes itself from the cookie, or from
  `prefers-color-scheme`, which macOS Dark Mode drives. Measured with the browser
  forced to `prefers-color-scheme: light`, so the browser could not fake the
  result.
- **URL parameters never write cookies.** They override per request, which is why
  they cannot fight a machine's own saved settings beyond the keys they name.
- **Plain `duckduckgo.com/` is the promotional homepage** ("Switch to DuckDuckGo",
  "Download Browser"). `duckduckgo.com/?startpage=1` renders the same minimal page
  as `start.duckduckgo.com` on the origin that holds the cookies, which would make
  the theme apply there as well — but that parameter appears only in the page's own
  JavaScript, so a silent removal would drop the profile onto the promotional page.
- **Cloud Save can be automated, and deliberately is not.**
  `?key=<SHA-512 hex of the passphrase>` sets the cloud key and triggers
  `GET /settings.js?key=…`, which returns the saved settings or 404. That key reads
  *and* overwrites the blob, and DuckDuckGo stores it unencrypted, so it is a
  bearer token — it belongs in 1Password, not in a git-tracked profile or a URL
  that lands in browsing history.

To read what a machine currently has, parse iTerm2's own WebKit store — it
persists across restarts, which is what makes a one-time manual setup stick:

```bash
cd ~/Library/WebKit/com.googlecode.iterm2/WebsiteDataStore/*/   # one store, keyed by UUID

# Cookies/Cookies.binarycookies carries the settings cookies in Apple's binary
# format, so reading it needs a parser rather than grep. The domain recorded
# there has no leading dot — that is the host-only property above, on disk.

# localStorage: the origin files are length-prefixed binary (hence -a), and
# duckduckgo.com and start.duckduckgo.com are separate origins with separate
# databases — only the former carries duckduckgo_settings and objectKey. The
# value is UTF-16, so `cast(value as text)` in the sqlite3 CLI stops at the
# first NUL byte and prints a lone `{`.
for f in Origins/*/*/origin; do
  grep -aq 'duckduckgo\.com' "$f" || continue
  db=${f%/origin}/LocalStorage/localstorage.sqlite3
  [ -f "$db" ] || continue
  sqlite3 "file:$db?mode=ro" \
    "select hex(value) from ItemTable where key='duckduckgo_settings';" |
    python3 -c 'import sys;print(bytes.fromhex(sys.stdin.read().strip()).decode("utf-16-le"))'
done
```

`objectKey` there is the Cloud Save key — treat it as a credential.

Editing the profile follows the usual path: change the JSON, `just build`,
`just switch`. iTerm2 re-reads dynamic profiles live, so no restart is needed.

### Updating flake inputs

**Use `just update`, not `nix flake update`.** They are not the same command any more.
`nix flake update` always jumps every input to the CURRENT head of its branch, which is
precisely the window a supply-chain attack lives in. `just update` runs
`scripts/supply-chain.py`, which resolves each input to the newest revision that is at
least N days old and writes those revisions into `flake.lock`.

**Policy lives in `scripts/supply-chain.toml`, not in the recipes or the code** — the
cooldowns, the per-input overrides and the freeze list, each with the measurement that
justifies it. The same file drives `just audit`, so the check and the thing being
checked cannot drift apart. Defaults: 5 days for flake inputs, 14 for npm packages and
VS Code extensions, matching `modules/supply-chain-hardening.nix`.

Measured on 2026-08-22, and the reason this exists: a plain `nix flake update` in this
repo moved six inputs to a HEAD committed the same day — worktrunk 0.1 days old,
home-manager 0.2, llm-agents 0.3, devenv 0.5, determinate 0.6, nix-homebrew 0.8 — while
the ChainDrop/Shai-Hulud npm campaign was live and still classified active by CSA
advisory AD-2026-009. Nothing in the repo said a word about it.

**Why a cooldown rather than a scanner.** The poisoned ChainDrop tarballs carried valid
npm provenance and SLSA L3 attestations, signed by GitHub Actions through Sigstore: every
cryptographic check passed, because the source was trojanized before the build ran. A
vulnerability scanner answers "clean" for exactly as long as it matters. Age is the one
signal an attacker cannot forge — malicious releases are typically pulled within hours to
days, so declining to be the first consumer turns most of these incidents into a
non-event. This is the same reasoning `modules/supply-chain-hardening.nix` already
applies to npm/pnpm/bun/uv, moved one level up to the flake inputs.

Four behaviours worth knowing, each of which cost a measurement:

- **The cooldown lives in `flake.lock`, not `flake.nix`.** `nix flake lock
  --override-input <name> github:<o>/<r>/<rev>` writes the explicit rev while leaving
  `original` as plain branch-tracking. The consequence: **a bare `nix flake update`
  silently discards the cooldown.** `just update` is the only update path that honours
  it, exactly as `just switch` is the only supported apply path.
- **nixpkgs channel branches are exempt, automatically, and must stay that way.**
  `nixos-26.05` and `nixos-unstable` advance only to revisions Hydra has built and
  tested; their HEAD is the published channel. The commits *between* two heads were never
  published as a channel, so they are neither Hydra-validated nor covered by
  cache.nixos.org. Cooling nixpkgs down trades "2 days old and fully cached" for "5 days
  old, never validated, rebuild the world". Verified:
  `channels.nixos.org/nixos-26.05/git-revision` returned exactly the branch head a plain
  update had locked, while a 5-day cooldown selected the intermediate commit `5c11f83f0`.
  The script detects this via channels.nixos.org and reports those inputs as `channel`.
- **A `ref` may be a branch or a tag, and guessing from the string does not work** —
  `6.0.17` and `release-26.05` are both plausible either way. Each `ref` is resolved
  against the GitHub branches endpoint: branch → cooldown applies, tag → immutable, `nix
  flake update` never moved it anyway.
- **"Immutable" says `just update` will not move it — not that it is soaked.** Skipping
  tag pins in layer 1 is right, but it leaves the bar to whatever moves them by hand, and
  for a long time nothing did: `just brew-bump` took `releases/latest`. Measured
  2026-09-01, that resolved to Homebrew 6.0.21 **twelve hours** after publication, in the
  repo whose entire update path exists to avoid being the first consumer of anything.
  The three tag pins therefore now split into two classes. `brew-src` is scripted and
  cooled: the recipe calls `supply-chain.py release Homebrew/brew`, which picks the newest
  release clearing `[cooldown] inputs` and prints every candidate it declined and why —
  a silent skip would read as "not published yet". A tag passed as an argument still
  overrides the bar, and says so on stderr. `yt-dlp-src` and `agent-browser-src` are
  edited by hand and have **no** gate at all; check the release date yourself before
  bumping either.
- **FlakeHub inputs are covered too, and yanks are honoured.** `determinate` is a semver
  *range* (`…/determinate/3`), so it re-resolves on every lock — a floating range on the
  root `nix-daemon` would defeat every cooldown in the repo. It moved 3.21.8 → 3.22.2
  (0.7 days old) on that same update. The script reads FlakeHub's releases endpoint,
  which carries `published_at` **and `yanked_at`**, and pins `=<version>`. That yank
  filter earned its keep immediately: determinate 3.22.0 was old enough at 15 days but
  had been yanked on 2026-08-17, so the script correctly fell back to 3.21.9.

- **An update never moves an input BACKWARDS.** Raising a bar — say `nixpkgs-llm-agents`
  from 5 to 14 days — would otherwise roll the lock back to a revision that has already
  been built, cached and possibly deployed, to fix a problem that waiting fixes anyway.
  The regression is reported, not silent: *"5b3a7eff4 (5.2d) is NEWER than the 14d bar's
  pick df0664e9f (14.5d) — not rolled back; it clears the bar on its own in 8.8d."*
  `--allow-rollback` forces it, for the one case that wants it: a lock polluted by a
  bare `nix flake update`.

`just update-preview` shows the decision without writing anything, and re-running
`just update` when there is nothing to do exits 0 and says so. `just update-head` is the
deliberate bypass — if you use it, write down why in the commit body.

#### `just audit` — the other half, and a different question

`just pulumi-audit` asks *"is anything KNOWN-bad?"* against OSV. `just audit` asks *"is
anything suspiciously NEW, or has upstream WITHDRAWN it?"*. Do not let one be reported
as if it answered the other: on 2026-08-04 ChainDrop's poisoned tarballs carried valid
npm provenance and SLSA L3 attestations, and every scanner said clean.

The second half of that question is the one a cooldown alone misses. **A withdrawn
artifact is the strongest signal available**, because the ecosystem emits it *after*
someone found the problem — and age cannot express it, since a malicious version pulled
yesterday is still "old enough" tomorrow. So each layer checks presence as well as age:
FlakeHub `yanked_at`, npm `unpublished` or a version missing from the registry's `time`
map, and for a VS Code extension a 404, a `deprecated` flag, or a chosen version that
has vanished from `allVersions` while the extension itself survives. That is not
hypothetical — on its first real run it rejected determinate 3.22.0, comfortably old
enough at 15 days and yanked on 2026-08-17.

Layer 2 exists because **an input's age bounds its contents only from below, and
loosely.** Measured with `nixpkgs-llm-agents` at 5.2 days old, the npm packages inside
it were claude-code 7.9 d, opencode 9.6 d, gemini-cli 10.8 d, ccusage 7.1 d — every one
still inside the 14-day npm bar. Hence the per-input override raising that input to 14.

Two traps in layer 3, both found by testing rather than reading docs:

- **Open VSX `allVersions` begins with ALIASES, not versions** — measured,
  `['latest', 'pre-release', '0.4.3022', …]`. Both resolve to a real manifest, so a
  naive walk "finds" one and pins the literal string `latest`: a floating pointer, i.e.
  exactly what this tool exists to prevent. Only keys starting with a digit are used.
- **The per-version walk is capped at 40 and says so.** Open VSX costs one request per
  version and some extensions ship nightlies (rust-analyzer lists 100). A bounded search
  that reports "no suitable version" without saying how far it looked is
  indistinguishable from a real absence.

`[[extensions]]` in the manifest is deliberately empty until the default-extension set
is actually wired into a module; `just audit-extensions <id>…` exercises the machinery
meanwhile.

The cooldown bounds the age of everything *inside* an input from below (a llm-agents.nix
rev from 14 days ago cannot pin an npm version published yesterday), but it is a soak,
not a verdict: it says nothing about whether that older code is malicious, and it cannot
help against an attack nobody notices for longer than the threshold.

**The date is attacker-settable, and that defines what the cooldown is for.** The
committer date this sorts by is chosen by whoever makes the commit — measured
2026-08-22, `GIT_COMMITTER_DATE=2019-01-01 git commit` yields an input this tool reports
as 2790 days old. So anyone who already controls the upstream repo walks through the
bar, and the same holds one level down: npm's `time` map and GitHub's `published_at` are
supplied by the party being audited. What the cooldown *does* defend against is the
common shape of these incidents — a compromised account publishes, the release is live
for hours, someone notices, it gets pulled — where simply not being an early consumer
takes you out of the blast radius. Do not present it as more than that.

**The largest uncovered surface is Homebrew, not Nix.** The generated Brewfile carries
83 casks and **zero version strings** (`cask "1password", trusted: true`); Homebrew 6
resolves them from a rolling JSON API at `just switch` time
(`~/Library/Caches/Homebrew/api/cask.jws.json`, ~20 MB), entirely outside `flake.lock`.
1Password, Firefox, Brave, Chrome and ChatGPT install whatever that API serves at
activation. No cooldown, pin or audit in this repo covers any of it.

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
   `.dependencies`. This is the common case: `2c665a6` (tar, brace-expansion),
   `964d3c9` (seven advisories at once).
2. **It does not fit → bump the direct dependency** in `infra/package.json` so the
   floor is encoded where a human will see it (`^3.0.0` → `^3.252.0`). Example:
   `430370e`.
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
