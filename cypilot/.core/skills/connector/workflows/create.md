---
name: connector-create
description: "Create a new Insight Connector package"
---

# Create Connector

Creates a complete Insight Connector package with all required files.

## Phase 1: Gather Information

Ask the user (skip questions where context already provides the answer):

```
[Q1] Category? (collaboration / hr-directory / git / task-tracking / crm / support / ai / wiki)
[Q2] Connector name? (short, lowercase, e.g. m365, bamboohr, jira)
[Q3] API base URL? (e.g. https://graph.microsoft.com/v1.0)
[Q4] Auth type? (oauth2_client_credentials / api_key / bearer / basic)
[Q5] Connector type? (nocode / cdk)
[Q6] API documentation URL? (optional — will fetch and analyze)
[Q7] What data streams should the connector extract? (e.g. users, activities, tickets)
```

## Phase 2: Research API (if docs URL provided)

1. Fetch API documentation via WebFetch
2. Identify: endpoints, auth flow, pagination pattern, rate limits
3. Identify: available fields per stream, primary keys, cursor fields
4. Summarize findings for user confirmation

## Phase 3: Create Package

### For nocode (`CONNECTOR_TYPE=nocode`):

Read the reference connector for patterns:
- `src/ingestion/connectors/collaboration/m365/connector.yaml`
- `src/ingestion/connectors/collaboration/m365/descriptor.yaml`

Create files:

#### 3.1 `connector.yaml` — Airbyte declarative manifest

```yaml
version: 7.0.4
type: DeclarativeSource
```

MUST include:
- `definitions` block with reusable `$ref` components (auth, paginator, incremental, add_fields)
- `add_fields` with ALL three mandatory fields:
  ```yaml
  add_fields:
    type: AddFields
    fields:
      - path: [tenant_id]
        value: "{{ config['insight_tenant_id'] }}"
      - path: [source_id]
        value: "{{ config['insight_source_id'] }}"
      - path: [unique_key]
        value: "{{ config['insight_tenant_id'] }}-{{ config['insight_source_id'] }}-{{ record['<primary_field>'] }}"
  ```
- `spec.connection_specification` with `insight_tenant_id` and `insight_source_id` as required fields
- All config fields with source-specific prefixes (e.g. `azure_*`, `github_*`, `jira_*`)
- `InlineSchemaLoader` with `additionalProperties: true`
- Incremental sync with computed dates (no config params for start/end)

#### 3.2 `descriptor.yaml`

```yaml
name: <connector_name>
version: "1.0"
type: nocode

schedule: "0 2 * * *"
dbt_select: "tag:<connector_name> tag:silver"
workflow: sync

connection:
  namespace: "bronze_<connector_name>"
  streams:
    - name: <stream_name>
      sync_mode: full_refresh_overwrite
```

#### 3.3 `credentials.yaml.example`

List all required credentials with empty values and comments explaining how to obtain them.
Always include `insight_source_id`.

#### 3.4 `dbt/<connector_name>__<domain>.sql`

```sql
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['<connector_name>', 'silver:class_<domain>']
) }}

SELECT
    tenant_id,
    source_id,
    unique_key,
    -- source-specific field mappings
    '<connector_name>' AS source
FROM {{ source('bronze_<connector_name>', '<stream_name>') }}
{% if is_incremental() %}
WHERE <cursor_field> > (SELECT max(<mapped_field>) FROM {{ this }})
{% endif %}
```

#### 3.5 `dbt/schema.yml`

Define source (bronze database) and model with tests:
- `tenant_id`: not_null
- `source_id`: not_null
- `unique_key`: not_null, unique

### For CDK (`CONNECTOR_TYPE=cdk`):

Create Python scaffold:

#### 3.1 `src/source_<name>/__init__.py`
#### 3.2 `src/source_<name>/source.py`

```python
from airbyte_cdk.sources import AbstractSource

class Source<Name>(AbstractSource):
    def check_connection(self, logger, config):
        # Validate credentials
        ...

    def streams(self, config):
        tenant_id = config["insight_tenant_id"]
        source_id = config["insight_source_id"]
        return [
            Stream1(tenant_id=tenant_id, source_id=source_id, ...),
        ]
```

Each stream MUST inject `tenant_id`, `source_id`, `unique_key` in `parse_response()`:

```python
def parse_response(self, response, **kwargs):
    for record in response.json()["data"]:
        record["tenant_id"] = self.tenant_id
        record["source_id"] = self.source_id
        record["unique_key"] = f"{self.tenant_id}-{self.source_id}-{record['id']}"
        yield record
```

#### 3.3 `src/source_<name>/schemas/<stream>.json`
#### 3.4 `setup.py`
#### 3.5 `Dockerfile`
#### 3.6 Same descriptor.yaml, credentials.yaml.example, dbt/ as nocode

## Phase 4: Validate Package Structure

After creating all files, run:
```
/connector validate <name>
```

## Phase 5: Local Testing (MANDATORY before Airbyte)

All testing MUST happen locally first via `source.sh` before uploading to Airbyte.

### 5.1 Add credentials to tenant config

```yaml
# connections/<tenant>.yaml
connectors:
  <name>:
    insight_source_id: "<name>-main"
    <credential_fields>
```

### 5.2 Validate manifest structure (no API call)

```bash
./tools/declarative-connector/source.sh validate <category>/<name>
```

### 5.3 Check credentials against API

```bash
./tools/declarative-connector/source.sh check <category>/<name> <tenant>
```

### 5.4 Discover streams and generate schema from real data

```bash
./tools/declarative-connector/source.sh discover <category>/<name> <tenant>
./scripts/generate-schema.sh <name>
```

This saves real JSON schemas to `connectors/<category>/<name>/schemas/`.

### 5.5 Update manifest with real schema

Replace InlineSchemaLoader schemas in `connector.yaml` with the generated ones from `schemas/`.
Verify that all cursor fields exist in the schema (this prevents ClickHouse destination NPE).

### 5.6 Read data locally

```bash
./scripts/generate-catalog.sh <name>
./tools/declarative-connector/source.sh read <category>/<name> <tenant>
```

Verify every record has `tenant_id`, `source_id`, `unique_key`.

### 5.7 Only then deploy to Airbyte

```bash
/connector deploy <name>
```

## Phase 6: Summary

```
Connector package created and tested: src/ingestion/connectors/<category>/<name>/

Completed:
  ✓ Package structure validated
  ✓ Credentials checked against API
  ✓ Streams discovered, schema generated from real data
  ✓ Data read locally — all mandatory fields present

Next: /connector deploy <name>
```
