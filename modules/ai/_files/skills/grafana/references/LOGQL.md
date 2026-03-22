# LogQL Reference for Grafana Datasource Queries

## Query Object Format

When querying a Loki datasource via `POST /api/ds/query`,
each query in the `queries` array needs these fields:

```json
{
  "refId": "A",
  "datasource": { "uid": "<UID>", "type": "loki" },
  "expr": "<LOGQL_EXPRESSION>",
  "queryType": "range",
  "maxLines": 1000,
  "maxDataPoints": 1000,
  "intervalMs": 15000,
  "legendFormat": "",
  "direction": "backward"
}
```

### Field Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `expr` | string | *required* | The LogQL expression |
| `queryType` | string | `"range"` | `"range"` (over time) or `"instant"` (single point) |
| `maxLines` | int | `1000` | Max log lines to return (for log queries) |
| `legendFormat` | string | `""` | Template for metric query legend |
| `direction` | string | `"backward"` | `"backward"` (newest first) or `"forward"` (oldest first) |
| `maxDataPoints` | int | `1000` | Resolution for metric queries |
| `intervalMs` | int | calculated | Step interval for metric queries |

### Query Types

**Log queries** return raw log lines:
```logql
{namespace="production", app="api-server"} |= "error"
```

**Metric queries** return numeric time series derived from logs:
```logql
rate({namespace="production"} |= "error" [5m])
```

The datasource auto-detects which type based on the expression.
Log queries return log lines; metric queries return Data Frames like Prometheus.

---

## LogQL Quick Reference

### Stream Selectors

The stream selector is mandatory and selects log streams by label.

```logql
# Exact match
{job="api-server"}

# Regex match
{namespace=~"prod|staging"}

# Exclusion
{job!="debug"}

# Multiple labels (AND logic)
{namespace="production", app="web", container="nginx"}
```

**Important:** Loki indexes only labels, not log content. Narrow your stream
selector as much as possible before applying line filters.

### Line Filters

Applied after stream selection. Processed left-to-right.

| Operator | Description | Example |
|----------|-------------|---------|
| `\|=` | Contains string | `\|= "error"` |
| `!= ` | Does not contain | `!= "healthcheck"` |
| `\|~` | Matches regex | `\|~ "status=[45]\\d{2}"` |
| `!~` | Does not match regex | `!~ "GET /health"` |

```logql
{app="api"} |= "error" != "timeout" |~ "user_id=\\d+"
```

**Performance tip:** Place the most selective line filter first (leftmost).
Loki evaluates left-to-right and discards non-matching lines early.

### Parser Stages

Extract structured fields from log lines.

**JSON parser:**
```logql
{app="api"} | json
{app="api"} | json level, method, duration   # extract only specific fields
```

**Logfmt parser:**
```logql
{app="api"} | logfmt
```

**Pattern parser (fast, template-based):**
```logql
{app="nginx"} | pattern `<ip> - - [<timestamp>] "<method> <path> <_>" <status> <size>`
```

**Regex parser:**
```logql
{app="api"} | regexp `(?P<method>\w+) (?P<path>/\S+) (?P<status>\d+)`
```

### Label Filters

Filter on extracted labels (after parsing).

```logql
# Comparison operators
{app="api"} | json | status >= 400
{app="api"} | logfmt | duration > 10s
{app="api"} | json | method = "POST"

# Logical operators
{app="api"} | json | level = "error" or level = "critical"
{app="api"} | json | duration > 5s and status != 200
```

### Line Format (rewrite log lines)

```logql
{app="api"} | json | line_format "{{.method}} {{.path}} → {{.status}} ({{.duration}})"
```

### Label Format (rename/create labels)

```logql
{app="api"} | json | label_format new_label="{{.old_label}}"
```

### Drop Labels

```logql
{app="api"} | json | drop __error__, internal_id
```

---

## Metric Queries

Wrap a log query in an aggregation function to get numeric time series.

### Range Aggregations

| Function | Description |
|----------|-------------|
| `rate(... [interval])` | Log entries per second |
| `count_over_time(... [interval])` | Count of log entries |
| `bytes_rate(... [interval])` | Bytes per second |
| `bytes_over_time(... [interval])` | Total bytes |
| `sum_over_time(... \| unwrap field [interval])` | Sum of extracted numeric field |
| `avg_over_time(... \| unwrap field [interval])` | Average of extracted field |
| `max_over_time(... \| unwrap field [interval])` | Max of extracted field |
| `min_over_time(... \| unwrap field [interval])` | Min of extracted field |
| `quantile_over_time(q, ... \| unwrap field [interval])` | Quantile of extracted field |

### Examples

```logql
# Error rate per second
rate({namespace="production"} |= "error" [5m])

# Errors per minute, grouped by app
sum by (app) (count_over_time({namespace="production"} |= "error" [1m]))

# P99 response time from structured logs
quantile_over_time(0.99,
  {app="api"} | json | unwrap duration_ms [5m]
) by (endpoint)

# Log volume (bytes/sec) per service
sum by (service_name) (bytes_rate({namespace="production"} [5m]))

# Top 5 error-producing apps
topk(5, sum by (app) (rate({namespace="production"} | json | level="error" [5m])))
```

### Unwrap

`unwrap` extracts a numeric value from a label for use with statistical
aggregation functions.

```logql
{app="api"} | json | unwrap response_time_ms
```

Only works with labels that contain numeric values.
Use `| unwrap duration(label)` to unwrap Go-style duration strings (e.g. `"1.5s"`).

---

## Grafana-Specific Macros

| Macro | Description |
|-------|-------------|
| `$__auto` | Auto-calculated range interval based on time range and resolution |

Use `$__auto` in metric queries instead of hardcoded intervals:
```logql
rate({app="api"} |= "error" [$__auto])
```

---

## Example Queries via API

### Log query: recent errors in a namespace

```python
query_datasource(
    ds_uid="loki-1",
    ds_type="loki",
    query_body={
        "expr": '{namespace="production"} |= "error" != "healthcheck" | json',
        "queryType": "range",
        "maxLines": 100,
        "direction": "backward",
    },
    time_from="now-30m",
    time_to="now",
)
```

### Metric query: error rate by service

```python
query_datasource(
    ds_uid="loki-1",
    ds_type="loki",
    query_body={
        "expr": 'sum by (service_name) (rate({namespace="production"} |= "error" [$__auto]))',
        "queryType": "range",
        "legendFormat": "{{service_name}}",
    },
    time_from="now-6h",
    time_to="now",
)
```

### Log query: specific trace context

```python
query_datasource(
    ds_uid="loki-1",
    ds_type="loki",
    query_body={
        "expr": '{namespace="production"} |= "trace_id=abc123def456"',
        "queryType": "range",
        "maxLines": 500,
        "direction": "forward",  # chronological order
    },
    time_from="now-24h",
    time_to="now",
)
```

---

## Pitfalls

1. **Stream selector is mandatory.** `|= "error"` alone is invalid. You must start with `{...}`.
2. **High-cardinality labels are expensive.** Never use unique identifiers (user_id, request_id) as stream labels. Filter them with line filters instead.
3. **Parser order matters.** Apply line filters (`|=`, `!=`) BEFORE parsers (`| json`). Filtering raw text is much faster than parsing then filtering.
4. **`__error__` label:** If a parser fails (e.g., non-JSON line), the line gets an `__error__` label instead of being dropped. Use `| __error__ = ""` to exclude parse failures.
5. **`maxLines` only applies to log queries**, not metric queries. Metric queries are controlled by `maxDataPoints` and `intervalMs`.
6. **Direction:** For log queries, `"backward"` returns newest first (default). For tracing a request flow, use `"forward"`.
