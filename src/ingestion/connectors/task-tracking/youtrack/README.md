# YouTrack Connector

Extracts projects, users, agiles+sprints, issue link types, issues, activities (changelog), comments, worklogs, and per-project custom field definitions from YouTrack (Cloud or self-hosted) REST API. Declarative Airbyte manifest — no custom code. Field-history replay is produced downstream by the Rust `youtrack-enrich` binary (separate feature, see `docs/components/connectors/task-tracking/youtrack/specs/DECOMPOSITION.md`).

## Specification

- **PRD**: [../../../../../docs/components/connectors/task-tracking/youtrack/specs/PRD.md](../../../../../docs/components/connectors/task-tracking/youtrack/specs/PRD.md) *(planned)*
- **DESIGN**: [../../../../../docs/components/connectors/task-tracking/youtrack/specs/DESIGN.md](../../../../../docs/components/connectors/task-tracking/youtrack/specs/DESIGN.md) *(planned)*
- **DECOMPOSITION**: [../../../../../docs/components/connectors/task-tracking/youtrack/specs/DECOMPOSITION.md](../../../../../docs/components/connectors/task-tracking/youtrack/specs/DECOMPOSITION.md)

## Prerequisites

1. Create a permanent token in YouTrack: Profile → Account Security → Tokens → New token.
2. The token's service account must have **Read Issues** on every project to ingest plus **Read Project** for the admin endpoints (`/api/admin/projects`, `/api/admin/projects/{id}/customFields`).
3. No project whitelist is required — the connector ingests everything the token can reach.

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-youtrack-main
  namespace: data
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: youtrack
    insight.cyberfabric.com/source-id: youtrack-main
type: Opaque
stringData:
  youtrack_base_url: "https://myorg.youtrack.cloud"
  youtrack_token: "CHANGE_ME"
  # youtrack_start_date: "2024-01-01"          # optional, default 2020-01-01
  # youtrack_page_size: "100"                  # optional, default 100
  # youtrack_activities_page_size: "200"       # optional, default 200
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `youtrack_base_url` | Yes | YouTrack URL, no trailing slash (e.g. `https://myorg.youtrack.cloud` or `https://youtrack.myorg.local`) |
| `youtrack_token` | Yes | YouTrack permanent token. Marked `airbyte_secret: true` — never logged |
| `youtrack_start_date` | No | Earliest issue `updated` timestamp (`YYYY-MM-DD`). Default `2020-01-01` |
| `youtrack_page_size` | No | Issue search `$top` size, 1-500. Default `100` |
| `youtrack_activities_page_size` | No | activitiesPage `$top` size, 1-500. Default `200` |

> No `youtrack_project_short_names` field — the connector ingests every project the token can reach. See DECOMPOSITION §2 decomposition strategy "No-whitelist scope".

### Automatically injected

These fields are added to every record by the connector — do **not** put them in the K8s Secret:

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML (`connections/<tenant>.yaml`) |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation on the K8s Secret |
| `tenant_id` / `source_id` | Mirrored onto every Bronze row |
| `unique_key` | Composite PK — varies per stream |
| `collected_at` | UTC ISO-8601 timestamp at extraction time |

### Local development

```bash
cp src/ingestion/secrets/connectors/youtrack.yaml.example src/ingestion/secrets/connectors/youtrack.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/youtrack.yaml
```

## Streams

| Stream | Endpoint | Sync Mode | Cursor | Pagination | Feature |
|--------|----------|-----------|--------|------------|---------|
| `youtrack_projects` | `GET /api/admin/projects` | Full refresh | — | Offset (`$skip/$top`) | 2.2 |
| `youtrack_user` | `GET /api/users` | Full refresh | — | Offset | 2.2 |
| `youtrack_agiles` | `GET /api/agiles` | Full refresh | — | Offset | 2.2 |
| `youtrack_sprints` | `GET /api/agiles/{id}/sprints` | Substream of `youtrack_agiles` | — | Offset | 2.2 |
| `youtrack_issue_link_types` | `GET /api/issueLinkTypes` | Full refresh | — | Offset | 2.2 |
| `youtrack_issue` | `GET /api/issues?query=updated:...` | Incremental | `updated` (epoch ms) | Offset | 2.3 |
| `youtrack_issue_history` | `GET /api/issues/{id}/activitiesPage` | Substream of `youtrack_issue` | — | Cursor (`afterCursor/hasAfter`) | 2.3 |
| `youtrack_comments` | `GET /api/issues/{id}/comments` | Substream of `youtrack_issue` | — | Offset | 2.3 |
| `youtrack_worklogs` | `GET /api/issues/{id}/timeTracking/workItems` | Substream of `youtrack_issue` | — | Offset | 2.3 |
| `youtrack_project_custom_fields` | `GET /api/admin/projects/{id}/customFields` | Substream of `youtrack_projects` | — | Offset | 2.4 |
| `youtrack_issue_links` | Projection of `youtrack_issue.links[]` | Derived | — | — | 2.5 *(deferred — emitted by dbt staging in feature 2.5, not by the manifest)* |

### Identity Key

- `youtrack_user.email` — primary identity key where available.
- Self-hosted YouTrack may return users without email (Hub integration required); the connector falls back to `login` in that case, and downstream Silver layers reconcile via `login` → email mapping.

## Silver Targets

- `class_task_*` — cross-source task-tracker unification is the responsibility of the Silver/dbt layer via `union_by_tag('silver:class_task_*')`. YouTrack plugs in via tagged per-source staging models (`youtrack__task_*.sql`, feature 2.5 planned).
- This connector package currently ships the Bronze source declaration (`dbt/schema.yml`) plus, once feature 2.5 lands, the staging projections.

## Operational Constraints

- **Auth**: Bearer permanent token. Missing/invalid token → HTTP 401; per-project permission failures → 403. Both halt the run.
- **Rate limits**: YouTrack throttles per-user and per-IP. The connector honours `Retry-After` on HTTP 429 and 503 with backoff.
- **Scope**: no whitelist — ingests every project the token can see. Scope is controlled by provisioning the YouTrack service account with appropriately narrow permissions.
- **Custom fields**: project-scoped. `youtrack_project_custom_fields` enumerates the registry per project; raw issue values live inside the issue payload and are preserved for downstream enrich.
- **activitiesPage cursor**: pagination for `/api/issues/{id}/activitiesPage` is cursor-based (`afterCursor/hasAfter`), not offset. Cursor lost on error → page is re-fetched from `afterCursor=""`.

## Related

- Silver layer (unified task-tracker schema): `src/ingestion/silver/task-tracking/` (delivered by PR #205).
- Sibling connector: [Jira](../jira/README.md) — same Silver target.
- Local manifest runner: `src/ingestion/tools/declarative-connector/source.sh` — `validate` / `check` / `discover` / `read`.
