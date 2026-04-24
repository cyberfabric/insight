# HubSpot Connector

CDK-based Python connector for HubSpot CRM. Pulls data via CRM v3 Search API with v4 associations; property-discovery driven so custom HubSpot properties on any portal are captured without connector changes; properties where `hubspotDefined=false` are folded into a single `custom_fields` JSON column so Bronze stays stable across portals.

Architecture mirrors `crm/salesforce/` — envelope shape, concurrent cursor slicing, error-handler contract, dbt staging tags — so HubSpot and Salesforce unify cleanly in Silver.

## Prerequisites

1. In HubSpot: **Settings → Integrations → Private Apps → Create private app**.
2. Grant read scopes for each enabled object plus the matching property-schema scope (HubSpot has no wildcard — list scopes individually):
   - Objects: `crm.objects.contacts.read`, `crm.objects.companies.read`, `crm.objects.deals.read`, `crm.objects.leads.read`, `tickets`, `crm.objects.owners.read`
   - Property schemas: `crm.schemas.contacts.read`, `crm.schemas.companies.read`, `crm.schemas.deals.read`, `crm.schemas.leads.read`
   - Engagements (calls/emails/meetings/tasks) read is covered by the per-object CRM scopes.
3. Copy the access token — it begins with `pat-`.

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-hubspot-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: hubspot
    insight.cyberfabric.com/source-id: hubspot-main
type: Opaque
stringData:
  hubspot_access_token: ""                           # Private App token (pat-...)
  hubspot_start_date: "2024-01-01T00:00:00Z"         # Optional
  hubspot_num_workers: "20"                          # Optional (1–50)
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `hubspot_access_token` | Yes | Private App access token (sensitive) |
| `hubspot_start_date` | No | Incremental sync start (ISO 8601). Defaults to two years before current date |
| `hubspot_streams` | No | JSON array of stream names (e.g. `["contacts", "deals"]`). Overrides curated default |
| `hubspot_stream_slice_step` | No | Concurrent cursor window. Default `P30D`. Shrink to `PT1H` on very active portals to stay under the 10k search-result cap per slice |
| `hubspot_lookback_window` | No | Re-read window for `hs_lastmodifieddate` eventual consistency. Default `PT10M` |
| `hubspot_num_workers` | No | Max concurrent slice fetches (1–50). Default `20` |
| `hubspot_include_archived` | No | Fetch archived records alongside active. Default `true` |

### Automatically injected

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

### Multi-instance

Deploy additional Secrets with distinct `source-id` annotations to ingest multiple HubSpot portals as separate sources.

## Streams

Active by default: **10 streams** — 8 feed Silver (`class_crm_*`), 2 are bronze-only for parity with the Salesforce `Lead`/`Case` setup.

### Feeding Silver

| Stream | Silver target | Cursor | PK |
|---|---|---|---|
| `contacts` | `class_crm_contacts` | `updatedAt` (filtered on `hs_lastmodifieddate`) | `id` |
| `companies` | `class_crm_accounts` | `updatedAt` | `id` |
| `deals` | `class_crm_deals` | `updatedAt` | `id` |
| `engagements_calls` | `class_crm_activities` | `updatedAt` | `id` |
| `engagements_emails` | `class_crm_activities` | `updatedAt` | `id` |
| `engagements_meetings` | `class_crm_activities` | `updatedAt` | `id` |
| `engagements_tasks` | `class_crm_activities` | `updatedAt` | `id` |
| `owners` | `class_crm_users` | `updatedAt` | `id` |

### Bronze-only (v1)

| Stream | Notes |
|---|---|
| `leads` | HubSpot Leads object. No Silver staging model in v1 — awaiting a `class_crm_leads` Silver class |
| `tickets` | HubSpot service tickets. No Silver staging model in v1 — awaiting a `class_crm_tickets` Silver class |

## Robustness

### 10,000-result search cap
HubSpot's CRM Search endpoint caps at `after = 10,000`. The connector paginates by time slice first, then — if a slice still overflows — falls through to keyset pagination on `hs_object_id` within the same window. Logs show `switching to keyset pagination from id>...` when this kicks in.

### Rate limits
- Burst: 10 rps (standard portals), 100 rps (Enterprise). Controlled by `hubspot_num_workers`.
- Search endpoint: 4 rps portal-wide, no `Retry-After` header. Connector uses a 1.2s fallback on 429 for search requests, 3s elsewhere.
- Daily request limit: fails fast with a `transient_error` after 5 retries so orchestration can alert.

### Error surfacing
- `401` — Private App token invalid or revoked. Fail fast with config-error message.
- `403 MISSING_SCOPES` — fail with the missing scope list parroted back from HubSpot's response.
- `530` — Cloudflare origin-DNS; indicates a malformed token. Fail fast with token-format hint.
- `5xx`, chunked-encoding, connection resets — retried with exponential backoff.

### Deleted / archived records
`hubspot_include_archived=true` (default) runs a second pass per object with `archived=true` so soft-deleted records land in Bronze carrying `archived: true`. Silver models expose this through the `metadata` JSON column.

## Local development

```bash
cp src/ingestion/secrets/connectors/hubspot.yaml.example src/ingestion/secrets/connectors/hubspot.yaml
# fill in real values, then:
./src/ingestion/secrets/apply.sh
```

Build + test:

```bash
/connector build crm/hubspot
/connector test  crm/hubspot
/connector schema crm/hubspot
```

Run a sync:

```bash
./src/ingestion/run-sync.sh hubspot {tenant_id}
./src/ingestion/logs.sh hubspot {tenant_id}     # tail logs
```

## Troubleshooting

**Sync succeeds but Bronze counts are lower than expected on a busy portal.** Your slice step is too large and a time window crosses the 10k search cap. Shrink `hubspot_stream_slice_step` from `P30D` to `P7D` or `PT1H`. Logs show keyset-fallback activations.

**401 immediately after token rotation.** Private App tokens propagate eventually but HubSpot can cache the previous value at the edge for a minute or two. Wait and retry; if it persists, regenerate.

**`MISSING_SCOPES` on a stream the operator didn't realize needed scopes.** Property discovery requires `crm.schemas.{object}.read` for custom properties — granting only `crm.objects.{object}.read` returns standard fields but may still fail property lookup. Grant both.

**Silver `class_crm_users.email NOT NULL` test failing.** Deactivated HubSpot Owners can have null email. The staging model `hubspot__crm_users.sql` filters these out; if a null-email owner surfaces anyway, it's usually a test row created with an empty email field. Filter at source or relax the Silver test — see the plan notes.
