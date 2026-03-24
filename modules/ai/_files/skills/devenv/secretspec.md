# SecretSpec Reference

SecretSpec separates secret **declaration** from secret **provisioning**.
You commit a `secretspec.toml` that declares what secrets your application needs,
while actual values live in a secure provider.

Documentation:
- Overview: https://secretspec.dev/
- Quick Start: https://secretspec.dev/quick-start/
- Concepts: https://secretspec.dev/concepts/overview/
- Providers Reference: https://secretspec.dev/reference/providers/
- CLI Reference: https://secretspec.dev/reference/cli/
- Devenv integration: https://devenv.sh/integrations/secretspec/

## secretspec.toml structure

```toml
[project]
name = "my-app"
revision = "1.0"

[profiles.default]
DATABASE_URL = { description = "PostgreSQL connection string", required = true }
REDIS_URL = { description = "Redis connection string", required = false }
TLS_CERT = { description = "TLS certificate", as_path = true }

[profiles.development]
# Inherits from default — only override what changes
DATABASE_URL = { default = "postgresql://localhost/myapp_dev" }
REDIS_URL = { default = "redis://localhost:6379" }

[profiles.production]
DATABASE_URL = { required = true }  # No default, must be provided
```

### Secret options

| Field | Type | Description |
|---|---|---|
| `description` | string | Human-readable description |
| `required` | bool | Whether the secret must be provided (default: true) |
| `default` | string | Default value (use only for development) |
| `as_path` | bool | Write value to temp file, expose path instead of value |
| `type` | string | Secret type for generation (e.g., "password") |
| `generate` | bool | Auto-generate if missing |
| `providers` | list | Per-secret provider override with fallback chain |

### Profile inheritance

Profiles inherit from `[profiles.default]`. You only override what changes per profile.

## Supported providers

| Provider | URI format | Features |
|---|---|---|
| **Keyring** | `keyring://` | System keychain (macOS Keychain, Windows Credential Manager, Linux Secret Service). Read/write, encrypted. |
| **Dotenv** | `dotenv://[path]` | `.env` files. `dotenv://` = default `.env`. Read/write, no encryption. |
| **Environment** | `env://` | Read-only, current process environment variables. No setup needed. |
| **Pass** | `pass://` | Unix password manager with GPG. Read/write, encrypted. |
| **1Password** | `onepassword://[account@]vault` | Cloud sync, read/write. `onepassword+token://user:token@vault` for service accounts. |
| **LastPass** | `lastpass://[folder]` | Cloud sync, read/write. Requires `lpass` CLI. |
| **Google Cloud SM** | `gcsm://PROJECT_ID` | GCP Secret Manager. Read/write. Requires `gcloud` CLI. |
| **AWS Secrets Manager** | `awssm://[profile@]REGION` | AWS managed secrets. Read/write. |
| **Vault / OpenBao** | `vault://[mount/path]` | HashiCorp Vault or OpenBao. Read/write. |

### Per-secret provider overrides

```toml
[profiles.production.defaults]
providers = ["vault", "keyring"]  # Default for all secrets

[profiles.production]
DATABASE_URL = { description = "Production DB" }       # Uses profile defaults
API_KEY = { description = "API key", providers = ["env"] }  # Override: env only
```

Provider aliases are configured in `~/.config/secretspec/config.toml`:
```bash
secretspec config provider add vault "onepassword://Production"
```

## CLI commands

```bash
secretspec init                        # Create secretspec.toml
secretspec init --from dotenv          # Import from existing .env
secretspec check                       # Verify all secrets available
secretspec set <SECRET_NAME>           # Set a secret value
secretspec run -- <command>            # Run command with secrets injected
secretspec run --profile production -- npm start
secretspec run --provider env -- npm test
secretspec import dotenv://.env.prod   # Import secrets between providers
secretspec config init                 # Interactive provider setup
```

## Devenv integration

### Via devenv.yaml (recommended)

```yaml
# devenv.yaml
secretspec:
  enable: true
  # provider: keyring://         # optional override
  # profile: development         # optional override
```

### Via CLI flags (devenv 2.0+)

```bash
devenv --secretspec-provider "dotenv://.env" shell
devenv --secretspec-profile production test
```

### Best practice: Runtime loading

The devenv docs recommend loading secrets at runtime in your application
rather than baking them into the devenv shell environment:

- Use the Rust SDK: https://secretspec.dev/sdk/rust/
- Or use `secretspec run -- <command>` to inject secrets only when running

This avoids secrets appearing in environment variable listings or shell history.

## Auto-generation

Secrets with `type` and `generate` are automatically created when missing:

```toml
DB_PASSWORD = { description = "Database password", type = "password", generate = true }
SESSION_KEY = { description = "Session signing key", type = "hex", generate = true }
```
