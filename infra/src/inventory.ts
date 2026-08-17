/**
 * Hosts this stack *records* but does not *provision*.
 *
 * Everything else in `index.ts` is a real resource: Pulumi created or adopted it,
 * talks to a provider, and detects drift on every `preview`. The entries here are
 * none of that — they are hand-maintained constants, and it is worth being precise
 * about why, because "just add a provider later" is not on the table.
 *
 * The IONOS VPS lives in the **Cloud Panel** (`cloudpanel.ionos.de/panel/corevps/…`),
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
 *      and Dedicated Servers" — never VPS or Core VPS.
 *
 * So there is no API to read these values from and none to reconcile them against.
 * They are recorded here anyway so the host appears in the stack inventory that
 * `Architecture.md` §6 defines as the Pulumi->Nix contract, rather than living only
 * in a browser tab. `just infra-verify` supplies the drift detection Pulumi cannot.
 *
 * Trade-off accepted: routing constants through Pulumi buys no reconciliation and
 * adds a build step; a plain committed JSON file would be simpler. It earns its place
 * only by keeping *one* inventory instead of two, and by being the file the Nix side
 * is already specified to read. If that stops being true, move it.
 */

/** A host recorded for inventory purposes only — see the file comment. */
export interface UnmanagedHost {
  /** Which console owns this machine. Also a reminder of why it is not a resource. */
  readonly provider: "ionos-cloudpanel";
  readonly hostname: string;
  readonly ipv4: string;
  readonly ipv6: string;
  /** Operating system as installed today, not as desired. */
  readonly os: string;
  /**
   * Public SSH host key, `ssh-keyscan` format minus the address column.
   *
   * Ed25519 only, deliberately: the host also offers RSA and ECDSA keys, but
   * OpenSSH prefers Ed25519 by default and all three are regenerated together on
   * a reinstall — so one is enough to detect drift, and three would be noise.
   * Public key material; safe to commit, and exactly what `known_hosts` wants.
   */
  readonly sshHostKeyEd25519: string;
  /**
   * Inbound TCP the IONOS firewall policy permits, as configured in the Cloud
   * Panel. Provider-side and unreachable by any API, so nothing can reconcile it
   * against the host's own firewall — recorded so the two are at least comparable.
   *
   * Note 80/443/8443/8447 currently have nothing listening behind them: 8443+8447
   * is the Plesk pair from IONOS' default template, not evidence of a Plesk
   * install. Candidates for deletion in the Cloud Panel.
   */
  readonly firewallAllowsTcp: readonly number[];
}

export const unmanagedHosts = {
  "ionos-vps": {
    provider: "ionos-cloudpanel",
    hostname: "p-ion-ber-xs56r6",
    ipv4: "87.106.149.208",
    ipv6: "2a01:239:485:8d00::1",
    os: "ubuntu-24.04",
    sshHostKeyEd25519:
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJHiT2qgBqoN9nkIbBSn86WiFEbvLpilHdFtkPK/LGgb",
    firewallAllowsTcp: [22, 80, 443, 8443, 8447],
  },
} as const satisfies Record<string, UnmanagedHost>;
