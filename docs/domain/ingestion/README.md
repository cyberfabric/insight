# Ingestion Domain

The Ingestion Layer provides the end-to-end data pipeline from external source APIs to unified Silver step 1 tables. It replaces the previously designed custom Orchestrator and custom Connector Framework with an industry-standard stack: Airbyte for extraction, Kestra for orchestration, dbt-clickhouse for Bronze-to-Silver transformations, and Terraform for connection management.

## Documents

| Document | Description |
|---|---|
| [`specs/PRD.md`](specs/PRD.md) | Product requirements: actors, scope, functional/non-functional requirements, use cases |
| [`specs/DESIGN.md`](specs/DESIGN.md) | Technical design: architecture layers, components (Airbyte, Kestra, dbt, ClickHouse, Terraform), deployment, sequences |
| [`specs/ADR/0001-kestra-over-airflow.md`](specs/ADR/0001-kestra-over-airflow.md) | ADR: Why Kestra over Airflow — YAML-first, no Python dependency |

## Scope

This domain covers:
- Data extraction from external sources via Airbyte (nocode and CDK connectors)
- Pipeline orchestration via Kestra (scheduling, dependencies, retry)
- Bronze layer storage in ClickHouse (raw tables matching Airbyte stream names)
- Silver step 1 transformations via dbt-clickhouse (`class_{domain}` unified tables)
- Connector package structure (manifest/code + dbt models + descriptor)
- Airbyte connection management via Terraform
- `tenant_id` injection at connector level for tenant isolation
- Production deployment (Kubernetes + Helm) and local development (Docker Compose)

Out of scope: Silver step 2 (identity resolution — see [`../identity-resolution/`](../identity-resolution/)), Gold layer metrics, per-source connector specs (see [`../airbyte-connector/`](../airbyte-connector/)).

## Related Domains

| Domain | Relationship |
|---|---|
| [Airbyte Connector](../airbyte-connector/) | Connector development guide: nocode/CDK patterns, package structure, local debugging |
| [Connector Framework](../connector/) | Superseded by this domain (historical reference) |
| [Identity Resolution](../identity-resolution/) | Downstream consumer of Silver step 1 tables |

## Supersedes

- [Orchestrator PRD](../../components/orchestrator/specs/PRD.md) — replaced by Kestra
- [Connector Framework DESIGN](../connector/specs/DESIGN.md) — replaced by Airbyte
- [ADR-0001: Stdout Protocol](../connector/specs/ADR/0001-connector-integration-protocol.md) — replaced by Airbyte Protocol

## Implementation

Source code: [`src/ingestion/`](../../../src/ingestion/)

```
src/ingestion/
  connectors/{class}/{source}/   # Connector packages (manifests, dbt, descriptors)
  connections/                    # Airbyte connection configs (Terraform)
  tools/declarative-connector/   # Local debugging tooling (source.sh, Dockerfile)
```

## Open Questions — Implementation Gaps

The following questions must be resolved before the full local development stack can be generated. They are grouped by component.

### Docker Compose (local development stack)

- **OQ-IMPL-01**: What is the complete set of Airbyte services required in docker-compose (server, worker, temporal, postgres for metadata)? What environment variables does each service need?
- **OQ-IMPL-02**: What database backend should Kestra use locally — ClickHouse, MariaDB, or embedded H2? What are the required environment variables and configuration?
- **OQ-IMPL-03**: Should ClickHouse run as a single node or a minimal cluster (1 shard, 1 replica) for local dev? How should shard-local tables be configured?
- **OQ-IMPL-04**: How should services be initialized on first run — init containers, startup scripts, or manual bootstrap?

### dbt Project Configuration

- **OQ-IMPL-05**: Where is the root `dbt_project.yml` located — `src/ingestion/dbt/` or at the connector package level? How are per-connector models discovered and organized?
- **OQ-IMPL-06**: What `profiles.yml` settings are needed for dbt-clickhouse (host, port, database, schema, engine settings)?
- **OQ-IMPL-07**: What materialization strategy should Silver tables use — `view`, `table`, or `incremental`? What ClickHouse engine and `ORDER BY` / `PARTITION BY` should Silver tables use?
- **OQ-IMPL-08**: Should there be shared dbt macros for `tenant_id` filtering, source tagging, or common transformations?

### Kestra Flows

- **OQ-IMPL-09**: What is the flow granularity — one flow per connector, per tenant, or per (connector, tenant) pair? (relates to OQ-ING-02 in DESIGN)
- **OQ-IMPL-10**: What are the exact Kestra plugin names and parameters for Airbyte sync triggering (`io.kestra.plugin.airbyte.*`)? How is the Airbyte API token passed?
- **OQ-IMPL-11**: What are the exact Kestra plugin names and parameters for dbt CLI execution? How is the dbt project directory mounted or referenced?
- **OQ-IMPL-12**: What retry policy should be default — how many retries, what backoff strategy, what timeout per task?

### Terraform Configuration

- **OQ-IMPL-13**: Where should Terraform code live — `src/ingestion/connections/` or a separate `terraform/` directory? How should it be organized (by connector, by environment)?
- **OQ-IMPL-14**: How should the `airbytehq/airbyte` Terraform provider be configured — what authentication method, what base URL for self-managed?
- **OQ-IMPL-15**: What are the required fields for `airbyte_source`, `airbyte_destination`, and `airbyte_connection` resources? How is `tenant_id` passed through connection configuration?
- **OQ-IMPL-16**: Where is Terraform state stored for local dev vs production?

### ClickHouse Destination

- **OQ-IMPL-17**: What Airbyte normalization mode should be used for ClickHouse destination — `raw`, `basic`, or `none`? (relates to OQ-ING-01 in DESIGN)
- **OQ-IMPL-18**: Does the Airbyte ClickHouse destination auto-create tables with `ReplacingMergeTree`? If not, how are Bronze tables created?
- **OQ-IMPL-19**: What is the namespace/database naming convention for Bronze data — one database per connector (e.g., `bronze_github`), one shared database, or configurable per connection?

### Local Debugging Tooling (source.sh)

- **OQ-IMPL-20**: Should `source.sh` and `destination.sh` be copied from the prototype (`monitor/insights_concept/airbyte_cli/`) or rewritten? What changes are needed for the new path structure?
- **OQ-IMPL-21**: Should `destination.sh` support ClickHouse in addition to PostgreSQL? What ClickHouse destination image should be used?
- **OQ-IMPL-22**: How should state.json be captured and persisted after a `read` command — automatically by the script or manually by the developer?

### Standard Fields and Conventions

- **OQ-IMPL-23**: Should all connectors emit standard fields beyond `tenant_id` — e.g., `_extracted_at` (timestamp), `_source` (connector name)? (relates to OQ-ABC-01 in Airbyte Connector DESIGN)
- **OQ-IMPL-24**: Should source-native field names be preserved in Bronze or normalized to snake_case?

### Bootstrap and Initialization

- **OQ-IMPL-25**: What is the step-by-step sequence to bring up a local dev environment from scratch — create databases, register connectors, create connections, run first sync?
- **OQ-IMPL-26**: Should there be a `Makefile` or bootstrap script that automates the local setup?
