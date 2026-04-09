# Claude API Connector

API usage reports, cost reports, API keys, workspaces, and invites from the Anthropic Admin API.

## Prerequisites

1. Log in to the Anthropic Console as an organization admin
2. Go to **Settings > Admin API Keys** and generate a new admin API key
3. The key must have organization-level read permissions

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-claude-api-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: claude-api
    insight.cyberfabric.com/source-id: claude-api-main
type: Opaque
stringData:
  admin_api_key: ""                     # Anthropic Admin API key
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `admin_api_key` | Yes | Anthropic Admin API key (Console > Settings > Admin API Keys) |

### Automatically injected

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

### Local development

Create `src/ingestion/secrets/connectors/claude-api.yaml` (gitignored) from the example:

```bash
cp src/ingestion/secrets/connectors/claude-api.yaml.example src/ingestion/secrets/connectors/claude-api.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/claude-api.yaml
```

## Streams

| Stream | Description | Sync Mode |
|--------|-------------|-----------|
| `claude_api_messages_usage` | Token usage per model/key/workspace/day | Incremental |
| `claude_api_cost_report` | Cost breakdown per workspace/day | Incremental |
| `claude_api_keys` | Organization API keys | Full refresh |
| `claude_api_workspaces` | Organization workspaces | Full refresh |
| `claude_api_invites` | Pending invitations | Full refresh |

## Silver Targets

- `class_ai_api_usage` -- unified AI API usage metrics
