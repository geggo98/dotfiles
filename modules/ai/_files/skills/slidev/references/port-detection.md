# Port Detection

## How Slidev Determines the Port

In `packages/slidev/node/cli.ts` (lines 132–137), the dev server picks a port like this:

```ts
port = userPort || await getPort({
  port: 3030,
  random: false,
  portRange: [3030, 4000],
  host,
})
```

- If `--port` / `-p` is given, that exact port is used (`userPort`).
- Otherwise, `getPort()` finds the first free port in the range **3030–4000**.

This means without `--port`, the actual port is non-deterministic and depends on what else is running.

## Best Practice

**Always pass `--port` explicitly** to avoid guessing:

```bash
slidev dev --port 3030
# or via bun:
bun run dev -- --port 3030
```

## Finding the Port After the Fact

### 1. Port scan script (recommended)

Run `./scripts/find-slidev-port.sh` — it curls ports 3030–4000 and looks for the `slidev` marker in the HTML response (`<meta name="slidev:version">`).

### 2. Check listening Node processes

```bash
lsof -i -P | grep node | grep LISTEN
```

This shows all ports any Node process is listening on.

### 3. VS Code Extension approach

The official Slidev VS Code extension (`packages/vscode/src/composables/useServerDetector.ts`) uses the same strategy: it polls `http://localhost:<port>` for ports 3030–4000 via HTTP and checks for the `slidev` marker in the HTML response.
