# PromQL Reference for Grafana Datasource Queries

## Query Object Format

When querying a Prometheus or Mimir datasource via `POST /api/ds/query`,
each query in the `queries` array needs these fields:

```json
{
  "refId": "A",
  "datasource": { "uid": "<UID>", "type": "prometheus" },
  "expr": "<PROMQL_EXPRESSION>",
  "range": true,
  "instant": false,
  "maxDataPoints": 1000,
  "intervalMs": 15000,
  "legendFormat": "{{label_name}}",
  "format": "time_series"
}
```

### Field Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `expr` | string | *required* | The PromQL expression |
| `range` | bool | `true` | Execute as range query (returns time series) |
| `instant` | bool | `false` | Execute as instant query (returns single value per series) |
| `legendFormat` | string | `"__auto"` | Template for series names. Use `{{label}}` syntax. `"__auto"` = auto-generate |
| `format` | string | `"time_series"` | `"time_series"`, `"table"`, or `"heatmap"` |
| `maxDataPoints` | int | `100` | Controls query resolution. Higher = more data points |
| `intervalMs` | int | calculated | Minimum step between data points in ms. Usually set by Grafana from maxDataPoints and time range |
| `editorMode` | string | `"code"` | `"code"` (raw PromQL) or `"builder"` (visual builder). Use `"code"` |

### Query Types

**Range query** (`range: true, instant: false`):
Returns a matrix — multiple data points per series over the time range.
Use for time series graphs.

**Instant query** (`range: false, instant: true`):
Returns a vector — one value per series at the end of the time range.
Use for stat panels, tables, gauges.

**Both** (`range: true, instant: true`):
Grafana executes both and merges the results (used in "Both" mode in the UI).

---

## PromQL Quick Reference

### Selectors

```promql
# Exact match
http_requests_total{method="GET", status="200"}

# Regex match
http_requests_total{method=~"GET|POST"}

# Negative match
http_requests_total{status!="500"}

# Negative regex
http_requests_total{method!~"OPTIONS|HEAD"}
```

### Range Vectors & Functions

```promql
# Rate of increase per second over 5 minutes
rate(http_requests_total[5m])

# Increase (absolute) over 5 minutes
increase(http_requests_total[5m])

# Use $__rate_interval instead of fixed intervals in Grafana
rate(http_requests_total[$__rate_interval])
```

### Aggregation

```promql
# Sum across all instances
sum(rate(http_requests_total[5m]))

# Group by label
sum by (method, status) (rate(http_requests_total[5m]))

# Excluding labels
sum without (instance) (rate(http_requests_total[5m]))

# Top 10 by value
topk(10, sum by (pod) (rate(container_cpu_usage_seconds_total[5m])))
```

### Common Aggregation Operators

`sum`, `min`, `max`, `avg`, `count`, `stddev`, `stdvar`,
`topk(k, ...)`, `bottomk(k, ...)`, `quantile(q, ...)`

### Binary Operators

```promql
# Arithmetic
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# Division with label matching
sum(rate(errors_total[5m])) / sum(rate(requests_total[5m]))

# Comparison (filter)
http_requests_total > 100

# Logical: and, or, unless
up == 1 and on(job) changes(process_start_time_seconds[1h]) > 0
```

### Over-Time Functions

```promql
# Average over time
avg_over_time(node_cpu_seconds_total[1h])

# Min/Max over time
max_over_time(response_time_seconds[24h])

# Quantile over time
quantile_over_time(0.95, request_duration_seconds[1h])
```

### Label Functions

```promql
# Replace/create labels
label_replace(up, "short_instance", "$1", "instance", "(.*):.*")

# Join labels
label_join(up, "combined", "-", "job", "instance")
```

### Subqueries

```promql
# Rate of the max of a metric, evaluated every 30s over 1h
rate(max_over_time(my_metric[5m])[1h:30s])
```

---

## Grafana-Specific Macros

These are resolved server-side. Leave them in the `expr` as-is.

| Macro | Expands to | Use case |
|-------|-----------|----------|
| `$__rate_interval` | Max of `$__interval + scrape_interval` and 4x scrape_interval | Always use inside `rate()` and `increase()` |
| `$__interval` | Calculated step interval based on time range and maxDataPoints | Range vector selectors |
| `$__range` | Duration of selected time range (e.g. `3600s`) | `avg_over_time(metric[$__range])` |

---

## Example Queries via API

### Time series: request rate by status code

```python
query_datasource(
    ds_uid="prometheus-1",
    ds_type="prometheus",
    query_body={
        "expr": 'sum by (status) (rate(http_requests_total[$__rate_interval]))',
        "range": True,
        "instant": False,
        "legendFormat": "{{status}}",
    },
    time_from="now-1h",
    time_to="now",
)
```

### Instant: current memory usage per pod

```python
query_datasource(
    ds_uid="prometheus-1",
    ds_type="prometheus",
    query_body={
        "expr": 'sum by (pod) (container_memory_working_set_bytes{namespace="production"})',
        "range": False,
        "instant": True,
        "format": "table",
    },
)
```

### Heatmap: request duration distribution

```python
query_datasource(
    ds_uid="prometheus-1",
    ds_type="prometheus",
    query_body={
        "expr": 'sum(increase(http_request_duration_seconds_bucket[5m])) by (le)',
        "range": True,
        "format": "heatmap",
    },
    time_from="now-6h",
    time_to="now",
)
```

---

## Common Patterns

### Error rate percentage
```promql
100 * sum(rate(http_requests_total{status=~"5.."}[5m]))
    / sum(rate(http_requests_total[5m]))
```

### P99 latency (from histogram)
```promql
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

### Pod restart count
```promql
increase(kube_pod_container_status_restarts_total{namespace="production"}[1h])
```

### CPU usage percentage per node
```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

### Available memory percentage
```promql
100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
```

---

## Pitfalls

1. **`rate()` needs a range vector.** `rate(metric)` is invalid. Use `rate(metric[5m])`.
2. **Use `$__rate_interval` in Grafana**, not hardcoded intervals, to avoid gaps with slow scrape targets.
3. **`increase()` can return non-integer values** due to extrapolation. This is expected.
4. **`histogram_quantile()` operates on `_bucket` metrics.** Ensure you aggregate `by (le)`.
5. **Label cardinality:** Queries that produce thousands of time series will be slow and may hit limits.
6. **`absent()` returns a single time series** with value 1 when the selector matches nothing. Useful for alerting on missing data.
