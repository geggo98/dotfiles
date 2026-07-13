# Authentication, token cache & secrets

## Login flow
Email/password login (reverse-engineered from the app):
```
POST {base}/api/v3/auth.json
Content-Type: application/json
{ "email": "<username>", "password": "<password>" }
```
Response: `{ "token": "<X-Token>", "type": ..., ... }`. The `token` value is what the app sends as the
`X-Token` header on every subsequent request. There is **no** CSRF token, HMAC, request signing, or
app secret — a plain bearer token over HTTPS.

The client sends these headers on every request (mirrors the app, but honest UA):
| Header | Value |
|---|---|
| `X-Token` | the login token (empty for pre-auth calls) |
| `Accept` | `application/json; api_version=10` (required — server negotiates API version here) |
| `X-Capabilities` | `direct-upload` |
| `X-Device` | a stable random UUID generated once and cached at `~/.local/state/bookfusion-api-skill/device-id` |
| `User-Agent` | `bookfusion-api-skill/<ver> (Claude Code Skill; …)` — identifies this skill |
| `X-Client` | `bookfusion-api` |

## Token cache
On `login` (or auto-login), the token is cached at
`${XDG_STATE_HOME:-~/.local/state}/bookfusion-api-skill/token-<sha256(baseUrl|user)>.json` with mode
`0600`, so subsequent calls do not re-login. Commands other than the `auth*` ones auto-login when no
token is cached. `BOOKFUSION_TOKEN` overrides the cache. `bookfusion login` forces a refresh;
`bookfusion logout` clears all cached tokens. The token is never printed.

## Credential resolution (first non-empty wins; values never printed — only the *source* is logged)

| Credential | Order |
|---|---|
| **username** | `--username-file PATH` → `$BOOKFUSION_USERNAME` → `$BOOKFUSION_USERNAME_FILE` → `~/.config/sops-nix/secrets/bookfusion_username` → `--username` (inline; warns) |
| **password** | `--password-file PATH` → `$BOOKFUSION_PASSWORD` → `$BOOKFUSION_PASSWORD_FILE` → `~/.config/sops-nix/secrets/bookfusion_password` → `--password` (inline; warns) |
| **token** | `$BOOKFUSION_TOKEN` → `--token-file PATH` → `$BOOKFUSION_TOKEN_FILE` → on-disk token cache (else auto-login) |

Never paste passwords inline in a shared shell; prefer env, a `0600` file, or sops-nix.

## Secrets never reach the context
Credentials are write-only from the agent's point of view: the client resolves them, uses them, and
never prints them. Any *response* that carries a credential (e.g. an auth `token`, `getTtsCredentials`)
is written to a `0600` temp file (full value on disk) and only a **redacted** preview + the file path are
surfaced — sensitive keys print as `***REDACTED***`. If an `auth*` command returns a token, it is cached
and stripped from output automatically.

## Using sops-nix on this machine
sops-nix decrypts each declared secret to an individual **plaintext file** under
`~/.config/sops-nix/secrets/` at activation time; a tool simply reads that file path. No
`bookfusion_*` secret is declared yet. To add them, in your nix-darwin config
(`~/.config/nix-darwin/modules/secrets.nix`), add the keys to the encrypted source and declare:
```nix
sops.secrets.bookfusion_username = { };
sops.secrets.bookfusion_password = { };
```
After `darwin-rebuild switch`, they appear at `~/.config/sops-nix/secrets/bookfusion_username` and
`…/bookfusion_password`, and the client picks them up automatically (step 4 above). Until then, use
`BOOKFUSION_USERNAME` / `BOOKFUSION_PASSWORD` or `--username-file` / `--password-file`.

## Example
```
# via env (not persisted)
BOOKFUSION_USERNAME='me@example.com' BOOKFUSION_PASSWORD='…' \
  bookfusion login

# thereafter, token is cached:
bookfusion searchUserBooks --data '{"query":"rust","per_page":10}' --pretty
```
