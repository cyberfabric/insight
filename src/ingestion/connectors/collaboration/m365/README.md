# M365 Connector

Microsoft 365 activity reports (email, Teams, OneDrive, SharePoint).

## Prerequisites

1. Create an App Registration in Azure AD
2. Grant application permissions (all type **Application**, not Delegated; admin consent required):

   | Scope | Used by | Required for |
   |-------|---------|--------------|
   | `Reports.Read.All` | `email_activity`, `teams_activity`, `onedrive_activity`, `sharepoint_activity` | All daily activity reports |
   | `User.Read.All` | `users` (parent stream for `calendar_events`) | Enumerating mailboxes to slice calendar by |
   | `Calendars.Read` | `calendar_events` | Reading per-user calendar invites — required for the `class_meeting_invite` silver class. **New scope; existing deployments need re-consent.** |

3. Create a client secret

> **Migration note for existing deployments:** the `Calendars.Read` scope is new in this version. Until tenant admin grants consent, the `calendar_events` stream will fail with `Authorization_RequestDenied` and `class_meeting_invite` will be empty. Other streams continue to work.

## K8s Secret

Create a Kubernetes Secret with the connector credentials:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-m365-main                          # convention: insight-{connector}-{source-id}
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: m365          # must match descriptor.yaml name
    insight.cyberfabric.com/source-id: main          # passed as insight_source_id
type: Opaque
stringData:
  azure_tenant_id: ""       # Azure AD tenant ID
  azure_client_id: ""       # App registration client ID
  azure_client_secret: ""   # App registration client secret
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `azure_tenant_id` | Yes | Azure AD tenant ID |
| `azure_client_id` | Yes | App registration client ID |
| `azure_client_secret` | Yes | App registration client secret (sensitive) |

### Automatically injected

These fields are set by `airbyte-toolkit/connect.sh` and should NOT be in the Secret:

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

All connector parameters are in the K8s Secret. Tenant YAML contains only `tenant_id`.

## Multi-Instance

To sync multiple Azure AD tenants, create separate Secrets with different `source-id` annotations:

```yaml
# Secret 1: insight-m365-main
annotations:
  insight.cyberfabric.com/source-id: main

# Secret 2: insight-m365-emea
annotations:
  insight.cyberfabric.com/source-id: emea
```
