# bq (Google BigQuery)

Part of `google-cloud-sdk`. Uses Application Default Credentials (ADC).

> **Use `scripts/bq.sh`** instead of raw `bq` — it enforces the cost cap.
> Drop to `bq.sh raw -- ...` only when you need a flag the wrapper doesn't expose.

## Install

```bash
nix shell nixpkgs#google-cloud-sdk
gcloud auth application-default login   # one-time
```

## Non-interactive patterns

```bash
# JSON, standard SQL
bq query --use_legacy_sql=false --format=json --quiet \
   'SELECT id, name FROM `project.dataset.users` LIMIT 10'

# CSV, explicit project
bq --project_id=my-project query \
   --use_legacy_sql=false --format=csv --quiet \
   'SELECT * FROM dataset.users LIMIT 1000' > users.csv

# Schema
bq show --format=prettyjson project:dataset.table | jq '.schema'

# Dry-run (cost estimate, no execution)
bq query --use_legacy_sql=false --dry_run \
   'SELECT * FROM `project.dataset.events`'
```

## Formats (`--format=...`)

- `json`, `prettyjson`, `csv`, `none` (for writes)
- `pretty`, `sparse`, `table` (human, not agent)

## Mandatory flags

| Flag | Meaning |
|---|---|
| `--quiet` | Drop status spam on stderr |
| `--use_legacy_sql=false` | Force standard SQL |
| `--format=json` | Machine-readable |
| `--max_rows=N` | Cap for large result sets |
| `--dry_run` | Plan without execution (no charge) |
| `--maximum_bytes_billed=N` | **Cost cap — always set via `bq.sh`** |
| `--location=EU` | Force region (e.g. `europe-west3` for Frankfurt) |

## Why `bq.sh` exists

Without `--maximum_bytes_billed`, an agent can burn thousands of euros
from a typo. `bq.sh`:

1. Always sets the cap.
2. Pre-flights with `--dry_run` to refuse the query before any charge if
   the estimate exceeds the cap.
3. Requires `--confirm-cost` when raising the cap above ~5 EUR.

For cost details and partitioning strategies, see
[`bigquery-pricing.md`](bigquery-pricing.md).

## Docs

<https://cloud.google.com/bigquery/docs/bq-command-line-tool>
<https://cloud.google.com/bigquery/pricing>
