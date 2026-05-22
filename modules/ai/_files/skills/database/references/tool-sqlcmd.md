# sqlcmd / go-sqlcmd (MS SQL Server)

Two implementations:
- **Classic `sqlcmd`** — Microsoft, .NET-based.
- **`go-sqlcmd`** — newer Go rewrite, leaner; **prefer in CI / agents**.

## Install

```bash
nix shell nixpkgs#go-sqlcmd
# Classic lives in mssql-tools (not directly in nixpkgs).
```

## Non-interactive patterns

```bash
# One-shot, batch mode, CSV-ish
sqlcmd -S server.example.com -d kfzif -U stefan -P "$MSSQL_PWD" \
       -b -h -1 -s "," -W \
       -Q "SET NOCOUNT ON; SELECT id, name FROM dbo.users"

# Entra / Azure AD (fits OIDC stacks)
sqlcmd -S server.database.windows.net -d kfzif \
       --authentication-method ActiveDirectoryDefault \
       -Q "SELECT @@VERSION"

# Run script
sqlcmd -S server -d kfzif -U stefan -P "$PWD" -b -i script.sql
```

## Flags

| Flag | Meaning |
|---|---|
| `-Q SQL` | One-shot, exit |
| `-q SQL` | One-shot, stay in REPL (**not for scripts**) |
| `-i FILE` | Script file |
| `-b` | **Required** — exit code reflects SQL errors |
| `-h -1` | No headers |
| `-s SEP` | Column separator |
| `-W` | Trim trailing spaces |
| `-o FILE` | Redirect output |
| `-y 0` | Variable column width (else silently truncated!) |

## Pitfalls

- **Without `-b` the exit code does not reflect SQL errors.** Mandatory in CI.
- **Without `-y 0` long values are silently truncated.** Data-loss trap.
- Prefix `SET NOCOUNT ON;` to silence "X rows affected".

## EXPLAIN equivalent

```bash
sqlcmd ... -Q "SET SHOWPLAN_XML ON; SELECT ...; SET SHOWPLAN_XML OFF;"
# Or:
sqlcmd ... -Q "SET STATISTICS PROFILE ON; SELECT ..."
```

## Read-only

No session-level read-only. Rely on DB-user permissions. `db.sh`
warns and proceeds; pass `--write` to silence.

## Docs

<https://github.com/microsoft/go-sqlcmd>
