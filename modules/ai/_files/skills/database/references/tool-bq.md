# bq (Google BigQuery)

Part of `google-cloud-sdk`. Reads from gcloud's active configuration —
either Application Default Credentials (ADC), a user login, or a
service-account activation.

> **Use `scripts/bq.sh`** instead of raw `bq` — it enforces the cost cap
> and can activate a service-account JSON ephemerally without touching
> user-global gcloud state. Drop to `bq.sh raw -- ...` only when you need
> a flag the wrapper doesn't expose.

## Install

```bash
nix shell nixpkgs#google-cloud-sdk
gcloud auth application-default login   # interactive ADC
# OR — for service accounts, prefer the wrapper:
#   ${CLAUDE_SKILL_DIR}/scripts/bq.sh --credentials-file <PATH> ...
```

## Auth via service-account JSON

The wrapper handles the whole `CLOUDSDK_CONFIG` tempdir + `gcloud auth
activate-service-account` dance. Pass `--credentials-file PATH` (or set
`$GOOGLE_APPLICATION_CREDENTIALS`) and the wrapper:

1. Creates an isolated `CLOUDSDK_CONFIG` under `$TMPDIR`.
2. Validates the JSON's `type == "service_account"`.
3. Activates the account quietly (no stdout/stderr noise).
4. Derives `--project-id` from the JSON's `project_id` field if not
   given on the CLI / via env.
5. Cleans up the tempdir on exit.

```bash
${CLAUDE_SKILL_DIR}/scripts/bq.sh \
  --credentials-file ~/.config/sops-nix/secrets/my-sa.json \
  query 'SELECT 1 AS one'
```

This is preferable to `gcloud auth activate-service-account` outside the
wrapper because:
- No mutation of `~/.config/gcloud/`.
- No risk of leaving an activated SA as the default in subsequent shells.
- Works in parallel runs (each gets its own `CLOUDSDK_CONFIG`).
- The key path goes through the wrapper but never appears in `bq`'s own
  command line.

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

## Pitfall: `DECLARE` and multi-statement scripts

`bq query` is single-statement by default. Multi-statement scripts that
use `DECLARE` (e.g. for parameterised dates) confuse the CLI:

- `--dry_run` does not produce a per-script estimate; it sees only the
  first statement.
- The wrapper passes the whole SQL as one `bq query` argument; the parser
  often rejects the trailing `SELECT` after a `DECLARE`.

Workarounds, in order of preference:

1. **Inline the values directly** — trade DRY for correctness:

   ```sql
   -- bad (DECLARE):
   DECLARE day DATE DEFAULT '2026-05-01';
   SELECT * FROM `prj.ds.events` WHERE event_day = day;

   -- good (inline):
   SELECT * FROM `prj.ds.events` WHERE event_day = '2026-05-01';
   ```

2. **Use bq's `--parameter` flag** for genuine parameterisation:

   ```bash
   ${CLAUDE_SKILL_DIR}/scripts/bq.sh raw -- \
     query --use_legacy_sql=false \
            --parameter='day:DATE:2026-05-01' \
     'SELECT * FROM `prj.ds.events` WHERE event_day = @day'
   ```

   (Go through `bq.sh raw -- ...` so the cap and timeout still apply.)

3. **Submit as a script file** for genuine multi-statement scripts:

   ```bash
   bq query --use_legacy_sql=false \
            --max_statement_results=10 \
            --maximum_bytes_billed=$BQ_MAX_BYTES_BILLED \
            < script.sql
   ```

## Docs

<https://cloud.google.com/bigquery/docs/bq-command-line-tool>
<https://cloud.google.com/bigquery/pricing>
<https://cloud.google.com/bigquery/docs/parameterized-queries>
