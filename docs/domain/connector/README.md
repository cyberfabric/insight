# Connector Domain

Development guide and architecture for Airbyte connectors on the Insight platform. Covers declarative (nocode YAML) and CDK (Python) connector types.

> **Note**: This domain replaces the previous custom Connector Framework. The old DESIGN.md in `specs/` is retained as historical reference. The current approach uses Airbyte declarative manifests and CDK.

## Documents

| Document | Description |
|---|---|
| [`specs/DESIGN.md`](specs/DESIGN.md) | Historical: custom connector framework architecture |
| [Airbyte Connector DESIGN](../airbyte-connector/specs/DESIGN.md) | Current: declarative + CDK patterns, package structure, local debugging |

## Implementation

Source code: [`src/ingestion/`](../../../src/ingestion/)

```
src/ingestion/
  connectors/{class}/{source}/     # Connector packages
    connector.yaml                 # Declarative manifest
    descriptor.yaml                # Package metadata
    .env.local                     # Credentials (git-ignored)
    example.env.local              # Credential template
    dbt/                           # Bronze → Silver transforms
    connections/{name}/            # Configured catalogs + state
  tools/declarative-connector/
    source.sh                      # Local debugging tool
    Dockerfile
    entrypoint.sh
  scripts/
    upload-manifests.sh            # Push manifest to Airbyte API
```

---

## Declarative Connector Guide

### Mandatory Fields

Every connector MUST include these fields in every record:

| Field | Source | Purpose |
|-------|--------|---------|
| `tenant_id` | `config['insights_tenant_id']` via `AddFields` | Tenant isolation |
| `unique_key` | Computed via `AddFields` transformation | Deduplication / primary key |

`unique_key` is a composite string that uniquely identifies a record. Typical pattern:
```
{{ record['userPrincipalName'] }}-{{ record['reportRefreshDate'] }}
```

### Config Field Naming

Config fields MUST use prefixes to avoid collision with platform fields:

| Field | Description |
|-------|-------------|
| `insights_tenant_id` | Insight platform tenant ID (mandatory, injected as `tenant_id`) |
| `azure_tenant_id` | Azure AD tenant ID |
| `azure_client_id` | Azure AD application client ID |
| `azure_client_secret` | Azure AD client secret (`airbyte_secret: true`) |

**Rule**: `insights_tenant_id` is always required. Source-specific fields use a prefix matching the source (e.g., `azure_*`, `github_*`, `jira_*`).

### Manifest Structure

Use `definitions` with `$ref` for reusable components:

```yaml
version: 7.0.4
type: DeclarativeSource

check:
  type: CheckStream
  stream_names: [stream_name]

definitions:
  auth:          # Reusable auth config
  paginator:     # Reusable pagination
  incremental:   # Reusable cursor config
  add_fields:    # tenant_id + unique_key injection
  base_requester:
  base_record_selector:
  base_retriever:

streams:
  - type: DeclarativeStream
    name: stream_name
    primary_key: [unique_key]
    retriever:
      $ref: "#/definitions/base_retriever"
      requester:
        $ref: "#/definitions/base_requester"
        url: https://api.example.com/endpoint
    incremental_sync:
      $ref: "#/definitions/incremental"
    transformations:
      - $ref: "#/definitions/add_fields"
    schema_loader:
      type: InlineSchemaLoader
      schema: ...

spec:
  type: Spec
  connection_specification: ...
```

### Incremental Sync

Use `DatetimeBasedCursor` with computed dates (no config parameters):

```yaml
incremental:
  type: DatetimeBasedCursor
  cursor_field: reportRefreshDate
  datetime_format: "%Y-%m-%d"
  cursor_granularity: P1D
  start_datetime:
    type: MinMaxDatetime
    datetime: "{{ (today_utc() - duration('P27D')).strftime('%Y-%m-%d') }}"
    datetime_format: "%Y-%m-%d"
  end_datetime:
    type: MinMaxDatetime
    datetime: "{{ (today_utc() - duration('P2D')).strftime('%Y-%m-%d') }}"
    datetime_format: "%Y-%m-%d"
  step: P1D
```

**Rules**:
- `start_date` and `end_date` are NEVER passed via config — always computed from current date
- Step should match API granularity (P1D for daily reports)
- End date accounts for data lag (e.g., 2–3 days for Graph API)

### Pagination

For OData APIs with `@odata.nextLink`:

```yaml
paginator:
  type: DefaultPaginator
  page_token_option:
    type: RequestPath
  pagination_strategy:
    type: CursorPagination
    cursor_value: "{{ response.get('@odata.nextLink', '') }}"
    stop_condition: "{{ not response.get('@odata.nextLink') }}"
```

### AddFields (tenant_id + unique_key)

```yaml
add_fields:
  type: AddFields
  fields:
    - path: [tenant_id]
      value: "{{ config['insights_tenant_id'] }}"
    - path: [unique_key]
      value: "{{ record['field1'] }}-{{ record['field2'] }}"
```

### Schema

Use `additionalProperties: true` to accept all fields from the API. Define known fields explicitly for documentation:

```yaml
schema_loader:
  type: InlineSchemaLoader
  schema:
    type: object
    properties:
      tenant_id:
        type: string
      unique_key:
        type: string
      # ... source-specific fields
    additionalProperties: true
```

### Request Parameters

For APIs that return CSV by default, add `$format` as a GET parameter (not a header):

```yaml
requester:
  type: HttpRequester
  request_parameters:
    $format: application/json
```

### Record Extraction

JSON APIs with `value` array wrapper:

```yaml
record_selector:
  type: RecordSelector
  extractor:
    type: DpathExtractor
    field_path:
      - value
```

---

## Development Workflow

### 1. Create connector directory

```
src/ingestion/connectors/{class}/{source}/
  connector.yaml
  descriptor.yaml
  example.env.local
```

### 2. Write manifest

Start with `definitions` (auth, paginator, incremental, add_fields), then define streams using `$ref`.

### 3. Create credentials

```bash
cp example.env.local .env.local
# Edit .env.local with real values:
# AIRBYTE_CONFIG={"insights_tenant_id":"...","azure_tenant_id":"...","azure_client_id":"...","azure_client_secret":"..."}
```

### 4. Validate manifest (no credentials needed)

```bash
./tools/declarative-connector/source.sh validate {class}/{source}
```

- Exit 0 = manifest structure valid
- Exit 1 = schema validation error with details

### 5. Test connectivity

```bash
./tools/declarative-connector/source.sh check {class}/{source}
```

- `STATUS: SUCCEEDED` = auth + API working
- `STATUS: FAILED` + error message = debug from the message

### 6. Discover streams

```bash
./tools/declarative-connector/source.sh discover {class}/{source}
```

### 7. Read data

```bash
mkdir -p connectors/{class}/{source}/connections/dev
echo '[]' > connectors/{class}/{source}/connections/dev/state.json
# Create configured_catalog.json with desired streams

./tools/declarative-connector/source.sh read {class}/{source} dev
```

### 8. Verify data

Check that every record has:
- `tenant_id` present and correct
- `unique_key` present and unique per record
- Expected fields from the API

### 9. Upload to Airbyte

```bash
./scripts/upload-manifests.sh {class}/{source}
```

This creates/updates the builder project and publishes the active manifest.

---

## Common Pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| `no stream slices were found` | `start_date` in future or after `end_date` | Fix date computation in `incremental` |
| `json is not a valid format value` | `$format=json` instead of `$format=application/json` | Use full MIME type |
| `Unexpected UTF-8 BOM` | API returns CSV with BOM instead of JSON | Add `$format: application/json` to `request_parameters` |
| `Validation against declarative_component_schema.yaml schema failed` | Invalid manifest structure | Check error details for the specific invalid field |
| `AIRBYTE_CONFIG is not valid JSON` | `.env.local` has shell-escaped quotes | Use raw JSON without surrounding quotes |
| Builder UI shows wrong test values after upload | Airbyte rebuilds test config from spec on manifest update | Re-enter test values manually in UI |

---

## M365 Connector Spec Discrepancies

The following differences exist between the current implementation (`src/ingestion/connectors/collaboration/m365/connector.yaml`) and the spec (`docs/components/connectors/collaboration/m365/specs/DESIGN.md`). These need to be resolved:

| Item | Spec | Implementation | Action needed |
|------|------|----------------|---------------|
| Config fields | `tenant_id`, `client_id`, `client_secret` | `insights_tenant_id`, `azure_client_id`, `azure_client_secret`, `azure_tenant_id` | Update spec |
| Streams | 5 (email, teams, onedrive, sharepoint, copilot) + collection_runs | 4 (email, teams, onedrive, sharepoint) | Add copilot when license available; remove collection_runs (not in manifest) |
| `unique_key` | `lower(userPrincipalName + '-' + reportRefreshDate)` | `userPrincipalName + '-' + reportRefreshDate` (no lower) | Align — add `lower()` or update spec |
| `start_date` | Configurable with default | Always computed (today - 27 days) | Update spec |
| `end_date` | `today - 3 days` | `today - 2 days` | Align |
| Pagination | OData `$skiptoken` via request parameter | `@odata.nextLink` via `RequestPath` cursor | Update spec |

## Related Domains

| Domain | Relationship |
|---|---|
| [Ingestion](../ingestion/) | Parent architecture — orchestration, deployment, Terraform connections |
| [Airbyte Connector](../airbyte-connector/) | Detailed DESIGN spec for connector development |
