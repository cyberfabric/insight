# Cursor Connector

Team member roster, audit logs, usage events, and daily usage from Cursor via API Key authentication.

## Prerequisites

1. Log in to the Cursor dashboard as a team admin
2. Go to **Settings > API** and generate or copy the team API key

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-cursor-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: cursor
    insight.cyberfabric.com/source-id: cursor-main
type: Opaque
stringData:
  api_key: ""                           # Cursor team API key
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `api_key` | Yes | Cursor team API key (Settings > API) |

### Automatically injected

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

### Local development

Create `src/ingestion/secrets/connectors/cursor.yaml` (gitignored) from the example:

```bash
cp src/ingestion/secrets/connectors/cursor.yaml.example src/ingestion/secrets/connectors/cursor.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/cursor.yaml
```

## Streams

| Stream | Description | Sync Mode |
|--------|-------------|-----------|
| `cursor_members` | Team member roster (email, name, role) | Full refresh |
| `cursor_audit_logs` | Audit events (user actions) | Incremental |
| `cursor_usage_events` | Per-request usage events (hourly) | Incremental |
| `cursor_usage_events_daily_resync` | Per-request usage events (daily resync, finalized costs) | Incremental |
| `cursor_daily_usage` | Aggregated daily usage per user | Incremental |

## Silver Targets

- `class_ai_dev_usage` -- unified AI developer tool usage
