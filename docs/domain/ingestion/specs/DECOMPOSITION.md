---
status: proposed
date: 2026-03-24
---

# Decomposition: Ingestion Layer

<!-- toc -->

- [1. Overview](#1-overview)
- [2. Entries](#2-entries)
  - [2.1 Local Infrastructure Stack — HIGH](#21-local-infrastructure-stack--high)
  - [2.2 Local Manifest Debugging — HIGH](#22-local-manifest-debugging--high)
  - [2.3 Manifest Upload Script — HIGH](#23-manifest-upload-script--high)
  - [2.4 Terraform Connection Management — HIGH](#24-terraform-connection-management--high)
  - [2.5 Kestra Orchestration — HIGH](#25-kestra-orchestration--high)
  - [2.6 dbt Project & Silver Union — HIGH](#26-dbt-project--silver-union--high)
  - [2.7 Reference Connector Package — M365 — MEDIUM](#27-reference-connector-package--m365--medium)
- [3. Feature Dependencies](#3-feature-dependencies)

<!-- /toc -->

## 1. Overview

The Ingestion Layer DESIGN is decomposed into seven features organized around deployment, tooling, and data flow concerns. The decomposition follows a dependency order: local infrastructure must exist before connectors can be tested; connectors must be registered before orchestration can run; dbt must be configured before Silver union models work.

**Decomposition Strategy**:
- Features grouped by operational boundary (infrastructure, tooling, data pipeline, configuration)
- Dependencies follow the natural setup order: infra → connectors → orchestration → transforms
- Each feature covers specific components, sequences, and requirements from DESIGN and PRD
- 100% coverage of all DESIGN elements verified
- Reference connector package (m365) serves as integration test across all features

**Key Architectural Decisions**:
- Silver layer union via dbt tags: each connector's `to_{domain}.sql` tagged with `silver:class_{domain}`, union models auto-discover by tag
- Per-tenant Terraform workspaces for connection isolation
- Per-tenant Kestra flows stored in Git, pushed via API script
- ClickHouse cluster locally (mirrors production shard-local tables)
- MariaDB as Kestra metadata backend
- Auto-initialization on `docker compose up` — no manual setup

## 2. Entries

**Overall implementation status:**

- [ ] `p1` - **ID**: `cpt-insightspec-status-overall`

### 2.1 [Local Infrastructure Stack](feature-local-infra/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-local-infra`

- **Purpose**: Provide a fully automated local development environment via Docker Compose that mirrors production topology. Running `docker compose up` creates a working instance with ClickHouse cluster, Airbyte, Kestra, MariaDB, and all initialization — no manual configuration required.

- **Depends On**: None

- **Scope**:
  - Docker Compose with all services: ClickHouse cluster (shard-local capable), Airbyte (server + worker + temporal + postgres), Kestra (server + worker + MariaDB), dbt runner
  - Init containers that create databases, register connectors, apply Terraform, load Kestra flows
  - Network configuration, health checks, volume mounts for persistence
  - Automatic registration of all connector manifests from `src/ingestion/connectors/`
  - Automatic application of all Terraform connection configs from `src/ingestion/connections/`
  - Automatic loading of all Kestra flows

- **Out of scope**:
  - Production Kubernetes Helm deployment (separate feature later)
  - CI/CD pipelines
  - Monitoring and alerting

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-airbyte-extract`
  - [ ] `p1` - `cpt-insightspec-fr-ing-clickhouse-destination`
  - [ ] `p1` - `cpt-insightspec-fr-ing-bronze-storage`
  - [ ] `p1` - `cpt-insightspec-fr-ing-bronze-schema-native`
  - [ ] `p1` - `cpt-insightspec-fr-ing-secret-management`
  - [ ] `p1` - `cpt-insightspec-nfr-ing-error-isolation`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-no-custom-runtime`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-ing-clickhouse-destination`

- **Domain Model Entities**:
  - AirbyteConnection
  - BronzeTable
  - KestraFlow

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-ing-airbyte`
  - [ ] `p1` - `cpt-insightspec-component-ing-clickhouse`
  - [ ] `p1` - `cpt-insightspec-component-ing-kestra`

- **API**:
  - Airbyte API (connector registration, connection creation)
  - Kestra API (flow upload)
  - Terraform CLI (apply)

- **Sequences**:

  (none defined — new sequence for init flow to be added)

- **Data**:

  - [ ] `p1` - `cpt-insightspec-constraint-ing-clickhouse-destination`


### 2.2 [Local Manifest Debugging](feature-local-debug/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-local-debug`

- **Purpose**: Enable rapid iteration on declarative connector manifests without the full Airbyte platform. Developer runs `source.sh check/discover/read` to validate manifests and inspect output locally.

- **Depends On**: None

- **Scope**:
  - `source.sh` script in `src/ingestion/tools/declarative-connector/` with commands: `check`, `discover`, `read`
  - Dockerfile and entrypoint.sh for wrapping `airbyte/source-declarative-manifest` image
  - Credentials via `.env.local` (AIRBYTE_CONFIG JSON)
  - Output to stdout only (no destination write)
  - Manifest validation (check command verifies manifest + credentials)
  - State management for incremental reads (state.json)

- **Out of scope**:
  - Destination write (no piping to ClickHouse/Postgres)
  - CDK connector debugging (Python)
  - Full platform integration testing

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-nocode-connector`
  - [ ] `p1` - `cpt-insightspec-fr-ing-incremental-sync`
  - [ ] `p1` - `cpt-insightspec-fr-ing-tenant-id`
  - [ ] `p1` - `cpt-insightspec-usecase-ing-local-debug`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-declarative-first`
  - [ ] `p1` - `cpt-insightspec-principle-abc-declarative-first`
  - [ ] `p1` - `cpt-insightspec-principle-abc-tenant-id-mandatory`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-abc-airbyte-protocol`

- **Domain Model Entities**:
  - DeclarativeManifest
  - ConnectorPackage

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-abc-package`

- **API**:
  - `./source.sh check {connector}`
  - `./source.sh discover {connector}`
  - `./source.sh read {connector} {connection}`

- **Sequences**:

  - `cpt-insightspec-seq-abc-ultralight-debug`
  - `cpt-insightspec-seq-abc-nocode-execution`

- **Data**:

  (none — stdout only)


### 2.3 [Manifest Upload Script](feature-manifest-upload/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-manifest-upload`

- **Purpose**: Provide a script to register or update a declarative connector manifest in a running Airbyte instance via its Public API. Used both by init containers and manually by developers.

- **Depends On**: `cpt-insightspec-feature-local-infra`

- **Scope**:
  - Script `src/ingestion/tools/upload-manifest.sh` (or similar)
  - Reads `connector.yaml` from connector package directory
  - Creates or updates source definition in Airbyte via POST/PATCH API
  - Supports all connectors in `src/ingestion/connectors/` via directory scan
  - Idempotent — safe to re-run

- **Out of scope**:
  - CDK connector registration (Docker image push)
  - Connection creation (that's Terraform — feature 4)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-nocode-connector`
  - [ ] `p2` - `cpt-insightspec-fr-ing-airbyte-api-custom`
  - [ ] `p1` - `cpt-insightspec-fr-ing-package-monorepo`
  - [ ] `p1` - `cpt-insightspec-usecase-ing-new-nocode-connector`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-declarative-first`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-ing-no-external-registry`

- **Domain Model Entities**:
  - DeclarativeManifest
  - ConnectorPackage
  - Descriptor

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-ing-airbyte`

- **API**:
  - Airbyte Public API: POST /sources, PATCH /sources/{id}
  - `./upload-manifest.sh {connector}` or `./upload-manifest.sh --all`

- **Sequences**:

  (none defined — new sequence for manifest upload to be added)

- **Data**:

  (none)


### 2.4 [Terraform Connection Management](feature-terraform-connections/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-terraform-connections`

- **Purpose**: Manage Airbyte connections (source → destination + catalog) as code via Terraform with per-tenant workspace isolation. Applying Terraform creates all necessary connections for a tenant.

- **Depends On**: `cpt-insightspec-feature-manifest-upload`

- **Scope**:
  - Terraform configuration in `src/ingestion/connections/`
  - Airbyte Terraform provider (`airbytehq/airbyte`) configuration
  - Per-tenant Terraform workspaces (`terraform workspace select tenant-{id}`)
  - Source, destination, and connection resources per tenant
  - `tenant_id` passed through connection configuration variables
  - Local state storage (for dev)
  - Apply script: `./apply-connections.sh {tenant_id}`

- **Out of scope**:
  - Remote state backend (production)
  - Custom connector registration via Terraform (API only)
  - CI/CD integration

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-terraform-connections`
  - [ ] `p1` - `cpt-insightspec-fr-ing-tenant-id`
  - [ ] `p1` - `cpt-insightspec-nfr-ing-tenant-isolation`
  - [ ] `p1` - `cpt-insightspec-usecase-ing-add-source-to-workspace`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-tenant-isolation`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-ing-terraform-connections`

- **Domain Model Entities**:
  - AirbyteConnection
  - Descriptor

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-ing-terraform`

- **API**:
  - `terraform plan` / `terraform apply`
  - `./apply-connections.sh {tenant_id}`

- **Sequences**:

  - `cpt-insightspec-seq-ing-terraform-apply`

- **Data**:

  (none — Terraform state is local)


### 2.5 [Kestra Orchestration](feature-kestra-orchestration/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-kestra-orchestration`

- **Purpose**: Configure Kestra to orchestrate the full ingestion pipeline: trigger Airbyte sync → wait for completion → run dbt transformations. Each tenant has its own set of flows. Flows are stored in Git and pushed to Kestra via API script.

- **Depends On**: `cpt-insightspec-feature-local-infra`, `cpt-insightspec-feature-terraform-connections`

- **Scope**:
  - Per-tenant Kestra flow YAML files in `src/ingestion/flows/{tenant_id}/`
  - Flow template: Airbyte sync task → dbt run task (with dependency)
  - Kestra Airbyte plugin configuration (connectionId, API token)
  - Kestra dbt plugin configuration (project path, profiles)
  - Retry policy (default + per-flow configurable)
  - Script to push flows to Kestra API: `./sync-flows.sh {tenant_id}` or `./sync-flows.sh --all`
  - Cron scheduling per flow

- **Out of scope**:
  - Event-driven triggers (webhook-based)
  - Complex DAG branching (parallel syncs)
  - Monitoring and alerting

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-kestra-scheduling`
  - [ ] `p1` - `cpt-insightspec-fr-ing-kestra-dependency`
  - [ ] `p2` - `cpt-insightspec-fr-ing-kestra-retry`
  - [ ] `p1` - `cpt-insightspec-usecase-ing-scheduled-run`
  - [ ] `p2` - `cpt-insightspec-nfr-ing-observability`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-no-custom-runtime`

- **Design Constraints Covered**:

  (none specific — Kestra is a design choice, not a constraint)

- **Domain Model Entities**:
  - KestraFlow

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-ing-kestra`

- **API**:
  - Kestra REST API: POST /flows, PUT /flows/{id}
  - `./sync-flows.sh {tenant_id}`

- **Sequences**:

  - `cpt-insightspec-seq-ing-scheduled-pipeline`

- **Data**:

  (none)


### 2.6 [dbt Project & Silver Union](feature-dbt-silver/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-dbt-silver`

- **Purpose**: Configure the dbt project for Bronze-to-Silver transformations with automatic Silver layer union. Each connector package contains `to_{domain}.sql` models tagged with `silver:class_{domain}`. Shared union models auto-discover tagged sources via Jinja macros, producing unified Silver tables incrementally.

- **Depends On**: `cpt-insightspec-feature-local-infra`

- **Scope**:
  - Root `dbt_project.yml` at `src/ingestion/dbt/`
  - `profiles.yml` for dbt-clickhouse adapter (local + production targets)
  - Per-connector dbt models in `src/ingestion/connectors/{class}/{source}/dbt/to_{domain}.sql`
  - Tag convention: `silver:class_{domain}` on each connector model
  - Shared union models in `src/ingestion/dbt/silver/class_{domain}.sql` — auto-discover by tag via Jinja macro
  - `schema.yml` with `not_null` test on `tenant_id` for all Silver tables
  - Materialization strategy for Silver tables (incremental on ClickHouse)
  - ClickHouse engine settings (ReplacingMergeTree, ORDER BY, PARTITION BY)
  - Shared macros: tag-based union, `tenant_id` validation

- **Out of scope**:
  - Gold layer transformations
  - Identity resolution (Silver step 2)
  - dbt Cloud integration

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-dbt-bronze-to-silver`
  - [ ] `p1` - `cpt-insightspec-fr-ing-dbt-clickhouse`
  - [ ] `p1` - `cpt-insightspec-fr-ing-silver-unified-schema`
  - [ ] `p1` - `cpt-insightspec-fr-ing-tenant-id`
  - [ ] `p1` - `cpt-insightspec-nfr-ing-idempotency`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-silver-at-design-time`
  - [ ] `p1` - `cpt-insightspec-principle-abc-silver-targets-known`
  - [ ] `p1` - `cpt-insightspec-principle-ing-package-self-contained`
  - [ ] `p1` - `cpt-insightspec-principle-abc-package-self-contained`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-ing-monorepo`

- **Domain Model Entities**:
  - DbtModels
  - SilverTable
  - BronzeTable
  - Descriptor

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-ing-dbt`

- **API**:
  - `dbt run --select tag:silver`
  - `dbt test --select tag:silver`

- **Sequences**:

  (dbt execution is part of `cpt-insightspec-seq-ing-scheduled-pipeline`)

- **Data**:

  - [ ] `p1` - `cpt-insightspec-constraint-ing-clickhouse-destination`


### 2.7 [Reference Connector Package — M365](feature-ref-m365/) — MEDIUM

- [ ] `p2` - **ID**: `cpt-insightspec-feature-ref-m365`

- **Purpose**: Provide a complete, working connector package for Microsoft 365 (email activity + teams activity) as the reference implementation. Demonstrates all packaging conventions: declarative manifest with `tenant_id` injection, descriptor YAML, dbt models with Silver tags, and integration with the full pipeline.

- **Depends On**: `cpt-insightspec-feature-local-debug`, `cpt-insightspec-feature-dbt-silver`

- **Scope**:
  - `src/ingestion/connectors/collaboration/m365/connector.yaml` — declarative manifest (OAuth2, pagination, incremental, `tenant_id` via AddFields)
  - `src/ingestion/connectors/collaboration/m365/descriptor.yaml` — package metadata (silver_targets, streams)
  - `src/ingestion/connectors/collaboration/m365/dbt/to_comms_events.sql` — Bronze → Silver transform with `silver:class_comms_events` tag
  - `src/ingestion/connectors/collaboration/m365/dbt/schema.yml` — column docs + tests
  - `src/ingestion/connectors/collaboration/m365/.env.local.example` — credential template
  - Terraform connection config for m365
  - Kestra flow template for m365

- **Out of scope**:
  - Other connectors (GitHub, GitLab, Jira, etc.)
  - CDK connector examples

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-ing-package-structure`
  - [ ] `p1` - `cpt-insightspec-fr-ing-nocode-connector`
  - [ ] `p1` - `cpt-insightspec-fr-ing-tenant-id`
  - [ ] `p1` - `cpt-insightspec-fr-ing-incremental-sync`
  - [ ] `p1` - `cpt-insightspec-usecase-ing-new-nocode-connector`
  - [ ] `p1` - `cpt-insightspec-contract-ing-airbyte-protocol`
  - [ ] `p1` - `cpt-insightspec-contract-ing-dbt-contracts`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-ing-declarative-first`
  - [ ] `p1` - `cpt-insightspec-principle-ing-package-self-contained`
  - [ ] `p1` - `cpt-insightspec-principle-abc-tenant-id-mandatory`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-abc-airbyte-protocol`
  - [ ] `p1` - `cpt-insightspec-constraint-abc-monorepo`
  - [ ] `p1` - `cpt-insightspec-constraint-ing-monorepo`

- **Domain Model Entities**:
  - ConnectorPackage
  - DeclarativeManifest
  - Descriptor
  - DbtModels

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-abc-package`
  - [ ] `p1` - `cpt-insightspec-component-ing-airbyte`
  - [ ] `p1` - `cpt-insightspec-component-ing-dbt`

- **API**:
  - All connector commands (check, discover, read)
  - dbt run/test for m365 models

- **Sequences**:

  - `cpt-insightspec-seq-abc-nocode-execution`

- **Data**:

  - [ ] `p1` - `cpt-insightspec-contract-ing-dbt-contracts`


---

## 3. Feature Dependencies

```text
cpt-insightspec-feature-local-infra
    ↓
    ├─→ cpt-insightspec-feature-manifest-upload
    │       ↓
    │       └─→ cpt-insightspec-feature-terraform-connections
    │               ↓
    │               └─→ cpt-insightspec-feature-kestra-orchestration
    ├─→ cpt-insightspec-feature-dbt-silver
    │       ↓
    │       └─→ cpt-insightspec-feature-ref-m365
    └─→ (none)

cpt-insightspec-feature-local-debug  (independent — no platform dependency)
    ↓
    └─→ cpt-insightspec-feature-ref-m365
```

**Dependency Rationale**:

- `cpt-insightspec-feature-manifest-upload` requires `cpt-insightspec-feature-local-infra`: needs a running Airbyte instance to upload manifests to
- `cpt-insightspec-feature-terraform-connections` requires `cpt-insightspec-feature-manifest-upload`: connections reference source definitions that must be registered first
- `cpt-insightspec-feature-kestra-orchestration` requires `cpt-insightspec-feature-local-infra` and `cpt-insightspec-feature-terraform-connections`: flows trigger syncs on existing connections
- `cpt-insightspec-feature-dbt-silver` requires `cpt-insightspec-feature-local-infra`: dbt needs ClickHouse to be running
- `cpt-insightspec-feature-ref-m365` requires `cpt-insightspec-feature-local-debug` and `cpt-insightspec-feature-dbt-silver`: reference package needs both debugging tools and dbt project structure
- `cpt-insightspec-feature-local-debug` is independent — runs standalone Docker containers without the platform

**Parallel tracks**:
- Track A (platform): local-infra → manifest-upload → terraform-connections → kestra-orchestration
- Track B (data): local-infra → dbt-silver → ref-m365
- Track C (standalone): local-debug → ref-m365
