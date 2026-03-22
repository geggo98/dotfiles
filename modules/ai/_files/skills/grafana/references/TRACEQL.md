# TraceQL Reference for Grafana Datasource Queries

## Query Object Format

Tempo supports multiple query types. The `queryType` field determines which
one is used.

### Trace search (TraceQL)

```json
{
  "refId": "A",
  "datasource": { "uid": "<UID>", "type": "tempo" },
  "queryType": "traceqlSearch",
  "query": "<TRACEQL_EXPRESSION>",
  "limit": 20,
  "maxDataPoints": 1000,
  "intervalMs": 15000,
  "tableType": "traces"
}
```

### Trace by ID

```json
{
  "refId": "A",
  "datasource": { "uid": "<UID>", "type": "tempo" },
  "queryType": "traceql",
  "query": "<TRACE_ID>",
  "tableType": "traces"
}
```

### Service map

```json
{
  "refId": "A",
  "datasource": { "uid": "<UID>", "type": "tempo" },
  "queryType": "serviceMap"
}
```

### Field Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `query` | string | *required* | TraceQL expression or trace ID |
| `queryType` | string | `"traceqlSearch"` | `"traceqlSearch"`, `"traceql"`, `"serviceMap"` |
| `limit` | int | `20` | Max number of traces to return |
| `tableType` | string | `"traces"` | `"traces"` or `"spans"` |
| `minDuration` | string | | Filter: minimum trace duration (e.g. `"100ms"`) |
| `maxDuration` | string | | Filter: maximum trace duration |
| `filters` | array | | Structured filters (alternative to raw TraceQL) |

---

## TraceQL Quick Reference

TraceQL selects traces by matching span attributes.

### Basic Selectors

```traceql
# Match spans by resource attribute
{ resource.service.name = "api-server" }

# Match by span attribute
{ span.http.method = "GET" }

# Match by status
{ status = error }

# Match by span name
{ name = "HTTP GET" }

# Match by duration
{ duration > 500ms }

# Match by span kind
{ kind = server }
```

### Attribute Scopes

| Scope | Syntax | Description |
|-------|--------|-------------|
| Resource | `resource.key` | Resource-level attributes (service.name, k8s.namespace, etc.) |
| Span | `span.key` | Span-level attributes (http.method, http.status_code, etc.) |
| Unscoped | `.key` or `key` | Searches both resource and span attributes |

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Equals | `{ span.http.status_code = 200 }` |
| `!=` | Not equals | `{ status != ok }` |
| `>`, `>=`, `<`, `<=` | Numeric comparison | `{ duration > 1s }` |
| `=~` | Regex match | `{ resource.service.name =~ "api-.*" }` |
| `!~` | Regex not match | `{ name !~ "health.*" }` |

### Combining Conditions

**AND within a span (same span must match all):**
```traceql
{ span.http.method = "POST" && span.http.status_code >= 400 }
```

**OR within a span:**
```traceql
{ span.http.status_code = 500 || span.http.status_code = 503 }
```

**Span pipeline (AND across different spans in the same trace):**
```traceql
{ resource.service.name = "frontend" } >> { resource.service.name = "backend" && status = error }
```

### Structural Operators

| Operator | Description |
|----------|-------------|
| `>>` | Descendant (A is an ancestor of B) |
| `>` | Direct child (A is the parent of B) |
| `<<` | Ancestor (A is a descendant of B) |
| `<` | Direct parent (A is a child of B) |
| `~` | Sibling (A and B share a parent) |
| `!>>`, `!>`, etc. | Negated structural operators |

```traceql
# Find traces where frontend calls backend and backend errors
{ resource.service.name = "frontend" } >> { resource.service.name = "backend" && status = error }

# Find traces where a parent span is slow
{ duration > 2s } > { status = error }
```

### Aggregate Functions (Metrics from Traces)

TraceQL supports metric queries using aggregate functions:

```traceql
# Count of traces with errors
{ status = error } | count()

# Average duration of matching spans
{ resource.service.name = "api" } | avg(duration)

# P99 duration
{ resource.service.name = "api" } | quantile_over_time(duration, 0.99)

# Rate of requests
{ resource.service.name = "api" } | rate()
```

---

## Example Queries via API

### Search for error traces

```python
query_datasource(
    ds_uid="tempo-1",
    ds_type="tempo",
    query_body={
        "queryType": "traceqlSearch",
        "query": '{ resource.service.name = "api-server" && status = error }',
        "limit": 20,
        "tableType": "traces",
    },
    time_from="now-1h",
    time_to="now",
)
```

### Fetch a specific trace

```python
query_datasource(
    ds_uid="tempo-1",
    ds_type="tempo",
    query_body={
        "queryType": "traceql",
        "query": "abc123def456789",  # trace ID
        "tableType": "traces",
    },
    time_from="now-24h",
    time_to="now",
)
```

### Slow requests with structural matching

```python
query_datasource(
    ds_uid="tempo-1",
    ds_type="tempo",
    query_body={
        "queryType": "traceqlSearch",
        "query": '{ resource.service.name = "frontend" } >> { duration > 2s && status = error }',
        "limit": 10,
        "tableType": "spans",
        "minDuration": "1s",
    },
    time_from="now-6h",
    time_to="now",
)
```

---

## Response Format

Trace search returns frames with columns like:

| Column | Description |
|--------|-------------|
| `traceID` | Full trace ID (hex string) |
| `spanID` | Span ID |
| `rootServiceName` | Service name of the root span |
| `rootTraceName` | Name of the root span |
| `startTimeUnixNano` | Trace start time |
| `durationMs` | Total trace duration in ms |

To get the full trace detail, take the `traceID` value and run a
`queryType: "traceql"` query with that ID.

---

## Pitfalls

1. **Tempo needs time range.** Even when fetching by trace ID, provide a reasonable `from`/`to` range that encompasses when the trace was generated. Tempo partitions data by time.
2. **Attribute names vary.** OpenTelemetry semantic conventions use `http.request.method` (new) vs `http.method` (old). Check which your instrumentation uses.
3. **`status` values:** `ok`, `error`, `unset`. These are OpenTelemetry status codes, not HTTP status codes.
4. **Structural queries are expensive.** `>>` and `>` require Tempo to load full trace trees. Use them with specific selectors, not broad ones.
5. **Span vs Trace results:** `tableType: "traces"` returns one row per trace. `tableType: "spans"` returns one row per matching span.
