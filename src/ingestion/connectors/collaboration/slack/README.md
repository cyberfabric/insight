# Slack Connector

Slack workspace data: users, channels, and message activity via Bot Token.

## Prerequisites

### Creating a Bot Token

1. Go to https://api.slack.com/apps and click **Create New App** -> **From scratch**
2. Enter app name (e.g. `Insight`) and select your workspace
3. In the left sidebar, go to **OAuth & Permissions**
4. Scroll to **Bot Token Scopes** and add the following scopes:
   - `channels:history`, `channels:read`
   - `groups:history`, `groups:read`
   - `im:history`, `im:read`
   - `mpim:history`, `mpim:read`
   - `users:read`, `users:read.email`
5. Scroll up and click **Install to Workspace** -> **Allow**
6. Copy the **Bot User OAuth Token** (`xoxb-...`) from the OAuth & Permissions page

## Streams

| Stream | Sync Mode | Primary Key | Description |
|--------|-----------|-------------|-------------|
| `users` | Full Refresh | `unique_key` | Slack user directory (id, email, display name, role flags) |
| `channels` | Full Refresh | `unique_key` | Channel directory with type classification |
| `messages` | Incremental (cursor: `ts`) | `unique_key` | Messages partitioned by channel, daily slices |

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-slack-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: slack
    insight.cyberfabric.com/source-id: slack-main
type: Opaque
stringData:
  slack_bot_token: "xoxb-..."       # Bot User OAuth Token
  slack_start_date: "2026-01-01"    # Earliest date for message sync (YYYY-MM-DD)
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `slack_bot_token` | Yes | Bot User OAuth Token (`xoxb-*`) with scopes listed above |
| `slack_start_date` | Yes | Earliest date for incremental message sync (YYYY-MM-DD) |

### Optional fields

| Field | Default | Description |
|-------|---------|-------------|
| `slack_page_size` | `200` | Records per API page (1-999) |
| `slack_lookback_days` | `7` | Days to re-scan on incremental sync |
| `slack_channel_types` | `public_channel,private_channel,mpim,im` | Channel types to scan |

### Automatically injected

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

### Multi-instance example

To connect multiple Slack workspaces, create separate Secrets with different `source-id`:

```yaml
# Workspace 1
metadata:
  name: insight-slack-acme
  annotations:
    insight.cyberfabric.com/source-id: slack-acme

# Workspace 2
metadata:
  name: insight-slack-partner
  annotations:
    insight.cyberfabric.com/source-id: slack-partner
```
