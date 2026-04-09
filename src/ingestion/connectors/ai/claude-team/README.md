# Claude Team Connector

Team users, Claude Code usage, workspaces, workspace members, and invites from the Anthropic Admin API.

## Prerequisites

1. Log in to the Anthropic Console as a team/enterprise admin
2. Go to **Settings > Admin API Keys** and generate a new admin API key
3. The key must have organization-level read permissions

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-claude-team-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: claude-team
    insight.cyberfabric.com/source-id: claude-team-main
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

Create `src/ingestion/secrets/connectors/claude-team.yaml` (gitignored) from the example:

```bash
cp src/ingestion/secrets/connectors/claude-team.yaml.example src/ingestion/secrets/connectors/claude-team.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/claude-team.yaml
```

## Streams

| Stream | Description | Sync Mode |
|--------|-------------|-----------|
| `claude_team_users` | Team seat roster (email, name, role) | Full refresh |
| `claude_team_code_usage` | Daily Claude Code usage per user | Incremental |
| `claude_team_workspaces` | Workspace structure | Full refresh |
| `claude_team_workspace_members` | Per-workspace membership | Full refresh |
| `claude_team_invites` | Pending invitations | Full refresh |

## Migration

**From `tenant_id` to `insight_tenant_id` spec (PR #142):**

The connector spec changed `tenant_id` → `insight_tenant_id` and added `insight_source_id` as required. After merging:

1. Ensure K8s Secret exists with `insight.cyberfabric.com/source-id` annotation
2. Run `register.sh` (or `upload-manifests.sh`) to update the Airbyte definition
3. Run `connect.sh` (or `apply-connections.sh`) to update existing source configs — this auto-injects `insight_tenant_id` and `insight_source_id` from tenant YAML and Secret annotation

Without step 3, existing Airbyte sources will fail validation on next sync.

## Silver Targets

- `class_ai_dev_usage` -- unified AI developer tool usage (from Claude Code)
- `class_ai_tool_usage` -- Claude conversational usage (planned)
