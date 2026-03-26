# Airbyte Connector Domain

Development guide for creating Airbyte connectors for the Insight platform. Covers both nocode (declarative YAML manifest) and CDK (Python) connector types, packaged with dbt transformations and descriptor metadata.

## Documents

| Document | Description |
|---|---|
| [`specs/DESIGN.md`](specs/DESIGN.md) | Connector development guide: package structure, declarative manifest patterns, CDK patterns, `tenant_id` injection, descriptor YAML, dbt models, local debugging (ultra-light and full stack) |

## Scope

This domain covers:
- Connector package structure (`connector.yaml` / `src/`, `dbt/`, `descriptor.yaml`)
- Nocode declarative manifest authoring (authentication, pagination, incremental sync, `tenant_id` injection via `AddFields`)
- CDK (Python) connector development (`AbstractSource`, `tenant_id` in `parse_response()`)
- Descriptor YAML schema (name, version, type, silver_targets, streams)
- dbt models for Bronze-to-Silver transformations (`to_{domain}.sql`)
- Local debugging workflows: ultra-light (`source.sh`) and full stack (Docker Compose)
- Production connector registration via Airbyte API

Out of scope: ingestion pipeline orchestration (see [`../ingestion/`](../ingestion/)), identity resolution, Gold layer.

## Related Domains

| Domain | Relationship |
|---|---|
| [Ingestion](../ingestion/) | Parent architecture — orchestration, deployment, Terraform connections |
| [Connector Framework](../connector/) | Superseded approach (historical reference) |

## Implementation

Source code: [`src/ingestion/connectors/`](../../../src/ingestion/connectors/)

```
src/ingestion/
  connectors/{class}/{source}/
    connector.yaml       # Nocode manifest (or src/ for CDK)
    descriptor.yaml      # Package metadata
    dbt/
      to_{domain}.sql    # Bronze → Silver transformations
      schema.yml
  tools/declarative-connector/
    source.sh            # Ultra-light local debugging
    destination.sh
    Dockerfile
    entrypoint.sh
```
