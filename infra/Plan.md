# Plan: Pulumi rollout

> Companion to [`Architecture.md`](./Architecture.md). This file describes the
> incremental path from the current scaffolding to a working Pulumi + Nix
> setup that provisions and configures cloud hosts. Phases are ordered by
> risk: each one builds on the one before it and is shippable on its own.

---

## Where we are now (Phase 0 — done)

Already on the `feat/pulumi-integration` branch:

- `infra/` Pulumi project scaffolded with TypeScript, ESM, pnpm runtime
  (`infra/Pulumi.yaml`, `infra/package.json`, `infra/tsconfig.json`,
  `infra/src/index.ts`)
- `readSopsSecret()` helper at `infra/src/helpers/sops.ts` — wraps
  `sops -d --extract` output as a `pulumi.secret`
- `devenv`-backed dev shell with `pulumi`, `node`, `pnpm`, `sops`
  (see `modules/devshell.nix`)
- Per-repo pre-commit hooks (gitleaks, nixpkgs-fmt, …) replacing the global
  `core.hooksPath` setup
- `justfile` recipes: `pulumi-install`, `pulumi-preview`, `pulumi-up`,
  `pulumi-stack`
- `.envrc` pinning the flake ref so direnv enters the right shell

What is **not** done yet: no stack initialised, no AWS resource defined, no
NixOS host targets, no CI.

---

## Recommended rollout order

The phases below mirror the four-phase NixOS lifecycle from
[`Architecture.md` §6](./Architecture.md#6-nixos-lifecycle-forward-looking),
with the explicit local-runner path of this repo. Each phase has an exit
criterion: do not start the next one until the current one is durable.

| # | Phase | Outcome |
|---|---|---|
| 1 | Infra SOPS file + first AWS resource | `secrets/infra.enc.yaml` exists with `PULUMI_ACCESS_TOKEN`; `pulumi up` from a wrapper creates a real S3 bucket |
| 2 | Generated secrets back to SOPS | Pulumi creates a credential, writes it to the right SOPS file, downstream consumer picks it up |
| 3 | First NixOS host (single) | One IONOS or AWS VM, provisioned by Pulumi, installed via `nixos-anywhere`, configured via `colmena` |
| 4 | Multi-host inventory + colmena | Two or more hosts driven from `infra/pulumi-outputs.json`; `colmena --on '@all'` works |
| 5 | (Optional) GitHub Actions runner | GHA Age key added as recipient on `infra.enc.yaml`; `preview` workflow on PRs, `deploy` workflow on `main`, AWS via OIDC |
| 6 | Hardening | Least-priv IAM, branch protection, environment approval gates, `known_hosts` instead of `accept-new` |

---

## Phase 1 — Infra SOPS file + first AWS resource

**Goal:** Stand up `secrets/infra.enc.yaml` as the operating-secret store
for Pulumi, then prove the full chain works by creating one real, low-risk
AWS resource end-to-end. Doing the SOPS file *before* the first resource
means the wrapper pattern (`sops -d` → env vars → `pulumi`) is in place
from day one — no later retrofit when CI arrives.

**Prerequisites already satisfied** (do not redo): AWS credentials for the
laptop are declared in SOPS at `aws-access-key-id` / `aws-secret-access-key`
and exported to `~/.aws/credentials` by sops-nix
(`modules/secrets.nix:23-25`). They stay there — the laptop continues to use
the static profile; CI will use OIDC instead (Phase 5).

**Steps:**

1. **Add a creation rule for `secrets/infra.enc.yaml`** to `.sops.yaml`.
   Recipients: the workstation Ed25519 SSH public keys *that run Pulumi*
   (currently both Macs) plus the recovery PGP key. Do **not** add a GHA Age
   key yet — that comes in Phase 5. Example:

   ```yaml
   creation_rules:
     - path_regex: ^secrets/infra\.enc\.yaml$
       pgp: ["B6CA7BD9B0973FBF981C3B1E7C8C077F1B72E98B"]
       age:
         - "ssh-ed25519 AAAAC3...JqRmE94"   # FCX19GT9XR
         - "ssh-ed25519 AAAAC3...c6c+EP"   # DKL6GDJ7X1
   ```

2. **Create the file with `PULUMI_ACCESS_TOKEN`.** Generate the token at
   `app.pulumi.com` → Settings → Access Tokens, then ask the user to run:

   ```bash
   env SOPS_AGE_KEY=$(ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key) \
       sops edit secrets/infra.enc.yaml
   ```

   First content:
   ```yaml
   pulumi_access_token: pul-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```

   Verify decryption from both Macs (or at least confirm the recipient list
   is correct via `sops -d --extract '["pulumi_access_token"]' …`).

3. **Add a `pulumi` wrapper that loads infra secrets into the env.** Two
   options:

   - **Justfile recipe** (preferred for the laptop):
     ```just
     # Run any pulumi command with infra secrets loaded into the env
     pulumi *args:
         #!/usr/bin/env bash
         set -euo pipefail
         export PULUMI_ACCESS_TOKEN=$(sops -d --extract '["pulumi_access_token"]' secrets/infra.enc.yaml)
         cd infra && pulumi {{args}}
     ```
     Replace the existing `pulumi-preview`/`pulumi-up`/`pulumi-stack`
     recipes with thin wrappers around this one.

   - **Shell function in the devshell** (alternative): export the same
     vars in `enterShell` of `modules/devshell.nix`. Less explicit, harder
     to audit.

4. **Initialise the stack.**
   ```bash
   just pulumi login           # writes ~/.pulumi/credentials.json (cache only)
   just pulumi stack init prod
   just pulumi config set aws:region eu-central-1
   ```

5. **Pick a low-risk first resource.** Suggested: an S3 bucket with
   versioning enabled and a deny-public bucket policy. It is observable,
   cheap, and trivial to destroy if the experiment fails.

6. **Wire AWS credentials into the provider.** Locally, the AWS SDK picks
   up `~/.aws/credentials` automatically — no `readSopsSecret` call needed.
   In CI (Phase 5), the OIDC step exports `AWS_*` env vars before `pulumi`
   runs; the same code path works in both runtimes.

7. **Run `just pulumi preview`, then `just pulumi up`.** Confirm the
   bucket appears in the AWS console.

8. **Update `infra/README.md`.** Document the wrapper, the new SOPS file,
   and the bucket module.

**Exit criterion:** `just pulumi up` is idempotent (second run shows zero
changes), `just pulumi destroy` works without manual cleanup, and *no
plaintext `PULUMI_ACCESS_TOKEN` exists anywhere on disk* outside the env of
the wrapper process.

**Trip-wires:**

- `readSopsSecret` shells out to `sops` synchronously at *evaluation* time.
  If the Age key isn't loaded, the error is `failed to get the data key`.
  Make sure `~/.ssh/id_ed25519_sops_nopw` exists and has correct permissions.
- The S3 bucket name must be globally unique. Derive a stable suffix from
  `pulumi.getStack()` to avoid collisions.
- Don't put the `PULUMI_ACCESS_TOKEN` in a `.env` file or in
  `direnv` — those files are easy to commit by accident. The wrapper-recipe
  pattern keeps the secret short-lived (one process invocation).

---

## Phase 2 — Pulumi-generated secrets back to SOPS

**Goal:** Establish the writeable bridge from Pulumi to SOPS. Once a Pulumi
resource generates a credential, Pulumi must be able to land that value in
the *correct* SOPS file so the right consumer (sops-nix on a Mac, the colmena
step in CI, etc.) can read it.

**Routing reminder** (from Architecture §4):

- Generated secret needed *to operate Pulumi* or to deploy NixOS hosts (e.g.
  the colmena `deploy_key`, per-host `provisioning_key`) → write to
  `secrets/infra.enc.yaml`.
- Generated secret needed at *macOS host runtime* (e.g. a DB password an app
  on a Mac connects with) → write to `secrets/secrets.enc.yaml`.
- Generated secret needed only by another cloud resource → don't write it
  to SOPS at all; let the cloud's secret store hold it.

**Why this is non-trivial:** Pulumi resources are normally side-effect-free;
shelling out to `sops set` from a `command.local.Command` mutates a tracked
file, which means the next `pulumi up` may diff against itself unless the
trigger is set carefully.

**Steps:**

1. **Decide the SOPS-write contract.**
   - Wrap `sops set` calls in a small helper (e.g. `helpers/sops-write.ts`)
     that takes `(file, key, value)` so the call site is uniform and the
     file-routing decision is explicit at every callsite.
   - Use `triggers: [<output of the random resource>]` so the command only
     re-runs when the value changes.
   - Mark the command's output as a secret via `additionalSecretOutputs`.
   - For host-runtime targets: declare the key in `modules/secrets.nix`
     *before* the first write, so sops-nix knows it exists.
   - For infra targets: no declaration step needed — `infra.enc.yaml` is
     not consumed by sops-nix, only by the Pulumi/colmena wrappers.

2. **Test on a throwaway value.** Generate a `random.RandomPassword`,
   write it to `secrets/infra.enc.yaml` under `pulumi-test-token`, and
   verify:
   - `sops -d --extract '["pulumi-test-token"]' secrets/infra.enc.yaml`
     returns the value
   - A second `pulumi up` is a no-op (no diff against itself)
   - The same test repeated against `secrets/secrets.enc.yaml` also works,
     and the corresponding sops-nix declaration in `modules/secrets.nix`
     is honoured by `darwin-rebuild build`

3. **Document the round-trip.** Add a "Generated secret round-trip"
   section to `infra/README.md` showing the pattern *and* the file-routing
   decision tree.

**Exit criterion:** Generating a secret from Pulumi and consuming it on a
nix-darwin host requires only `pulumi up` followed by `darwin-rebuild
switch` — no manual `sops edit` step in between. Same for infra-routed
secrets: a regenerated colmena `deploy_key` is usable by the next
`colmena apply` without manual handling.

**Trip-wires:**

- Don't commit the *plaintext* output anywhere — `--show-secrets=false` on
  `pulumi stack output` is essential.
- `sops set` is happy to overwrite an existing key. Have a guard or an
  explicit "force" knob if the same Pulumi resource gets recreated.
- The `command.local` runs in the laptop's working directory at `pulumi up`
  time. Working directory and `cwd:` of the command must agree, otherwise
  `sops set` writes to the wrong file silently.
- Routing mistakes (writing a host-runtime secret to `infra.enc.yaml`) only
  surface when the consumer fails. Code-review the `(file, key, value)`
  argument at every callsite.

---

## Phase 3 — First NixOS host (single)

**Goal:** One real cloud VM, provisioned by Pulumi and configured by Nix.
This is where the dendritic flake gains a non-Darwin configuration class.

**Prerequisite memory note:** the user has flagged x86 Linux + x86 Darwin
hosts as upcoming, so do not let `nixosSystem` calls land on `aarch64-darwin`
by accident — set `system = "x86_64-linux"` explicitly.

**Steps:**

1. **Define a `NixosHost` ComponentResource** in
   `infra/src/components/nixos-host.ts`. It owns:
   - A `tls.PrivateKey` provisioning key (ED25519)
   - The AWS or IONOS instance resource
   - A SOPS-write of the provisioning key (Phase 2 pattern), keyed on
     hostname
   - Public outputs: `publicIp`, `hostname`, `provisioningPubkey`

2. **Define a single `deploy_key`** at the top of `index.ts` (one shared key
   for all NixOS hosts initially). Write it to SOPS once.

3. **Add the NixOS configuration class to the flake.**
   - Create `modules/nixos-base.nix` with the OpenSSH + deploy-user module,
     reading the deploy public key out of SOPS.
   - Wire `flake.nixosConfigurations.<host>` in a parallel module to the
     existing `darwin-wiring.nix`.

4. **Initial install via `nixos-anywhere`** (manual, one-shot per host):
   ```bash
   pulumi -C infra stack output --json --show-secrets=false \
       > infra/pulumi-outputs.json
   HOST=web-1
   IP=$(jq -r ".nixosInventory.\"$HOST\".ip" infra/pulumi-outputs.json)
   PROV_KEY=$(mktemp); chmod 600 "$PROV_KEY"
   sops -d --extract "[\"nixos-${HOST}-provisioning\"]" \
       secrets/secrets.enc.yaml > "$PROV_KEY"
   nix run github:nix-community/nixos-anywhere -- \
       --flake ".#${HOST}" --target-host "root@${IP}" -i "$PROV_KEY"
   shred -u "$PROV_KEY"
   ```

5. **Verify ongoing configuration via colmena.** Add `colmena` to the
   devshell, define a minimal `colmena` flake output, and run
   `colmena apply --on "$HOST"`.

**Exit criterion:** `colmena apply --on "$HOST"` after a no-op change
completes cleanly, with the deploy user authenticated by the SOPS-stored
deploy key.

**Trip-wires:**

- The `nixos-anywhere` step needs the host's bootstrap AMI to support kexec.
  Default AWS Debian 12 AMIs work; AL2023 does not.
- After initial install, the provisioning key should *not* be in
  `authorized_keys`. The Nix module that lays down `authorized_keys` should
  enumerate only the deploy key + user keys.
- `infra/pulumi-outputs.json` is consumed by Nix at evaluation time. It must
  be committed and stay in sync; if you forget to regenerate it after
  `pulumi up`, the next `nix build` reads stale IPs. Consider a `just`
  recipe that runs both.

---

## Phase 4 — Multi-host with inventory + colmena

**Goal:** Two or more NixOS hosts driven from `infra/pulumi-outputs.json`,
deployable in one shot.

**Steps:**

1. Generalise the `NixosHost` component so the top-level stack iterates over
   a list of host descriptors.
2. Generate the colmena hive dynamically from the inventory file (see the
   reference `Anleitung.md` §5.4 for the `mapAttrs` pattern — adapt it to
   the dendritic discovery layer in this repo).
3. Tag hosts (e.g. `web`, `db`) so `colmena apply --on '@web'` works.
4. Add a `just colmena-apply` recipe that re-exports the inventory before
   invoking colmena, to avoid stale-IP surprises.

**Exit criterion:** Adding a third host requires only an entry in `index.ts`
and a host module — no procedural steps beyond Phase 1's `nixos-anywhere`
bootstrap.

---

## Phase 5 — GitHub Actions runner (optional)

Only worth doing once at least one of the following is true:

- A second person collaborates on this repo
- `pulumi preview` on every PR is valuable enough to justify a CI Age key
- Drift detection (`pulumi preview` on a schedule) is desired

The architecture is already CI-ready: `secrets/infra.enc.yaml` exists,
secrets are loaded into env via a wrapper, AWS access is treated as
"static locally / OIDC in CI". This phase is a recipient-list expansion
plus a workflow file — not a re-architecture.

**Steps when the trigger fires:**

1. **Generate a dedicated GitHub Actions Age key.** Do this on a trusted
   workstation, not in CI:
   ```bash
   age-keygen -o /tmp/gha-age-key.txt
   # File contains the private key (line starting with AGE-SECRET-KEY-1...)
   # and a comment with the public key (age1...).
   ```
   - **Private form** → GitHub repo Settings → Secrets and variables →
     Actions → new secret named `SOPS_AGE_KEY`. Verify, then `shred -u
     /tmp/gha-age-key.txt`.
   - **Public form** → recipient on `secrets/infra.enc.yaml` *only*.

2. **Add the public key as a recipient on `infra.enc.yaml`** in
   `.sops.yaml`:
   ```yaml
   - path_regex: ^secrets/infra\.enc\.yaml$
     pgp: ["B6CA7BD9B0973FBF981C3B1E7C8C077F1B72E98B"]
     age:
       - "ssh-ed25519 ..."   # FCX19GT9XR
       - "ssh-ed25519 ..."   # DKL6GDJ7X1
       - "age1...            # GHA — created step 1"
   ```
   Then re-encrypt:
   ```bash
   sops updatekeys secrets/infra.enc.yaml
   ```
   Crucially, the global `secrets/secrets.enc.yaml` recipient list is **not**
   touched — CI cannot read host-runtime secrets.

3. **Configure AWS OIDC for the repo.** One-shot, in AWS:
   - Create the OIDC provider for `token.actions.githubusercontent.com`
     (per reference `Anleitung.md` §1.3 — same template).
   - Create an IAM role `pulumi-deploy` with a trust policy scoped to
     `repo:<OWNER>/<REPO>:environment:prod`.
   - Attach the policies Pulumi needs (start broad, tighten in Phase 6).
   - Note the role ARN and the AWS region as **GitHub Variables** (not
     secrets — the ARN is not sensitive):
     - `AWS_DEPLOY_ROLE_ARN`
     - `AWS_REGION`

4. **Create the GitHub Environment `prod`** with required reviewers (the
   user's GitHub account) and `main`-only deployment branches. This is the
   approval gate referenced by the OIDC trust policy's `:sub` condition.

5. **Add `.github/workflows/preview.yml`** for PR previews. Sketch:
   ```yaml
   on:
     pull_request:
       paths: ['infra/**', '.github/workflows/**']
   permissions:
     id-token: write
     contents: read
     pull-requests: write
   jobs:
     preview:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: aws-actions/configure-aws-credentials@v4
           with:
             role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
             aws-region: ${{ vars.AWS_REGION }}
         - uses: DeterminateSystems/nix-installer-action@v9
         - name: Decrypt infra secrets into env
           env:
             SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
           run: |
             {
               printf 'PULUMI_ACCESS_TOKEN=%s\n' \
                 "$(nix run nixpkgs#sops -- -d --extract '["pulumi_access_token"]' secrets/infra.enc.yaml)"
               # Add IONOS_TOKEN etc. as the resource set grows
             } >> "$GITHUB_ENV"
         - uses: pulumi/actions@v5
           with:
             command: preview
             stack-name: prod
             work-dir: infra
             comment-on-pr: true
   ```

6. **Add `.github/workflows/deploy.yml`** for main-branch applies.
   Same shape as `preview.yml` plus `environment: prod` (engages the
   approval gate) and `command: up`.

**Exit criterion:** A PR triggers `pulumi preview` and posts the diff as a
comment; merging to `main` triggers `pulumi up` after manual approval; no
secrets exist in the workflow YAML other than `SOPS_AGE_KEY`.

**Trip-wires:**

- The trust policy's `:sub` claim must match the workflow exactly. A common
  mistake is leaving `:environment:prod` in the policy but forgetting to
  declare `environment: prod` in the deploy job — the assume-role step then
  fails with `AccessDenied`.
- `sops` must be available in the runner. Either install it via
  `nix-installer` + `nix run nixpkgs#sops`, or use the
  `getsops/sops-installer` action.
- Avoid printing decrypted values into logs. The `$GITHUB_ENV` mechanism
  redacts values automatically when the workflow has registered them as
  secrets via `::add-mask::`; without that, an `env: |` echo could leak.
- Rotating the GHA Age key means: generate a new one, run `sops
  updatekeys`, swap the `SOPS_AGE_KEY` repo secret. Do *not* attempt to
  re-encrypt with both old and new in flight.

**Trade-off to revisit at this point:** if managing the CI Age key feels
heavier than introducing a service account from a dedicated secret manager
(1Password, Bitwarden Secrets Manager, …), reconsider the secret-store
choice from Architecture §2. The file split makes that swap localised — only
`infra.enc.yaml`'s consumers would change.

---

## Phase 6 — Hardening

Defer until the workflow is real (i.e. multiple hosts, multiple deploys per
week). Items, in roughly the order they pay off:

- **Least-privilege IAM** — replace the bootstrap admin role with policies
  scoped to the resources Pulumi actually manages. `IAM Access Analyzer`
  can suggest a starting policy from CloudTrail.
- **`known_hosts` instead of `accept-new`** — collect host SSH host keys
  from the `nixos-anywhere` step into SOPS, drop them into the colmena
  invocation's `known_hosts`.
- **`protect: true` on irreversible resources** — buckets with state, RDS
  instances, generated SSH keys.
- **Branch protection on `main`** — required PR review, required CI checks
  green.
- **Environment approval rules** (only after Phase 5) — require manual
  approval for `prod` deploys, `dev` self-serve.

---

## Definition of done for the integration

The `feat/pulumi-integration` work is "done" when:

- A real cloud resource exists, owned by Pulumi
- Generated secrets round-trip through SOPS without manual editing
- At least one cloud host is in `darwinConfigurations` *or*
  `nixosConfigurations` and is deployable from a single command on the
  laptop
- `infra/README.md`, `infra/Architecture.md`, `infra/Plan.md` are in sync
  with the actual code

Phases 5 and 6 are explicitly *future* work and should not block the merge.
