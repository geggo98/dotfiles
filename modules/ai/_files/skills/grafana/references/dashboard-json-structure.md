# Dashboard JSON Structure Reference

Annotated reference for the Grafana dashboard JSON model used by the `POST /api/dashboards/db` endpoint.

## Save Request Envelope

The API expects a wrapper object containing the dashboard and metadata:

```json
{
  "dashboard": { ... },   // The dashboard object (see below)
  "folderUid": "abc123",  // Target folder UID (omit for General folder)
  "message": "Initial commit",  // Version history message
  "overwrite": false       // true = force-save even if version conflicts
}
```

- Set `dashboard.id` to `null` for new dashboards.
- Set `dashboard.uid` to `null` to auto-generate, or provide a specific UID.
- For updates, include `dashboard.version` to enable optimistic locking (prevents overwriting concurrent edits).

## Dashboard Object

Top-level fields of the dashboard model:

```json
{
  "id": null,              // Numeric ID (null for new, auto-assigned by Grafana)
  "uid": null,             // String UID (null to auto-generate, or set explicitly)
  "title": "My Dashboard", // Required. Displayed in UI and search
  "tags": ["prod", "api"], // Searchable tags
  "timezone": "browser",   // "browser", "utc", or IANA timezone
  "schemaVersion": 38,     // Dashboard schema version (use latest)
  "version": 1,            // Current version (include for updates)
  "refresh": "30s",        // Auto-refresh interval ("5s", "1m", "5m", "" for off)
  "description": "",       // Optional description
  "editable": true,        // Whether UI editing is allowed
  "time": {
    "from": "now-6h",      // Default time range start
    "to": "now"            // Default time range end
  },
  "timepicker": {},        // Timepicker config (usually empty)
  "panels": [ ... ],       // Array of panel objects
  "templating": { "list": [ ... ] },  // Template variables
  "annotations": { "list": [ ... ] }, // Annotation queries
  "links": [ ... ]         // Dashboard-level links
}
```

## Panels

Each panel is an object in the `panels` array:

```json
{
  "id": 1,                  // Unique within the dashboard (auto-incrementing)
  "type": "timeseries",     // Panel type (see Panel Types below)
  "title": "CPU Usage",     // Panel title
  "description": "",        // Tooltip description (optional)
  "transparent": false,     // Transparent background
  "gridPos": {              // Position and size on the grid
    "h": 8,                 // Height in grid units
    "w": 12,                // Width (max 24)
    "x": 0,                 // X position (0-23)
    "y": 0                  // Y position (rows from top)
  },
  "datasource": {           // Default datasource for this panel
    "type": "prometheus",
    "uid": "prometheus-uid"
  },
  "targets": [ ... ],       // Query definitions (see Targets below)
  "fieldConfig": { ... },   // Field display configuration
  "options": { ... },       // Panel-type-specific options
  "transformations": [ ... ], // Data transformations
  "links": [ ... ],         // Panel links
  "repeat": "variable",     // Repeat panel for each value of this variable
  "repeatDirection": "h"    // "h" (horizontal) or "v" (vertical)
}
```

### Panel Types

| Type | Description |
|------|-------------|
| `timeseries` | Time series line/bar/point chart |
| `stat` | Single value with optional sparkline |
| `gauge` | Gauge with threshold colors |
| `bargauge` | Horizontal/vertical bar gauge |
| `table` | Tabular data display |
| `heatmap` | Heatmap visualization |
| `text` | Markdown/HTML text panel |
| `alertlist` | List of alert states |
| `logs` | Log viewer (Loki, Elasticsearch) |
| `traces` | Trace viewer (Tempo, Jaeger) |
| `canvas` | Freeform element placement |
| `geomap` | Geographic map |
| `barchart` | Categorical bar chart |
| `piechart` | Pie/donut chart |
| `histogram` | Histogram distribution |
| `row` | Collapsible row (used to group panels) |

## Grid Layout (gridPos)

Grafana uses a **24-column grid**. Panels are placed using `gridPos`:

```
x=0         x=12        x=24
|-----------|-----------|
|  w=12     |  w=12     |  y=0, h=8
|           |           |
|-----------|-----------|
|        w=24           |  y=8, h=4
|-----------|-----------|
```

Common layout patterns:

| Layout | gridPos |
|--------|---------|
| Full width | `{"x":0, "y":0, "w":24, "h":8}` |
| Two columns | Left: `{"x":0, "w":12}`, Right: `{"x":12, "w":12}` |
| Three columns | `{"w":8}` at x=0, x=8, x=16 |
| Four stat panels | `{"w":6, "h":4}` at x=0, x=6, x=12, x=18 |

Panels are rendered top-to-bottom by `y`, left-to-right by `x`.

## Targets (Queries)

Each target defines a query against a datasource:

```json
{
  "refId": "A",              // Reference ID (A, B, C, ...)
  "datasource": {            // Override panel default
    "type": "prometheus",
    "uid": "prometheus-uid"
  },
  "expr": "rate(http_requests_total[5m])",  // Prometheus query
  "legendFormat": "{{service}}",             // Legend template
  "instant": false,          // true for instant query (single value)
  "range": true,             // true for range query (time series)
  "intervalMs": 15000,       // Query interval
  "maxDataPoints": 1000      // Max data points to return
}
```

### Datasource-specific query fields

**Prometheus:**
```json
{
  "refId": "A",
  "expr": "up{job=\"prometheus\"}",
  "legendFormat": "{{instance}}",
  "instant": false,
  "range": true
}
```

**Loki:**
```json
{
  "refId": "A",
  "expr": "{job=\"nginx\"} |= \"error\"",
  "queryType": "range",
  "maxLines": 1000
}
```

**SQL (PostgreSQL, MySQL):**
```json
{
  "refId": "A",
  "rawSql": "SELECT time, value FROM metrics WHERE $__timeFilter(time)",
  "format": "time_series"
}
```

**TestData (useful for prototyping):**
```json
{
  "refId": "A",
  "datasource": {"type": "grafana-testdata-datasource", "uid": "grafana"},
  "scenarioId": "random_walk"
}
```

## Field Configuration

Controls how data values are displayed. Applied at `fieldConfig.defaults` (all fields) and `fieldConfig.overrides` (specific fields).

```json
{
  "fieldConfig": {
    "defaults": {
      "unit": "percent",       // Display unit (percent, bytes, s, reqps, etc.)
      "decimals": 1,           // Decimal places
      "min": 0,                // Axis minimum
      "max": 100,              // Axis maximum
      "color": {
        "mode": "palette-classic"  // "palette-classic", "fixed", "thresholds"
      },
      "thresholds": {
        "mode": "absolute",    // "absolute" or "percentage"
        "steps": [
          {"value": null, "color": "green"},  // Base color
          {"value": 80, "color": "yellow"},   // Warning
          {"value": 90, "color": "red"}       // Critical
        ]
      },
      "custom": {
        "drawStyle": "line",   // timeseries: "line", "bars", "points"
        "lineWidth": 1,
        "fillOpacity": 10,
        "gradientMode": "none",
        "showPoints": "auto",
        "spanNulls": false
      }
    },
    "overrides": [
      {
        "matcher": {"id": "byName", "options": "errors"},
        "properties": [
          {"id": "color", "value": {"fixedColor": "red", "mode": "fixed"}}
        ]
      }
    ]
  }
}
```

### Common units

| Unit | Key | Example |
|------|-----|---------|
| Percent (0-100) | `percent` | 95.2% |
| Percent (0-1) | `percentunit` | 0.952 -> 95.2% |
| Bytes | `bytes` | 1.5 GiB |
| Bits/sec | `bps` | 100 Mbps |
| Seconds | `s` | 1.5s |
| Milliseconds | `ms` | 150ms |
| Requests/sec | `reqps` | 1.2k req/s |
| Short | `short` | 1.5K |
| None | `none` | Raw value |

## Variables / Templating

Template variables appear in the `templating.list` array:

### Query variable (datasource-driven)

```json
{
  "name": "namespace",
  "type": "query",
  "datasource": {"type": "prometheus", "uid": "prometheus-uid"},
  "query": "label_values(kube_pod_info, namespace)",
  "refresh": 1,            // 1 = on dashboard load, 2 = on time range change
  "multi": false,           // Allow multiple selection
  "includeAll": false,      // Add "All" option
  "sort": 1                 // 0=disabled, 1=alpha-asc, 2=alpha-desc, 3=num-asc
}
```

### Chained variable (depends on another)

```json
{
  "name": "service",
  "type": "query",
  "datasource": {"type": "prometheus", "uid": "prometheus-uid"},
  "query": "label_values(kube_service_info{namespace=\"$namespace\"}, service)",
  "refresh": 1,
  "multi": true,
  "includeAll": true
}
```

### Custom variable (static values)

```json
{
  "name": "env",
  "type": "custom",
  "query": "production,staging,development",
  "current": {"text": "production", "value": "production"}
}
```

### Other variable types

| Type | Purpose |
|------|---------|
| `constant` | Fixed value, hidden from user |
| `textbox` | Free-text input |
| `datasource` | Select datasource by type |
| `interval` | Time interval selection (1m, 5m, 1h) |
| `adhoc` | Dynamic label filter (Prometheus) |

### Using variables in queries

```
rate(http_requests_total{namespace="$namespace", service=~"$service"}[$__rate_interval])
```

Built-in variables: `$__timeFrom`, `$__timeTo`, `$__interval`, `$__rate_interval`, `$__org`, `$__user`.

## Annotations

Annotation queries display event markers on time series panels:

```json
{
  "annotations": {
    "list": [
      {
        "name": "Annotations & Alerts",
        "datasource": {"type": "grafana", "uid": "-- Grafana --"},
        "enable": true,
        "hide": true,
        "builtIn": 1,
        "type": "dashboard"
      },
      {
        "name": "Deployments",
        "datasource": {"type": "grafana", "uid": "-- Grafana --"},
        "enable": true,
        "hide": false,
        "iconColor": "blue",
        "tags": ["deploy"]
      }
    ]
  }
}
```

## Dashboard Links

Navigate between related dashboards:

```json
{
  "links": [
    {
      "title": "Service Detail",
      "type": "link",
      "url": "/d/service-detail/service-detail?var-service=$service",
      "targetBlank": false
    },
    {
      "title": "All Monitoring",
      "type": "dashboards",
      "tags": ["monitoring"],
      "targetBlank": false
    }
  ]
}
```

## Row Panels

Rows are special panels that group other panels:

```json
{
  "id": 10,
  "type": "row",
  "title": "Database Metrics",
  "collapsed": false,
  "gridPos": {"h": 1, "w": 24, "x": 0, "y": 16},
  "panels": []
}
```

When `collapsed: true`, child panels (those with higher `y` values before the next row) are hidden.

## Transformations

Applied after queries, before visualization:

```json
{
  "transformations": [
    {
      "id": "organize",
      "options": {
        "excludeByName": {"Time": true},
        "renameByName": {"instance": "Instance", "Value": "Status"}
      }
    },
    {
      "id": "sortBy",
      "options": {"sort": [{"field": "Value", "desc": true}]}
    }
  ]
}
```

Common transformations: `organize`, `sortBy`, `filterByValue`, `merge`, `calculateField`, `groupBy`, `convertFieldType`.

## v2beta1 Format (Kubernetes-style)

Newer Grafana versions export dashboards in a Kubernetes-style format:

```json
{
  "apiVersion": "dashboard.grafana.app/v2beta1",
  "kind": "Dashboard",
  "metadata": {
    "name": "dashboard-uid",
    "generation": 1,
    "creationTimestamp": "2024-06-10T16:46:19Z"
  },
  "spec": {
    "title": "My Dashboard",
    "tags": ["demo"],
    "elements": {
      "panel-1": { "kind": "Panel", "spec": { ... } }
    },
    "layout": {
      "kind": "GridLayout",
      "spec": {
        "items": [
          {
            "kind": "GridLayoutItem",
            "spec": {
              "x": 0, "y": 0, "width": 12, "height": 8,
              "element": {"kind": "ElementReference", "name": "panel-1"}
            }
          }
        ]
      }
    },
    "variables": [],
    "timeSettings": { "from": "now-6h", "to": "now" }
  }
}
```

Key differences from the legacy format:
- Panels are in `spec.elements` (keyed by name) instead of `spec.panels` (array)
- Layout is separate from panel definitions (`spec.layout`)
- Queries use `kind: "DataQuery"` with `group` and `version` fields
- Cannot be used directly with `POST /api/dashboards/db` -- use the legacy format for API operations

The `examples/` directory contains dashboards exported in v2beta1 format for reference.
