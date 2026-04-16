# Dashboard v2beta1 JSON Structure Reference

Annotated reference for the Grafana **v2beta1** dashboard model (Kubernetes-style resource). This format is used by Grafana v13+ and the K8s-style API at `/apis/dashboard.grafana.app/v2beta1/`.

For the legacy format used with `POST /api/dashboards/db`, see [dashboard-json-structure.md](dashboard-json-structure.md).

**OpenAPI spec source:** `https://play.grafana.org/openapi/v3/apis/dashboard.grafana.app/v2beta1`

## Resource Envelope

Every v2beta1 dashboard is a Kubernetes-style resource:

```json
{
  "apiVersion": "dashboard.grafana.app/v2beta1",
  "kind": "Dashboard",
  "metadata": {
    "name": "my-dashboard-uid",
    "generation": 1,
    "creationTimestamp": "2024-06-10T16:46:19Z",
    "labels": {},
    "annotations": {}
  },
  "spec": { ... },
  "status": { "conversion": { "failed": false } }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `apiVersion` | string | Must be `"dashboard.grafana.app/v2beta1"` |
| `kind` | string | Must be `"Dashboard"` |
| `metadata.name` | string | Dashboard UID (equivalent to legacy `uid`) |
| `metadata.generation` | integer | Incremented on each save (equivalent to legacy `version`) |
| `metadata.creationTimestamp` | string | ISO 8601 creation time |
| `metadata.labels` | object | Arbitrary key-value labels |
| `metadata.annotations` | object | Arbitrary key-value annotations |
| `status` | object | Conversion status (set by server) |

## DashboardSpec

The `spec` object contains the dashboard definition. Required fields per the OpenAPI spec are marked with **R**.

```json
{
  "spec": {
    "title": "My Dashboard",
    "description": "Optional description",
    "tags": ["prod", "api"],
    "editable": true,
    "cursorSync": "Off",
    "liveNow": false,
    "preload": false,
    "timeSettings": { ... },
    "elements": { ... },
    "layout": { ... },
    "variables": [ ... ],
    "annotations": [ ... ],
    "links": [ ... ]
  }
}
```

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `title` | string | **R** | Dashboard title |
| `description` | string | | Optional description |
| `tags` | string[] | **R** | Searchable tags |
| `editable` | boolean | | Whether UI editing is allowed |
| `cursorSync` | string | **R** | `"Off"`, `"Crosshair"`, or `"Tooltip"` |
| `liveNow` | boolean | | Redraw panels to keep data moving left |
| `preload` | boolean | **R** | Load all panels on dashboard load (default: false) |
| `revision` | integer | | Plugin dashboard version |
| `timeSettings` | object | **R** | Time picker configuration |
| `elements` | object | **R** | Map of panel definitions (keyed by name) |
| `layout` | object | **R** | Layout definition (GridLayout, RowsLayout, etc.) |
| `variables` | array | **R** | Template variable definitions |
| `annotations` | array | **R** | Annotation query definitions |
| `links` | array | **R** | Dashboard-level links |

## Elements (Panels)

Panels are defined in `spec.elements` as a keyed map. Each key is a panel name (e.g. `"panel-1"`), and each value is a `PanelKind` or `LibraryPanelKind`.

### PanelKind

```json
{
  "panel-1": {
    "kind": "Panel",
    "spec": {
      "id": 1,
      "title": "CPU Usage",
      "description": "",
      "transparent": false,
      "links": [],
      "data": { ... },
      "vizConfig": { ... }
    }
  }
}
```

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `kind` | string | **R** | Must be `"Panel"` |
| `spec.id` | number | **R** | Unique numeric ID within the dashboard |
| `spec.title` | string | **R** | Panel title |
| `spec.description` | string | **R** | Panel description (can be empty) |
| `spec.transparent` | boolean | | Transparent background |
| `spec.links` | DataLink[] | **R** | Panel data links |
| `spec.data` | QueryGroupKind | **R** | Query configuration |
| `spec.vizConfig` | VizConfigKind | **R** | Visualization configuration |

### LibraryPanelKind

```json
{
  "panel-lib": {
    "kind": "LibraryPanel",
    "spec": {
      "id": 2,
      "title": "Shared Panel",
      "libraryPanel": {
        "uid": "lib-panel-uid",
        "name": "Shared Panel Name"
      }
    }
  }
}
```

## Data & Queries

Panel data is structured as `QueryGroupKind` → `PanelQueryKind` → `DataQueryKind`.

### QueryGroupKind

```json
{
  "kind": "QueryGroup",
  "spec": {
    "queries": [ ... ],
    "transformations": [ ... ],
    "queryOptions": {
      "interval": "",
      "maxDataPoints": 1000,
      "cacheTimeout": "",
      "timeFrom": "",
      "timeShift": "",
      "hideTimeOverride": false
    }
  }
}
```

### PanelQueryKind

Each query in the `queries` array is wrapped in a `PanelQueryKind`:

```json
{
  "kind": "PanelQuery",
  "spec": {
    "refId": "A",
    "hidden": false,
    "query": {
      "kind": "DataQuery",
      "group": "datasource",
      "version": "v0",
      "spec": { ... },
      "labels": {
        "grafana.app/export-label": "datasource-1"
      }
    }
  }
}
```

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `kind` | string | | Must be `"PanelQuery"` |
| `spec.refId` | string | **R** | Reference ID (`"A"`, `"B"`, ...) |
| `spec.hidden` | boolean | | Hide query results |
| `spec.query` | DataQueryKind | **R** | The actual query definition |

### DataQueryKind

The inner query uses a `kind`/`group`/`version`/`spec` pattern:

```json
{
  "kind": "DataQuery",
  "group": "datasource",
  "version": "v0",
  "spec": {
    "expr": "rate(http_requests_total[5m])",
    "legendFormat": "{{service}}",
    "instant": false,
    "range": true
  },
  "labels": {
    "grafana.app/export-label": "datasource-1"
  }
}
```

The `spec` contents are datasource-specific (same fields as legacy targets). The `labels` map typically contains a `grafana.app/export-label` that references the datasource.

## VizConfig

Visualization configuration uses a `kind`/`group`/`version`/`spec` pattern:

```json
{
  "kind": "VizConfig",
  "group": "timeseries",
  "version": "8.0.0-beta2",
  "spec": {
    "options": { ... },
    "fieldConfig": {
      "defaults": { ... },
      "overrides": [ ... ]
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Must be `"VizConfig"` |
| `group` | string | Panel plugin type (e.g. `"timeseries"`, `"stat"`, `"table"`, `"geomap"`) |
| `version` | string | Plugin version |
| `spec.options` | object | Plugin-specific visualization options |
| `spec.fieldConfig` | FieldConfigSource | Field display configuration (same structure as legacy) |

### FieldConfigSource

```json
{
  "defaults": {
    "unit": "percent",
    "decimals": 1,
    "min": 0,
    "max": 100,
    "color": { "mode": "palette-classic" },
    "thresholds": {
      "mode": "absolute",
      "steps": [
        { "value": null, "color": "green" },
        { "value": 80, "color": "yellow" },
        { "value": 90, "color": "red" }
      ]
    },
    "custom": { ... }
  },
  "overrides": [
    {
      "matcher": { "id": "byName", "options": "errors" },
      "properties": [
        { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }
      ]
    }
  ]
}
```

See [dashboard-json-structure.md](dashboard-json-structure.md) for the full fieldConfig reference — the structure is identical in both formats.

## Layout

Layout is separate from panel definitions. The `spec.layout` field uses one of four kinds.

### GridLayout

Flat grid of panels. Most common for simple dashboards.

```json
{
  "kind": "GridLayout",
  "spec": {
    "items": [
      {
        "kind": "GridLayoutItem",
        "spec": {
          "x": 0,
          "y": 0,
          "width": 12,
          "height": 8,
          "element": {
            "kind": "ElementReference",
            "name": "panel-1"
          }
        }
      }
    ]
  }
}
```

**GridLayoutItem fields:**

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `x` | integer | **R** | X position (0-23) |
| `y` | integer | **R** | Y position (rows from top) |
| `width` | integer | **R** | Width in grid units (max 24) |
| `height` | integer | **R** | Height in grid units |
| `element` | ElementReference | **R** | Reference to an element in `spec.elements` |
| `repeat` | RepeatOptions | | Panel repeat configuration |

**ElementReference:** `{ "kind": "ElementReference", "name": "<element-key>" }` — the `name` must match a key in `spec.elements`.

**Grid rules:** 24-column grid. `x + width` must not exceed 24. Panels render top-to-bottom by `y`, left-to-right by `x`.

### RowsLayout

Groups panels into collapsible rows, each containing a nested layout.

```json
{
  "kind": "RowsLayout",
  "spec": {
    "rows": [
      {
        "kind": "RowsLayoutRow",
        "spec": {
          "title": "HTTP Metrics",
          "collapse": false,
          "hideHeader": false,
          "fillScreen": false,
          "layout": {
            "kind": "GridLayout",
            "spec": {
              "items": [ ... ]
            }
          }
        }
      }
    ]
  }
}
```

**RowsLayoutRow fields:**

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Row title |
| `collapse` | boolean | Whether the row is collapsed |
| `hideHeader` | boolean | Hide row header |
| `fillScreen` | boolean | Row fills remaining screen height |
| `layout` | Layout | Nested layout (typically GridLayout) |
| `repeat` | RowRepeatOptions | Row repeat configuration |
| `conditionalRendering` | object | Conditional visibility rules |

### AutoGridLayout

Automatically sizes and arranges panels.

```json
{
  "kind": "AutoGridLayout",
  "spec": {
    "columnWidthMode": "standard",
    "rowHeightMode": "standard",
    "maxColumnCount": 3,
    "fillScreen": false,
    "items": [
      {
        "kind": "AutoGridLayoutItem",
        "spec": {
          "element": { "kind": "ElementReference", "name": "panel-1" }
        }
      }
    ]
  }
}
```

### TabsLayout

Organizes panels into tabs.

```json
{
  "kind": "TabsLayout",
  "spec": {
    "tabs": [
      {
        "kind": "TabsLayoutTab",
        "spec": {
          "title": "Overview",
          "layout": { "kind": "GridLayout", "spec": { "items": [...] } }
        }
      }
    ]
  }
}
```

## Variables

Variables are an array of typed kinds in `spec.variables`. Each has a `kind` field that determines its type and `spec` contents.

### Variable Kinds

| Kind | Description |
|------|-------------|
| `QueryVariable` | Values from a datasource query |
| `CustomVariable` | Static comma-separated values |
| `ConstantVariable` | Fixed hidden value |
| `TextVariable` | Free-text input |
| `DatasourceVariable` | Select datasource by plugin type |
| `IntervalVariable` | Time interval selection |
| `GroupByVariable` | Group-by label selection |
| `AdhocVariable` | Dynamic label filter |
| `SwitchVariable` | Boolean toggle (on/off values) |

### QueryVariable

```json
{
  "kind": "QueryVariable",
  "spec": {
    "name": "namespace",
    "label": "Namespace",
    "description": "",
    "query": {
      "kind": "DataQuery",
      "group": "datasource",
      "version": "v0",
      "spec": { "expr": "label_values(kube_pod_info, namespace)" }
    },
    "refresh": "OnDashboardLoad",
    "regex": "",
    "sort": "AlphabeticalAsc",
    "multi": false,
    "includeAll": false,
    "allValue": "",
    "current": { "text": "default", "value": "default" },
    "hide": "",
    "skipUrlSync": false,
    "allowCustomValue": false
  }
}
```

### CustomVariable

```json
{
  "kind": "CustomVariable",
  "spec": {
    "name": "env",
    "query": "production,staging,development",
    "current": { "text": "production", "value": "production" },
    "options": [
      { "text": "production", "value": "production", "selected": true }
    ],
    "multi": false,
    "includeAll": false,
    "hide": "",
    "skipUrlSync": false,
    "allowCustomValue": false
  }
}
```

### ConstantVariable

```json
{
  "kind": "ConstantVariable",
  "spec": {
    "name": "version",
    "query": "v2.0",
    "current": { "text": "v2.0", "value": "v2.0" },
    "hide": "variable",
    "skipUrlSync": false
  }
}
```

### TextVariable

```json
{
  "kind": "TextVariable",
  "spec": {
    "name": "search",
    "query": "default value",
    "current": { "text": "default value", "value": "default value" },
    "hide": "",
    "skipUrlSync": false
  }
}
```

### SwitchVariable

```json
{
  "kind": "SwitchVariable",
  "spec": {
    "name": "showErrors",
    "current": "enabled",
    "enabledValue": "true",
    "disabledValue": "false",
    "hide": "",
    "skipUrlSync": false
  }
}
```

### Common variable fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Variable name (used as `$name` in queries) |
| `label` | string | Display label (optional) |
| `description` | string | Tooltip description |
| `hide` | string | `""` = visible, `"label"` = hide label, `"variable"` = hide completely |
| `skipUrlSync` | boolean | Exclude from URL state |
| `current` | VariableOption | Currently selected value: `{ "text": "...", "value": "..." }` |

## Annotations

Annotation queries are an array of `AnnotationQueryKind` in `spec.annotations`:

```json
{
  "kind": "AnnotationQuery",
  "spec": {
    "name": "Annotations & Alerts",
    "enable": true,
    "hide": true,
    "builtIn": true,
    "iconColor": "rgba(0, 211, 255, 1)",
    "query": {
      "kind": "DataQuery",
      "group": "datasource",
      "version": "v0",
      "spec": { "type": "dashboard", "limit": 100 }
    },
    "filter": {
      "ids": [],
      "exclude": false
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Annotation name |
| `enable` | boolean | Whether annotation is active |
| `hide` | boolean | Hide in annotation picker |
| `builtIn` | boolean | Built-in annotation (Annotations & Alerts) |
| `iconColor` | string | Marker color |
| `query` | DataQueryKind | Annotation data source query |
| `filter` | AnnotationPanelFilter | Limit to specific panels |

## TimeSettings

```json
{
  "timeSettings": {
    "from": "now-6h",
    "to": "now",
    "timezone": "browser",
    "autoRefresh": "30s",
    "autoRefreshIntervals": ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h", "2h", "1d"],
    "hideTimepicker": false,
    "fiscalYearStartMonth": 0,
    "weekStart": "",
    "nowDelay": "",
    "quickRanges": []
  }
}
```

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `from` | string | **R** | Default start time (e.g. `"now-6h"`) |
| `to` | string | **R** | Default end time (e.g. `"now"`) |
| `timezone` | string | | `"browser"`, `"utc"`, or IANA timezone |
| `autoRefresh` | string | **R** | Refresh interval (`"5s"`, `"1m"`, `""` for off) |
| `autoRefreshIntervals` | string[] | **R** | Available refresh intervals |
| `hideTimepicker` | boolean | **R** | Hide time picker UI |
| `fiscalYearStartMonth` | integer | **R** | 0-11 (January=0) |
| `weekStart` | string | | Day of week start |
| `nowDelay` | string | | Delay for "now" |
| `quickRanges` | TimeRangeOption[] | | Custom quick ranges |

## Dashboard Links

```json
{
  "links": [
    {
      "title": "Service Detail",
      "type": "link",
      "url": "/d/service-detail?var-service=$service",
      "targetBlank": false,
      "includeVars": true,
      "keepTime": true,
      "tooltip": ""
    },
    {
      "title": "All Monitoring",
      "type": "dashboards",
      "tags": ["monitoring"],
      "asDropdown": true,
      "targetBlank": false
    }
  ]
}
```

## Legacy ↔ v2beta1 Mapping

| Concept | Legacy format | v2beta1 format |
|---------|--------------|----------------|
| **UID** | `uid` | `metadata.name` |
| **Version** | `version` (integer) | `metadata.generation` (integer) / `metadata.resourceVersion` (string for OCC) |
| **Title** | `title` | `spec.title` |
| **Tags** | `tags` | `spec.tags` |
| **Panels** | `panels` (array, each with `gridPos`) | `spec.elements` (keyed map) + `spec.layout` (separate) |
| **Panel type** | `panels[].type` | `spec.elements.<name>.spec.vizConfig.group` |
| **Panel queries** | `panels[].targets` | `spec.elements.<name>.spec.data.spec.queries` (wrapped in PanelQueryKind) |
| **Grid position** | `panels[].gridPos` (part of panel) | `spec.layout.spec.items[].spec` (separate from panel) |
| **Variables** | `templating.list` (untyped) | `spec.variables` (typed kinds: QueryVariable, CustomVariable, etc.) |
| **Annotations** | `annotations.list` | `spec.annotations` (AnnotationQueryKind) |
| **Time range** | `time.from` / `time.to` | `spec.timeSettings.from` / `spec.timeSettings.to` |
| **Refresh** | `refresh` | `spec.timeSettings.autoRefresh` |
| **Timezone** | `timezone` | `spec.timeSettings.timezone` |
| **Crosshair** | `graphTooltip` (0/1/2) | `spec.cursorSync` (`"Off"`/`"Crosshair"`/`"Tooltip"`) |
| **Schema version** | `schemaVersion` (integer) | `apiVersion` (string) |
| **Rows** | `panels[]` with `type: "row"` | `RowsLayout` with `RowsLayoutRow` items |
| **Datasource ref** | `datasource: { type, uid }` | `labels["grafana.app/export-label"]` on DataQueryKind |

## Repeat Options

### Panel repeat (GridLayoutItem)

```json
{
  "repeat": {
    "mode": "variable",
    "value": "namespace",
    "direction": "h",
    "maxPerRow": 4
  }
}
```

### Row repeat (RowsLayoutRow)

```json
{
  "repeat": {
    "mode": "variable",
    "value": "namespace"
  }
}
```

## Conditional Rendering (RowsLayoutRow)

Rows can be conditionally shown/hidden based on variable values or data:

```json
{
  "conditionalRendering": {
    "kind": "ConditionalRenderingGroup",
    "spec": {
      "condition": "AND",
      "items": [
        {
          "kind": "ConditionalRenderingVariable",
          "spec": {
            "name": "showAdvanced",
            "operator": "equals",
            "value": "true"
          }
        }
      ]
    }
  }
}
```
