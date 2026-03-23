# SQL Reference for Grafana Datasource Queries

Covers: MySQL, PostgreSQL, ClickHouse, Google BigQuery.

All SQL-based datasources share a similar query object structure but differ
in dialect-specific syntax and `type` strings.

## Query Object Format

```json
{
  "refId": "A",
  "datasource": { "uid": "<UID>", "type": "<TYPE>" },
  "rawSql": "<SQL_QUERY>",
  "format": "table",
  "maxDataPoints": 1000,
  "intervalMs": 15000
}
```

### Type Strings

| Datasource | `type` value |
|------------|-------------|
| MySQL | `mysql` |
| PostgreSQL | `postgres` or `grafana-postgresql-datasource` |
| ClickHouse | `grafana-clickhouse-datasource` |
| Google BigQuery | `grafana-bigquery-datasource` |

### Field Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `rawSql` | string | *required* | The SQL query. May contain Grafana macros |
| `format` | string | `"table"` | `"table"` or `"time_series"` |
| `maxDataPoints` | int | `100` | Used by `$__timeGroup` macro for auto-bucketing |
| `intervalMs` | int | calculated | Interval for time-based grouping |

### Format Modes

**`"table"`:** Returns results as-is. Suitable for tables, stat panels, or
post-processing. Column names become field names.

**`"time_series"`:** Requires the result to have a time column and one or more
numeric value columns. Grafana converts this into time series frames.
For time_series format, the query should return:
- Column 1: time (datetime or epoch)
- Column 2+: numeric values
- Optional: a string column for series names (metric column)

---

## Grafana SQL Macros

These are resolved server-side by the SQL datasource plugin. Leave them in
`rawSql` as-is. They are replaced based on the dashboard time range and query
interval.

### Time Filter Macros

| Macro | MySQL expands to | Postgres expands to |
|-------|-----------------|-------------------|
| `$__timeFilter(col)` | `col BETWEEN '2024-01-01' AND '2024-01-02'` | `col BETWEEN '2024-01-01' AND '2024-01-02'` |
| `$__timeFrom()` | `'2024-01-01T00:00:00Z'` | `'2024-01-01T00:00:00Z'` |
| `$__timeTo()` | `'2024-01-02T00:00:00Z'` | `'2024-01-02T00:00:00Z'` |
| `$__unixEpochFilter(col)` | `col >= 1704067200 AND col <= 1704153600` | same |
| `$__unixEpochFrom()` | `1704067200` | `1704067200` |
| `$__unixEpochTo()` | `1704153600` | `1704153600` |

### Time Grouping Macros

| Macro | Description |
|-------|-------------|
| `$__timeGroup(col, interval)` | Groups time column into buckets. `interval` can be `$__interval` for auto-sizing |
| `$__timeGroup(col, interval, NULL)` | Same but fills gaps with NULL |
| `$__timeGroupAlias(col, interval)` | Same as timeGroup but aliases the column as `time` |

### ClickHouse-Specific Macros

| Macro | Description |
|-------|-------------|
| `$__timeFilter(col)` | ClickHouse datetime filter |
| `$__dateFilter(col)` | Date-only filter (Date type) |
| `$__timeInterval(col)` | Groups by auto interval |
| `$__conditionalAll(col, $variable)` | Returns `1=1` if variable is "All" |

### BigQuery-Specific Macros

BigQuery uses the same macros as Postgres but adapted for BigQuery SQL dialect.

---

## Query Examples

### MySQL / PostgreSQL: Time Series

```sql
SELECT
  $__timeGroupAlias(created_at, $__interval),
  count(*) AS "requests",
  avg(response_time_ms) AS "avg_response_time"
FROM requests
WHERE $__timeFilter(created_at)
GROUP BY 1
ORDER BY 1
```

### MySQL / PostgreSQL: Table

```sql
SELECT
  endpoint,
  count(*) AS total_requests,
  avg(response_time_ms) AS avg_ms,
  max(response_time_ms) AS max_ms
FROM requests
WHERE $__timeFilter(created_at)
GROUP BY endpoint
ORDER BY total_requests DESC
LIMIT 20
```

### MySQL: Multi-Series (metric column)

```sql
SELECT
  $__timeGroupAlias(created_at, $__interval),
  status_code AS metric,
  count(*) AS "value"
FROM requests
WHERE $__timeFilter(created_at)
GROUP BY 1, 2
ORDER BY 1
```

When using `format: "time_series"`, a string column named `metric` becomes the
series name.

### PostgreSQL: Using epoch timestamps

```sql
SELECT
  extract(epoch from created_at)::bigint AS time,
  count(*) AS value
FROM events
WHERE $__unixEpochFilter(extract(epoch from created_at)::bigint)
GROUP BY 1
ORDER BY 1
```

### ClickHouse: Time Series

```sql
SELECT
  $__timeInterval(timestamp) AS time,
  count() AS requests,
  quantile(0.99)(duration_ms) AS p99
FROM default.requests
WHERE $__timeFilter(timestamp)
GROUP BY time
ORDER BY time
```

### ClickHouse: Table with conditional variable

```sql
SELECT
  service_name,
  count() AS errors
FROM default.logs
WHERE level = 'error'
  AND $__timeFilter(timestamp)
  AND $__conditionalAll(service_name, $service)
GROUP BY service_name
ORDER BY errors DESC
LIMIT 50
```

### BigQuery: Time Series

```sql
SELECT
  TIMESTAMP_TRUNC(event_time, MINUTE) AS time,
  COUNT(*) AS events,
  COUNTIF(status = 'error') AS errors
FROM `project.dataset.events`
WHERE $__timeFilter(event_time)
GROUP BY 1
ORDER BY 1
```

---

## Example Queries via API

### MySQL: table query

```python
query_datasource(
    ds_uid="mysql-prod",
    ds_type="mysql",
    query_body={
        "rawSql": """
            SELECT endpoint, count(*) AS total, avg(response_ms) AS avg_ms
            FROM api_requests
            WHERE $__timeFilter(created_at)
            GROUP BY endpoint
            ORDER BY total DESC
            LIMIT 10
        """,
        "format": "table",
    },
    time_from="now-24h",
    time_to="now",
)
```

### PostgreSQL: time series

```python
query_datasource(
    ds_uid="postgres-analytics",
    ds_type="postgres",
    query_body={
        "rawSql": """
            SELECT
              $__timeGroupAlias(created_at, $__interval),
              count(*) AS "value"
            FROM events
            WHERE $__timeFilter(created_at)
            GROUP BY 1
            ORDER BY 1
        """,
        "format": "time_series",
    },
    time_from="now-7d",
    time_to="now",
)
```

### ClickHouse: aggregated query

```python
query_datasource(
    ds_uid="clickhouse-logs",
    ds_type="grafana-clickhouse-datasource",
    query_body={
        "rawSql": """
            SELECT
              $__timeInterval(timestamp) AS time,
              service_name,
              count() AS errors
            FROM logs
            WHERE level = 'error' AND $__timeFilter(timestamp)
            GROUP BY time, service_name
            ORDER BY time
        """,
        "format": "time_series",
    },
    time_from="now-6h",
    time_to="now",
)
```

---

## Dialect Differences Cheat Sheet

| Feature | MySQL | PostgreSQL | ClickHouse | BigQuery |
|---------|-------|------------|------------|----------|
| String concat | `CONCAT(a, b)` | `a \|\| b` | `concat(a, b)` | `CONCAT(a, b)` |
| Current time | `NOW()` | `NOW()` | `now()` | `CURRENT_TIMESTAMP()` |
| Date trunc | `DATE(col)` | `date_trunc('day', col)` | `toStartOfDay(col)` | `DATE_TRUNC(col, DAY)` |
| Epoch → time | `FROM_UNIXTIME(col)` | `to_timestamp(col)` | `toDateTime(col)` | `TIMESTAMP_SECONDS(col)` |
| Regex match | `col REGEXP 'pat'` | `col ~ 'pat'` | `match(col, 'pat')` | `REGEXP_CONTAINS(col, 'pat')` |
| Approximate count | N/A | N/A | `uniq(col)` | `APPROX_COUNT_DISTINCT(col)` |
| Quantile | N/A | `percentile_cont(0.99)` | `quantile(0.99)(col)` | `APPROX_QUANTILES(col, 100)[OFFSET(99)]` |
| Array support | JSON functions | native arrays | `Array(T)` | `ARRAY<T>` |

---

## Pitfalls

1. **`$__timeFilter` requires a datetime column.** If your column is epoch seconds, use `$__unixEpochFilter` instead.
2. **`format: "time_series"` needs specific column naming.** The first column must be time-like. A string column named `metric` is used as the series name. All other columns must be numeric.
3. **SQL injection: Grafana does NOT validate SQL.** The `rawSql` is sent as-is to the database. The database user configured in the datasource should have minimal permissions (SELECT only, restricted to specific schemas/tables).
4. **ClickHouse type string:** The official Grafana plugin uses `grafana-clickhouse-datasource`, not `clickhouse`. The community plugin (Altinity) uses `vertamedia-clickhouse-datasource`. Check your datasource config.
5. **BigQuery costs money per query.** BigQuery bills by bytes scanned. Always include time filters and avoid `SELECT *`. Use `$__timeFilter` to limit scan range.
6. **NULL handling differs across dialects.** ClickHouse does not have NULL by default (uses default values). Use `Nullable(T)` column types if you need NULLs.
7. **Macro expansion happens server-side.** You cannot test macros locally — they only expand when Grafana processes the query. For debugging, replace macros with hardcoded values first.
