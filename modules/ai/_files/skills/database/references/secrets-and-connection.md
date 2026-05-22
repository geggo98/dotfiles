# Secrets & connection management

> **Hard rule:** the resolved secret never appears in the LLM context.
> Wrappers in `scripts/` enforce this; this doc explains how to feed
> them and how to do the same for native CLIs.

## Never put on the CLI in the prompt

```bash
# WRONG:
psql -h db -U stefan -W -d kfzif        # prompts in script, hangs
mysql -ustefan -pgeheim123 ...          # password in process list
${CLAUDE_SKILL_DIR}/scripts/db.sh --dsn 'pg://stefan:hunter2@db/kfzif' ...
                                        # literal — wrapper warns; agent saw it anyway
```

## Idiomatic per-tool secret stores

| Tool | Recommended |
|---|---|
| psql | `~/.pgpass` (mode 600), or `PGSERVICE` + `~/.pg_service.conf` |
| mysql | `~/.my.cnf` with `[client] password=...` (mode 600) |
| sqlcmd | `MSSQL_PWD` env or Entra/AAD token |
| sqlcl | `connmgr` saved connections |
| bq | gcloud ADC (`gcloud auth application-default login`) |
| mongosh | URI with `authMechanism=...` (X509 / SCRAM / AWS-IAM) |
| usql | DSN from a secret provider: `usql "$(vault read -field=dsn ...)"` |

## Wrapper resolution chain

Both `db.sh` and `bq.sh` walk this chain. First non-empty wins.

| # | Source | How to use |
|---|---|---|
| 1 | `--<name>-cmd 'cmd'` | `--dsn-cmd 'vault kv get -field=dsn kv/db/prod'` |
| 2 | `--<name>-file PATH` | `--dsn-file ~/.config/db/staging.dsn` |
| 3 | `--<name> 'literal'` | **Warns** (history-leak) |
| 4 | `${NAME}_CMD` env | `export DB_DSN_CMD='vault kv get -field=dsn kv/db/prod'` |
| 5 | `$NAME` env | **Warns** (env-leak) |

Resolved value is never logged. Warnings reference only source names.

## Executable secret providers

These print the secret to stdout. The wrapper captures stdout into a
shell variable that never leaves the wrapper process; the LLM only sees
the command string, never the secret.

```bash
# HashiCorp Vault
--dsn-cmd 'vault kv get -field=dsn kv/db/prod'

# Mozilla SOPS (encrypted YAML/JSON)
--dsn-cmd 'sops decrypt --extract "[\"db\"][\"dsn\"]" secrets.enc.yaml'

# 1Password CLI
--dsn-cmd 'op item get "Postgres prod" --fields dsn --format=json | jq -r ".value"'

# gopass / pass
--dsn-cmd 'pass show db/prod/dsn'

# AWS Secrets Manager
--dsn-cmd 'aws secretsmanager get-secret-value --secret-id db/prod --query SecretString --output text'

# GCP Secret Manager
--dsn-cmd 'gcloud secrets versions access latest --secret=db-prod-dsn'

# macOS Keychain
--dsn-cmd 'security find-generic-password -a stefan -s db-prod -w'
```

## SOPS quick recipe (matches this repo's setup)

```bash
# Encrypted file: db-secrets.enc.yaml
# Decryption key: $SOPS_AGE_KEY or sops.yaml-resolved keys.

# Dump to a temp env file:
eval "$(sops decrypt --output-type dotenv db-secrets.enc.yaml)"
# Then pass the env var:
${CLAUDE_SKILL_DIR}/scripts/db.sh query "SELECT 1"   # uses $DB_DSN
```

Or inline (preferred — never materialises plaintext on disk):

```bash
${CLAUDE_SKILL_DIR}/scripts/db.sh query \
  --dsn-cmd 'sops decrypt --extract "[\"db\"][\"prod_dsn\"]" db-secrets.enc.yaml' \
  "SELECT 1"
```

## Vault quick recipe

```bash
${CLAUDE_SKILL_DIR}/scripts/db.sh query \
  --dsn-cmd 'vault read -field=dsn secret/data/kfzif/readonly' \
  "SELECT count(*) FROM users"
```

## Credentials-file format (if you make one)

INI-style with one section per environment:

```ini
[prod]
dsn-cmd = vault kv get -field=dsn kv/db/prod

[staging]
dsn = pg://reader@stage.internal/kfzif
```

Mode 600 enforced; the wrapper warns if it's looser.

## Audit trail

Mark every agent-issued query so DB logs identify the source:

```bash
PGAPPNAME=claude-skill-database psql ...    # db.sh sets this automatically
mysql --connect-attr=program_name=claude-skill ...
```
