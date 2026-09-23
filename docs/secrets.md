# Secrets: env/file discipline, the `key` grouping, moving a secret between SOPS files

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### One env name, one file — and export as few secret values as possible

**Files are the default source. An environment variable is a deliberate manual
override.** Two rules follow, and both were paid for.

**A credential chain gets exactly one env name and one file.** No generic
aliases, no cross-product fallback tiers. Measured 2026-08-24: `modules/shells.nix`
exported `ATLASSIAN_API_TOKEN` into every shell holding the *Bitbucket* token,
while the `jira` and `bitbucket-pr` skills consulted **every env name before any
file** — so the dead alias outranked the correct `jira_api_token` file and every
Jira call failed. Both skills were dead in any interactive shell for weeks.

The symptom is what makes this worth a section: **Jira answers 404, not 401**, on
an issue endpoint when the token is invalid, because it hides issue existence
from unauthenticated callers. `prs JIRA-3325` reported *"Jira resource not
found"* for a ticket that exists. Reordering the tiers would only postpone the
next instance, so the alias tier is gone; both scripts now also print **which
source** the token came from on 401/404, never the token.

**`modules/shells.nix` exports no secret VALUES at all** — only `*_PATH`. Every
consumer in this repo reads its sops-nix file through `load_from_secret`
(`modules/_files/shell/load-secrets.sh`), so the ambient copy bought nothing and
cost plenty: a globally exported secret lands in every child process, `env` dump,
crash report and agent transcript. Tools with no file-based key store of their
own (`llm`, `ollama`) get a same-named wrapper in `modules/ai-tools.nix` that
loads the key per invocation instead. Adding a secret value back to `shells.nix`
needs a reason a wrapper cannot serve.

**Atlassian tokens, specifically.** The classic `ATATT3…` tokens used here are
**unscoped** — they carry the user's full Jira/Confluence permissions — they
**expire**, and they are **not Bitbucket credentials**: the Bitbucket REST API
rejects them as a category ("API Token provided has no Bitbucket scopes" means
the wrong *kind* of credential, not a missing scope; Bitbucket goes through `bb`
and its own `config-cli.yml`). The token is opaque, so nothing can read its
expiry — `just creds-check` probes instead. Note the two products do **not**
share an auth scheme: Jira Cloud is Basic (email + token), while the
self-hosted Confluence (Data Center) needs **Bearer**. Guessing wrong
returns 401 and looks exactly like a dead credential.

**Vault, specifically: `-address` never reaches the token helper.** Vault starts
an external token helper with a plain `os.Environ()`, so the helper sees
`VAULT_ADDR` and nothing else. `modules/vault.nix` keys its token files on
`sha256(VAULT_ADDR)` precisely so that staging and production logins can coexist
— which means a bare `vault … -address=<production>` in an interactive fish,
where `VAULT_ADDR` holds the staging default, signs a production request with the
**staging** token. Measured 2026-09-03 against Vault v1.21.1:

```console
$ env -u VAULT_ADDR vault token lookup -address=https://vault.invalid:8200
failed to get token from token helper: "vault-token-helper: VAULT_ADDR is not set\n": exit status 1
```

That is what `+vault` is for: it resolves the `-address` value and exports
`VAULT_ADDR` to the same address before exec'ing the real binary. Environments
are matched by any unambiguous **prefix** of their name (`-address=p`,
`-address=prod`, `-address=production`); an exact name wins over an otherwise
ambiguous prefix; anything containing `://` passes through as a literal URL. An
unknown or ambiguous name aborts and lists the candidates — never a quiet
fallback, which would redirect a production command in silence.

That guarantee is about *names*, not about an absent flag. `+vault` with no
`-address` uses `VAULT_ADDR` — resolving an alias there too — and falls back to
`staging` when it is unset. A bare `vault` does **not** do the same: with
`VAULT_ADDR` unset it fails at the token helper (`vault-token-helper: VAULT_ADDR
is not set`, exit 1) rather than defaulting anywhere, so the two agree only
inside an interactive fish, where the variable is set either way. That
distinction matters because agents do not run interactively. So `+vault kv get
secret/x` reads staging, where the removed `+vault-prod` read production. What
makes that a documentation matter rather than a hazard is that the removed
commands fail loudly with `command not found` instead of quietly redirecting.

`+vault-login <environment> [<token> | -]` logs in the same way and takes **no**
default environment, so a forgotten argument cannot land in the wrong instance.
A token goes in on **stdin** (`… | +vault-login staging -`), or is asked for
silently when OIDC fails; passing it as the second argument still works but puts
it in argv, where `ps` exposes it to every process of this user for the lifetime
of the command — so that form warns. `vault` itself never receives the token as
an argument in any of the three paths.

Both are generated from one `vaultEnvironments` attrset. A new instance costs
**three** steps, not two: the line there, the declaration in
`hosts/<serial>/secrets.nix`, and the encrypted value in
`hosts/<serial>/secrets.enc.yaml` — without the last one the resolver aborts
with `cannot read the address of …`.

One consequence of the per-address token files is worth stating out loud,
because it lives only in a Nix comment otherwise: a **staging** login also
mirrors the fresh token into `~/.vault-token`, a plaintext token at a
well-known path, for tools that hardcode that location. Production logins do
not. A literal-URL login (`+vault-login https://…`) skips the mirror too,
because it has no environment name to match.

Two divergences from the real CLI, both deliberate. `+vault` honours `-address`
wherever it stands, where Vault parses flags only *before* the positional
arguments — the wrapper **removes** the flag before `vault` sees the command
line, so no `Command flags must be provided before positional arguments` warning
fires and the typed instance is reached. That removal replaced an earlier
in-place rewrite, which was measurably broken: the rewritten flag stayed in argv
and Vault counted it as a positional, so `+vault kv get secret/x -address=…`
died on `Too many arguments (expected 1, got 2)` instead of reaching anything.
`token lookup` and `version` tolerate a surplus argument, which is why it went
unnoticed. And a `VAULT_ADDR` that is neither a URL nor a known prefix aborts,
where Vault itself would fail later on a URL parse error.

The German-language version of this trap ships as a global agent rule,
`modules/_files/vault/rules/vault-address.md`, contributed through
`my.ai.extraRules` so it reaches only hosts that import `homeManager.vault` — an
agent working in some other repository on this machine would otherwise never see
it. What follows here is the repo-side detail that does not belong in a global
rule.

The plain `vault` binary (Homebrew, `hashicorp/tap/vault`) is deliberately **not**
shadowed. It could not be by a package name anyway: `brew shellenv` in
`modules/_files/shell/promptInit.fish` moves `/opt/homebrew/bin` to the front of
the interactive PATH, ahead of the home-manager profile (measured: positions 1
and 43), so a Nix package called `vault` would never run.

- **Location:** `secrets/secrets.enc.yaml` (global), `hosts/<serial>/secrets.enc.yaml` (per-host)
- **Decryption keys:** SSH Ed25519 key at `~/.ssh/id_ed25519_sops_nopw` (passwordless)
- **Secrets declaration:** In `modules/secrets.nix` and `hosts/<serial>/secrets.nix`
- **Critical note:** SOPS does not work in the agent sandbox — ask the user to edit secrets manually
- **Edit command:** `sops edit secrets/secrets.enc.yaml` — **no `env` prefix.**
  `SOPS_AGE_SSH_PRIVATE_KEY_FILE` is already exported from `home.sessionVariables`
  (`modules/shells.nix`), so sops finds the identity on its own. The
  `env SOPS_AGE_KEY=$(ssh-to-age …)` form this file used to prescribe was not
  merely redundant, it was broken: it passed the literal `{/Users/stefan}/.ssh/…`.
  See the comment on the `+sops-*` abbreviations in `modules/shells.nix`, which
  has been correct about this for longer than this section has.
- **Changing recipients:** after editing a rule in `.sops.yaml`, existing files
  are NOT re-encrypted automatically — `sops updatekeys -y <file>`. Without `-y`
  it asks `Is this okay? (y/n)` and dies on `EOF` when run without a terminal.
- Ensure new secrets are declared with explicit paths and modes; avoid committing derived plaintext files
- When provisioning a new machine, confirm the correct host serial directory under `hosts/` before switching


**Group related secrets in the YAML with `key`, keep the attribute name flat.**
`name` and `key` are separate options: `key` addresses a value *inside* the
encrypted file, `/`-separated, while `path` defaults to a location built from
`name` and never from `key`. So a nested `key` reorganises the file without
moving a single file on disk — no consumer changes.

```nix
r2_access_key_id.key = "nix_cache/r2/access_key_id";     # file: …/r2_access_key_id
restic_r2_access_key_id.key = "restic/r2/access_key_id"; # file: …/restic_r2_access_key_id
```

Do it whenever two secrets are the same *kind* of thing with different powers.
The case that motivated it: `r2_access_key_id` (nix-cache, read+write, on both
Macs, used automatically many times a day) sat next to `restic_r2_access_key_id`
(backup, read+write, able to destroy the only copy of the data) — same provider,
same shape, told apart by a prefix. Structure beats care.

**The NixOS module's description of `key` is wrong** — it says "No tested data
structures are supported right now", a typo for "nested" and untrue regardless.
Both classes call the same `recurseSecretKey` in `sops-install-secrets`, which
splits on `/` and descends. The home-manager module documents it correctly, and
a deploy of `p-ion-berlin-xs56r6` on 2026-08-21 settled it on the NixOS class
too: activation logged `adding secrets: dropbox_client_id, …,
r2_backup_ro_secret_access_key`, all five of them nested.

Renaming or regrouping an existing key means moving the value in the encrypted
file too. On the home-manager class that is safe: the build fails until they
agree, with `manifest is not valid: … the key '<x>' cannot be found`. On the
NixOS class the same mistake surfaces only at activation — see below.

**On the NixOS class it is a different module and a different identity.**
`modules/secrets.nix` is home-manager only. Servers use
`modules/nixos-secrets.nix`, which decrypts to `/run/secrets/<name>` for system
services rather than into a home directory, and authenticates with a dedicated
key generated *on the host* (`/var/lib/sops-nix/ssh_ed25519_sops`) rather than
the SSH host key — the host key is regenerated by a reinstall, which would make
every secret unreadable exactly when things are already going wrong.

Two traps, both paid for once:

- **List the `age1…` conversion in `.sops.yaml`, not just the `ssh-ed25519`
  form.** sops-nix converts the SSH key to an age X25519 identity, and that
  cannot open an `ssh-ed25519` recipient stanza. Symptom at activation:
  `failed to decrypt …: Error getting data key: 0 successful groups required,
  got 0`. The conversion is printed in the same log
  (`Imported … as age key with fingerprint age1…`), so read it there rather than
  deriving it. Every rule in `.sops.yaml` carries both forms for this reason.
- **`just nixos-eval` does not catch a missing secret.** sops-nix validates that
  a declared key exists in the encrypted file at *activation*, not at evaluation,
  so a configuration referencing a secret nobody encrypted evaluates perfectly
  and then fails the deploy. To check before deploying, compare the declarations
  in `hosts/<host>/secrets.nix` against the top-level keys of
  `hosts/<host>/secrets.enc.yaml`.

  **This is a NixOS-class statement and does not generalise — the home-manager
  class is stricter, and in the useful direction.** There, `sops-install-secrets`
  checks the manifest at *build* time, so `just build` fails outright:

  ```
  manifest is not valid: secret restic_password in …-secrets.enc.yaml
  is not valid: the key 'restic_password' cannot be found
  ```

  Measured on 2026-08-19 while adding `restic_password` to
  `modules/secrets.nix`. The practical consequence is an ordering constraint
  rather than a hazard: on a workstation, put the value in the encrypted file
  *before* declaring it, or the tree does not build. The comparison-by-hand above
  is only needed for servers.


### Moving a secret between SOPS files

Host-scoping a credential — global `secrets/secrets.enc.yaml` → `hosts/<serial>/secrets.enc.yaml`
— is four steps in a fixed order, and **`sops edit` is not one of them.** `sops`
has `set` and `unset`, so the whole move is scriptable and no editor opens at all:

```bash
sops -d --extract '["k"]' "$SRC" \
  | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.buffer.read().decode()))' \
  | sops set --value-stdin "$DST" '["k"]'
sops unset "$SRC" '["k"]'
```

Three details in those two commands each cost a measurement:

- **`--value-stdin` wants JSON, and says so when it doesn't get it.** Fed the raw
  value it aborts with `Value for --set is not valid JSON` — loudly, never
  truncating. Hence the `json.dumps`. `--value-file` behaves the same and both
  exist for one reason: passing the value as an *argument* would put the secret in
  the process list.
- **Pipe the value; never `v=$(sops -d …)`.** Command substitution strips trailing
  newlines, which silently corrupts any multi-line value — the
  `c24_bi_kfz_*.json` service accounts are 12 lines each.
- **`--idempotent` on both** makes the loop resumable, which the rules under *Any
  script that processes a list must be resumable* require anyway.

**The order is not stylistic.** Each step is safe to stop after:

1. **`.sops.yaml` first, then `sops updatekeys -y <dst>`.** `sops set` inherits the
   key groups of the **file**, not the creation rule, so a rule fixed afterwards
   leaves the new values encrypted to the old recipient set in the meantime.
   `-y` is required — without it sops asks `Is this okay? (y/n)` and dies on EOF.
   `updatekeys` re-encrypts only the data key; the values stay byte-identical.
2. **Copy the values.** Both files now hold them; nothing is broken, nothing is
   deployed differently yet.
3. **Flip the declarations** (`modules/secrets.nix` → `hosts/<serial>/secrets.nix`),
   atomically. The reverse order fails: the home-manager class validates the
   manifest at **build** time, so a declaration without a value breaks `just build`
   with `manifest is not valid: … the key '<x>' cannot be found`.
4. **Only then `sops unset` from the source** — and make the delete predicate
   "the destination's decrypted value hashes the same as the source's, right now",
   not "I copied it earlier". An interrupted copy fails that check.

Two things this does **not** buy, both worth stating before someone relies on them:

- **It scopes deployment, not readability.** Every rule in `.sops.yaml` carries the
  same pair of `age1…` recipients, and their private halves sit on both
  workstations — measured: `sops -d hosts/FCX19GT9XR/secrets.enc.yaml` succeeds
  from DKL6GDJ7X1, whose SSH key is not among that file's `ssh-ed25519` recipients
  and whose GPG keyring holds neither of its PGP fingerprints. What changes is
  which host writes the value into `~/.config/sops-nix/secrets`.
- **The other host keeps the stale files until it is switched.** sops-nix removes
  what it no longer manages during activation, not before.

**Watch for Nix-side references.** A secret consumed only at runtime
(`load_from_secret`, a skill reading `$SOPS_SECRETS_DIR`) moves freely. One that a
module dereferences as `config.sops.secrets.<name>.path` does not: that is an
**eval** error where it is undeclared, so a host-specific secret referenced from a
module both hosts import — `modules/shells.nix` via `homeManager.base` is the live
example — breaks the *other* host's build. Grep before moving:

```bash
grep -rn --include='*.nix' 'sops\.secrets\.' modules/
```

