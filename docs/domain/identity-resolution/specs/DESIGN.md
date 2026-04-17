# Technical Design -- Identity Resolution

## 1. Architecture Overview

Three append-only vertical tables connected by dbt models:

```
                    CONNECTORS (automatic)
                         |
        staging.*__identity_input (per connector, dbt macro)
                         |
                   union_by_tag
                         |
              identity.identity_input (VIEW)
                         |
                    dbt incremental
                         |
            identity.identity_proposals (table)
                         |
                   OPERATOR (manual)
                         |
                identity.links (table)
                         |
                    dbt incremental
                         |
             identity.identity_person (table)
```

All tables are append-only (MergeTree). No UPDATE or DELETE operations. History is preserved by appending new rows with later timestamps.

## 2. Tables

### 2.1 identity.identity_input (VIEW)

Union of all `staging.*__identity_input` models via `union_by_tag('identity:input')`.

| Column | Type | Description |
|---|---|---|
| insight_tenant_id | String | Tenant isolation |
| source_type | String | bamboohr, zoom, gitlab, ... |
| source_id | String | Connector instance ID |
| profile_id | Nullable(String) | Source account ID (e.g., employee number, zoom user ID) |
| field_type | String | email, display_name, employee_id, username, platform_id |
| field_value | Nullable(String) | Field value (empty for DELETE operations) |
| field_path | String | Fully qualified source field: bronze_bamboohr.employees.workEmail |
| operation | String | UPSERT or DELETE |
| observed_at | DateTime | When the change occurred in the source system |
| _synced_at | DateTime64(3) | When dbt processed this row |

### 2.2 identity.links

Operator decisions. Each row = one link/unlink event. Append-only.

| Column | Type | Description |
|---|---|---|
| id | UUID (UUIDv7) | PK |
| insight_tenant_id | String | Tenant isolation |
| person_id | UUID | Person being linked/unlinked |
| source_type | LowCardinality(String) | Source system |
| profile_id | String | Source profile ID. Always set, even on unlink |
| action | LowCardinality(String) | `link` or `unlink` |
| reason | String | new_person, same_email, merge, split, operator_decision |
| created_by | String | Operator name |
| created_at | DateTime64(3, 'UTC') | When the decision was made |

**ENGINE**: MergeTree ORDER BY (insight_tenant_id, source_type, profile_id, created_at)

Primary lookup pattern: "which person is this profile linked to?" filters by source_type + profile_id, which matches the ORDER BY prefix.

**Current link resolution**: For each (tenant, source_type, profile_id), take the row with latest created_at. If action = 'link', the profile is currently linked to that person_id.

### 2.3 identity.identity_proposals

System-generated matching suggestions. Append-only, incremental.

| Column | Type | Description |
|---|---|---|
| id | UUID (UUIDv7) | PK |
| insight_tenant_id | String | Tenant isolation |
| proposal_type | LowCardinality(String) | new_profile, email_match, deactivation |
| status | LowCardinality(String) | pending (always; status tracking is future) |
| source_type | LowCardinality(String) | Source of the profile |
| profile_id | String | Source profile ID |
| field_type | LowCardinality(String) | For email_match: 'email'; for deactivation: field being deactivated |
| field_value | String | For email_match: the matching email |
| matched_source_type | LowCardinality(String) | For email_match: the other source |
| matched_profile_id | String | For email_match: the other profile |
| match_reason | String | same_email, connector_delete |
| confidence | Float32 | Match confidence (1.0 for exact email match) |
| _synced_at | DateTime64(3) | When the proposal was generated |

**ENGINE**: MergeTree ORDER BY (insight_tenant_id, status, proposal_type, source_type, profile_id, _synced_at)

### 2.4 identity.identity_person

Vertical history of person fields. Append-only, incremental. Each row = one field value assignment for a person at a point in time. Empty field_value = field was nullified (unlink/deactivation).

| Column | Type | Description |
|---|---|---|
| insight_tenant_id | String | Tenant isolation |
| person_id | UUID | Person this field belongs to |
| field_type | String | email, display_name, employee_id, ... |
| field_value | String | Value (empty = nullified) |
| field_source | String | Source system that provided this value |
| field_profile_id | String | Source profile this value came from |
| valid_from | DateTime64(3, 'UTC') | When this value became effective |

**ENGINE**: MergeTree ORDER BY (insight_tenant_id, person_id, field_type, field_source, valid_from)

**Current state query**:
```sql
SELECT field_type, field_source,
       argMax(field_value, valid_from) AS current_value
FROM identity.identity_person
WHERE person_id = ?
GROUP BY field_type, field_source
HAVING current_value != ''
```

**State at date query**:
```sql
SELECT field_type, field_source,
       argMax(field_value, valid_from) AS value_at_date
FROM identity.identity_person
WHERE person_id = ? AND valid_from <= ?
GROUP BY field_type, field_source
HAVING value_at_date != ''
```

## 3. dbt Models

### 3.1 Macro: identity_input_from_history

File: `src/ingestion/dbt/macros/identity_input_from_history.sql`

Generates identity input rows from a connector's fields_history model. Each connector calls this macro with:
- `fields_history_ref`: ref to the fields_history model
- `source_type`: connector name (e.g., 'bamboohr')
- `identity_fields`: list of {field, field_type, field_path} dicts mapping source fields to identity field types
- `deactivation_condition`: SQL expression detecting entity deactivation

Produces UPSERT rows when identity fields change, DELETE rows when deactivation condition is met. Incremental: processes only rows newer than last observed_at.

### 3.2 Connector Models: *__identity_input

File: `src/ingestion/connectors/{category}/{connector}/dbt/{connector}__identity_input.sql`

Each connector has a staging model that calls `identity_input_from_history`. Example (bamboohr):

```sql
{{ config(materialized='incremental', incremental_strategy='append', schema='staging',
          tags=['bamboohr', 'identity', 'identity:input']) }}

{{ identity_input_from_history(
    fields_history_ref=ref('bamboohr__employees_fields_history'),
    source_type='bamboohr',
    identity_fields=[
        {'field': 'workEmail', 'field_type': 'email', 'field_path': '...'},
        {'field': 'employeeNumber', 'field_type': 'employee_id', 'field_path': '...'},
        {'field': 'displayName', 'field_type': 'display_name', 'field_path': '...'},
    ],
    deactivation_condition="field_name = 'status' AND new_value IN ('Inactive', 'Terminated')"
) }}
```

Currently implemented: bamboohr, zoom. Adding a new connector requires only creating this model file.

### 3.3 identity_input (VIEW)

File: `src/ingestion/dbt/identity/identity_input.sql`

Unions all connector identity_input models by tag `identity:input`.

### 3.4 identity_proposals (incremental)

File: `src/ingestion/dbt/identity/identity_proposals.sql`

Generates three types of proposals from new identity_input data:
1. **new_profile**: Profiles in identity_input with no corresponding link in identity.links
2. **email_match**: Two profiles from different sources sharing the same email (case-insensitive)
3. **deactivation**: DELETE operations from connectors

Deduplicated: existing proposals are not recreated.

### 3.5 identity_person (incremental)

File: `src/ingestion/dbt/identity/identity_person.sql`

Reacts to three event types:

**EVENT 1a (link)**: New link in identity.links with action='link'. Copies the latest field state (not full history) from identity_input for the linked profile. valid_from = link.created_at (operator decision date).

**EVENT 1b (unlink)**: New link with action='unlink'. Writes empty field_value for all fields the person had from that profile. valid_from = unlink.created_at. profile_id is always set on unlink rows.

**EVENT 2 (new input)**: New data in identity_input for an already-linked profile (observed_at > link.created_at). Copies new field values with valid_from = observed_at. This handles ongoing connector syncs after the initial link.

## 4. Merge / Split Operations

### Merge (person P2 absorbed into P1)

Operator inserts two rows in identity.links (profile_id always set):
```
(P2, source, profile_id, 'unlink', 'merge')  -- detach from P2
(P1, source, profile_id, 'link',   'merge')  -- attach to P1
```

On next `dbt run --select identity_person`:
- Unlink generates nullification rows for P2 (all fields from that profile = empty)
- Link generates field rows for P1 (latest field state from that profile)

P2's historical data (before merge date) remains unchanged. P1 gains the source's fields from the merge date forward.

### Split (undo merge)

Operator inserts two rows:
```
(P1, source, profile_id, 'unlink', 'split')  -- detach from P1
(P2, source, profile_id, 'link',   'split')  -- reattach to P2
```

Same mechanics: P1 loses the source's fields (nullified), P2 regains them, both from the split date.

Historical data is never modified. The append-only log preserves full audit trail.

## 5. Files

| File | Role |
|---|---|
| `src/ingestion/dbt/macros/identity_input_from_history.sql` | Macro for connector identity input |
| `src/ingestion/connectors/*/dbt/*__identity_input.sql` | Per-connector staging models |
| `src/ingestion/dbt/identity/identity_input.sql` | VIEW union |
| `src/ingestion/dbt/identity/identity_proposals.sql` | Proposal generation |
| `src/ingestion/dbt/identity/identity_person.sql` | Person field materialization |
| `src/ingestion/dbt/identity/schema.yml` | Source definitions |
| `src/ingestion/scripts/migrations/20260415000000_identity-resolution.sql` | DDL for links + proposals |
| `src/ingestion/k8s/clickhouse/deployment.yaml` | ClickHouse HTTP probes fix |

## 6. Migration

File: `src/ingestion/scripts/migrations/20260415000000_identity-resolution.sql`

Creates `identity.links` and `identity.proposals` tables. Other tables (identity_input VIEW, identity_person) are managed by dbt.

Prerequisite: `identity` database must exist (created by `20260408000000_init-identity.sql`).
