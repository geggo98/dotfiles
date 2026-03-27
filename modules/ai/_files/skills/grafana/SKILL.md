---
name: grafana
description: "Manage Grafana dashboards, datasources, folders, alerting, and annotations via the HTTP API. Query datasources (PromQL, LogQL, TraceQL, SQL) and export results to Parquet, TSV, or JSONL. Use when creating, editing, or querying Grafana resources programmatically."
argument-hint: "<command> [args...] | help"
allowed-tools: Read(references/*) Bash(./scripts/grafana.sh:*)
dependencies: "uv, gtimeout"
---

# Grafana Skill

Manage Grafana resources via the HTTP API using a Python CLI tool. Supports dashboard CRUD, folder management, datasource inspection, annotations, alerting, format conversion, structural diffing, three-way merge with conflict resolution, datasource queries (PromQL, LogQL, TraceQL, SQL), result export (Parquet, TSV, JSONL), and raw API access.

## How to run (always use the helper script)

The helper script lives at `scripts/grafana.sh`.

> **Important:** Run the script directly (`./scripts/grafana.sh`). Do **not** prefix with `bash` — the script requires zsh and will fail under bash.

## Connection

Pass credentials via `--env-file` or environment variables. The `--url` flag sets the base URL directly (useful for non-secret host names).

```bash
# Load credentials from an env file
./scripts/grafana.sh --env-file ~/.config/grafana/prod.env list

# Or set URL directly and token via env var
GRAFANA_TOKEN=glsa_... ./scripts/grafana.sh --url https://myinstance.grafana.net list

# Multiple env files (later overrides earlier)
./scripts/grafana.sh --env-file base.env --env-file prod.env health
```

## API Modes

The CLI supports two Grafana API styles:

| Mode | API | OCC Token | When Used |
|------|-----|-----------|-----------|
| `legacy` | `/api/dashboards/...` | `version` (integer) | All Grafana versions |
| `k8s` | `/apis/dashboard.grafana.app/v1beta1/...` | `resourceVersion` (string) | Grafana 12.x+ |
| `auto` | Probes K8s endpoint, falls back to legacy | Depends on detected mode | Default |

Set via `--api` flag or `GRAFANA_API_MODE` env var:

```bash
./scripts/grafana.sh --api legacy list     # force legacy API
./scripts/grafana.sh --api k8s list        # force K8s API
./scripts/grafana.sh --api auto health     # auto-detect (default)
```

The K8s API requires a `--namespace` (default: `default`):

```bash
./scripts/grafana.sh --api k8s --namespace my-org list
```

## Timeout

The wrapper enforces a global timeout via `gtimeout`. Pass `--timeout DURATION` to override (default: `5m`).

```bash
./scripts/grafana.sh --timeout 2m list
```

## Commands

| Command | Description | Example |
|---------|-------------|---------|
| `health` | Check Grafana instance health | `./scripts/grafana.sh health` |
| `list` | Search/list dashboards | `./scripts/grafana.sh list --query prod --tag monitoring` |
| `get <uid>` | Get dashboard details | `./scripts/grafana.sh get abc123 --json` |
| `export <uid>` | Export dashboard to JSON + base sidecar | `./scripts/grafana.sh export abc123 --output dash.json` |
| `create` | Create dashboard from JSON | `./scripts/grafana.sh create --file dash.json --folder my-folder` |
| `update <uid>` | Update with OCC and auto-merge on conflict | `./scripts/grafana.sh update abc123 --file dash.json` |
| `delete <uid>` | Delete dashboard | `./scripts/grafana.sh delete abc123` |
| `clone <uid>` | Clone existing dashboard | `./scripts/grafana.sh clone abc123 --title "Copy"` |
| `versions <uid>` | List version history | `./scripts/grafana.sh versions abc123` |
| `restore <uid>` | Restore to specific version | `./scripts/grafana.sh restore abc123 --version 5` |
| `diff <uid>` | Structural diff: local file vs server | `./scripts/grafana.sh diff abc123 --file dash.json` |
| `merge <uid>` | Three-way merge: local vs server | `./scripts/grafana.sh merge abc123 --file dash.json` |
| `convert` | Convert between legacy and K8s format | `./scripts/grafana.sh convert --file dash.json --to k8s` |
| `folders` | List all folders | `./scripts/grafana.sh folders --json` |
| `datasources` | List all datasources | `./scripts/grafana.sh datasources --json` |
| `annotations` | Query annotations | `./scripts/grafana.sh annotations --dashboard abc123 --tag deploy` |
| `alerts` | List alert rules | `./scripts/grafana.sh alerts --active --json` |
| `user` | Current user info | `./scripts/grafana.sh user` |
| `org` | Current org info | `./scripts/grafana.sh org` |
| `query <ds_uid>` | Query a datasource | `./scripts/grafana.sh query prom1 --expr 'up' --preview 10` |
| `panel-query <dash> <id>` | Execute queries from a dashboard panel | `./scripts/grafana.sh panel-query abc123 2 --preview 10` |
| `panel-list <dash_uid>` | List panels in a dashboard | `./scripts/grafana.sh panel-list abc123` |
| `raw` | Raw API call | `./scripts/grafana.sh raw GET /api/search` |

### Common flags

| Flag | Used by | Description |
|------|---------|-------------|
| `--json` | list, get, folders, datasources, annotations, alerts | Output raw JSON |
| `--query <q>` | list | Filter by title |
| `--tag <t>` | list, annotations | Filter by tag |
| `--folder <uid>` | list, create, clone | Target folder UID |
| `--file <path>` | create, update, diff, merge, convert | Input JSON file |
| `--output <path>` | export, merge, convert | Output file path |
| `--title <t>` | create, clone | Override dashboard title |
| `--message <m>` | create, update | Commit message for version history |
| `--force` | update | Force overwrite, bypass OCC |
| `--overwrite` | create | Force overwrite (alias for `--force` in create) |
| `--no-base` | export | Skip writing the `.base.json` sidecar |
| `--format <legacy\|k8s>` | export | Export in specific format |
| `--to <legacy\|k8s>` | convert | Target format for conversion |
| `--base <path>` | merge | Explicit base file (overrides sidecar) |
| `--limit <n>` | list, versions, annotations | Limit results |
| `--version <n>` | restore | Version number to restore |
| `--active` | alerts | Show active (firing) alerts instead of rules |
| `--expr <expr>` | query | PromQL / LogQL expression |
| `--raw-sql <sql>` | query | SQL query string |
| `--query <json>` | query | Raw JSON query body |
| `--type <type>` | query | Datasource type (auto-detected if omitted) |
| `--from <time>` | query, panel-query | Time range start (default: `now-1h`) |
| `--to <time>` | query, panel-query | Time range end (default: `now`) |
| `--format <fmt>` | query, panel-query | Export format: `parquet`, `tsv`, `jsonl` |
| `--output-dir <dir>` | query, panel-query | Auto-named output in directory |
| `--max-data-points <n>` | query | Max data points (default: 1000) |
| `--interval-ms <n>` | query | Query interval in ms (default: 15000) |
| `--ref-id <id>` | query | RefId for the query (default: `A`) |
| `--instant` | query | Execute as instant query |
| `--preview <n>` | query, panel-query | Print first N rows as JSONL to stdout |
| `--var key=value` | panel-query | Template variable substitution (repeatable) |

## Conflict Resolution

The `update` command uses optimistic concurrency control (OCC) by default:

1. **Export** creates `<uid>.json` (working copy) and `<uid>.base.json` (base snapshot with OCC metadata)
2. **Edit** the working copy locally
3. **Update** sends the change with the OCC token from the base sidecar
4. If the server version has changed (412/409), and a `.base.json` exists, the CLI attempts a **three-way merge**:
   - **Clean merge**: auto-saves and updates the sidecar
   - **Conflicts**: writes `<uid>.merged.json`, prints conflict details, exits with code 2
5. Use `--force` to bypass OCC entirely (equivalent to the old `--overwrite`)

### Workflow

```bash
# 1. Export (creates working copy + base sidecar)
./scripts/grafana.sh export abc123

# 2. Edit locally
$EDITOR abc123.json

# 3. Update (OCC-safe, auto-merges on conflict)
./scripts/grafana.sh update abc123 --file abc123.json --message "My changes"

# If conflicts: resolve abc123.merged.json, then retry with --force
./scripts/grafana.sh update abc123 --file abc123.merged.json --force --message "Resolved"
```

### Explicit merge

```bash
./scripts/grafana.sh merge abc123 --file abc123.json --output merged.json
```

## Creating Dashboards from JSON

When creating a dashboard, provide a JSON file with the standard Grafana dashboard model. The script accepts:

- **Bare dashboard object** — `{"title": "...", "panels": [...]}`
- **Wrapped format** — `{"dashboard": {"title": "...", "panels": [...]}, "folderUid": "..."}`
- **K8s format** — `{"apiVersion": "dashboard.grafana.app/v1beta1", "kind": "Dashboard", ...}`

The input format is auto-detected and converted as needed. The `id` and `uid` fields are set to `null` automatically for new dashboards.

See `references/dashboard-json-structure.md` for the annotated JSON schema and `examples/` for sample dashboard JSON files.

## Format Conversion

Convert between legacy and K8s dashboard formats without any API calls:

```bash
# Legacy to K8s
./scripts/grafana.sh convert --file dash.json --to k8s --output k8s-dash.json

# K8s to legacy
./scripts/grafana.sh convert --file k8s-dash.json --to legacy

# Roundtrip test
./scripts/grafana.sh convert --file dash.json --to k8s --output /tmp/k8s.json
./scripts/grafana.sh convert --file /tmp/k8s.json --to legacy --output /tmp/rt.json
```

## Querying Data

Query any Grafana datasource via the `/api/ds/query` endpoint. Grafana proxies the query to the underlying datasource (Prometheus, Loki, Tempo, MySQL, etc.) and returns results in a unified Data Frame format.

### Direct query

```bash
# PromQL — preview 10 rows
./scripts/grafana.sh query prom-uid --expr 'sum by (job) (rate(http_requests_total[5m]))' --preview 10

# PromQL — instant query
./scripts/grafana.sh query prom-uid --expr 'up' --instant --json

# LogQL — last 30 minutes of errors
./scripts/grafana.sh query loki-uid --expr '{app="api"} |= "error"' --from now-30m --preview 20

# SQL datasource
./scripts/grafana.sh query mysql-uid --raw-sql 'SELECT endpoint, count(*) AS n FROM requests WHERE $__timeFilter(created_at) GROUP BY endpoint ORDER BY n DESC LIMIT 10'

# Raw query body (any datasource)
./scripts/grafana.sh query tempo-uid --query '{"queryType":"traceqlSearch","query":"{ status = error }","limit":10}'
```

### Export formats

```bash
# Parquet (default for large results — requires pyarrow)
./scripts/grafana.sh query prom-uid --expr 'up' --format parquet --output /tmp/up.parquet

# TSV (opens in Excel)
./scripts/grafana.sh query prom-uid --expr 'up' --format tsv --output /tmp/up.tsv

# JSONL (no dependencies)
./scripts/grafana.sh query prom-uid --expr 'up' --format jsonl --output /tmp/up.jsonl

# Auto-named file in a directory
./scripts/grafana.sh query prom-uid --expr 'up' --output-dir /tmp/results
```

### Panel queries

Extract and execute queries directly from an existing dashboard panel:

```bash
# List panels to find the ID
./scripts/grafana.sh panel-list <dashboard_uid>

# Execute panel queries with variable substitution
./scripts/grafana.sh panel-query <dashboard_uid> <panel_id> --var namespace=production --var job=api-server --preview 20

# Export panel data to Parquet
./scripts/grafana.sh panel-query <dashboard_uid> <panel_id> --format parquet --output /tmp/panel.parquet
```

### Output behavior

When no output flags are given, the CLI auto-selects:
- **≤50 rows** → prints JSONL preview to stdout
- **>50 rows** → exports to a temp file (Parquet by default)

Use `--json` for the raw API response, `--preview N` for a quick look, or `--output`/`--output-dir` for explicit file export.

### Query language references

Before constructing queries, read the appropriate reference file:

| Datasource | Type String | Reference |
|------------|-------------|-----------|
| Prometheus / Mimir | `prometheus` | `references/PROMQL.md` |
| Loki | `loki` | `references/LOGQL.md` |
| Tempo | `tempo` | `references/TRACEQL.md` |
| MySQL / PostgreSQL / ClickHouse / BigQuery | `mysql`, `postgres`, etc. | `references/SQL.md` |

## Raw API Access

For any endpoint not covered by a dedicated command, use `raw`:

```bash
# GET request
./scripts/grafana.sh raw GET /api/search

# POST with JSON body
./scripts/grafana.sh raw POST /api/annotations --body '{"text":"deploy","tags":["deploy"],"time":1700000000000}'

# DELETE
./scripts/grafana.sh raw DELETE /api/annotations/123
```

## Wrapper Options

| Option | Description |
|--------|-------------|
| `--url <url>` | Grafana base URL (overrides `GRAFANA_URL`) |
| `--org-id <id>` | Organization ID (overrides `GRAFANA_ORG_ID`) |
| `--api <auto\|legacy\|k8s>` | API mode (overrides `GRAFANA_API_MODE`, default: `auto`) |
| `--namespace <ns>` | K8s namespace (overrides `GRAFANA_NAMESPACE`, default: `default`) |
| `--env-file <path>` | Load env vars from file (repeatable, later wins) |
| `--timeout <duration>` | Global timeout (default: `5m`) |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GRAFANA_URL` | Grafana base URL (e.g. `https://myinstance.grafana.net`) |
| `GRAFANA_TOKEN` | Service account token |
| `GRAFANA_ORG_ID` | Organization ID (optional, for multi-org setups) |
| `GRAFANA_API_MODE` | API mode: `auto`, `legacy`, `k8s` (default: `auto`) |
| `GRAFANA_NAMESPACE` | K8s namespace (default: `default`) |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (invalid args, API error, missing prerequisites) |
| 2 | Unresolved merge conflicts |
| 124 | Timeout (killed by gtimeout) |

## Reference Documentation

| Document | Description |
|----------|-------------|
| `references/dashboard-json-structure.md` | Annotated dashboard JSON schema (panels, gridPos, targets, variables, fieldConfig) |
| `references/dashboard-design.md` | Dashboard design principles (RED/USE methods, layout, best practices) |
| `references/api-dashboards.md` | Dashboard API endpoints (legacy + K8s-style, OCC, versions, permissions) |
| `references/api-datasources.md` | Datasource API (list, get, create, query, health check) |
| `references/api-alerting.md` | Alerting API (rules, contact points, notification policies, silences, templates) |
| `references/api-folders.md` | Folder API (CRUD, permissions, nested folders) |
| `references/api-annotations.md` | Annotations API (query, create, update, delete, tags) |
| `references/api-users-teams.md` | Users, teams, service accounts, organizations |
| `references/api-common-patterns.md` | Error handling, pagination, conflict handling, three-way merge patterns |
| `references/api-workflow.md` | Step-by-step workflows for common dashboard operations |
| `references/PROMQL.md` | PromQL query language reference (Prometheus/Mimir) |
| `references/LOGQL.md` | LogQL query language reference (Loki) |
| `references/TRACEQL.md` | TraceQL query language reference (Tempo) |
| `references/SQL.md` | SQL query reference (MySQL, PostgreSQL, ClickHouse, BigQuery) |
| `references/labels-fields-geomap.md` | Labels vs. Fields, "Labels to Fields" transformation, Geomap panel location modes, Prometheus-to-Geomap pipelines |

## Example Dashboards

The `examples/` directory contains representative Grafana dashboard JSON files:

| File | Format | Shows |
|------|--------|-------|
| `traces.json` | v2beta1 | Traces visualization, text panel, new Kubernetes-style format |
| `timeseries.json` | v2beta1 | Time series panels with multiple queries |
| `variables.json` | v2beta1 | Template variables (custom, constant, textbox, query) |
| `alerting.json` | v2beta1 | Alert list, thresholds, time region annotations |
| `pokemon.json` | v2beta1 | Infinity datasource, external API integration |
| `canvas.json` | v2beta1 | Canvas visualization |
| `geomap.json` | v2beta1 | Geomap with geohash heatmap layer, `labelsToFields` transformation pipeline |

Note: The example files use the **v2beta1** Kubernetes-style format (exported from newer Grafana with a restructured spec: `elements`, `layout`, `vizConfig`). This is distinct from the **v1beta1** format, which wraps the legacy panel model in a K8s envelope. The CLI's `convert` command handles `legacy ↔ v1beta1` conversion but does **not** support v2beta1. For creating dashboards via the API, use the legacy format documented in `references/dashboard-json-structure.md`.

## Examples

**List production dashboards and export them:**
```bash
./scripts/grafana.sh list --tag production --json | jq -r '.[].uid' | while read uid; do
  ./scripts/grafana.sh export "$uid" --output "exports/${uid}.json"
done
```

**Create a dashboard from a JSON file:**
```bash
./scripts/grafana.sh create --file my-dashboard.json --folder my-folder --title "My Dashboard"
```

**Clone a dashboard to a different folder:**
```bash
./scripts/grafana.sh clone abc123 --title "Staging Copy" --folder staging-folder
```

**Export, edit, and update with OCC:**
```bash
./scripts/grafana.sh export abc123
$EDITOR abc123.json
./scripts/grafana.sh update abc123 --file abc123.json --message "Updated thresholds"
```

**Diff local changes against server:**
```bash
./scripts/grafana.sh export abc123
# ... edit abc123.json ...
./scripts/grafana.sh diff abc123 --file abc123.json
```

**Add a deploy annotation:**
```bash
./scripts/grafana.sh raw POST /api/annotations --body '{"text":"Deploy v2.1","tags":["deploy","production"],"time":'$(date +%s000)'}'
```

**Check if Grafana is reachable:**
```bash
./scripts/grafana.sh health
```
