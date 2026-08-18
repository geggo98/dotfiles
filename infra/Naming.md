# Naming: machines, sites, realms, and two domains with distinct jobs

Every machine here used to be named for a different reason: the VPS was `ionos-vps` in
the flake and `p-ion-ber-xs56r6` in the IONOS panel, the NAS was `nas-aleuten` in the
tailnet, the Macs are serial numbers. There were no names for *services* at all. This
file is the rule that replaces that, and — more usefully — the evidence behind each part
of it, so a future change can argue with the reasoning instead of guessing at it.

The scheme is enforced in code, not only described here: `src/inventory.ts` validates
every name against the grammars below when the module loads, so a malformed name breaks
`tsc` and `pulumi preview` rather than sitting in a table looking plausible.

## Two grammars, because two things are un-migratable

**Physical — where it stands:**

```
p-<provider>-<site>-<rand6>          p-ion-berlin-xs56r6
                                     p-own-muenchen-j5jghb
```

**Virtual — what it runs on:**

```
[vc]-<arch>-<rand6>                  v-amd64-k9y25p     virtual machine
                                     c-arm64-h6pedq     system container
```

A physical machine is pinned to a place, so it carries the place. A virtual one is
supposed to move, so it carries the only thing moving cannot change.

| Field | Values | Why it is in the name |
|---|---|---|
| type | `p` physical · `v` VM · `c` container | the one boundary with no conversion path — see below. `p` means "I do not own the hypervisor", so a rented VPS counts as physical |
| provider | `ion` IONOS · `own` own hardware | who supplies the metal |
| site | `berlin` `muenchen` `lengenwang` | spelled out, no codes; nothing forces abbreviation (see limits) |
| arch | `amd64` `arm64` | not convertible in practice. **Never `x86_64`** — RFC 1123 forbids `_` in host names, and nixpkgs warns about it explicitly |
| rand | 6 chars from `a-hjkmnp-tv-z2-9` | the only field that is genuinely stable. `i l o u` and `0 1` are excluded so a name can be read aloud and cannot accidentally spell something |

Generator: `tr -dc 'a-hjkmnp-tv-z2-9' < /dev/urandom | head -c 6`

**Macs are exempt and keep their serial** (`FCX19GT9XR`, `DKL6GDJ7X1`). A serial does the
same job as the random field — stable, and carrying no semantics that can go stale — and
on the work machine it is not negotiable anyway.

### What is deliberately *not* in the name

**The virtualization ecosystem** (kvm, proxmox, libvirt, vmware, xen, incus). It is the
most *movable* layer of the stack, so encoding it would pin the thing likeliest to
change:

- `virt-v2v` converts VMware, Xen and Hyper-V guests to run on KVM, injecting the drivers
  the guest needs. It is a supported, routine operation.
- Proxmox VMs, libvirt domains and Incus VMs **are** QEMU/KVM. Moving a guest between
  those management stacks is a config translation; the guest does not change.
- Disk formats convert with `qemu-img convert` (raw, qcow2, vmdk, vdi, vhdx).

One honest limit: cross-hypervisor migration is *offline*. Live migration only works
within one hypervisor family — and there the name would not change anyway.

**The role.** It lives in DNS (below), so retiring or moving a role costs one CNAME line
instead of a flake attribute, a sops path, a tailnet node and a DNS record.

### Why the type letter carries VM-vs-container

Because that is the boundary conversion does not cross. A container supplies a **root
filesystem** and shares the host's kernel; a VM needs a **bootable disk** with its own
kernel and bootloader. The Incus documentation is explicit that you cannot create a
virtual machine from a running container — going either direction is a rebuild, not a
migration. Everything else in this list converts; this does not, so this is what the
name records.

## Limits: nothing here forces abbreviation

| Limit | Value | Source |
|---|---|---|
| `networking.hostName` | **63** | nixpkgs regex `^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$` in `nixos/modules/tasks/network-interfaces.nix` |
| DNS label / FQDN | 63 / 253 | RFC 1035 |
| Linux `HOST_NAME_MAX` | 64 | kernel `__NEW_UTS_LEN` |
| macOS `HOST_NAME_MAX` | 255 | `getconf HOST_NAME_MAX` |
| **NetBIOS / SMB name** | **15** | SMB inheritance; Samba truncates silently |

The longest name in use is `p-own-lengenwang-ra4jpy` — 23 characters. It fits everywhere
except NetBIOS, and **no variant of this scheme reaches 15**: even `p-own-len-ra4jpy` is
16. So do not contort the hostname for SMB. Set Samba's `netbios name` explicitly
instead (`NAS-LENGENWANG`, 14) — SMB browsing wants a role name, which is exactly what
the hostname deliberately is not.

The same nixpkgs option documentation carries the underscore warning that rules out
`x86_64` as a name component: *"Do not use underscores (\_) or you may run into
unexpected issues."*

## DNS: the label says which network

```
<name>.pub.0xf1a5c0.net           public address
<name>.tailnet.0xf1a5c0.net       tailnet address
<name>.muenchen.0xf1a5c0.net      address inside the Munich LAN (10.2.0.0/24)
<name>.lengenwang.0xf1a5c0.net    address inside the Lengenwang LAN (later)
```

No split horizon: every name has exactly one answer, the same everywhere, and the name
says which path you are taking. With four routes to the same host — public IP, WireGuard,
tailnet, MagicDNS — that is the point of the exercise, not a stylistic preference.

**Services are CNAMEs onto machine names, one per realm:**

```
mqtt.muenchen.0xf1a5c0.net   CNAME   p-ion-berlin-xs56r6.muenchen.0xf1a5c0.net
mqtt.tailnet.0xf1a5c0.net    CNAME   p-ion-berlin-xs56r6.tailnet.0xf1a5c0.net
```

The bare `<name>.0xf1a5c0.net` is deliberately left free. Filling it in would hide the
"over which network?" question that the realm label exists to answer.

**Mobile hosts get no records.** The Macs' only stable address is the tailnet one, and
MagicDNS already names it. An A record for a laptop would be a promise the DHCP lease
cannot keep.

### Which domain, and why it is a technical decision

> `0xf1a5c0.net` carries machines and internal services.
> `schwetschke.dev` carries everything published — mail, www, services for humans.

The reason is measured, not aesthetic: **the FRITZ!Box strips private addresses out of
public DNS answers.** Using `nip.io`, which resolves any embedded address:

```
dig @10.2.0.1  10.2.0.203.nip.io   ->  (empty)
dig @1.1.1.1   10.2.0.203.nip.io   ->  10.2.0.203
dig            10.2.0.203.nip.io   ->  10.2.0.203    (default resolver = MagicDNS)
```

That is DNS rebind protection, and it means internal names in public DNS need an
exception entry in *Heimnetz → Netzwerk → Netzwerkeinstellungen → DNS-Rebind-Schutz*.
The exception applies **per domain**. Granting it to an infrastructure domain has a far
smaller blast radius than granting it to the domain that also carries mail.

Measured again on the real records once they existed, which corrected an assumption
worth stating because the correction is the more useful fact:

| resolver | A `10.2.0.203` | AAAA `fd11:1b58:53c0::203` |
|---|---|---|
| `1.1.1.1`, `8.8.8.8` | answers | answers |
| FRITZ!Box `10.2.0.1` | **NXDOMAIN** | **NXDOMAIN** |
| MagicDNS `100.100.100.100` | **empty** | answers |

Two things follow. The FRITZ!Box does not strip the private *record*, it denies the
whole *name* — NXDOMAIN, while `…pub.0xf1a5c0.net` on the same query path resolves
fine, so this is the rebind protection and not a zone problem.

And **Tailscale is not an escape from it.** MagicDNS forwards to the system's other
resolvers, the FRITZ!Box among them, so it inherits the filter — here partially, which
is worse than inheriting it wholly: a client gets an AAAA and no A, so the failure
depends on whether the caller can use IPv6 rather than being uniformly visible. Which
upstream served which query is not established and is not worth relying on either way.

So the exception is needed for tailnet devices too, and "it works over Tailscale" is
not evidence that it works.

`just infra-verify` therefore queries `@10.2.0.1` explicitly for site realms, so the
exception is a checked state rather than a setting someone silently loses to a factory
reset.

### Two documented exceptions

**`nix-cache.pub.schwetschke.dev` stays where it is.** Its signing key is named
`nix-cache.pub.schwetschke.dev-1:…`, and that name appears in every narinfo signature
already shipped. Moving the domain would mean either a key name that no longer matches
the domain, or invalidating every existing signature.

**`pub` rather than `public`** — the short form comes from that same frozen name, and
consistency with it beats consistency with the spelled-out site labels.

## The machines

| Name | Was | Realms |
|---|---|---|
| `p-ion-berlin-xs56r6` | `ionos-vps` / `p-ion-ber-xs56r6` | pub, tailnet, muenchen |
| `p-own-lengenwang-c5esve` | `nas-aleuten` | tailnet |
| `p-own-lengenwang-ra4jpy` | `nas-aleuten-blikvm` | tailnet |
| `p-own-muenchen-j5jghb` | `nas-muenchen` | — not in the tailnet, no address known |
| `p-own-muenchen-k9y25p` | its PiKVM | — none yet |
| `FCX19GT9XR`, `DKL6GDJ7X1` | unchanged | none, by the mobile-host rule above |

Sites are the actual places: `berlin` is the IONOS datacentre, `muenchen` is Hallsteinweg
(the FRITZ!Box LAN, `10.2.0.0/24`), `lengenwang` is Aleutenstraße. The addresses live in
`src/inventory.ts`; this table is the naming map only.

Only the VPS is renamed today. The NAS names are reserved and take effect when those
hosts are converted to NixOS.

## Things this scheme deliberately does not do

**`deployTarget` stays an IP literal.** `modules/hosts/*.nix` argues it already: the
route used to rescue a host should not depend on that host's own DNS. A naming scheme is
not a reason to make the rescue path longer.

**Renaming a machine is expected to be rare and is not free.** It touches the flake
attribute, `hosts/<name>/`, the `.sops.yaml` path regex, the secrets module name,
justfile defaults, the tailnet node name and its MagicDNS name. That cost is the reason
roles live in DNS: a role changing must not become a machine renaming.

One thing that is *not* part of that cost: re-encrypting secrets. sops stores its
recipients inside the file, and `.sops.yaml` only governs future writes — so moving
`hosts/<old>/secrets.enc.yaml` to a new path needs the rule updated, not the file
re-encrypted. `sops -d` on the moved file is the proof.
