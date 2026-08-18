/**
 * DNS for the machine domain, derived from the inventory.
 *
 * Every record here comes from `./inventory.ts`, so the addresses recorded and the
 * addresses published are the same values by construction rather than by anyone
 * remembering to edit both. Adding a machine with addresses is enough; adding a record
 * by hand in the dashboard shows up as drift on the next `preview`.
 *
 * The layout and the reasoning behind it are in ../Naming.md. The two things worth
 * repeating at the point where they are actually implemented:
 *
 *   * `<name>.<realm>.<zone>` — the realm label names the network the address is valid
 *     in, so a name never means "it depends where you ask".
 *   * Services are CNAMEs onto these machine names, one per realm, so moving a role is
 *     a one-line change here rather than a machine rename everywhere.
 */
import * as cloudflare from "@pulumi/cloudflare";
import {
  fqdn,
  machines,
  machineZone,
  type Endpoint,
  type Machine,
  type Realm,
} from "./inventory.js";

const zone = cloudflare.getZoneOutput({ filter: { name: machineZone } });

// --- Machine records --------------------------------------------------------
for (const [name, machine] of Object.entries(machines) as [string, Machine][]) {
  for (const [realm, endpoint] of Object.entries(machine.addresses) as [Realm, Endpoint][]) {
    for (const [type, address] of [["A", endpoint.v4], ["AAAA", endpoint.v6]] as const) {
      if (address === undefined) continue;

      new cloudflare.DnsRecord(`${name}-${realm}-${type.toLowerCase()}`, {
        zoneId: zone.zoneId,
        name: fqdn(name, realm),
        type,
        content: address,
        ttl: 300,

        // NOT proxied, and this is load-bearing rather than a default worth omitting.
        // Proxying replaces the answer with a Cloudflare anycast address, which would
        // defeat the entire purpose of a record whose job is to say where the machine
        // is — and for the private realms Cloudflare could not proxy them anyway.
        proxied: false,

        // Cloudflare caps comments at 100 characters, so this stays terse: its job is to
        // stop someone editing a generated record in the dashboard, not to explain.
        comment: `${machine.role}; generated from infra/src/inventory.ts`,
      });
    }
  }
}

// --- This domain sends no mail, and says so ---------------------------------
// Cheap insurance for a domain that carries machines: nothing here will ever send or
// receive mail, so publishing that fact costs three records and removes the domain as a
// spoofing vehicle. If that ever changes, this block is the single place to undo.
//
// TXT content carries LITERAL quotation marks on purpose. The v5/v6 `DnsRecord` resource
// (unlike v5's older `Record`.value) compares content against what the Cloudflare API
// returns, and the API returns TXT values quoted — omit them and every `preview` reports
// a change forever. See cloudflare/terraform-provider-cloudflare#5351 and #6354.
const mailTtl = 3600;

// Null MX (RFC 7505): "this domain accepts no mail", so senders fail immediately instead
// of retrying for days. Cloudflare's *dashboard* rejects this when the name field is `@`,
// which is where the "Cloudflare does not support null MX" reports come from; giving the
// zone name explicitly — which is what we do here — is the case that works. Confirm after
// the first apply with `dig 0xf1a5c0.net MX +short`, expecting `0 .`; if it comes back as
// `..` the provider mangled it and this record should simply be dropped, since SPF and
// DMARC below are what actually stop forgery.
new cloudflare.DnsRecord("mail-null-mx", {
  zoneId: zone.zoneId,
  name: machineZone,
  type: "MX",
  content: ".",
  priority: 0,
  ttl: mailTtl,
  comment: "no mail here (RFC 7505); see infra/src/dns.ts",
});

// No host is authorised to send as this domain.
new cloudflare.DnsRecord("mail-spf", {
  zoneId: zone.zoneId,
  name: machineZone,
  type: "TXT",
  content: '"v=spf1 -all"',
  ttl: mailTtl,
  comment: "no sender authorised; see infra/src/dns.ts",
});

// `p=reject` with strict alignment, and no `rua` — a reporting address would be a
// mailbox to maintain for a domain that by construction produces no legitimate mail.
new cloudflare.DnsRecord("mail-dmarc", {
  zoneId: zone.zoneId,
  name: `_dmarc.${machineZone}`,
  type: "TXT",
  content: '"v=DMARC1; p=reject; sp=reject; aspf=s; adkim=s"',
  ttl: mailTtl,
  comment: "reject everything; see infra/src/dns.ts",
});

// An empty `p=` revokes every DKIM selector, so a forged signature cannot validate under
// any selector name someone invents.
new cloudflare.DnsRecord("mail-dkim-null", {
  zoneId: zone.zoneId,
  name: `*._domainkey.${machineZone}`,
  type: "TXT",
  content: '"v=DKIM1; p="',
  ttl: mailTtl,
  comment: "no DKIM key valid; see infra/src/dns.ts",
});

export const machineDomain = machineZone;
