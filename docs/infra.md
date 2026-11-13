---
paths:
  - "infra/**"
---

# `infra/`: naming, DNS realms, dependency advisories

`infra/` is the Pulumi project (TypeScript, pnpm 11) and the only npm tree in this
repository. Read this file before changing a host or DNS name, `infra/src/inventory.ts`, or
`infra/package.json`.

## Host and DNS naming

The full rule, with the evidence behind each part, is `infra/Naming.md`.
`infra/src/inventory.ts` validates every name when the module loads. A malformed name breaks
`tsc` and `pulumi preview` and never reaches a zone file.

```
p-<provider>-<site>-<rand6>     physical    p-ion-berlin-xs56r6, p-own-muenchen-j5jghb
[vc]-<arch>-<rand6>             VM / container   v-amd64-k9y25p, c-arm64-h6pedq
<SERIAL>                        Macs, exempt     FCX19GT9XR, DKL6GDJ7X1
```

Physical machines carry where they stand. Virtual ones carry the only thing migration cannot
change: the virtualization ecosystem (VMware, KVM, Proxmox, …) is deliberately absent from
names, because it lives in the inventory.

DNS puts the network in the label (`<name>.pub.0xf1a5c0.net`, `.tailnet.`, `.muenchen.`), so
a name never means "it depends where you ask". `0xf1a5c0.net` is the machine domain;
`schwetschke.dev` is the published one. The split exists because the home FRITZ!Box strips
private addresses out of public DNS answers, and the rebind exception that re-enables them is
granted per domain. Measurements and the MagicDNS details: `docs/dns-realms.md`.

## Closing a dependency advisory

`just pulumi-audit` checks against OSV and also flags anything published inside the cooldown
window. Work the ladder top-down and stop at the first rung that applies:

1. The fixed version fits the parent's declared semver range:
   `pnpm update <pkg> --depth Infinity` (lockfile only).
2. It does not fit: bump the direct dependency in `package.json`.
3. `pnpm.overrides` / `resolutions`: **never.** Rejected once on evidence (it broke the
   Pulumi SDK at load).
4. The fix is younger than the 3-day cooldown: exempt it via `minimumReleaseAgeExclude`.
   **Never lower the floor itself.**

**Undercutting a cooldown is not negotiable: research first, fetch second.** `pnpm update`
downloads and unpacks the tarball, and `tsc`/Pulumi then import it. By the time a test could
fail, the code has already run on a machine that holds this repository's SOPS secrets and
cloud credentials. Establish from registry *metadata only* (no install) that the specific
`package@version` is not part of a live supply-chain incident: maintainer set, provenance,
GitHub Security Advisories, Socket, StepSecurity, Snyk, OpenSSF. Do this *before* adding the
exclude entry. If the research cannot conclude cleanly, wait out the cooldown and mitigate
another way. The same precondition governs every other cooldown here: the uv
`exclude-newer-package` overrides and the floors in `modules/supply-chain-hardening.nix`.

Before committing: `just pulumi-audit` clean, `cd infra && pnpm audit` clean,
`pnpm exec tsc --noEmit` green. The full ladder and worked commit examples are in
`docs/supply-chain.md`.
