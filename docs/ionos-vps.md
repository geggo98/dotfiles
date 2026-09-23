# The IONOS VPS (NixOS)

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

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

