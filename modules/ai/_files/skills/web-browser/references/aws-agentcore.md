# AWS Bedrock AgentCore — Reference

This is the deep reference for the `--aws-agent-core` flag on
`${CLAUDE_SKILL_DIR}/scripts/web-browser.sh`. The main `SKILL.md` covers the
quick-start; this file covers env vars, regions, persistent profiles, the live
view URL, troubleshooting, and pricing.

When `--aws-agent-core` is set, the wrapper:

1. Sources any of the env vars below from `~/.config/sops-nix/secrets/` (lowercase
   snake_case filename) **only if the var is not already set in the
   environment**. Missing secrets are silently ignored — `agent-browser` falls
   back to the AWS CLI / SSO / IAM-role chain.
2. Prepends `-p agentcore` to the `agent-browser` command.

## Credentials

Resolved automatically (in priority order):

1. Env vars: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optionally
   `AWS_SESSION_TOKEN`.
2. AWS CLI fallback (`aws configure export-credentials`), which supports SSO,
   IAM roles, and named profiles via `AWS_PROFILE`.

## Environment Variables

| Variable                    | Sops-nix file              | Description                                              | Default      |
|-----------------------------|----------------------------|----------------------------------------------------------|--------------|
| `AWS_ACCESS_KEY_ID`         | `aws_access_key_id`        | Access key                                               | (CLI fallback) |
| `AWS_SECRET_ACCESS_KEY`     | `aws_secret_access_key`    | Secret key                                               | (CLI fallback) |
| `AWS_SESSION_TOKEN`         | `aws_session_token`        | STS session token (optional)                             | —            |
| `AWS_PROFILE`               | `aws_profile`              | Named CLI profile                                        | `default`    |
| `AGENTCORE_REGION`          | `agentcore_region`         | AWS region                                               | `us-east-1`  |
| `AGENTCORE_BROWSER_ID`      | `agentcore_browser_id`     | Browser identifier                                       | `aws.browser.v1` |
| `AGENTCORE_PROFILE_ID`      | `agentcore_profile_id`     | Persistent browser profile (cookies, localStorage)       | (none)       |
| `AGENTCORE_SESSION_TIMEOUT` | `agentcore_session_timeout`| Session timeout in seconds                               | `3600`       |

## Persistent Profiles

Use `AGENTCORE_PROFILE_ID` to persist browser state across sessions — useful for
keeping login sessions alive:

```bash
# First run: log in
AGENTCORE_PROFILE_ID=my-app \
  ${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://app.example.com/login
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core snapshot -i
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core fill @e1 "user@example.com"
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core fill @e2 "password"
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core click @e3
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core close

# Future runs: already authenticated
AGENTCORE_PROFILE_ID=my-app \
  ${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://app.example.com/dashboard
```

## Live View

When a session starts, AgentCore prints a Live View URL to stderr. Open it in a
browser to watch the session in real time from the AWS Console:

```
Session: abc123-def456
Live View: https://us-east-1.console.aws.amazon.com/bedrock-agentcore/browser/aws.browser.v1/session/abc123-def456#
```

## Region Selection

```bash
# Default: us-east-1
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://example.com

# Explicit region
AGENTCORE_REGION=eu-west-1 \
  ${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://example.com
```

## Credential Patterns

```bash
# Explicit credentials (CI/CD, scripts)
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://example.com

# SSO (interactive)
aws sso login --profile my-profile
AWS_PROFILE=my-profile \
  ${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://example.com

# IAM role / default credential chain
${CLAUDE_SKILL_DIR}/scripts/web-browser.sh --aws-agent-core open https://example.com
```

## Using `AGENT_BROWSER_PROVIDER`

If you want every plain `agent-browser` invocation (outside this skill) to use
AgentCore, set the provider via env var instead of the flag:

```bash
export AGENT_BROWSER_PROVIDER=agentcore
export AGENTCORE_REGION=us-east-2

agent-browser open https://example.com
agent-browser snapshot -i
agent-browser click @e1
agent-browser close
```

Inside this skill, prefer `--aws-agent-core` — it is per-invocation and also
loads the secrets.

## Common Issues

**"Failed to run aws CLI"** — AWS CLI is not installed or not on PATH. Either
install it or set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` directly (in
the env or as sops-nix secrets).

**"AWS CLI failed: ... Run 'aws sso login'"** — SSO credentials have expired.
Run `aws sso login` to refresh.

**Session timeout** — default is 3600 seconds (1 hour). For longer tasks,
increase with `AGENTCORE_SESSION_TIMEOUT=7200` (or set the corresponding
sops-nix secret).

## Pricing

> **Always verify before quoting.** AWS pricing changes; the figures below are
> a snapshot from <https://aws.amazon.com/bedrock/agentcore/pricing/> at the
> time this skill was last updated. Re-fetch authoritative pricing before
> giving cost estimates to users (see "Verifying current prices" below).

AgentCore is billed on active consumption with per-second granularity (1-second
minimum, 128 MB minimum memory). Browser Tool charges share the same rate card
as Runtime and Code Interpreter:

| Component                  | Rate                                                                 |
|----------------------------|----------------------------------------------------------------------|
| Browser Tool — CPU         | $0.0895 / vCPU-hour                                                  |
| Browser Tool — Memory      | $0.00945 / GB-hour (128 MB min)                                      |
| Runtime                    | $0.0895 / vCPU-hour + $0.00945 / GB-hour                             |
| Code Interpreter           | $0.0895 / vCPU-hour + $0.00945 / GB-hour                             |
| Gateway — API invocations  | $0.005 per 1K                                                        |
| Gateway — Search           | $0.025 per 1K                                                        |
| Gateway — Tool indexing    | $0.02 per 100 tools / month                                          |
| Identity                   | $0.010 per 1,000 token or API-key requests (free via Runtime/Gateway)|
| Memory — Short-term        | $0.25 per 1K events                                                  |
| Memory — Long-term store   | $0.75 per 1K records                                                 |
| Memory — Retrieval         | $0.50 per 1K retrievals                                              |
| Policy — Authorization     | $0.000025 per request                                                |
| Policy — Authoring         | $0.13 per 1K input tokens                                            |
| Evaluations — Built-in     | $0.0024 per 1K input tokens / $0.012 per 1K output tokens            |
| Evaluations — Custom       | $1.50 per 1K evaluations                                             |
| AWS Agent Registry         | Records $0.400 per 1K (5K free); Search $0.020 per 1K (1M free); List/Get $0.004 per 1K (2M free) |
| Observability              | CloudWatch standard rates apply                                      |

### Verifying current prices

Before quoting prices, re-fetch them through one of:

- **AWS CLI** (the Pricing API itself is regional — only `us-east-1`,
  `eu-central-1`, `ap-south-1`, regardless of which region you're billing in):
  ```bash
  aws pricing list-price-lists \
    --service-code AmazonBedrock \
    --effective-date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --currency-code USD \
    --region us-east-1
  ```
  See <https://docs.aws.amazon.com/cli/latest/reference/pricing/list-price-lists.html>.

- **AWS Pricing MCP server** (preferred for ad-hoc agent queries — no shell
  required). Add to your MCP config:
  ```json
  {
    "mcpServers": {
      "awslabs.aws-pricing-mcp-server": {
        "command": "uvx",
        "args": ["awslabs.aws-pricing-mcp-server@latest"],
        "env": { "FASTMCP_LOG_LEVEL": "ERROR" },
        "autoApprove": [],
        "disabled": false
      }
    }
  }
  ```
