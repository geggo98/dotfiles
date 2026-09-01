# Plan: what is still open

> Companion to [`Architecture.md`](./Architecture.md), which describes what is
> built and why those choices were made. This file describes what is **not**
> built. Read it as intent plus the traps found while designing the work — not
> as instructions to run verbatim, because none of it has been executed.

The original rollout plan had six phases. Phases 1 and 3 are done, and their
step-by-step instructions have been removed rather than annotated: `README.md`
and the `justfile` are the authority for anything you would actually run, and
the old text had drifted into contradicting them. It told you to run
`just pulumi stack init prod`, which `README.md` explicitly warns against
("do NOT run `stack init`, that creates a second, empty one"), and it decrypted
SOPS with the `env SOPS_AGE_KEY=$(ssh-to-age …)` form that `AGENTS.md` records
as measured-broken. A stale plan that reads like a runbook is worse than no
plan.

The phase numbers below are kept as aliases because `Architecture.md` cites
them ("see Plan.md Phase 2"). **Careful: `Architecture.md` §6 uses "Phase 1–4"
for its own NixOS lifecycle model, which is a different numbering that happens
to overlap.** When citing, say which.

---

## Where we are (2026-09-01)

Built, in production, and documented in `README.md`:

- The `prod` stack on Pulumi Cloud, selected by the `just pulumi` wrapper via
  `PULUMI_STACK`, with `secrets/infra.enc.yaml` supplying every token.
- AWS: two adopted S3 buckets plus eight standalone sub-resources.
  Cloudflare: R2 buckets for the nix cache and for restic, an R2 custom domain,
  a cache ruleset, DNS.
- One NixOS host, `p-ion-berlin-xs56r6`, deployed and reachable.

Two things about that host differ from what the original plan assumed, and the
difference is the reason several phases below shrank rather than completed:

- **It was not provisioned by Pulumi.** It is a hand-ordered IONOS VPS,
  installed with `nixos-anywhere` and configured by `just nixos-deploy`. The
  `NixosHost` ComponentResource, the `tls.PrivateKey` provisioning key and the
  per-host SOPS write were never built. `modules/nixos-secrets.nix` solved the
  key problem differently: the host generates its own age identity at
  `/var/lib/sops-nix/ssh_ed25519_sops`, so no key needs to travel.
- **`infra/pulumi-outputs.json` was never created.** Host addresses come from
  `modules/nixos-wiring.nix` `deployTarget`. See "the inventory bridge" below
  for why that is a reprieve rather than an omission.

---

## Pulumi → SOPS write bridge (Phase 2)

**Not built, and there is a live loose end pointing at it.**
`infra/package.json` declares `@pulumi/command`, and `infra/pnpm-workspace.yaml`
allow-lists it under `allowBuilds` so its postinstall may execute — in a repo
that spends forty lines justifying a three-day supply-chain cooldown. **Nothing
under `infra/src/` imports it.** This section is the only record of what that
dependency is for. If this work is abandoned, drop the dependency and the
`allowBuilds` grant in the same commit.

**Goal:** when a Pulumi resource generates a credential, land that value in the
*correct* SOPS file so the right consumer picks it up, with no manual
`sops edit` in between.

**Routing** (from Architecture §4):

- Needed to *operate* Pulumi or to deploy hosts → `secrets/infra.enc.yaml`.
- Needed at *host runtime* → `secrets/secrets.enc.yaml` (workstations) or
  `hosts/<host>/secrets.enc.yaml`.
- Needed only by another cloud resource → do not write it to SOPS at all; let
  the cloud's own secret store hold it.

**Why it is not trivial:** Pulumi resources are normally side-effect-free.
Shelling out from a `command.local.Command` mutates a tracked file, so the next
`up` can diff against itself unless the trigger is set deliberately.

**The contract, as far as it was designed:**

- A `helpers/sops-write.ts` taking `(file, key, value)`, so the routing decision
  is explicit and reviewable at every call site.
- `triggers: [<output of the generating resource>]`, so the command re-runs only
  when the value changes.
- `additionalSecretOutputs` on the command.
- For host-runtime targets, declare the key in `modules/secrets.nix` **before**
  the first write. The home-manager class validates the manifest at build time,
  so the wrong order fails `just build` with `the key '<x>' cannot be found`.

`AGENTS.md` § "Moving a secret between SOPS files" has since worked out the
mechanics of scripted SOPS writes for a different purpose, and that is the
starting point rather than this section: `sops set --value-stdin` takes JSON on
stdin (never as an argument, which would put the secret in the process list),
and command substitution must be avoided because it strips trailing newlines and
silently corrupts multi-line values.

**Trip-wires, all four still current:**

- Never commit the plaintext. `--show-secrets=false` on `pulumi stack output`.
- **`sops set` overwrites an existing key without complaint.** Needs a guard, or
  an explicit force knob, for the case where the generating resource is
  recreated.
- **A `cwd:` that disagrees with the working directory writes to the wrong file
  silently.** This one is confirmed real by its mirror image: the *read*
  direction already needs `projectRoot()` in `infra/src/helpers/sops.ts`, which
  walks up to the directory holding `Pulumi.yaml` because "pulumi runs the
  program with cwd = the compiled main's dir (`dist/`)". The write direction has
  no such anchor yet.
- Routing mistakes surface only when the consumer fails, never at write time.
  Review the `(file, key, value)` argument at every call site.

---

## Multi-host deploy (Phase 4)

**Not built. The trigger has not fired yet, but it is visible:**
`infra/src/inventory.ts` carries two machines at `managed: "planned"`, both in
Munich. A second live NixOS host is what makes this worth doing.

`just nixos-deploy <host>` is single-host by signature and deploys one closure
over ssh with an armed rollback timer. Deploying several would mean either
looping it or adopting a tool that fans out; `Architecture.md` §9 compares
colmena, `nixos-rebuild --target-host` and deploy-rs, and colmena remains the
candidate. Nothing about the current setup blocks it — but note that the
rollback timer, which is the best property `just nixos-deploy` has, would have
to be reimplemented or given up.

**The inventory bridge is the open design question, not the deploy tool.** The
original plan had Pulumi write `infra/pulumi-outputs.json`, commit it, and have
Nix read it with `builtins.fromJSON` at evaluation time. That file was never
created, and the hazard that argued against it still stands: **a committed JSON
consumed at eval time goes stale silently.** Forget to regenerate it after
`pulumi up` and the next `nix build` reads old IPs, with no error anywhere. Any
revival needs a `just` recipe that does both, or a different mechanism entirely.

---

## GitHub Actions runner (Phase 5)

**Not built, and the case for it is weaker than when it was written.** Of the
three original triggers, one is dead (a second collaborator — still one author)
and one is answered differently: drift for the hosts Pulumi cannot manage is
`just infra-verify`, not a scheduled `pulumi preview`. What remains is
`pulumi preview` on every PR, which has to be worth a CI Age key on its own.

The architecture is CI-ready — secrets already load into the environment through
a wrapper, AWS is "static locally / OIDC in CI" — so this is a recipient-list
expansion plus a workflow file, not a re-architecture. The workflow sketch that
used to sit here has been dropped: its action pins were from 2026-05-10, it was
never run, and current GitHub Actions documentation supplies a better one.

**Shape of the work:** generate a dedicated Age key on a workstation (never in
CI), add its public half as a recipient on `infra.enc.yaml` **only** — so CI
cannot read host-runtime secrets — put the private half in a repo secret, then
configure AWS OIDC and a `prod` GitHub Environment as the approval gate.

**Trip-wires, which is why this section survives at all:**

- **The OIDC trust policy's `:sub` must name the same GitHub Environment the job
  declares.** Leaving `:environment:prod` in the policy while forgetting
  `environment: prod` in the job fails assume-role with `AccessDenied`, which
  reads like a permissions problem and is not.
- **Name the CI role something other than `pulumi-deploy`.** That name is
  already taken by the IAM *user* the workstation authenticates as (README
  "## AWS"). A role and a user can share a name in IAM, so nothing stops you —
  which is exactly why it is worth writing down.
- **Do not start with broad IAM and tighten later.** README "## AWS" documents
  the scoping that already exists — `iam:CreateRole` limited to `role/pulumi/*`,
  `iam:PutRolePolicy` deliberately absent because an inline policy is a short
  path to account-admin. Match it; do not re-derive it.
- **`$GITHUB_ENV` does not redact anything on its own.** An earlier version of
  this file implied it did. Masking comes from `::add-mask::`, and a value
  written to `$GITHUB_ENV` without being masked first can surface in any later
  step that echoes the environment.
- **Rotating the CI Age key:** generate, `sops updatekeys -y` (without `-y` it
  asks `Is this okay? (y/n)` and dies on EOF), then swap the repo secret. Never
  have both keys in flight.

**Worth revisiting when this starts:** if managing a CI Age key feels heavier
than a service account from a dedicated secret manager, reconsider the
secret-store choice from Architecture §2. The file split keeps that swap local —
only `infra.enc.yaml`'s consumers would change.

---

## Branch protection (Phase 6)

**Not done, deliberately.** Measured 2026-09-01:
`gh api repos/geggo98/dotfiles/branches/main/protection` returns
`404 Branch not protected`. With one author and no CI, required review and
required checks would be a gate with nobody on the other side. This becomes real
at the same moment Phase 5 does, and for the same reason.

The rest of the original hardening list is closed and has been removed:
least-privilege IAM is done and documented far better in README "## AWS";
`protect: true` is on both buckets and all eight sub-resources, and
`src/index.ts` now records its *limits* (it blocks delete and replace, never
update); and `known_hosts` was solved differently — public host keys sit in
cleartext in `src/inventory.ts` as `ssh.hostKeyEd25519` and are checked by
`just infra-verify`, which is why putting them in SOPS would be backwards.
