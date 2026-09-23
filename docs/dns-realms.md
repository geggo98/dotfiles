# DNS realms and the FRITZ!Box rebind exception

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

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

