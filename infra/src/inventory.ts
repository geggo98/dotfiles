/**
 * Every machine, the addresses it answers on, and the facts that are true about it.
 *
 * Two jobs, and it is worth keeping them apart:
 *
 *   1. **The naming scheme lives here in executable form.** `../Naming.md` explains the
 *      rule and the evidence behind it; the regexes and checks at the bottom of this
 *      file *enforce* it, on module load, so a malformed name breaks `tsc` and
 *      `pulumi preview` instead of quietly reaching a zone file. The checks also catch
 *      the mistakes that are invisible in review: a public address pasted into a LAN
 *      realm, a tailnet address outside 100.64.0.0/10, a site in the name that
 *      disagrees with the `site` field.
 *
 *   2. **It is the source `../src/dns.ts` derives DNS records from**, so the addresses
 *      recorded here and the addresses published are the same values by construction,
 *      not by anyone remembering to update both.
 *
 * These are hand-maintained constants, not resources -- nothing here talks to a
 * provider, and `pulumi preview` detects no drift in them. That is unavoidable for the
 * IONOS VPS specifically, and the reason is worth stating once so nobody spends an
 * afternoon on "just add a provider":
 *
 * The IONOS VPS lives in the **Cloud Panel** (`cloudpanel.ionos.de/panel/corevps/...`),
 * which is a different product family from IONOS Cloud / DCD with a different API.
 * Two independent walls, either one sufficient:
 *
 *   1. `@ionos-cloud/sdk-pulumi` (and the Terraform provider it bridges) speaks only
 *      to `api.ionos.com/cloudapi/v6`. terraform-provider-ionoscloud issue #273 asks
 *      exactly whether it can drive the Cloud Panel; it was closed without a feature.
 *   2. The Cloud Panel API (`cloudpanel-api.ionos.com/v1`) needs a key issued under
 *      Management -> User -> API. This tariff's Cloud Panel has no User entry at all,
 *      so no key can be issued. Consistent with that API's public changelog ending at
 *      release 1.11, November 2019, and with IONOS scoping its docs to "Cloud Servers
 *      and Dedicated Servers" -- never VPS or Core VPS.
 *
 * `just infra-verify` supplies the drift detection Pulumi cannot: it scans host keys and
 * resolves every name recorded here. An inventory you cannot falsify is documentation
 * wearing an inventory's clothes.
 */

/** Architectures we run. `x86_64` is deliberately absent -- see Naming.md on underscores. */
export type Arch = "amd64" | "arm64";

/** Physical places. Spelled out; nothing forces abbreviation (Naming.md, "Limits"). */
export type Site = "berlin" | "muenchen" | "lengenwang";

/**
 * The domain machines and internal services live in. Anything published for humans --
 * mail, www, `nix-cache.pub.schwetschke.dev` -- lives in schwetschke.dev instead.
 *
 * That split is technical rather than cosmetic: the FRITZ!Box strips private addresses
 * out of public DNS answers, and the rebind exception that re-enables them is granted
 * per domain. Granting it to an infrastructure domain is a much smaller blast radius
 * than granting it to the domain that also carries mail. See ../Naming.md.
 */
export const machineZone = "0xf1a5c0.net";

/**
 * The places, and the resolver that serves each LAN.
 *
 * The resolver matters to `just infra-verify`: a site realm publishes RFC 1918
 * addresses, and the device that has to resolve them is the one using the LAN's own
 * resolver -- guests, IoT, anything without Tailscale. Querying that resolver directly
 * is what turns the FRITZ!Box rebind exception from an unmanaged setting into a
 * checked one.
 */
export const sites = {
  berlin: { description: "IONOS Cloud Panel datacentre", resolver: undefined },
  muenchen: { description: "Hallsteinweg, 81739 Muenchen", resolver: "10.2.0.1" },
  lengenwang: { description: "Aleutenstrasse, 87663 Lengenwang", resolver: undefined },
} as const satisfies Record<Site, { description: string; resolver: string | undefined }>;

/** Where a machine answers within one realm: `<name>.<realm>.<zone>`. */
export function fqdn(name: string, realm: Realm): string {
  return `${name}.${realm}.${machineZone}`;
}

/** Who supplies the metal. `own` is our own hardware, `ion` is IONOS. */
export type Provider = "ion" | "own";

/**
 * A DNS realm is the network an address is valid in, and it is the label between the
 * machine name and the domain: `<name>.<realm>.0xf1a5c0.net`.
 */
export type Realm = "pub" | "tailnet" | Site;

/** One address family pair inside one realm. Either half may be absent. */
export interface Endpoint {
  readonly v4?: string;
  readonly v6?: string;
}

/** The type letter of the name. See Naming.md for why VM-vs-container is the one that matters. */
export type Kind = "physical" | "vm" | "container" | "workstation";

/** How -- and whether -- this repository manages the machine today. */
export type Managed = "nixos" | "nix-darwin" | "unmanaged" | "planned";

/**
 * The virtualization stack. Deliberately NOT part of any name: `virt-v2v` moves guests
 * between VMware/Xen/Hyper-V and KVM, and Proxmox, libvirt and Incus VMs are all
 * QEMU/KVM, so this is the most movable layer in the whole picture. It belongs in a
 * field that can be edited, not in an identifier other things point at.
 */
export type Ecosystem = "kvm" | "proxmox" | "libvirt" | "incus" | "vmware" | "xen";

export interface Machine {
  readonly kind: Kind;
  readonly arch: Arch;
  /** What it does. Also not in the name -- roles move, and DNS is where that costs one line. */
  readonly role: string;
  readonly managed: Managed;
  /** Addresses per realm. A realm with no entry simply produces no DNS records. */
  readonly addresses: { readonly [R in Realm]?: Endpoint };

  /** Physical machines only; must agree with the name. */
  readonly provider?: Provider;
  /** Physical machines only; must agree with the name. Absent on VMs on purpose. */
  readonly site?: Site;
  readonly ecosystem?: Ecosystem;

  /** The name the machine still carries today, where the rename has not happened yet. */
  readonly renameFrom?: string;
  /** Operating system as installed, not as desired. */
  readonly os?: string;

  /**
   * Public SSH host key, `ssh-keyscan` format minus the address column.
   *
   * Ed25519 only, deliberately: the host also offers RSA and ECDSA keys, but OpenSSH
   * prefers Ed25519 by default and all three are regenerated together on a reinstall --
   * so one is enough to detect drift, and three would be noise. Public key material;
   * safe to commit, and exactly what `known_hosts` wants.
   */
  readonly ssh?: { readonly hostKeyEd25519: string };

  /**
   * What the *provider's* firewall permits inbound, as configured in its console.
   * Provider-side and unreachable by any API, so nothing can reconcile it against the
   * host's own firewall -- recorded so the two are at least comparable.
   */
  readonly providerFirewall?: {
    readonly tcp: readonly number[];
    readonly udp: readonly number[];
  };
}

export const machines = {
  // --- IONOS Core VPS, Berlin ----------------------------------------------
  "p-ion-berlin-xs56r6": {
    kind: "physical",
    provider: "ion",
    site: "berlin",
    arch: "amd64",
    role: "vps",
    managed: "nixos",
    renameFrom: "ionos-vps",
    os: "nixos-26.05",
    addresses: {
      pub: { v4: "87.106.149.208", v6: "2a01:239:485:8d00::1" },
      tailnet: { v4: "100.79.162.28" },
      // Not a second interface in Berlin: this is the WireGuard address the FRITZ!Box
      // proxy-ARPs onto the Munich LAN, so from that LAN the host answers as if it hung
      // off the switch. See modules/nixos-wireguard-home.nix.
      muenchen: { v4: "10.2.0.203", v6: "fd11:1b58:53c0::203" },
    },
    // Regenerated by the NixOS install on 2026-08-17; the Ubuntu-era key
    // (...JHiT2qg...) is dead. `just infra-verify` failing on this value is the
    // check working, not a false alarm -- update it here when the host is
    // legitimately reinstalled, never silence it.
    ssh: {
      hostKeyEd25519:
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILpkgb2WWOEoZCzjXIQE81Z4LnYazELWDtZ4JPjQjrZd",
    },
    providerFirewall: {
      // 80/443/8443/8447 currently have nothing listening behind them: 8443+8447 is the
      // Plesk pair from IONOS' default template, not evidence of a Plesk install.
      // Candidates for deletion in the Cloud Panel.
      tcp: [22, 80, 443, 8443, 8447],
      // 51820 WireGuard (the FRITZ!Box dials in -- mandatory, the tunnel cannot be
      // established without it). 41641 Tailscale -- NOT mandatory: without it Tailscale
      // still works via DERP relays, just indirectly and with more latency.
      //
      // That UDP passes at all was *measured*, not assumed -- the provider firewall has
      // no API, so its rules cannot be read back. Method: open the port there, add a
      // temporary `iptables -I nixos-fw` rule on the host (whose firewall normally has
      // no UDP rule at all), run `nc -u -l`, send from a workstation. Proof was the
      // payload arriving *plus* the rule's packet counter at 3/216 bytes. Both the
      // temporary rule and the listener were removed afterwards. The policy was also
      // renamed from IONOS' default "My firewall policy" to `ionos-vps`.
      udp: [41641, 51820],
    },
  },

  // --- Own hardware, Aleutenstrasse, 87663 Lengenwang -----------------------
  "p-own-lengenwang-c5esve": {
    kind: "physical",
    provider: "own",
    site: "lengenwang",
    arch: "amd64",
    role: "nas",
    // Not converted yet. The name is reserved here so the conversion is a rename that
    // was already decided, rather than a decision taken while a machine is half-built.
    managed: "unmanaged",
    renameFrom: "nas-aleuten",
    ecosystem: "kvm",
    addresses: { tailnet: { v4: "100.121.105.41" } },
    // No `ssh` entry on purpose. Both Lengenwang machines are reachable over exactly one
    // route today, so a key scanned there cannot be cross-checked against a second one --
    // and on the tailnet address it is `SSH-2.0-Tailscale` answering. On the VPS that
    // turned out to serve the host's own key (measured, byte-identical to OpenSSH's), but
    // "turned out to" is not a property to rely on for a machine we cannot check twice.
    // Recording an unattributable key would produce a confusing failure the day tailscaled
    // state is reset. Add it when the NixOS conversion gives these hosts a second route.
  },

  // The out-of-band manager for the machine above -- its own computer, on its own
  // power, which is the entire point of it. Reachable when the NAS is not.
  "p-own-lengenwang-ra4jpy": {
    kind: "physical",
    provider: "own",
    site: "lengenwang",
    arch: "arm64",
    role: "kvm",
    managed: "unmanaged",
    renameFrom: "nas-aleuten-blikvm",
    addresses: { tailnet: { v4: "100.110.151.40" } },
  },

  // --- Own hardware, Hallsteinweg, 81739 Muenchen ---------------------------
  // Both entries are addressless on purpose: neither is in the tailnet today (checked
  // against `tailscale status`, which lists only the Lengenwang pair). Names reserved,
  // no records generated -- dns.ts skips a machine with no addresses.
  "p-own-muenchen-j5jghb": {
    kind: "physical",
    provider: "own",
    site: "muenchen",
    arch: "amd64",
    role: "nas",
    managed: "planned",
    renameFrom: "nas-muenchen",
    ecosystem: "kvm",
    addresses: {},
  },

  "p-own-muenchen-k9y25p": {
    kind: "physical",
    provider: "own",
    site: "muenchen",
    arch: "arm64",
    role: "kvm",
    managed: "planned",
    addresses: {},
  },

  // --- Workstations ---------------------------------------------------------
  // Serial numbers, exempt from the scheme: a serial is stable and carries no semantics
  // that can go stale, which is exactly what the random field buys elsewhere.
  //
  // No addresses, and that is a rule rather than an omission (Naming.md): the only
  // stable address a laptop has is its tailnet one, and MagicDNS already names it. An A
  // record here would be a promise a DHCP lease cannot keep.
  FCX19GT9XR: {
    kind: "workstation",
    arch: "arm64",
    role: "workstation-personal",
    managed: "nix-darwin",
    addresses: {},
  },

  DKL6GDJ7X1: {
    kind: "workstation",
    arch: "arm64",
    role: "workstation-work",
    managed: "nix-darwin",
    addresses: {},
  },
} as const satisfies Record<string, Machine>;

export type MachineName = keyof typeof machines;

// ---------------------------------------------------------------------------
// The scheme, enforced.
//
// Named groups throughout, per the repo's regex rule: the name documents the field and
// the pattern survives someone inserting a group ahead of it.
// ---------------------------------------------------------------------------

// matches:  p-ion-berlin-xs56r6  ->  provider=ion site=berlin rand=xs56r6
const PHYSICAL_NAME = /^p-(?<provider>[a-z]{3})-(?<site>[a-z]{3,16})-(?<rand>[a-hjkmnp-tv-z2-9]{6})$/;

// matches:  v-amd64-k9y25p  ->  arch=amd64 rand=k9y25p
const VIRTUAL_NAME = /^[vc]-(?<arch>amd64|arm64)-(?<rand>[a-hjkmnp-tv-z2-9]{6})$/;

// matches:  FCX19GT9XR   (Apple serial; the workstation exemption)
const SERIAL_NAME = /^[A-Z0-9]{10}$/;

/** RFC 1918 plus the fd00::/8 ULA range -- what may appear in a site realm. */
function isPrivate(address: string): boolean {
  if (address.includes(":")) return /^f[cd][0-9a-f]{2}:/i.test(address);
  return /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/.test(address);
}

/** 100.64.0.0/10, the CGNAT range Tailscale allocates from. */
function isTailnet(address: string): boolean {
  if (address.includes(":")) return /^fd7a:115c:a1e0:/i.test(address);
  const m = /^100\.(?<second>\d{1,3})\./.exec(address);
  return m !== undefined && m !== null && Number(m.groups!.second) >= 64 && Number(m.groups!.second) <= 127;
}

function check(condition: boolean, message: string): void {
  // Thrown, not logged: this file is imported by the Pulumi program, so throwing is what
  // turns a bad name into a failed `preview` rather than a warning nobody reads.
  if (!condition) throw new Error(`inventory: ${message}`);
}

for (const [name, m] of Object.entries(machines) as [string, Machine][]) {
  // 63 is the hard limit in three places at once: the DNS label, the Linux kernel, and
  // the nixpkgs regex behind networking.hostName.
  check(name.length <= 63, `${name}: ${name.length} characters, the limit is 63`);

  if (m.kind === "workstation") {
    check(SERIAL_NAME.test(name), `${name}: workstations are named by serial (10 chars, A-Z0-9)`);
    check(
      Object.keys(m.addresses).length === 0,
      `${name}: workstations get no records -- their only stable address is the tailnet one, which MagicDNS already names`,
    );
  } else if (m.kind === "physical") {
    const parts = PHYSICAL_NAME.exec(name)?.groups;
    check(parts !== undefined, `${name}: expected p-<provider>-<site>-<rand6>`);
    check(parts!.provider === m.provider, `${name}: name says provider ${parts!.provider}, field says ${m.provider}`);
    check(parts!.site === m.site, `${name}: name says site ${parts!.site}, field says ${m.site}`);
  } else {
    const parts = VIRTUAL_NAME.exec(name)?.groups;
    check(parts !== undefined, `${name}: expected ${m.kind === "vm" ? "v" : "c"}-<arch>-<rand6>`);
    check(parts!.arch === m.arch, `${name}: name says arch ${parts!.arch}, field says ${m.arch}`);
    check(m.site === undefined, `${name}: VMs and containers carry no site -- they are supposed to move`);
  }

  for (const [realm, endpoint] of Object.entries(m.addresses) as [Realm, Endpoint][]) {
    for (const address of [endpoint.v4, endpoint.v6].filter((a): a is string => a !== undefined)) {
      if (realm === "pub") {
        check(!isPrivate(address), `${name}: ${address} is private but recorded in the pub realm`);
      } else if (realm === "tailnet") {
        check(isTailnet(address), `${name}: ${address} is outside the tailnet range`);
      } else {
        // A site realm is a LAN. A public address here would be published under a name
        // that promises the opposite, and the FRITZ!Box rebind exception would not even
        // be needed to reach it -- so the mistake would look like it worked.
        check(isPrivate(address), `${name}: ${address} is not private but recorded in the ${realm} realm`);
      }
    }
  }
}
