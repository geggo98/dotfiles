# p-own-lengenwang-c5esve (`nas-aleuten`)

Survey of 2026-08-18, taken to decide how this machine is converted to NixOS and what
has to leave it first. Facts here were measured on the machine, not read off a
datasheet. Regenerate with:

```bash
just infra-recon root@nas-aleuten.great-fiordland.ts.net > /tmp/nas-recon.txt
```

The raw 1652-line output is deliberately **not** committed: it carries share
definitions, export ACLs and account names, and this repository is public. The summary
below is what survives review; re-run the command when you need the rest.

Machine facts that belong in the inventory (hardware, host key, addresses) live in
`../src/inventory.ts`, not here, so `just infra-verify` can check them.

## Summary

A healthy 2018-class Supermicro storage server carrying ~1 TiB of data on **one
consumer NVMe with no redundancy and no backup of any kind**, running a TrueNAS SCALE
release that went end-of-life years ago. Nothing is failing. Everything is
single-point.

The conversion cannot preserve the data in place: `boot-pool` and the data pool
`boot-ssd-storage` are two partitions of the *same* disk, so a reinstall destroys both.
The data has to be copied off the machine and back.

## Access

| Route | Address | Notes |
|---|---|---|
| SSH | `nas-aleuten.great-fiordland.ts.net` / `192.168.2.115` | OpenSSH 8.4p1, key-only for root. **Enabled during this survey — see "What changed"** |
| Web UI | same, ports 80/443 | TrueNAS SCALE, `truenas_default` self-signed cert |
| BliKVM | `p-own-lengenwang-ra4jpy` over the tailnet | HDMI capture + USB HID + 5 GiB emulated storage. The only out-of-band route from outside the LAN — and the one to use |
| IPMI / BMC | `192.168.2.100` (DHCP, dedicated port) | Verified: `/dev/ipmi0`, `ipmi_si` loaded, `midclt call ipmi.query`. **LAN only, never expose** — see below |

### The BMC is the weakest link, not a second safety net

The board carries its own KVM over IP, and it is tempting to treat that as the good
remote route. It is not, and the reasoning is worth keeping:

A BMC is a second computer with complete authority over the first — it reads and writes
host memory, mounts virtual media, and keeps running when the host is powered off.
Compromising it is not "access to a management page", it is ownership of the machine.
Meanwhile Supermicro BMC firmware is rarely updated after purchase, and IPMI 2.0 has
weaknesses in the protocol itself that no firmware update fixes: the RAKP handshake
hands a password hash to any client that asks for it, and cipher suite zero accepts
authentication that never happened. What is running here announces itself as
`dropbear 2019.78`.

It currently sits on the flat house LAN with a DHCP lease, reachable by anything else on
that network. That is the present state, not a design decision, and segmenting it is a
candidate for the rebuild. In the meantime: never port-forward it, never put it on the
tailnet, and use the BliKVM for anything remote.

Tailscale SSH is **not** enabled here; port 22 is real sshd.

`root` logs in by key only. TrueNAS' `rootlogin` flag stayed `false` and key auth still
works, which settles a question the plan left open: SCALE 22.12 emits
`PermitRootLogin without-password` for that setting, not `no`.

## Hardware

Supermicro **A2SDi-12C-HLN4F** (board serial `OM224S031552`), Intel Atom C3858
(Denverton, 12 cores), 64 GiB DDR4 **ECC** in 1 of 4 slots (max 256 GiB), 4 × GbE of
which only `eno1` is connected.

The chassis and system serial are Supermicro's unset placeholder `0123456789` — a
concrete illustration of why `infra/Naming.md` gives non-Macs a random suffix instead of
trusting a serial number.

### USB peripherals

`usbutils` is not installed, so this came from sysfs (`/sys/bus/usb/devices`), which is
what `just infra-recon` now reads — "(no lsusb)" was a useless answer to "what is plugged
in".

```
usb1  xHCI @ 0000:00:15.0
├── 1-2      1d6b:0106  smart-kvm "Multifunction USB Device"  serial 6b65796d696d6570690
│            └── if0 HID keyboard · if1 HID mouse · if2 usb-storage   <- the BliKVM
└── 1-3      05e3:0610  Genesys Logic USB2.0 hub
    ├── 1-3.1    0557:7000  ATEN hub
    │   └── 1-3.1.1  0557:2419  ATEN HID, low speed: keyboard + mouse   <- ATEN KVM switch
    └── 1-3.2    05e3:0610  Genesys Logic USB2.0 hub
```

Three things this settles:

- **The BliKVM is the `sda` "disk".** One device presents keyboard, mouse *and* mass
  storage; interface 2 (class 08, `usb-storage`) is what appears as `sda`, model
  `File-Stor_Gadget`, serial identical to the USB device. Storage class next to HID
  siblings is a KVM emulating a drive, not a drive.
- **There is a second, local KVM.** Vendor `0557` is ATEN; `0557:2419` is a low-speed
  HID composite — the emulated keyboard/mouse an ATEN KVM switch presents to an attached
  host. So the machine hangs on a hardware KVM as well as the networked BliKVM. Only the
  BliKVM is reachable remotely, so only it is listed under `outOfBand` in the inventory.
- **There is no USB stick, and no UPS.** Nothing else is attached at all. Worth stating
  plainly given the assumption that a stick held the ZFS keys — it does not exist. And a
  storage server on a single non-redundant QLC drive with no UPS is a combination worth
  revisiting during the rebuild.

### Storage — the decisive part

One disk. Crucial **CT4000P3PSSD8** (P3 Plus, 4 TB, QLC), serial `2317E6CE9565`,
firmware `P9CR40A`, partitioned:

```
nvme0n1p1     1 M   BIOS boot
nvme0n1p2   512 M   EFI
nvme0n1p3    64 G   boot-pool          (2.68 G used)
nvme0n1p4    16 G   swap, encrypted
nvme0n1p5   3.6 T   boot-ssd-storage   (1.02 T used of 3.55 T)
```

Both pools are single-vdev. `zpool status` names one device each and the UI states
*"No Redundancy"* outright. There is no second disk: the only other block device is
`sda`, 5 GiB, model `File-Stor_Gadget` — the BliKVM's emulated USB mass storage, **not a
USB stick**.

Health is not the problem. SMART PASSED, **7 % endurance used**, 21.6 TB written,
26 161 power-on hours (~3 years), 40 °C. Both pools ONLINE, 0 errors, last scrubs clean
(`boot-ssd-storage` 2026-08-16, 51 minutes).

## Encryption — read this before wiping anything

Five datasets are encrypted, each its own encryption root:

```
Download  Familie  Filme  Musik  eBooks
encryption   aes-256-gcm
keyformat    hex
keylocation  prompt          <-- not a file, anywhere
keystatus    available       <-- unlocked right now, because the pool has not rebooted
```

`keylocation prompt` means ZFS itself loads no key material from disk. TrueNAS holds the
hex keys in its own configuration database, which lives on `boot-pool` — **on the
partition a reinstall erases**. There is no USB stick holding them; `lsblk` shows no such
device.

Two consequences:

1. **Export every dataset key before touching the disk.** Store in 1Password, labelled
   per dataset. Never in this repository.
2. **Do not reboot** until the data is off. The datasets lock on boot, and the unlock
   path runs through the same configuration database.

### Exporting and verifying the keys

`pool.dataset.export_key` is a **job**, so it needs `-job`; without it midclt returns a
job id and you get an integer where you expected a key. With it, stdout is exactly 64
hex characters and nothing else. Prefer the raw hex over "Manage Configuration →
Download File": the config blob is only restorable *into TrueNAS*, whereas 64 hex
characters can be handed to `zfs load-key` from any rescue system — which is the
situation these keys exist for.

```bash
# Export all five, tab-separated, ready to paste into 1Password.
ssh root@nas-aleuten.great-fiordland.ts.net \
  'for d in Download Familie Filme Musik eBooks; do
     printf "boot-ssd-storage/%-9s\t%s\n" "$d" \
       "$(midclt call -job pool.dataset.export_key "boot-ssd-storage/$d" 2>/dev/null)"
   done'
```

Verification uses **`zfs load-key -n`**, a dry run that checks a key against the
dataset's wrapping key without loading it. It works while the dataset is *unlocked*, so
there is no unmount, no service interruption and no risk of locking yourself out. This
is the test that matters — it takes what is in 1Password and asks the pool:

```bash
# Copy the key out of 1Password first; pbpaste keeps it out of shell history.
pbpaste | ssh root@nas-aleuten.great-fiordland.ts.net \
  'umask 077; t=$(mktemp); cat > "$t"; \
   zfs load-key -n -L "file://$t" boot-ssd-storage/Filme; shred -u "$t"'
```

`1 / 1 key(s) successfully verified` is the pass. A trailing newline in the pasted key
does not matter (measured).

The check discriminates — verified by feeding it a deliberately wrong key, which
answers `Key load error: Incorrect key provided` and `0 / 1 key(s) successfully
verified`. A verification that can only ever say OK proves nothing, so that control is
worth repeating if the procedure is ever changed.

**What this does and does not buy.** Exported keys defend against exactly one failure:
the machine rebooting before the data is off, which locks every dataset. They also keep
the door open to reading this pool from a rescue system later. They are **not a backup**
— if the single NVMe fails, the keys unlock nothing.

## Data

1.02 TiB used. Sizes are ZFS `used`, i.e. after `zstd-fast` compression; the ratios are
low enough that logical size is within a percent or two, except `eBooks` (1.13×).

| Dataset | Used | What it actually is | Backup? |
|---|---|---|---|
| `Filme` | 765 G | films, SMB share | yes — and it is 75 % of the upload |
| `Download` | 241 G | Mediathek recordings, each in 4–5 resolutions, plus `.part` fragments. Quota 250 G, CRITICAL at 96 % since 2025-03 | **probably not** — reviewable, largely re-acquirable |
| `Musik` | 33.7 G | music, SMB share | yes |
| `eBooks` | 4.61 G | **not just books** — see below | yes |
| `Familie` | 98 K | **empty.** Created 2023-08-24, never filled | nothing to save |
| `ix-applications` | 1.14 G | k3s state | no — does not survive the conversion anyway |

### `eBooks` is not redundant with `~/eBooks`

Checked, because the assumption was that the local copy made it disposable. It does not:

```
NAS   25 896 files   2 188 unique book filenames
Mac    1 756 files   1 754 unique book filenames
overlap by filename: 57
```

The layouts differ (`Books/<Author>/<Title>.epub` and a Calibre library on the NAS,
`<Title>/` on the Mac), so filename overlap understates real duplication — but not by
enough to matter, because the bulk of the dataset is something else entirely. The
largest branch is `Clara Schumann` with **23 830 files**: 5 604 YAML, 3 728 Ruby, 2 941
HTML, 1 755 JPEG, 1 521 PDF, 1 140 GIF, 822 Scala, plus a `Perry_Rhodan` folder. That is
the backup of an older machine, not a bookshelf. Keep it.

### The photos are not here

`Familie` is empty, and a search across the whole pool finds **zero** photo files in
`Familie`, `Musik` and `Download`. The image files that exist are cover art
(`Filme` 6 270, `eBooks` 2 433). Wherever the family photos are, this machine is not it —
worth establishing before anyone treats this NAS as their archive.

## Services

SMB (`Filme`, `Familie`, `eBooks`, `Musik`, all `purpose: MULTI_PROTOCOL_NFS`) and NFS
(`/mnt/boot-ssd-storage/Download`, exported to `127.0.0.1/32`, `192.168.2.0/24` and
`100.0.0.0/8` — the whole tailnet range). FTP, iSCSI, WebDAV, S3, SNMP, rsync, TFTP,
OpenVPN all stopped. 30 systemd services running.

Apps run on k3s, which TrueNAS drops in favour of Docker from SCALE 24.10 — so the app
layer needs rebuilding regardless of what we do:

- `ix-tailscale` — 1/1 Running, **20 520 restarts**. This is how the host is on the
  tailnet; it is a container, not a host daemon, and NixOS' native module replaces it.
- `ix-jdownloader` — 2/2 Running, **109 692 restarts**, most recent minutes ago. A crash
  loop running for roughly 18 months. It explains both the full `Download` dataset and
  the long-dead tailnet node `jdownloader-nas-aleuten`.
- Several `Error` / `TaintToleration` pods left from 596 and 800+ days ago.
- The TRUECHARTS catalog has failed to sync since 2024-07-12 (CRITICAL alert); that
  catalog no longer exists upstream.

There are **no virtual machines** (`midclt call vm.query` → `[]`), despite the machine
being sized for them.

## Network

`eno1`: `192.168.2.115/24` **by DHCP** (`midclt call interface.query` → `ipv4_dhcp: true`,
no static aliases), SLAAC `2003:eb:1f05:d8e7:7ec2:55ff:fe12:210e/64`. That settles why no
`lengenwang` DNS realm is published: an A record here would be a promise a DHCP lease
cannot keep, which is the same rule `Naming.md` applies to the workstations. Gateway
`192.168.2.1` is a **Speedport** (Telekom), not a FRITZ!Box — the DNS-rebind behaviour
measured in Munich says nothing about this site. Nameservers `192.168.2.1`, `fe80::1`,
`8.8.8.8`. Hostname `nas-aleuten`, domain `local`, additional domain
`great-fiordland.ts.net`.

**Uplink: 2.2–2.6 MB/s upload** (~17–21 Mbit/s), measured three times against
Cloudflare's speed endpoint from both this host and the BliKVM. That is the number that
sizes every backup plan:

| | at ~2.4 MB/s |
|---|---|
| `Musik` + `eBooks` (≈ 39 GiB) | ~5 hours |
| `+ Filme` (≈ 804 GiB) | ~4 days |
| everything incl. `Download` | ~5.3 days |

Saturated, i.e. the household connection is unusable meanwhile unless throttled.

## What changed during this survey

Recorded because a survey that quietly modifies its subject is worse than no survey.

1. **SSH enabled.** `root`'s `sshpubkey` set to the 1Password Homelab key
   (`SHA256:YEUc7NtEQhufJSJroPQqWBvEULURYRJSiC9cKWJKgiE`), service `enable: true` and
   started. Both reversible from the same UI. `passwordauth` was already `true` and was
   left untouched; `rootlogin` stays `false`.
2. **Clock corrected.** It ran **+7 h 37 min** ahead. Root cause: `ntp.service` in
   `failed` state (`ExecMainStatus=255`) since the last boot on 2026-04-18 — classic
   `ntpd` refuses any correction beyond 1000 s and exits, which makes the fault
   self-sustaining. Fixed with `ntpd -gq` (stepped −27 417 s), `hwclock --systohc`, then
   restarting the unit; `ntpq -pn` now selects a stratum-1 peer and the host agrees with
   a workstation to the second.

   This was a precondition, not housekeeping: S3 SigV4 rejects any request whose
   timestamp is more than 15 minutes out, so no object-storage backup could have worked.

   **Trap for the next reader:** `timedatectl` still reports `System clock
   synchronized: no` and `NTP service: n/a`. That flag describes `systemd-timesyncd`,
   which is not installed here (`not-found`); classic `ntpd` never sets it. Check
   `ntpq -pn` instead.

3. **Nameservers reordered** to `1.1.1.1`, `8.8.8.8`, `192.168.2.1` (was the Speedport
   first, then `fe80::1`, then `8.8.8.8`), via
   `midclt call network.configuration.update`. Reason below — it blocked the backup
   outright.

### The Speedport breaks Go's DNS resolver, and only for some names

`restic` is a static Go binary and therefore uses Go's own DNS resolver. Pointed at the
R2 endpoint it failed every time, immediately:

```
dial tcp: lookup 81e63dbf073ca45ebf67c430beac09a4.r2.cloudflarestorage.com
  on 192.168.2.1:53: no such host
```

Everything that would normally explain that was measured and ruled out:

| checked | result |
|---|---|
| glibc (`getent hosts`, `socket.gethostbyname`) via the same resolver | resolves correctly |
| raw UDP queries to 192.168.2.1 — A and AAAA, with and without EDNS0 | 80/80 succeeded |
| response shape — source address, transaction id, TC bit, RCODE, echoed question | all correct, 2×A and 2×AAAA returned |
| concurrent A+AAAA, the pattern Go actually uses | 10/10 succeeded |
| other names through Go via the same resolver (`s3.amazonaws.com`, `r2.cloudflarestorage.com`) | resolve fine |
| the `search`/`domain` lines in resolv.conf | irrelevant, tested with and without |

What settles it is the substitution test: with `nameserver 8.8.8.8` alone, restic works
instantly; with `nameserver 192.168.2.1` alone, it fails every time. An `/etc/hosts`
entry for the name also makes it work, which is consistent.

**The mechanism is not identified.** The failure cannot be reproduced outside Go, and
guessing at one would be worse than saying so. What is established: it is the Speedport,
it is specific to Go's resolver, and it is not intermittent. The household has seen DNS
oddities with this router on other devices too, so this is likely one instance of
something broader rather than a quirk of this host.

Practical consequence for the NixOS rebuild: **do not let this router be the first
resolver.** Any Go program — and that is most of the modern infrastructure toolchain —
inherits this failure mode.

## The backup

Repository: `s3:https://<account>.r2.cloudflarestorage.com/restic-backup/p-own-lengenwang-c5esve`,
id `c88e1334f4`, restic 0.18.1 on both ends (the appliance runs the official
static release, hash-verified against the GPG-signed SHA256SUMS; the workstation
gets it from the devenv shell). Credentials and repository password come from
sops — `restic_r2_access_key_id`, `restic_r2_secret_access_key`,
`restic_password` — and the password is also in 1Password, because a restic
repository without it is unrecoverable by design.

**Phase 1** (`Musik`, `eBooks`, `Familie`), snapshot `0bbb0e05`:

```
32051 files, 5968 dirs
38.910 GiB processed · 37.725 GiB added · 36.708 GiB stored
4:15:47 at full uplink speed
```

Verified before anything else was started, in two independent ways:

* `restic check --read-data` — 2239/2239 packs read back and their MACs
  verified, `no errors were found`, 1:38:46. Two `readFull: unexpected EOF`
  appeared mid-run and both succeeded on the first retry: transport hiccups, not
  damage.
* A real restore to a workstation — 20 files, 187 MiB, compared by SHA-256
  against the originals on the appliance: **20 identical, 0 differing, 0
  missing**. Read *from the Mac* with the password *from sops*, i.e. exactly the
  path that has to work once this machine no longer exists.

Restore throughput was ~8.5 MB/s from R2, roughly 3.5× the upload rate. That
asymmetry is the number that matters in an actual recovery.

**Phase 2** (`Filme`) runs throttled to `--limit-upload 1776`, i.e. 75 % of
2369 KiB/s — measured over 92 s against the running phase-1 job (2.43 MB/s) and
consistent with three Cloudflare speed tests (2.20 / 2.62 / 2.64 MB/s). Costs
~6 days instead of ~4.5, and leaves the household a quarter of the line.

It now covers 962 GiB, not the 765 GiB originally planned, and phase 3 has been
folded into it: once the 204 decoded recordings moved to `Filme/OTR` (+149 GiB)
and 35 Mediathek files were filed into `Filme/Infuse` and
`Filme/This Is Going To Hurt` (+48 GiB), both phases addressed the same path.
`/root/backup-phase2.sh` and `backup-phase3.sh` are therefore renamed
`.superseded`; `/root/backup-filme.sh` is the one to run.

Note on finding that +48 GiB: `find -newermt` reported **nothing**, because the
files were copied with their mtimes preserved (2023/2024). `find -newerct`
found all 35 at once. mtime is not the time a file appeared.

### An unattended multi-day upload must restart itself

`restic` resumes cheaply, and that was the whole argument for not worrying about
interruptions. It was half the story, and the missing half cost 28 hours.

The phase-2 run died at **03:50** on 2026-08-20 with `Fatal: unable to save
snapshot: … dial tcp: lookup ….r2.cloudflarestorage.com: i/o timeout`, then sat
idle until someone looked. The timestamp is the diagnosis: **German ISPs force a
reconnect nightly**, handing out a new IP, with the line dead for 10–30 minutes.
Both sites do this. It is a scheduled event, not a fault — and an upload that
takes six days meets it six times.

The error text points at DNS and invites blaming the Speedport's EDNS0 bug
(above). It was not that. `1.1.1.1` and `8.8.8.8` are `nameserver1`/`2` here, the
Speedport is only the third fallback; Go named it because it was the last
resolver it tried after all of them timed out.

`/root/backup-filme.sh` wraps restic in a restart loop. Four decisions in it are
load-bearing:

- **`systemd-run` does not set `HOME`.** First start logged `unable to open
  cache: neither $XDG_CACHE_HOME nor $HOME are defined` — restic then runs
  *without its local cache* and re-fetches the index from R2 on every restart,
  which is exactly the cost the restart loop exists to avoid. Pass
  `--setenv=HOME=/root`.
- **No exponential backoff.** Backoff exists to spare an overloaded service; here
  the service is healthy and the line is gone. Exponential retreat would idle up
  to 15 minutes past the end of a 10-minute outage, every night. A flat 60 s plus
  a real reachability probe (`getent hosts` **and** a TCP connect to :443 —
  after a redial the resolver often answers before the route is back) costs
  nothing per attempt.
- **Restarting is genuinely cheap, checked rather than assumed.** Uploaded packs
  are in the index and do not go over the line again — of 107.8 GiB in the bucket
  on 2026-08-21, 36.7 GiB was phase 1 and the remaining 71.1 GiB was what the
  aborted run had already achieved and kept. Without a parent snapshot restic
  must re-read and re-hash all 962 GiB, but the CPU reports `sha_ni`, so SHA-256
  runs in hardware: minutes, not hours. **This is why splitting the upload into
  per-directory stages is unnecessary here** — on a CPU without `sha_ni` that
  calculation flips.
- **`--json` plus a filter, or the log stays silent.** Without a TTY restic draws
  no progress bar, so the aborted run left no trace of how far it got — the only
  way to answer "how far along is it" was to measure the bucket with `rclone
  size`. The wrapper lets a status line through every 5 minutes and passes
  everything else verbatim.

restic's exit codes are mapped deliberately, per the resumability rule in
`AGENTS.md`: `0` done, `3` done but some files were unreadable (a valid snapshot
— not an error, and not to be retried), anything else means no snapshot, so wait
and restart. A missing `.restic-env` or binary exits `2` immediately: no amount
of waiting fixes it, and patiently retrying would hide it.

`Download` (241 GiB, now 356 GiB with snapshots) is deliberately not backed up —
see the OTR section below.

### The second copy: R2 → Dropbox, driven from the VPS

Prepared but **not yet runnable** — the five secrets below are declared and not
encrypted yet, and a `nixos-deploy` before they exist fails at activation, not
at build. That is the NixOS class's behaviour, not an oversight; see the sops
note in `AGENTS.md`.

`modules/nixos-backup-copy.nix` puts rclone and two manually-started template
units on `p-ion-berlin-xs56r6`:

```bash
systemctl start backup-copy-to-dropbox@p-own-lengenwang-c5esve   # ~1 TB
systemctl start backup-copy-check@p-own-lengenwang-c5esve        # sizes only
```

**Why the VPS and not a Mac.** Measured from the box on 2026-08-21: 37.0 MB/s
from R2 (319 MB in 8.6 s, against our own nix-cache) and 91.2 MB/s outbound
(100 MB in 1.1 s). Both homes are behind lines that drop nightly and whose
upstream is a fraction of their downstream. IONOS states "Unbegrenzt Traffic bis
zu 1 Gbit/s" with no fair-use clause on the product page — caveat, that is the
product page and not the Core VPS contract.

**Why rclone and not `restic copy --from-repo`.** `restic copy` decrypts the
source and re-encrypts into the destination, so it needs the repository password
— the one secret that unlocks every backup — on the only machine here that faces
the open internet. rclone copies the encrypted objects verbatim. The VPS
therefore holds a **read-only** R2 credential and a Dropbox token, and nothing
that can damage the original.

The trade is that a byte-identical copy would copy damage too. Sequencing
answers that rather than tooling: `restic check --read-data` against R2 *first*,
then copy, then verify the destination *as a repository* from a workstation —
`restic -r rclone:dropbox:restic-backup/<prefix> check`, which needs the
password and deliberately does not run on the VPS.

Note `rclone copy`, never `sync`: sync deletes whatever the source lacks, which
is exactly wrong if the source is ever truncated.

**Cost is a deadline, not a rate.** R2 egress is free in both classes, so the
copy itself is ~$0.02 in Class B operations — *while the objects are still
Standard*. The lifecycle rule demotes `<prefix>/data/` to Infrequent Access 30
days after upload, and IA charges $0.01/GB to read: the same copy afterwards
costs ~$10.30. `restic check --read-data` has the identical exposure. Phase-1
objects were written 2026-08-19 and turn cold on **2026-09-18**; the Filme
objects follow at the end of September.

**Still to do, in this order:**

1. An R2 API token scoped to the `restic-backup` bucket with permission group
   **"Workers R2 Storage Bucket Item Read"** only — no write group. Cloudflare
   shows the native S3 pair once; those are the values, not the `cfat_…` token,
   and they need no SHA-256 derivation (unlike `modules/nix-cache.nix`).

   The group's ID is `6a018a9f2fc74eb6b293b0c548f38b39`, confirmed against
   Cloudflare's own docs source (`r2/api/tokens.mdx:161`, `:210-211`), resource
   class `com.cloudflare.edge.r2.bucket` — the object tier, not the
   account-level "Workers R2 Storage" groups.

   **Restricting the token by IP works on the S3 endpoint — measured, because no
   Cloudflare page states it.** R2's token page defers the whole envelope to
   *Create API tokens via the API* without saying whether `condition` reaches the
   S3 data plane. Settled here on 2026-08-21 by an A/B test: the *same* command
   with the *same* credentials returned `403 AccessDenied` from the Munich
   workstation and succeeded through the IONOS Tailscale exit node. One command,
   two routes — which is also the first production use of that exit node.

   The token in use restricts to `2a01:239:485:8d00::/80` (the subnet IONOS
   assigns) plus `87.106.149.208/32`. Three notes, two of which correct
   plausible-sounding advice:

   * **`/80` works.** A 2023 community report has `/8 /16 /32 /128` working and
     `/48 /64` returning 500, which reads like "unusual prefix lengths break".
     It does not generalise: `/80` was measured working here. Either the bug was
     narrower than it looked or it has been fixed. Do not avoid a prefix on the
     strength of that report alone — but do test after changing it.
   * **`request_ip` (underscore) works**, at least as the API returns it, even
     though the docs' examples write `request.ip` with a dot. The dot form is
     what the documentation shows for *input*; the underscore is what came back
     and it is demonstrably in force. Verify by test, not by spelling.
   * **List IPv4 *and* IPv6.** Not optional: `curl` on this host picks IPv6
     unprompted and Cloudflare sees `2a01:239:485:8d00::1`. A v4-only allow-list
     would fail on the first connection. (No temporary addresses are in play —
     `use_tempaddr=0` on `ens6`, and the address arrives via DHCPv6 as a `/128`,
     which privacy extensions do not touch.)

   **`restic check` fails with a read-only token, and the error misleads.** It
   takes an *exclusive lock*, which is a PutObject into `locks/`, so it dies on
   lock creation rather than on reading — pointing at the repository instead of
   at the credential. Use `restic check --read-data --no-lock`. Expect the same
   trap from anything else that "only reads".
2. A **dedicated** Dropbox app, access type **App folder** (not Full Dropbox),
   then `rclone authorize dropbox <client_id> <client_secret>` on a Mac and keep
   the JSON it prints. rclone's shared built-in app is throttled across all its
   users worldwide, which on 1 TB is the difference between a day and a week.

   **Order matters, and getting it wrong is silent until it isn't.** Dropbox:
   *"Just adding a scope to your app via the App Console does not retroactively
   grant that scope to existing access tokens or refresh tokens."* A token
   carries the scopes that existed **when it was issued**. So:

   1. *Permissions* tab → tick `account_info.read`, `files.metadata.read`,
      `files.metadata.write`, `files.content.read`, `files.content.write` →
      **Submit** (the button is easy to miss, and without it nothing is saved)
   2. *only then* `rclone authorize`

   Do it the other way round and every write fails with `missing_scope/` —
   observed here on 2026-08-21 with `rclone mkdir`. The same applies to any
   later scope change: it needs a fresh `rclone authorize`, not just a tick.

   Diagnosing it takes one command, because read and write scopes fail
   separately: `rclone lsd db:` needs only `files.metadata.read`, while
   `rclone mkdir` needs `files.content.write`. If listing works and mkdir does
   not, the write scopes are missing; if both fail, the token predates all of
   them.

   **The button labelled *Generated access token* is a trap for this job.** It
   issues a token that expires in ~4 hours with no refresh token — fine for a
   scope check, fatal for a 12–24 h transfer. `modules/nixos-backup-copy.nix`
   refuses to start if `dropbox_token` contains no `refresh_token`, rather than
   dying mid-transfer with a 401 that looks like a network fault.

   So the shortest path is to skip the button entirely: once the scopes are
   submitted, a single `rclone authorize` yields a token that has both the
   scopes and a refresh token.

   Verified end to end on 2026-08-21: `rclone mkdir db:restic-backup` succeeded
   and the folder appeared at **`/Apps/nix-restic-backup/restic-backup`** — the
   path itself confirming the App-folder scope holds, since rclone's `restic-backup`
   resolved *inside* the app directory and not at the account root.
3. `sops edit hosts/p-ion-berlin-xs56r6/secrets.enc.yaml` and add this block,
   leaving the two existing `wireguard_wg0_*` keys where they are:

   ```yaml
   restic:
     r2_ro:
       access_key_id: <from the Cloudflare token dialog>
       secret_access_key: <from the same dialog>
     dropbox:
       client_id: <Dropbox app key>
       client_secret: <Dropbox app secret>
       token: <the whole JSON rclone authorize printed>
   ```

   Nested, not five more `restic_r2_*` keys at the top level. `key` and `name`
   are separate options in sops-nix, so the file gets structure while
   `/run/secrets` keeps flat, predictable filenames — see the header of
   `hosts/p-ion-berlin-xs56r6/secrets.nix` for why that matters and why the
   NixOS module's own "no nested data structures" note is wrong.

4. `sops edit secrets/secrets.enc.yaml` and regroup the seven existing keys the
   same way. **No new values here — these are moves.** Until the file and
   `modules/secrets.nix` agree, `just build` fails with `manifest is not valid:
   … the key 'nix_cache' cannot be found`, which is the home-manager class
   catching it at build time rather than at activation.

   ```yaml
   nix_cache:
     r2:
       access_key_id:     <was r2_access_key_id>
       secret_access_key: <was r2_secret_access_key>
     signing_key:         <was nix_cache_signing_key>
   restic:
     password:            <was restic_password>
     r2:
       access_key_id:     <was restic_r2_access_key_id>
       secret_access_key: <was restic_r2_secret_access_key>
       token:             <was restic_r2_token>
   ```

   Nothing that reads these files changes: `nix-cache-push` still opens
   `r2_access_key_id`, `r2_secret_access_key` and `nix_cache_signing_key` by
   name, because `path` is built from the attribute name and not from `key`.
5. Deploy, then run the copy — but only after the Filme backup has finished.
   Copying a repository that is being written to yields an inconsistent copy.

**Deployed and verified on 2026-08-21.** Two results worth keeping:

* Activation logged `adding secrets: dropbox_client_id, dropbox_client_secret,
  dropbox_token, r2_backup_ro_access_key_id, r2_backup_ro_secret_access_key` —
  all five nested `key` paths resolved, which is the NixOS class doing exactly
  what its own documentation says it cannot.
* `systemctl start backup-copy-verify-credentials` → *"OK -- Bucket ist
  lesbar"*, *"OK -- Schreiben wurde abgelehnt, wie es sein soll."* Because it
  ran from the allow-listed address, the refused write measures the
  **permission** and not the origin — which is the whole reason that probe lives
  on the VPS rather than on a workstation.

## The OTR recordings, and why `Download` was not throwaway

`Download` was excluded from the backup on the assumption that it held
re-acquirable Mediathek recordings. That was true of a fifth of it. Measured
before deciding anything:

```
206 .otrkey   151.73 GiB   169× Doctor Who, 24× Pumuckl, 2016-2024 — ENCRYPTED
 97 .mp4       84.72 GiB   Mediathek, each title in up to 9 resolutions
  6 .part       0.60 GiB   aborted downloads
```

**None of it existed decoded elsewhere.** The cross-check was done both ways: the
`.otrkey` names carry the decoded filename, and `Filme` uses the same TVOON
scheme — but its 124 TVOON files are from 2012–2021 and contain no Doctor Who at
all, so the sets are disjoint. Two apparent title matches on the mp4 side were
false: *Der Staatsfeind Nr. 1* (1998) is not *Becoming Nawalny – Putins
Staatsfeind Nr. 1*, and *Apocalypse Now Redux* is a different cut from *Final
Cut*.

Cleanup removed 33.3 GiB (resolution duplicates keeping the largest per title,
two SHA-256-confirmed duplicate otrkeys, and the fragments). The remaining
149 GiB was decoded and the encrypted originals deleted.

### Decoding: get the keys first, decrypt later

`otrdecoder` is proprietary and `otrtool` (last release 2023) targets
`gencode2.php`, which is now **404**. [ilyich](https://github.com/not-a-user/ilyich)
uses the current endpoint `/quelle_neu1.php`. OTR itself is alive — the homepage
carries developer comments dated 2026-07-21.

Two changes were needed and both are worth knowing:

* `Crypto` → `Cryptodome`. The appliance already ships **pycryptodomex**, so
  nothing had to be installed on it — no pip, no venv, no lasting change.
* `SCHEME = 'http'` → `'https'`. The endpoint serves HTTPS identically (measured).
  Over plain HTTP the account **email travels in clear text**, and while the
  password is Blowfish-encrypted, the key derives from `md5(password)` with known
  plaintext from block 2 onward — offline-guessable by anyone on the path.

**The order matters more than the tooling.** `ilyich fetch` retrieves the
keyphrases into a local cache without decrypting anything. Once
`/root/.ilyich_cache.json` holds all 204, the dependency on onlinetvrecorder.com
is gone and decryption is pure local computation. That step takes minutes and
should always come first; it earned its keep immediately, because the decode run
that followed failed 142 times and the cache made those retries free.

Those 142 failures were **`[Errno 122] Disk quota exceeded`**, every single one:
`decoded/` was created inside the 250 GiB-quota'd dataset. Quota raised to
450 GiB; the peak needs 357 GiB while originals and outputs coexist, and it can
go back to 250 once the snapshot below is destroyed.

Result: 204/204 decoded and verified against the hash in each otrkey header
(`ilyich verify`), then the originals deleted with a per-file re-verification.
Snapshots were taken first — `Download@pre-otr-unlink-2026-08-20` plus
`<dataset>@pre-migration-2026-08-20` on all five data datasets. They cost nothing
to make and now hold the 149 GiB of deleted originals, so `used` did not drop:
`usedbysnapshots` went from 0 to 149 GiB. **Space is only reclaimed by
`zfs destroy`**, which should wait until the decoded files are backed up.

They are not backed up yet. `Download` still sits outside the restic repository,
so 169 Doctor Who episodes and 24 Pumuckl episodes exist in exactly one place, on
the disk this migration intends to erase.

### Operating notes paid for once

* **`check` takes an EXCLUSIVE lock.** While it runs, every other client fails
  with `repository is already locked exclusively`. Read-only work alongside it
  needs `--no-lock` (safe: it only skips lock *creation*). This will matter more
  with 765 GiB, where the check runs for many hours.
* **restic prints no progress when stdout is not a terminal.** Under `tee` in
  tmux the log stays silent until the summary. Measure progress at the bucket
  instead: `aws s3 ls s3://restic-backup/<prefix>/ --recursive --summarize`.
* **The workstation's restic lives in the devenv shell**, and direnv does not
  watch `modules/devshell.nix` — adding a package there appears to do nothing
  until `.envrc` is touched.

## Open questions

- Where are the family photos? Not on this machine.
- Is `Download` disposable? 241 GiB of re-acquirable recordings, and it is the
  difference between a 4-day and a 5.3-day upload.
- Redundancy after the rebuild. Four DIMM slots with one module, and a single disk in a
  chassis built for more. The rebuild is the moment to change that or to decide
  deliberately not to.
