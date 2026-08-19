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

## Open questions

- Where are the family photos? Not on this machine.
- Is `Download` disposable? 241 GiB of re-acquirable recordings, and it is the
  difference between a 4-day and a 5.3-day upload.
- Redundancy after the rebuild. Four DIMM slots with one module, and a single disk in a
  chassis built for more. The rebuild is the moment to change that or to decide
  deliberately not to.
