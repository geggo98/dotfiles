---
name: pr-bb
description: Fetches review comments for a given Bitbucket pull request
argument-hint: [issue-number]
allowed-tools:
    - "Bash(./scripts/bitbucket_pr_comments.sh)"
    - "Bash(bash ./scripts/bitbucket_pr_comments.sh)"
---

# Bitbucket Pull Request Skill

## 1. Purpose

Use this skill to fetch and review comments from Bitbucket pull requests.
It retrieves all comments from a PR or fetches a specific comment by ID for detailed analysis.

## 2. Usage Scenarios

Run before:

- Reviewing PR comments to address feedback.
- Analyzing discussion patterns in a pull request.
- Extracting specific comment details for documentation.
- Understanding inline vs. general comments on a PR.

## 3. Helper Scripts

| Script                                | Purpose                              | Arguments                     |
| ------------------------------------- | ------------------------------------ | ----------------------------- |
| `scripts/bitbucket_pr_comments.sh`    | Fetch Bitbucket PR comments          | `list` or `get`               |

### Arguments

- **Required:** PR ID (pull request identifier)
- **For `get` mode:** Comment ID (specific comment identifier)
- **Modes:**
  - `list` - Get all comments for a PR (default)
  - `get` - Get one specific comment by ID

## 4. Examples

### List All Comments

```bash
bitbucket_pr_comments.sh list 12345
```

Returns all comments with ID, content, and inline status for PR #12345.

### Get Specific Comment

```bash
bitbucket_pr_comments.sh get 12345 67890
```

Returns detailed content for comment ID 67890 on PR #12345.

### Pipe to jq for Custom Filtering

```bash
bitbucket_pr_comments.sh list 12345 | jq 'map(select(.inline == true))'
```

Filter to show only inline comments.

## 5. Output Format

### List Mode (JSON array)

```json
[
  {
    "id": "67890",
    "content": "Please review this change.",
    "inline": false
  },
  {
    "id": "67891",
    "content": "Consider using async/await here.",
    "inline": true
  }
]
```

### Get Mode (Raw content)

Returns the raw markdown content of the specified comment.

## 6. Exit Codes

| Code | Meaning                     |
| ---- | --------------------------- |
| 0    | Success                     |
| 1    | Invalid arguments           |
| 2    | Bitbucket CLI not found     |
| 3    | API or network failure      |
| 4    | PR or comment not found     |

## 7. Environment Variables

| Variable        | Description                       |
| --------------- | --------------------------------- |
| `BITBUCKET_CLI` | Path to `bb` CLI (default: `bb`)  |
| `JQ_PATH`       | Path to `jq` (default: `jq`)      |

## 8. Troubleshooting

| Problem                          | Possible Cause                      | Fix                              |
| -------------------------------- | ----------------------------------- | -------------------------------- |
| `bb: command not found`          | Bitbucket CLI not installed         | Install Atlassian CLI            |
| `jq: command not found`          | jq not installed                    | Install via brew/apt             |
| `Error: Invalid PR ID`           | Non-numeric PR ID provided          | Use numeric PR ID only           |
| `Error: Invalid comment ID`      | Non-numeric comment ID for get mode | Use numeric comment ID only      |
| Empty output                     | No comments on PR                   | Verify PR has comments           |

## 9. Prerequisites

- **Bitbucket CLI** (`bb`) installed and authenticated
- **jq** for JSON parsing
- **Access** to the target Bitbucket repository
