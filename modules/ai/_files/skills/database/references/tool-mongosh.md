# mongosh (MongoDB)

Not SQL — JavaScript REPL over the Mongo wire protocol.

## Install

```bash
nix shell nixpkgs#mongosh
```

## Non-interactive patterns

```bash
# One-shot with JSON output
mongosh "mongodb://stefan@localhost/kfzif" --quiet \
        --eval 'JSON.stringify(db.users.find().limit(10).toArray())'

# Aggregation
mongosh "mongodb://localhost/kfzif" --quiet --eval '
  db.events.aggregate([
    { $match: { ts: { $gt: ISODate("2026-01-01") } } },
    { $group: { _id: "$type", count: { $sum: 1 } } }
  ]).toArray()
' | jq .

# Script
mongosh "mongodb://localhost/kfzif" --quiet --file analysis.js
```

## Data export

```bash
nix shell nixpkgs#mongodb-tools
mongoexport --uri="mongodb://localhost/kfzif" \
            --collection=users --type=json --out=users.json
```

## EXPLAIN

```js
db.users.find({ email: /^stefan/ }).explain("executionStats")
```

## Pitfall

`mongosh` writes banner + connection info to **stdout**, not stderr.
`--quiet` is mandatory for pipelines.

## Read-only

Mongo has no session-level read-only. `db.sh` **refuses** to invoke
mongosh without `--write`. Use a Mongo user with read-only role for
real enforcement.

## Docs

<https://www.mongodb.com/docs/mongodb-shell/>
