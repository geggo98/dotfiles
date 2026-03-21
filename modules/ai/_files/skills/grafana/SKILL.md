---
name: grafana
description: "Manage Grafana dashboards, datasources, folders, alerting, and annotations via the HTTP API. Use when creating, editing, or querying Grafana resources programmatically."
argument-hint: "<command> [args...] | help"
allowed-tools:
  - "Bash(./scripts/grafana.sh*)"
dependencies: "uv, gtimeout"
---

# Grafana Skill

Manage Grafana resources via the HTTP API using a Python CLI tool. Supports dashboard CRUD, folder management, datasource inspection, annotations, alerting, and raw API access.

## How to run (always use the helper script)

The helper script lives at `scripts/grafana.sh`.

> **Important:** Run the script directly (`./scripts/grafana.sh`). Do **not** prefix with `bash` — the script requires zsh and will fail under bash.

The script auto-loads credentials from `.env` (GRAFANA_INSTANCE and GRAFANA_SERVICE_ACCOUNT_TOKEN) and maps them to GRAFANA_URL and GRAFANA_TOKEN.

## Timeout

The wrapper enforces a global timeout via `gtimeout`. Pass `--timeout DURATION` to override (default: `5m`).

```bash
./scripts/grafana.sh list --timeout 2m
```

## Commands

| Command | Description | Example |
|---------|-------------|---------|
| `health` | Check Grafana instance health | `./scripts/grafana.sh health` |
| `list` | Search/list dashboards | `./scripts/grafana.sh list --query prod --tag monitoring` |
| `get <uid>` | Get dashboard details | `./scripts/grafana.sh get abc123 --json` |
| `export <uid>` | Export dashboard to JSON file | `./scripts/grafana.sh export abc123 --output dash.json` |
| `create` | Create dashboard from JSON | `./scripts/grafana.sh create --file dash.json --folder my-folder` |
| `update <uid>` | Update dashboard from JSON | `./scripts/grafana.sh update abc123 --file dash.json` |
| `delete <uid>` | Delete dashboard | `./scripts/grafana.sh delete abc123` |
| `clone <uid>` | Clone existing dashboard | `./scripts/grafana.sh clone abc123 --title "Copy"` |
| `versions <uid>` | List version history | `./scripts/grafana.sh versions abc123` |
| `restore <uid>` | Restore to specific version | `./scripts/grafana.sh restore abc123 --version 5` |
| `folders` | List all folders | `./scripts/grafana.sh folders --json` |
| `datasources` | List all datasources | `./scripts/grafana.sh datasources --json` |
| `annotations` | Query annotations | `./scripts/grafana.sh annotations --dashboard abc123 --tag deploy` |
| `alerts` | List alert rules | `./scripts/grafana.sh alerts --active --json` |
| `user` | Current user info | `./scripts/grafana.sh user` |
| `org` | Current org info | `./scripts/grafana.sh org` |
| `raw` | Raw API call | `./scripts/grafana.sh raw GET /api/search` |

### Common flags

| Flag | Used by | Description |
|------|---------|-------------|
| `--json` | list, get, folders, datasources, annotations, alerts | Output raw JSON |
| `--query <q>` | list | Filter by title |
| `--tag <t>` | list, annotations | Filter by tag |
| `--folder <uid>` | list, create, clone | Target folder UID |
| `--file <path>` | create, update | Input JSON file |
| `--output <path>` | export | Output file path (default: `<uid>.json`) |
| `--title <t>` | create, clone | Override dashboard title |
| `--message <m>` | create, update | Commit message for version history |
| `--overwrite` | create, update | Force overwrite |
| `--limit <n>` | list, versions, annotations | Limit results |
| `--version <n>` | restore | Version number to restore |
| `--active` | alerts | Show active (firing) alerts instead of rules |

## Creating Dashboards from JSON

When creating a dashboard, provide a JSON file with the standard Grafana dashboard model. The script accepts both:

- **Bare dashboard object** — `{"title": "...", "panels": [...]}`
- **Wrapped format** — `{"dashboard": {"title": "...", "panels": [...]}, "folderUid": "..."}`

The `id` and `uid` fields are set to `null` automatically for new dashboards.

See `references/dashboard-json-structure.md` for the annotated JSON schema and `examples/` for sample dashboard JSON files.

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

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GRAFANA_URL` | Full Grafana URL (e.g. `https://myinstance.grafana.net`) |
| `GRAFANA_TOKEN` | Service account token |
| `GRAFANA_INSTANCE` | Instance name — auto-prefixed with `https://` if GRAFANA_URL not set |
| `GRAFANA_SERVICE_ACCOUNT_TOKEN` | Mapped to GRAFANA_TOKEN if not set |
| `GRAFANA_ORG_ID` | Organization ID (optional, for multi-org setups) |

The `.env` file in the skill directory is auto-sourced by the wrapper script.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (invalid args, API error, missing prerequisites) |
| 124 | Timeout (killed by gtimeout) |

## Reference Documentation

| Document | Description |
|----------|-------------|
| `references/dashboard-json-structure.md` | Annotated dashboard JSON schema (panels, gridPos, targets, variables, fieldConfig) |
| `references/dashboard-design.md` | Dashboard design principles (RED/USE methods, layout, best practices) |
| `references/api-dashboards.md` | Dashboard API endpoints (search, get, create, update, delete, versions, permissions) |
| `references/api-datasources.md` | Datasource API (list, get, create, query, health check) |
| `references/api-alerting.md` | Alerting API (rules, contact points, notification policies, silences, templates) |
| `references/api-folders.md` | Folder API (CRUD, permissions, nested folders) |
| `references/api-annotations.md` | Annotations API (query, create, update, delete, tags) |
| `references/api-users-teams.md` | Users, teams, service accounts, organizations |
| `references/api-common-patterns.md` | Error handling, pagination, rate limiting, client examples |
| `references/api-workflow.md` | Step-by-step workflows for common dashboard operations |

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

Note: The example files use the v2beta1 Kubernetes-style format (exported from newer Grafana). For creating dashboards via the API, use the legacy format documented in `references/dashboard-json-structure.md`.

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

**Add a deploy annotation:**
```bash
./scripts/grafana.sh raw POST /api/annotations --body '{"text":"Deploy v2.1","tags":["deploy","production"],"time":'$(date +%s000)'}'
```

**Check if Grafana is reachable:**
```bash
./scripts/grafana.sh health
```
