# Output formats for agent consumption

**Rule of thumb:** JSON Lines (NDJSON) for streaming, plain JSON for
complete small result sets, CSV only when a downstream tool demands it.

| Format | When | Trade-offs |
|---|---|---|
| **JSON array** | Small result sets (<10k rows) | Easy to parse; must load whole thing |
| **JSON Lines** | Streaming, large sets | Line-by-line processable; no container |
| **CSV** | Excel / Pandas / Spreadsheet sink | NULL handling unclear; escaping fragile |
| **TSV** | `awk` / `cut` pipelines | No quoting — tabs in data break everything |
| **Parquet** | Bulk export for analytics | Columnar, compressed; not all tools accept |
| **Markdown** | Sometimes LLM-friendly | Token-efficient for small tables; escaping pain |

## Producing JSON Lines

```bash
# DuckDB
duckdb -c "COPY (SELECT ...) TO '/dev/stdout' (FORMAT JSON, ARRAY false)"

# psql
psql -X -A -t -c "SELECT row_to_json(t) FROM (SELECT ...) t"

# sqlite3
sqlite3 db -cmd ".mode jsonl" "SELECT ..."
```

## NULL handling

| Tool | Default | Recommendation |
|---|---|---|
| psql | empty string | `-P null=NULL` or `--csv` (handles it correctly) |
| mysql -B | text `NULL` | conflicts with string `"NULL"` — beware |
| sqlite3 csv | empty | `.nullvalue NULL` |
| usql CSV | empty | configurable via `\pset null` |

## Choosing for `db.sh --format`

| Flag | Maps to |
|---|---|
| `--format json` | Tool-specific JSON where available; SQL `json_agg` wrapping for psql |
| `--format csv` | `--csv` / `-csv` / `-s ','` per dialect |
| `--format tsv` | `-F $'\t'` / `-tsv` / `-s $'\t'` per dialect |
| `--format native` | Tool default (`-B` TSV for mysql, table for psql, …) |
