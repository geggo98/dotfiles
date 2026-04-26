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
| 1 | First AWS resource, end-to-end | `pulumi up` from the laptop creates a real S3 bucket; SOPS-bridged credentials work |
| 2 | Generated secrets back to SOPS | Pulumi creates a credential, writes it to SOPS, sops-nix picks it up on the next switch |
| 3 | First NixOS host (single) | One IONOS or AWS VM, provisioned by Pulumi, installed via `nixos-anywhere`, configured via `colmena` |
| 4 | Multi-host inventory + colmena | Two or more hosts driven from `infra/pulumi-outputs.json`; `colmena --on '@all'` works |
| 5 | (Optional) GitHub Actions runner | `preview` workflow on PRs, `deploy` workflow on `main` |
| 6 | Hardening | Least-priv IAM, branch protection, environment approval gates, `known_hosts` instead of `accept-new` |

---

## Phase 1 — First AWS resource

**Goal:** Replace the placeholder `index.ts` with one real, low-risk AWS
resource end-to-end. Validates the SOPS → Pulumi → AWS auth chain on the
laptop.

**Prerequisites already satisfied** (do not redo): AWS credentials are
declared in SOPS at `aws-access-key-id` / `aws-secret-access-key` and exported
to `~/.aws/credentials` by sops-nix (`modules/secrets.nix:23-25`).

**Steps:**

1. **Initialise the stack.**
   ```bash
   cd infra
   pulumi login          # uses PULUMI_ACCESS_TOKEN from ~/.pulumi
   pulumi stack init prod
   pulumi config set aws:region eu-central-1
   ```

2. **Pick a low-risk first resource.** Suggested: an S3 bucket with versioning
   and a deny-public bucket policy. It is observable, cheap, and easy to
   destroy if the experiment fails.

3. **Wire AWS credentials into the provider.** Either set
   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from the SOPS values
   (`readSopsSecret`) before constructing the provider, or rely on the
   already-present `~/.aws/credentials` file. The latter is simpler — only
   reach for `readSopsSecret` if you need a credential that *isn't* the AWS
   default profile.

4. **Run `pulumi preview`, then `pulumi up`.** Confirm the bucket appears in
   the AWS console.

5. **Add the resource to the README.** Update `infra/README.md` "Project
   structure" with whatever module file you create.

**Exit criterion:** `pulumi up` is idempotent (a second run shows zero
changes), and `pulumi destroy` works without manual cleanup.

**Trip-wires:**

- `readSopsSecret` shells out to `sops` synchronously at *evaluation* time.
  If the Age key isn't loaded, the error is `failed to get the data key`. Make
  sure `~/.ssh/id_ed25519_sops_nopw` exists and has correct permissions.
- The bucket name must be globally unique. Use a stable suffix derived from
  `pulumi.getStack()` to avoid collisions.

---

## Phase 2 — Pulumi-generated secrets back to SOPS

**Goal:** Establish the writeable bridge from Pulumi to SOPS. Once a Pulumi
resource generates a credential (a random password, a TLS key), Pulumi must
be able to land that value in `secrets/secrets.enc.yaml` so that sops-nix can
distribute it on the next `darwin-rebuild switch`.

**Why this is non-trivial:** Pulumi resources are normally side-effect-free;
shelling out to `sops set` from a `command.local.Command` mutates a tracked
file, which means the next `pulumi up` may diff against itself unless the
trigger is set carefully.

**Steps:**

1. **Decide the SOPS-write contract.**
   - Wrap `sops set` calls in a small helper (e.g. `helpers/sops-write.ts`)
     so the call site is uniform and testable.
   - Use `triggers: [<output of the random resource>]` so the command only
     re-runs when the value changes.
   - Mark the command's output as a secret via `additionalSecretOutputs`.
   - The committable manifest must end up in `secrets/secrets.enc.yaml`
     under a fixed key — declare that key in `modules/secrets.nix` *first*,
     so sops-nix knows about it.

2. **Test on a throwaway value.** Generate a `random.RandomPassword`,
   write it to a key like `pulumi-test-token`, and verify:
   - `sops -d secrets/secrets.enc.yaml | grep pulumi-test-token` shows it
   - `darwin-rebuild build` succeeds with the new declaration
   - A second `pulumi up` is a no-op (no diff against itself)

3. **Document the round-trip.** Add a short "Generated secret round-trip"
   section to `infra/README.md` showing the pattern.

**Exit criterion:** Generating a secret from Pulumi and consuming it on a
nix-darwin host requires only `pulumi up` followed by `darwin-rebuild
switch` — no manual `sops edit` step in between.

**Trip-wires:**

- Don't commit the *plaintext* output anywhere — `--show-secrets=false` on
  `pulumi stack output` is essential.
- `sops set` is happy to overwrite an existing key. Have a guard or an
  explicit "force" knob if the same Pulumi resource gets recreated.
- The `command.local` runs in the laptop's working directory at `pulumi up`
  time. Working directory and `cwd:` of the command must agree, otherwise
  `sops set` writes to the wrong file silently.

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

**Steps when the trigger fires:**

1. Create a CI-only Ed25519 key (or reuse a dedicated GitHub Actions Age key)
   and add its public form to `.sops.yaml`. Re-encrypt with
   `sops updatekeys secrets/secrets.enc.yaml`.
2. Configure AWS OIDC for the repo (see reference `Anleitung.md` §1.3 — same
   trust policy template, with this repo's name).
3. Add `.github/workflows/preview.yml` (PRs → `pulumi preview`) and
   `.github/workflows/deploy.yml` (main → `pulumi up`). Use a `prod`
   environment with required reviewers as the approval gate.
4. Move `PULUMI_ACCESS_TOKEN` into GitHub repo secrets.

**Trade-off to revisit at this point:** if managing the CI Age key feels
heavier than introducing 1Password, reconsider the secret-store choice from
Architecture §2.

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
