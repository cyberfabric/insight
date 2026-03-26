---
status: proposed
date: 2026-03-23
---

# DESIGN -- Ingestion Layer

<!-- toc -->

- [1. Architecture Overview](#1-architecture-overview)
  - [1.1 Architectural Vision](#11-architectural-vision)
  - [1.2 Architecture Drivers](#12-architecture-drivers)
  - [1.3 Architecture Layers](#13-architecture-layers)
- [2. Principles & Constraints](#2-principles--constraints)
  - [2.1 Design Principles](#21-design-principles)
  - [2.2 Constraints](#22-constraints)
- [3. Technical Architecture](#3-technical-architecture)
  - [3.1 Domain Model](#31-domain-model)
  - [3.2 Component Model](#32-component-model)
  - [3.3 API Contracts](#33-api-contracts)
  - [3.4 Internal Dependencies](#34-internal-dependencies)
  - [3.5 External Dependencies](#35-external-dependencies)
  - [3.6 Interactions & Sequences](#36-interactions--sequences)
  - [3.7 Database schemas & tables](#37-database-schemas--tables)
  - [3.8 Connector Package Structure](#38-connector-package-structure)
- [4. Deployment](#4-deployment)
  - [4.1 Production (Kubernetes + Helm)](#41-production-kubernetes--helm)
  - [4.2 Local Development (Docker Compose)](#42-local-development-docker-compose)
  - [4.3 Ultra-Light Connector Debugging](#43-ultra-light-connector-debugging)
- [5. Additional Context](#5-additional-context)
  - [5.1 Superseded Components](#51-superseded-components)
- [6. Open Questions](#6-open-questions)
  - [OQ-ING-01: ClickHouse Destination Normalization Mode](#oq-ing-01-clickhouse-destination-normalization-mode)
  - [OQ-ING-02: Kestra Flow Granularity](#oq-ing-02-kestra-flow-granularity)
  - [OQ-ING-03: MariaDB Destination Use Cases](#oq-ing-03-mariadb-destination-use-cases)
  - [OQ-ING-04: Gold Layer Ownership](#oq-ing-04-gold-layer-ownership)
  - [OQ-ING-05: Connector Package Versioning](#oq-ing-05-connector-package-versioning)
- [7. Traceability](#7-traceability)

<!-- /toc -->

---

## 1. Architecture Overview

### 1.1 Architectural Vision

The Ingestion Layer provides the complete data pipeline from external source APIs to unified Silver step 1 tables, built on industry-standard open-source tools. Airbyte handles data extraction through both nocode declarative manifests and Python CDK connectors. Kestra orchestrates the pipeline lifecycle -- scheduling syncs, managing dependencies between extraction and transformation, and handling retries. dbt-clickhouse transforms raw Bronze data into unified Silver schemas. Terraform manages Airbyte connection configuration as code.

This layer replaces the previously designed custom Orchestrator and custom Connector Framework with a simpler, more maintainable stack that requires no custom runtime code.

### 1.2 Architecture Drivers

#### Functional Drivers

| Requirement | Design Response |
|---|---|
| `cpt-insightspec-fr-ing-airbyte-extract` | Airbyte Platform with ClickHouse destination handles extraction and loading |
| `cpt-insightspec-fr-ing-nocode-connector` | Airbyte declarative manifests (YAML) with `source-declarative-manifest` base image |
| `cpt-insightspec-fr-ing-cdk-connector` | Airbyte Python CDK with custom Docker images |
| `cpt-insightspec-fr-ing-tenant-id` | `AddFields` transformation in manifests; explicit injection in CDK `read_records()` |
| `cpt-insightspec-fr-ing-incremental-sync` | Airbyte cursor-based incremental sync with persisted state |
| `cpt-insightspec-fr-ing-kestra-scheduling` | Kestra flows with cron triggers and event-driven execution |
| `cpt-insightspec-fr-ing-kestra-dependency` | Kestra DAG task ordering: sync -> dbt |
| `cpt-insightspec-fr-ing-bronze-storage` | ClickHouse `ReplacingMergeTree` with Airbyte stream name as table name |
| `cpt-insightspec-fr-ing-dbt-bronze-to-silver` | Per-package dbt models producing `class_{domain}` tables |
| `cpt-insightspec-fr-ing-terraform-connections` | Airbyte Terraform provider for connection management |
| `cpt-insightspec-fr-ing-package-structure` | Self-contained connector packages: manifest + dbt + descriptor |

#### NFR Allocation

| NFR | Component | Verification |
|-----|-----------|-------------|
| `cpt-insightspec-nfr-ing-idempotency` | ClickHouse ReplacingMergeTree | Re-run sync; verify no duplicates after OPTIMIZE TABLE FINAL |
| `cpt-insightspec-nfr-ing-error-isolation` | Kestra per-task execution | Fail one connector; verify others succeed |
| `cpt-insightspec-nfr-ing-tenant-isolation` | Connector-level tenant_id injection | Query tables; verify no missing/incorrect tenant_id |
| `cpt-insightspec-nfr-ing-observability` | Kestra UI + Airbyte UI | Verify executions visible within 1 minute |

#### Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [ADR-0001](ADR/0001-kestra-over-airflow.md) `cpt-insightspec-adr-ing-kestra-over-airflow` | Use Kestra over Airflow — YAML-first, no Python dependency |

### 1.3 Architecture Layers

```
┌──────────────────────────────────────────────────────────────────┐
│                      EXTERNAL DATA SOURCES                       │
│  GitHub · Jira · MS365 · GitLab · Slack · BambooHR · etc.       │
└───────────────────────┬──────────────────────────────────────────┘
                        │ HTTP / REST / GraphQL
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│                     AIRBYTE PLATFORM                             │
│                                                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────┐  │
│  │ Nocode Connectors│  │ CDK Connectors  │  │ ClickHouse     │  │
│  │ (YAML manifests) │  │ (Python)        │  │ Destination    │  │
│  └────────┬────────┘  └────────┬────────┘  └───────┬────────┘  │
│           │  tenant_id         │  tenant_id         │           │
│           └────────────────────┴────────────────────┘           │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Airbyte API  · Connection Management · Catalog Discovery │    │
│  └─────────────────────────────────────────────────────────┘    │
└───────────────────────┬──────────────────────────────────────────┘
                        │ Airbyte Protocol (RECORD, STATE)
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│                    BRONZE LAYER (ClickHouse)                     │
│                                                                  │
│  Airbyte stream name tables · ReplacingMergeTree · shard-local  │
│  tenant_id in every record · source-native schema preserved     │
└───────────────────────┬──────────────────────────────────────────┘
                        │ SQL (dbt-clickhouse)
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│               SILVER STEP 1 LAYER (ClickHouse)                   │
│                                                                  │
│  class_{domain} tables · unified schema · tenant_id             │
│  source-native user IDs intact (person_id added in step 2)      │
└──────────────────────────────────────────────────────────────────┘

                    ORCHESTRATION (KESTRA)
        ┌──────────────────────────────────────┐
        │  Schedule → Airbyte Sync → dbt Run   │
        │  Retry · Dependency · Observability   │
        └──────────────────────────────────────┘

                INFRASTRUCTURE AS CODE (TERRAFORM)
        ┌──────────────────────────────────────┐
        │  Airbyte Connections · CI/CD Apply    │
        └──────────────────────────────────────┘
```

## 2. Principles & Constraints

### 2.1 Design Principles

#### Self-Contained Connector Packages

- [ ] `p1` - **ID**: `cpt-insightspec-principle-ing-package-self-contained`

Each connector package contains everything needed for its pipeline: connector definition (manifest or code), dbt models for Bronze-to-Silver transformation, and a descriptor YAML declaring its capabilities. No external dependencies beyond the package directory.

**Why**: Enables independent development, testing, and deployment of connectors.

#### No Custom Runtime

- [ ] `p1` - **ID**: `cpt-insightspec-principle-ing-no-custom-runtime`

Use Airbyte's connector runtime for extraction and Kestra's execution engine for orchestration. No custom runner, subprocess management, or message protocol.

**Why**: Reduces maintenance burden; leverages battle-tested runtimes with community support.

#### Declarative-First

- [ ] `p1` - **ID**: `cpt-insightspec-principle-ing-declarative-first`

Prefer nocode declarative manifests for new connectors. Use CDK (Python) only when the declarative approach cannot express the required logic (complex auth, multi-step API calls, binary data).

**Why**: Declarative manifests are faster to develop, easier to review, and simpler to maintain.

#### Tenant Isolation at Source

- [ ] `p1` - **ID**: `cpt-insightspec-principle-ing-tenant-isolation`

Every record is tagged with `tenant_id` at the connector level -- before data leaves the extraction boundary. This is not a post-processing step; it is an extraction invariant.

**Why**: Guarantees tenant isolation from the earliest point in the pipeline.

#### Silver Targets Known at Design Time

- [ ] `p1` - **ID**: `cpt-insightspec-principle-ing-silver-at-design-time`

When creating a connector package, the author knows which Silver tables (`class_{domain}`) the connector will populate. The descriptor YAML declares these targets explicitly.

**Why**: Enables package-level validation and dependency tracking.

### 2.2 Constraints

#### ClickHouse as Primary Destination

- [ ] `p1` - **ID**: `cpt-insightspec-constraint-ing-clickhouse-destination`

All Bronze and Silver data resides in ClickHouse. MariaDB is an alternative destination for specific use cases (documented separately). No other storage engines are supported.

#### Monorepo Package Storage

- [ ] `p1` - **ID**: `cpt-insightspec-constraint-ing-monorepo`

All connector packages reside in the project monorepo. No external package registry, no Git submodules, no npm/pip packages.

#### No External Connector Registry

- [ ] `p1` - **ID**: `cpt-insightspec-constraint-ing-no-external-registry`

Custom connectors are registered directly with the Airbyte instance via its API. There is no separate registry service.

#### Terraform for Connections Only

- [ ] `p1` - **ID**: `cpt-insightspec-constraint-ing-terraform-connections`

Terraform manages Airbyte connections (source + destination + catalog). Custom connector registration is handled via Airbyte API, not Terraform.

## 3. Technical Architecture

### 3.1 Domain Model

```mermaid
classDiagram
    class ConnectorPackage {
        +String name
        +String class
        +String source
        +String type [nocode|cdk]
        +ConnectorDefinition definition
        +DbtModels dbt
        +Descriptor descriptor
    }
    class ConnectorDefinition {
        <<abstract>>
    }
    class DeclarativeManifest {
        +String version
        +Stream[] streams
        +Spec spec
    }
    class CdkConnector {
        +Dockerfile dockerfile
        +PythonSource source
    }
    class Descriptor {
        +String name
        +String version
        +String type
        +String[] silver_targets
        +StreamDef[] streams
    }
    class StreamDef {
        +String name
        +String bronze_table
        +String[] primary_key
        +String cursor_field
    }
    class DbtModels {
        +SqlFile[] models
        +SchemaYml schema
    }
    class AirbyteConnection {
        +String source_id
        +String destination_id
        +ConfiguredCatalog catalog
        +String tenant_id
    }
    class KestraFlow {
        +String id
        +String namespace
        +Trigger[] triggers
        +Task[] tasks
    }
    class BronzeTable {
        +String name [stream_name]
        +String engine [ReplacingMergeTree]
        +Column tenant_id
    }
    class SilverTable {
        +String name [class_domain]
        +Column tenant_id
    }

    ConnectorPackage *-- ConnectorDefinition
    ConnectorPackage *-- DbtModels
    ConnectorPackage *-- Descriptor
    ConnectorDefinition <|-- DeclarativeManifest
    ConnectorDefinition <|-- CdkConnector
    Descriptor *-- StreamDef
    AirbyteConnection --> ConnectorPackage : uses
    KestraFlow --> AirbyteConnection : triggers sync
    KestraFlow --> DbtModels : triggers run
    AirbyteConnection --> BronzeTable : writes to
    DbtModels --> BronzeTable : reads from
    DbtModels --> SilverTable : writes to
```

### 3.2 Component Model

#### Airbyte Platform

- [ ] `p1` - **ID**: `cpt-insightspec-component-ing-airbyte`

##### Why this component exists

Handles all data extraction from external sources, providing connector runtime, connection management, catalog discovery, and data delivery to ClickHouse.

##### Responsibility scope

- Execute nocode (declarative) and CDK (Python) connectors
- Manage source and destination configurations
- Discover source schemas (catalog)
- Deliver extracted records to ClickHouse via Airbyte Protocol
- Persist incremental sync state between runs
- Provide API for connection management and sync triggering

##### Responsibility boundaries

- Does NOT perform data transformation (that is dbt's responsibility)
- Does NOT schedule or orchestrate pipelines (that is Kestra's responsibility)
- Does NOT manage its own connection configurations in version control (that is Terraform's responsibility)

##### Related components (by ID)

- `cpt-insightspec-component-ing-kestra` -- Kestra triggers Airbyte syncs via API
- `cpt-insightspec-component-ing-terraform` -- Terraform manages Airbyte connections
- `cpt-insightspec-component-ing-clickhouse` -- ClickHouse is the sync destination

#### Kestra Orchestrator

- [ ] `p1` - **ID**: `cpt-insightspec-component-ing-kestra`

##### Why this component exists

Provides pipeline scheduling, task dependency management, retry handling, and execution observability. Selected over Airflow for YAML-first approach (see [ADR-0001](ADR/0001-kestra-over-airflow.md)).

##### Responsibility scope

- Schedule pipeline flows with cron expressions or event triggers
- Trigger Airbyte syncs via Airbyte API plugin
- Wait for sync completion and check status
- Trigger dbt runs via dbt CLI plugin
- Enforce task ordering (sync before transform)
- Retry failed tasks with configurable backoff
- Provide UI for monitoring and manual execution

##### Responsibility boundaries

- Does NOT execute extraction logic (Airbyte does)
- Does NOT execute transformation SQL (dbt does)
- Does NOT manage connection configurations (Terraform does)

##### Related components (by ID)

- `cpt-insightspec-component-ing-airbyte` -- triggers syncs, monitors completion
- `cpt-insightspec-component-ing-dbt` -- triggers dbt runs after sync

#### dbt-clickhouse

- [ ] `p1` - **ID**: `cpt-insightspec-component-ing-dbt`

##### Why this component exists

Transforms raw Bronze data into unified Silver step 1 tables using SQL. Each connector package includes its own dbt models.

##### Responsibility scope

- Execute Bronze-to-Silver SQL transformations
- Map source-specific fields to unified Silver schemas
- Preserve `tenant_id` in all Silver tables
- Validate data quality via dbt tests (not_null, unique, accepted_values)
- Document column definitions in schema.yml

##### Responsibility boundaries

- Does NOT extract data from external sources (Airbyte does)
- Does NOT schedule its own execution (Kestra does)
- Does NOT perform identity resolution (separate domain)

##### Related components (by ID)

- `cpt-insightspec-component-ing-kestra` -- Kestra triggers dbt runs
- `cpt-insightspec-component-ing-clickhouse` -- dbt reads from and writes to ClickHouse

#### ClickHouse Cluster

- [ ] `p1` - **ID**: `cpt-insightspec-component-ing-clickhouse`

##### Why this component exists

Analytical storage engine for all Bronze and Silver data. Provides columnar storage, shard-local tables, and `ReplacingMergeTree` for idempotent upserts.

##### Responsibility scope

- Store Bronze tables (Airbyte stream names) with source-native schema
- Store Silver tables (`class_{domain}`) with unified schema
- Provide shard-local table placement for distributed queries
- Handle record deduplication via `ReplacingMergeTree` versioning

##### Responsibility boundaries

- Does NOT manage its own schema migrations (Airbyte destination creates Bronze; dbt creates Silver)
- Does NOT provide application-level access control (handled at platform level)

##### Related components (by ID)

- `cpt-insightspec-component-ing-airbyte` -- Airbyte writes Bronze data
- `cpt-insightspec-component-ing-dbt` -- dbt reads Bronze, writes Silver

#### Terraform

- [ ] `p1` - **ID**: `cpt-insightspec-component-ing-terraform`

##### Why this component exists

Manages Airbyte connection configurations as code, enabling version control, PR review, and CI/CD deployment of pipeline configurations.

##### Responsibility scope

- Define Airbyte sources, destinations, and connections in HCL
- Apply configurations via `terraform plan` / `terraform apply`
- Manage state in remote backend (S3/GCS)
- Run in CI/CD pipelines

##### Responsibility boundaries

- Does NOT register custom connectors (Airbyte API handles registration)
- Does NOT manage Kestra flow definitions (stored as YAML in Git)
- Does NOT manage ClickHouse cluster infrastructure

##### Related components (by ID)

- `cpt-insightspec-component-ing-airbyte` -- manages Airbyte connections via API

### 3.3 API Contracts

#### Airbyte Protocol

Airbyte Protocol v2 defines structured JSON messages between connectors and the platform:
- `RECORD` -- data record with stream name and fields (including `tenant_id`)
- `STATE` -- incremental sync cursor for resumable extraction
- `LOG` -- connector execution logs
- `TRACE` -- detailed execution tracing
- `CATALOG` -- stream schema discovery results
- `SPEC` -- connector specification (configuration schema)

#### Kestra Flow YAML

Kestra flows are defined in YAML:
```yaml
id: ingest-ms365
namespace: ingestion
triggers:
  - id: schedule
    type: io.kestra.plugin.core.trigger.Schedule
    cron: "0 2 * * *"
tasks:
  - id: airbyte-sync
    type: io.kestra.plugin.airbyte.connections.Sync
    connectionId: "{{ vars.connection_id }}"
  - id: dbt-run
    type: io.kestra.plugin.dbt.cli.DbtCLI
    commands:
      - dbt run --select connectors.ms365
    dependsOn:
      - airbyte-sync
```

#### Descriptor YAML Schema

Each connector package includes `descriptor.yaml`:
```yaml
name: ms365
version: "1.0"
type: nocode
silver_targets:
  - class_comms_events
  - class_people
streams:
  - name: email_activity
    bronze_table: email_activity
    primary_key: [unique]
    cursor_field: reportRefreshDate
  - name: teams_activity
    bronze_table: teams_activity
    primary_key: [unique]
    cursor_field: reportRefreshDate
```

#### Terraform Configuration

Airbyte connections managed via Terraform:
```hcl
resource "airbyte_connection" "ms365_to_clickhouse" {
  name           = "ms365-tenant-acme"
  source_id      = airbyte_source.ms365.id
  destination_id = airbyte_destination.clickhouse.id

  configurations = {
    namespace_definition = "custom_format"
    namespace_format     = "bronze_ms365"
    streams = [
      { name = "email_activity", sync_mode = "incremental" },
      { name = "teams_activity", sync_mode = "incremental" }
    ]
  }
}
```

### 3.4 Internal Dependencies

| From | To | Mechanism |
|------|----|-----------|
| Kestra | Airbyte | REST API (trigger sync, poll status) |
| Kestra | dbt | CLI execution (dbt run) |
| Airbyte | ClickHouse | Airbyte ClickHouse destination (JDBC) |
| dbt | ClickHouse | dbt-clickhouse adapter (native protocol) |
| Terraform | Airbyte | Airbyte Terraform provider (REST API) |

### 3.5 External Dependencies

| Dependency | Version Constraint | Purpose |
|-----------|-------------------|---------|
| Airbyte Platform | Self-managed, latest stable | Connector runtime and connection management |
| Kestra | Latest stable, Apache 2.0 | Pipeline orchestration |
| dbt-clickhouse | Latest stable adapter | SQL transformations on ClickHouse |
| Terraform + airbytehq/airbyte provider | Provider >= 1.0 | Connection configuration as code |
| ClickHouse | Cluster deployment | Analytical storage |

### 3.6 Interactions & Sequences

#### Scheduled Pipeline Run

**ID**: `cpt-insightspec-seq-ing-scheduled-pipeline`

```mermaid
sequenceDiagram
    participant K as Kestra
    participant A as Airbyte
    participant S as Source API
    participant CH as ClickHouse
    participant D as dbt

    K->>A: POST /connections/{id}/sync (trigger)
    A->>S: HTTP requests (with tenant_id in config)
    S-->>A: API responses (records)
    A->>A: Add tenant_id to each record
    A->>CH: Write RECORD messages to Bronze tables
    A-->>K: Sync complete (status: succeeded)
    K->>D: dbt run --select connectors.{source}
    D->>CH: SELECT from Bronze tables
    D->>CH: INSERT INTO Silver class_{domain} tables
    D-->>K: dbt run complete
    K->>K: Mark flow execution successful
```

#### Terraform Connection Management

**ID**: `cpt-insightspec-seq-ing-terraform-apply`

```mermaid
sequenceDiagram
    participant E as Engineer
    participant G as Git / CI
    participant T as Terraform
    participant A as Airbyte API

    E->>G: Push HCL changes (PR)
    G->>T: terraform plan
    T->>A: GET current state
    T-->>G: Plan output (diff)
    E->>G: Approve & merge
    G->>T: terraform apply
    T->>A: POST/PATCH sources, destinations, connections
    A-->>T: Resources created/updated
    T-->>G: Apply complete
```

### 3.7 Database schemas & tables

#### Bronze Tables

Naming: Tables match Airbyte stream names directly (e.g., `commits`, `email_activity`). Tables are created in a namespace/database specified in the Airbyte connection configuration (managed via Terraform), such as `bronze_github` or `bronze_ms365`.

Engine: `ReplacingMergeTree(_version)` where `_version` is epoch milliseconds.

Required columns in every Bronze table:

| Column | Type | Description |
|--------|------|-------------|
| `tenant_id` | String | Tenant isolation -- injected by connector |
| `_airbyte_raw_id` | String | Airbyte deduplication key |
| `_airbyte_extracted_at` | DateTime64 | Extraction timestamp |
| `_version` | UInt64 | ReplacingMergeTree version (epoch ms) |

Shard-local tables: All Bronze tables use shard-local placement for distributed query execution.

#### Silver Step 1 Tables

Naming: `class_{domain}` (e.g., `class_commits`, `class_comms_events`, `class_people`)

Produced by dbt models. Unified schema across sources. `tenant_id` preserved from Bronze.

### 3.8 Connector Package Structure

```
src/ingestion/connectors/
  {class}/{source}/
    connector.yaml            # Nocode: Airbyte declarative manifest
    # OR for CDK:
    # src/
    #   source_{source}/
    #     __init__.py
    #     source.py
    #     schemas/
    #   setup.py
    #   Dockerfile
    descriptor.yaml            # Package metadata
    dbt/
      to_{domain}.sql          # dbt model(s) producing class_{domain} Silver tables
      schema.yml               # Column docs + tests
```

See [Airbyte Connector DESIGN](../../airbyte-connector/specs/DESIGN.md) for detailed connector development guide.

## 4. Deployment

### 4.1 Production (Kubernetes + Helm)

```
K8s Cluster
├── namespace: airbyte
│   ├── Airbyte Server (API + UI)
│   ├── Airbyte Workers (connector execution)
│   └── Temporal (internal orchestration)
├── namespace: kestra
│   ├── Kestra Server (API + UI + Scheduler)
│   └── Kestra Workers (task execution)
└── namespace: data (existing)
    └── ClickHouse Cluster (shards + replicas)
```

Key deployment decisions:
- Airbyte and Kestra in **separate namespaces** for independent lifecycle management
- External database for Kestra metadata (ClickHouse or MariaDB supported)
- External database for Airbyte metadata (PostgreSQL required by Airbyte)
- Helm charts: `airbyte/airbyte` and `kestra/kestra`
- Secrets managed via Kubernetes Secrets or external secret manager (Vault)
- Ingress for Airbyte and Kestra UIs (internal access only)

### 4.2 Local Development (Docker Compose)

Docker Compose for full-stack local development:
- Airbyte (server + worker + temporal + postgres)
- Kestra (server + worker)
- ClickHouse (single node)
- dbt runner (container with dbt-clickhouse)

This enables:
- Testing connector registration and sync execution
- Running full extract -> transform pipeline
- Debugging Kestra flows
- Validating dbt models against real data

### 4.3 Ultra-Light Connector Debugging

For rapid nocode connector iteration without the full Airbyte platform:
- Run connector Docker image directly with `source.sh`
- Commands: `check`, `discover`, `read`
- Mount custom manifest, pipe output to local destination

See [Airbyte Connector DESIGN](../../airbyte-connector/specs/DESIGN.md) for detailed debugging workflows.

## 5. Additional Context

### 5.1 Superseded Components

This design supersedes:

| Component | Document | Reason |
|-----------|----------|--------|
| Custom Orchestrator | [Orchestrator PRD](../../../components/orchestrator/specs/PRD.md) | Replaced by Kestra -- see [ADR-0001](ADR/0001-kestra-over-airflow.md) |
| Custom Connector Framework | [Connector Framework DESIGN](../../connector/specs/DESIGN.md) | Replaced by Airbyte connector runtime |
| Stdout JSON Protocol | [ADR-0001](../../connector/specs/ADR/0001-connector-integration-protocol.md) | Replaced by Airbyte Protocol |

These documents remain as historical reference. The ingestion layer is the current and forward-looking approach.

## 6. Open Questions

### OQ-ING-01: ClickHouse Destination Normalization Mode

Airbyte's ClickHouse destination supports different normalization modes (raw, basic, etc.). Which mode should be used for Bronze table creation? Does the destination correctly handle `ReplacingMergeTree` with version columns?

### OQ-ING-02: Kestra Flow Granularity

Should Kestra define one flow per connector, one flow per tenant, or one flow per (connector, tenant) pair? Trade-off between flow management overhead and execution granularity.

### OQ-ING-03: MariaDB Destination Use Cases

Which specific connectors or data types require MariaDB instead of ClickHouse as destination? This needs to be documented separately when the use cases are defined.

### OQ-ING-04: Gold Layer Ownership

Is the Gold layer part of the ingestion domain or a separate domain? Currently out of scope, but the boundary needs clarification.

### OQ-ING-05: Connector Package Versioning

How are connector packages versioned within the monorepo? Is there a version field in descriptor.yaml that gates deployment, or is Git commit the version?

## 7. Traceability

| Design Element | PRD Requirement |
|---------------|----------------|
| `cpt-insightspec-component-ing-airbyte` | `cpt-insightspec-fr-ing-airbyte-extract`, `cpt-insightspec-fr-ing-nocode-connector`, `cpt-insightspec-fr-ing-cdk-connector` |
| `cpt-insightspec-component-ing-kestra` | `cpt-insightspec-fr-ing-kestra-scheduling`, `cpt-insightspec-fr-ing-kestra-dependency`, `cpt-insightspec-fr-ing-kestra-retry` |
| `cpt-insightspec-component-ing-dbt` | `cpt-insightspec-fr-ing-dbt-bronze-to-silver`, `cpt-insightspec-fr-ing-dbt-clickhouse`, `cpt-insightspec-fr-ing-silver-unified-schema` |
| `cpt-insightspec-component-ing-clickhouse` | `cpt-insightspec-fr-ing-bronze-storage`, `cpt-insightspec-fr-ing-clickhouse-destination` |
| `cpt-insightspec-component-ing-terraform` | `cpt-insightspec-fr-ing-terraform-connections` |
| `cpt-insightspec-principle-ing-tenant-isolation` | `cpt-insightspec-fr-ing-tenant-id`, `cpt-insightspec-nfr-ing-tenant-isolation` |
| `cpt-insightspec-principle-ing-package-self-contained` | `cpt-insightspec-fr-ing-package-structure`, `cpt-insightspec-fr-ing-package-monorepo` |
| `cpt-insightspec-constraint-ing-terraform-connections` | `cpt-insightspec-fr-ing-terraform-connections`, `cpt-insightspec-fr-ing-airbyte-api-custom` |

- **PRD**: [PRD.md](PRD.md)
- **ADR-0001**: [ADR/0001-kestra-over-airflow.md](ADR/0001-kestra-over-airflow.md)
- **Airbyte Connector DESIGN**: [../../airbyte-connector/specs/DESIGN.md](../../airbyte-connector/specs/DESIGN.md)
- **Identity Resolution DESIGN**: [../../identity-resolution/specs/DESIGN.md](../../identity-resolution/specs/DESIGN.md) -- downstream consumer
