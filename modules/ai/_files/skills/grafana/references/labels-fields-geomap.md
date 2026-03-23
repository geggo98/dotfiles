# Grafana: Labels vs. Fields, the "Labels to Fields" Transformation, and Geomap Integration

## Core Concepts

### DataFrame

Since Grafana v7, the internal data model is the **DataFrame** — essentially a table of ordered columns (called Fields) of equal length, plus metadata.

### Field

A column within a DataFrame. Each Field has:

- `name` (e.g., `"Time"`, `"Value"`)
- `type` (`time`, `number`, `string`, …)
- `values[]` — the actual data points
- `labels` (optional) — a `map[string]string` of key-value metadata

### Label

A key-value pair attached to a Field as metadata. Labels originate from the Prometheus data model, where every time series is uniquely identified by its label combination (e.g., `{job="api", instance="10.0.0.1:8080"}`).

---

## How Prometheus Data Maps to Grafana DataFrames

Prometheus returns an array of time series per query. Each series is a tuple of `metric` (the label map) and `values` (timestamp + numeric value).

Grafana's Prometheus datasource translates this as follows:

```
Prometheus time series  →  DataFrame with 2 Fields:
  Field 0: name="Time",  type=time,   values=[t1, t2, ...]
  Field 1: name="Value", type=number, values=[42, 43, ...],
           labels={"job":"api", "instance":"10.0.0.1:8080"}
```

**Labels are metadata on the Value Field, not separate columns.** They do not appear in `values[]`; they live in `field.labels`.

### Why This Separation Exists

| Reason                  | Explanation                                                                                         |
| ----------------------- | --------------------------------------------------------------------------------------------------- |
| **Storage efficiency**  | A label like `instance="10.0.0.1:8080"` applies to every data point. As metadata, it's stored once. |
| **Prometheus semantics** | Labels identify a time series (dimensions), not measured values. Grafana mirrors this.              |
| **Panel rendering**     | Time Series panels use `field.labels` to generate legend entries and distinguish series.            |

### Practical Implications

| Aspect                               | Label (metadata)                      | Field (column)                        |
| ------------------------------------ | ------------------------------------- | ------------------------------------- |
| Storage location                     | `field.labels` map                    | `field.values[]` array                |
| Cardinality per series               | 1×                                    | N× (one per data point)               |
| Visible in Table panel               | **No** (without transformation)       | **Yes**                               |
| Visible in legend                    | **Yes** (automatic)                   | No (it *is* the value)                |
| Filterable via Grafana variables     | Yes (`label_values()`)                | Only via queries                      |

---

## The "Labels to Fields" Transformation

### What It Does

This transformation converts label metadata on Fields into **materialized columns** (i.e., proper Fields with repeated values). It denormalizes the data so that row-oriented panels and downstream transformations can access label values.

**Before** (internal model):

```
Field "Time"  → values: [t1, t2]
Field "Value" → values: [42, 43], labels: {job:"api", instance:"10.0.0.1:8080"}
```

**After** (Labels to Fields applied):

```
Field "Time"     → values: [t1, t2]
Field "job"      → values: ["api", "api"]
Field "instance" → values: ["10.0.0.1:8080", "10.0.0.1:8080"]
Field "Value"    → values: [42, 43], labels: {}
```

> **Note:** The transformation internally consists of two steps: (1) extracting labels into fields per series, and (2) a **merge** step that joins all resulting frames into a single table. The merge step is mandatory and cannot be turned off.

### Configuration Parameters

#### Mode

- **Columns** (default) — Each selected label key becomes a new column. This is the standard use case for Table panels and further transformations.
- **Rows** — Each label key becomes a separate row. Rarely needed; useful for vertical key-value displays.

#### Value Field Name

This parameter is **not** a rename/alias for the output column. It performs a **pivot operation**:

It takes the **values** of the specified label and uses them as **column names** for the Value field.

**Example without** `Value field name`:

```
Time | method | handler | Value
t1   | GET    | /api    | 42
t1   | POST   | /api    | 99
```

**Example with** `Value field name = method`:

```
Time | GET | POST
t1   | 42  | 99
```

The label values `GET` and `POST` become column headers. This is effectively a pivot/wide-format conversion.

#### Label Selection (keepLabels)

Controls which labels get materialized into columns.

- **Empty / unset** → All labels are extracted.
- **Specific labels selected** → Only those are materialized. **Remaining labels stay as metadata** on the Field. This is useful when you need only one label as a column (e.g., `geohash` for Geomap) but want other labels (e.g., `instance`, `job`) to remain visible in legends.

### Renaming Extracted Labels

There is **no per-label rename** within this transformation. To rename columns after extraction:

1. **"Organize fields by name"** transformation — chain it after "Labels to Fields" to rename individual Fields.
2. **"Rename by regex"** transformation — for systematic/pattern-based renaming.

Applying "Labels to Fields" multiple times is **not useful** — after the first pass, all selected labels have been materialized and removed from the metadata. A second pass finds nothing to do.

---

## When to Use "Labels to Fields"

### Panels That Require Fields

Some panels read only Fields, never label metadata:

- **Table** — only shows Fields as columns
- **Geomap** — needs `latitude`/`longitude` as numeric Fields or `geohash` as a string Field
- **Bar Chart / Bar Gauge** — labels must be Fields to serve as category axes
- **Stat panel** (in "Fields" mode) — grouping by label requires it to be a Field

### Downstream Transformations That Operate on Fields

- **Filter by value** — e.g., keep only rows where `env="prod"`
- **Group by** — aggregate by a label value
- **Join by field** — merge two queries on a shared label (e.g., `instance`)
- **Sort by** — sort by a label value
- **Add field from calculation** — reference a label in computed expressions
- **Convert field type** — change a label from string to number (needed for lat/lon)

### Wide-Format Conversion

Use the `Value field name` parameter to pivot multiple series into separate columns (one per label value).

### Export and Alerting

- **CSV export** from Table panels only includes Fields. Un-materialized labels are lost.
- **Alert annotations** — sometimes easier to template when labels are Fields.

### When NOT to Use It

- **Time Series panel** — reads `field.labels` directly for legends and tooltips. Applying the transformation would break series identification.
- **PromQL filtering** — happens server-side in Prometheus, not in Grafana.
- **Legend templates** — `{{instance}}` in the legend accesses labels directly.

**Rule of thumb:** Need the label value **as a data point in a row** (display, filter, join, export)? → Use "Labels to Fields". Need it only for **series identification** (legend, color, tooltip)? → Don't.

---

## Geomap Panel: Location Modes

The Geomap panel supports four location modes:

| Mode        | Input                                    | Field Requirements                                                                 |
| ----------- | ---------------------------------------- | ---------------------------------------------------------------------------------- |
| **Auto**    | Automatically detects location fields    | Fields named `latitude`/`lat`, `longitude`/`lon`/`lng`, `geohash`, or `lookup`     |
| **Coords**  | Explicit coordinate fields               | Two **numeric** Fields for latitude and longitude                                  |
| **Geohash** | Geohash-encoded location string          | One **string** Field containing geohash values                                     |
| **Lookup**  | Location name mapped via gazetteer       | One string Field with country codes, airport codes, or US state codes              |

### Auto-Detection

- If a field is named `latitude`/`lat` and another `longitude`/`lon`/`lng`, Geomap auto-detects coordinates.
- If a field is named `geohash`, Geomap auto-detects geohash mode.
- If a field is named `lookup`, Geomap auto-detects lookup mode with country codes.
- For non-standard field names, you must manually select the location mode and specify the field.

---

## Prometheus + Geomap: Transformation Pipelines

Since Prometheus labels are always strings and live in metadata (not as DataFrame Fields), you need transformations to make location data usable by Geomap.

### Prerequisite: The PromQL Query Must Expose the Label

Before any Grafana transformation can materialize a label, **the label must be present in the query result**. Prometheus only returns labels that survive the query's aggregation. If you aggregate with `sum()`, `rate()`, `avg()`, etc., all labels are dropped unless you explicitly preserve them with a `by` clause.

**Wrong** — `geohash` label is aggregated away:

```promql
sum(rate(http_requests_total[5m]))
```

**Correct** — `geohash` label is preserved via `by`:

```promql
sum by (geohash) (rate(http_requests_total[5m]))
```

This applies to all location labels (`geohash`, `latitude`, `longitude`, `country`, etc.). If the label is not in the `by` clause (or the query uses no aggregation and the label exists on the raw series), it will not appear in Grafana's DataFrame, and "Labels to Fields" has nothing to extract.

> **Tip:** When using multiple labels for display (e.g., `geohash` for location and `region` for the legend), include all of them in the `by` clause:
> ```promql
> sum by (geohash, region) (rate(http_requests_total[5m]))
> ```
> Then use Label Selection in "Labels to Fields" to materialize only `geohash`, keeping `region` as metadata for the legend.

### Option A: Geohash Label (Recommended)

This is the simplest approach. Store location as a single geohash label on your metric.

```
my_metric{geohash="u281z", region="bavaria"} 42
```

**Pipeline:**

```
1. Prometheus Query
2. Labels to Fields        → select only "geohash"
3. Geomap Panel            → Location mode: Geohash, field: geohash
```

Only two transformations needed. The geohash stays as a string — no type conversion required.

**Advantages:**

- One label instead of two (vs. separate `latitude`/`longitude`)
- No string-to-number conversion needed
- Controllable cardinality via geohash precision (fewer characters = coarser grid)
- Auto-detected if the field is named `geohash`

### Option B: Separate Latitude/Longitude Labels

```
my_metric{latitude="48.1351", longitude="11.5820", city="munich"} 42
```

**Pipeline:**

```
1. Prometheus Query
2. Labels to Fields        → select "latitude" and "longitude"
3. Convert field type      → latitude: String → Number
4. Convert field type      → longitude: String → Number
5. Geomap Panel            → Location mode: Coords, lat: latitude, lon: longitude
```

**Important:** Prometheus labels are **always strings**, even if they contain numeric-looking values like `"48.1351"`. The Geomap Coords mode requires **numeric** Fields. Without the "Convert field type" step, the panel will not render the data.

### Option C: Lookup Labels

```
my_metric{country="DE"} 42
```

**Pipeline:**

```
1. Prometheus Query
2. Labels to Fields        → select "country"
3. Geomap Panel            → Location mode: Lookup, field: country, gazetteer: Countries
```

No type conversion needed. The gazetteer maps codes to coordinates internally.

---

## Summary: Decision Flowchart

```
Do I need label values as row data (display, filter, join, export)?
├── No  → Leave labels as metadata. Time Series panel, legends, and PromQL handle them.
└── Yes → Apply "Labels to Fields"
          │
          ├── Need a specific label as a column?
          │   → Use Label Selection to pick only that label
          │
          ├── Need wide format (one column per label value)?
          │   → Set "Value field name" to the label key to pivot on
          │
          ├── Need to rename the resulting columns?
          │   → Chain "Organize fields by name" after
          │
          └── Need numeric values from string labels (e.g., lat/lon)?
              → Chain "Convert field type" after
```

---

## References

- [Grafana Docs: Transform data](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/query-transform-data/transform-data/)
- [Grafana Docs: Geomap panel](https://grafana.com/docs/grafana/latest/visualizations/panels-visualizations/visualizations/geomap/)
- [Grafana GitHub PR #41020: Labels to Fields — Rows mode](https://github.com/grafana/grafana/pull/41020)
