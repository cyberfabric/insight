---
status: proposed
date: 2026-03-27
decision-makers: antonz
---

# ADR-0002: Connector Responsibility Scope — Thin Extractor vs Smart Connector

**ID**: `cpt-insightspec-adr-connector-responsibility-scope`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Option 1: Thin Extractor (Airbyte-style)](#option-1-thin-extractor-airbyte-style)
  - [Option 2: Smart Connector (Extract + Transform + Load)](#option-2-smart-connector-extract--transform--load)
  - [Option 3: Bronze-Aware Extractor](#option-3-bronze-aware-extractor)
  - [Option 4: Plugin in Host Process (gRPC/IPC)](#option-4-plugin-in-host-process-grpcipc)
  - [Option 5: Sidecar Pattern](#option-5-sidecar-pattern)
- [More Information](#more-information)
  - [Comparison Matrix](#comparison-matrix)
  - [Why Not Smart Connector?](#why-not-smart-connector)
  - [Relationship to ADR-0001](#relationship-to-adr-0001)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The Insight platform needs connectors that extract data from external sources (Bitbucket, GitHub, Jira, Slack, etc.) and deliver it for analytical processing. ADR-0001 established that connectors communicate via stdout protocol (JSON-per-line). This ADR addresses a higher-level question: **how much work should a connector do?**

At one extreme, a connector is a thin extractor — it pulls raw API data and emits it to stdout with no transformation. At the other extreme, a connector is a "smart" pipeline that extracts data, writes it to Bronze tables, enriches it, resolves identities, and writes the result to Silver tables. Between these extremes lie several hybrid approaches.

The choice affects connector complexity, testability, operational flexibility, team velocity, and the ability to evolve the data pipeline without redeploying connectors.

## Decision Drivers

* Connectors are written by multiple teams in multiple languages — complexity should be minimized to lower the authoring barrier
* The platform must support 20+ source systems — each additional responsibility in the connector multiplies across all connectors
* Data transformations (schema mapping, identity resolution, enrichment) evolve independently of extraction logic — coupling them creates deployment bottleneck
* The platform uses a Medallion architecture (Bronze → Silver → Gold) — the boundary between extraction and transformation must be clear
* Operational teams need the ability to replay, backfill, and reprocess data without re-extracting from source APIs (which may rate-limit or have retention windows)
* Source APIs have different rate limits, pagination patterns, and auth mechanisms — connectors must handle these without being burdened by downstream concerns
* ADR-0001 already established stdout JSON-per-line as the delivery protocol — the chosen approach must be compatible with this

## Considered Options

1. **Thin Extractor (Airbyte-style)** — connector extracts raw data from source API, emits RECORD/STATE/LOG messages to stdout. Zero database dependencies. An orchestrator routes records to Bronze tables. dbt handles all transformations (Bronze → Silver → Gold).
2. **Smart Connector (Extract + Transform + Load)** — connector extracts data, transforms it to the unified Silver schema, resolves identities, and writes directly to Silver tables. Bronze is optional (API cache only).
3. **Bronze-Aware Extractor** — connector extracts data AND writes directly to Bronze tables (requires DB connection), but does not transform. dbt handles Silver.
4. **Plugin in Host Process (gRPC/IPC)** — connector runs as a plugin within a shared host process, communicating via gRPC or shared memory. Host provides common services (DB access, caching, identity resolution).
5. **Sidecar Pattern** — connector runs as a standalone extractor (stdout), but a co-deployed sidecar process handles Bronze writes, basic enrichment, and state management. Connector and sidecar communicate via stdout/stdin pipe.

## Decision Outcome

Chosen option: **Option 1 — Thin Extractor (Airbyte-style)**, because it is the only option that achieves all decision drivers simultaneously: minimal connector complexity, clear separation of extraction from transformation, independent evolution of pipeline stages, full replay/backfill capability from Bronze, and compatibility with the stdout protocol established in ADR-0001.

The connector's sole job is to extract data from the source API and emit it as structured RECORD messages to stdout. The orchestrator (runner) consumes stdout, routes records to Bronze tables, and persists STATE for incremental sync. All transformations — schema mapping to the unified model, identity resolution, enrichment, deduplication — are dbt's responsibility in the Silver and Gold layers.

**Bronze queryability**: Every connector MUST emit a set of platform-defined top-level fields in each RECORD alongside the full raw payload (`_raw_data`). These fields enable basic Bronze-level queries (time-range filtering, entity lookup, user filtering) without JSON parsing.

The exact field list is **not defined by this ADR** — it will be specified in the Connector Framework specification (e.g., a `connector-record-schema.yaml` or similar). Candidate fields include `timestamp`, `entity_id`, `author_id`, `instance_name`, but the authoritative list is a platform-level decision that applies uniformly to all connectors.

Key constraints on this mechanism:
- The set of required fields is **platform-defined, not connector-defined** — every connector extracts the same fields, preventing per-connector drift
- The field list is **declarative** — connectors read it from a shared schema definition, not hardcoded
- The raw JSON is **always preserved** in `_raw_data` — extracted fields are a queryability convenience, not a replacement for the full payload
- This is **not transformation** — the connector maps source fields to platform-defined Bronze columns; it does not derive, compute, or enrich values

Each connector instance is identified by an `instance_name` embedded in stream names (`bitbucket_{instance}_{stream}`), enabling multiple instances per source system with separate Bronze tables and no orchestrator-side routing complexity.

### Consequences

* Good, because connector authors focus exclusively on extraction — understanding the source API is the only prerequisite
* Good, because the same raw Bronze data can be re-transformed when dbt models change, without re-extracting from the source
* Good, because rate-limited APIs are called once — all downstream processing works from Bronze
* Good, because connectors have zero database dependencies — no connection strings, no drivers, no schema knowledge
* Good, because connectors are trivially testable — run the binary, capture stdout, assert on RECORD messages
* Good, because transformation logic (dbt) can be changed, tested, and deployed independently of connectors
* Good, because identity resolution can be improved globally (all sources) by updating dbt models, without touching any connector
* Good, because multi-instance support is trivial — different `instance_name` = different stream names = different Bronze tables
* Neutral, because raw Bronze data is larger than pre-transformed Silver data — storage cost is higher but storage is cheap
* Bad, because every record goes through two serialization hops: connector → JSON stdout → orchestrator → Bronze table → dbt → Silver table — adds latency
* Good, because Bronze tables are queryable without JSON parsing — connectors MUST extract a platform-defined set of top-level fields alongside raw JSON
* Neutral, because the platform-defined field list adds a shared dependency — but it is declarative (schema file), not code, and changes apply uniformly across all connectors
* Bad, because data freshness in Silver depends on both connector sync schedule AND dbt run schedule — two schedules to coordinate instead of one

### Confirmation

Confirmed when:

- A connector implementation (e.g., Bitbucket Server) emits only RECORD, STATE, and LOG messages to stdout with zero database imports or connection logic in its codebase
- The same Bronze data produces correct Silver output after a dbt model change without re-running the connector
- Two connector instances against the same Bitbucket Server (different project scopes) produce records on separate streams (`bitbucket_team_alpha_commits`, `bitbucket_team_beta_commits`) that the orchestrator routes to separate Bronze tables

## Pros and Cons of the Options

### Option 1: Thin Extractor (Airbyte-style)

Connector extracts raw data from the source API and emits structured JSON messages (RECORD, STATE, LOG) to stdout. It has no database dependency, no transformation logic, and no knowledge of the Bronze/Silver schema. An orchestrator reads stdout and routes records to Bronze tables. All transformations are handled by dbt downstream.

**Industry precedent**: Airbyte, Singer/Meltano, Fivetran SDK, dlt, PipelineWise.

* Good, because minimal connector complexity — typically 500-2000 lines of extraction logic per source
* Good, because language-agnostic — any language that writes JSON to stdout works (aligns with ADR-0001)
* Good, because full replay/backfill from Bronze — source API is called once, all reprocessing uses stored data
* Good, because transformation changes don't require connector redeployment
* Good, because connectors can be tested in isolation — no database, no infrastructure, just stdin/stdout
* Good, because multi-instance is trivial via stream naming (`{source}_{instance}_{stream}`)
* Good, because battle-tested pattern — Airbyte has 400+ connectors using this exact approach
* Good, because Bronze is queryable — connectors emit platform-defined top-level fields alongside raw JSON; no JSON parsing needed for common queries
* Neutral, because raw data in Bronze is denormalized and source-specific — full transformation to unified schema still requires dbt
* Bad, because two-hop latency — data must pass through Bronze before Silver is available
* Bad, because two schedules to manage — connector sync + dbt run (can be automated via orchestrator triggers)
* Bad, because Bronze storage cost is higher — raw JSON is larger than pre-transformed columnar data

### Option 2: Smart Connector (Extract + Transform + Load)

Connector extracts data from the source API, transforms it to the unified Silver schema (field mapping, state normalization, identity resolution), and writes directly to Silver tables. The connector owns a database connection and knows the target schema. Bronze may exist as an optional API cache.

**Industry precedent**: Traditional ETL tools (Informatica, Talend), some internal data platforms.

* Good, because data arrives in Silver ready to query — no dbt step needed for basic analytics
* Good, because single schedule — connector run produces queryable data immediately
* Good, because no Bronze storage overhead — data goes directly to the final form
* Bad, because connector complexity is 5-10x higher — each connector must implement field mapping, identity resolution, schema management, DB connection pooling, transaction handling
* Bad, because schema changes require redeploying ALL connectors — the Silver schema is compiled into each connector
* Bad, because identity resolution logic is duplicated across connectors (or requires a shared SDK — see ADR-0001's rejection of this approach)
* Bad, because connectors need database credentials — expanded security blast radius
* Bad, because no replay from raw data — if transformation logic was wrong, you must re-extract from the source API (which may rate-limit or have data retention limits)
* Bad, because testing requires a running database — can't test extraction logic in isolation
* Bad, because multi-instance requires each connector to manage its own table routing — significant complexity
* Bad, because a bug in transformation logic in one connector corrupts Silver data with no Bronze safety net

### Option 3: Bronze-Aware Extractor

Connector extracts data from the source API and writes raw records directly to Bronze tables (requires DB connection). It does not transform data. dbt handles Bronze → Silver transformation. The connector manages its own state in the database.

**Industry precedent**: Some Airbyte destinations write directly; custom internal pipelines.

* Good, because one fewer hop than Option 1 — connector writes Bronze directly without an orchestrator relay
* Good, because connector can read its own state from the database — no separate state mechanism needed
* Good, because dbt handles all transformations (same as Option 1)
* Bad, because connectors need database credentials and drivers — violates the language-agnostic principle from ADR-0001
* Bad, because connectors need to know Bronze table schemas — schema changes require connector updates
* Bad, because different databases require different drivers — a ClickHouse connector is different from a PostgreSQL connector
* Bad, because connector testing requires a running database
* Bad, because multi-instance requires connectors to manage table naming conventions — added complexity
* Bad, because connector failures can leave partial writes in Bronze — requires transaction management or idempotent upsert logic in the connector

### Option 4: Plugin in Host Process (gRPC/IPC)

Connector runs as a plugin within a shared host process. The host provides common services: database access, caching, identity resolution, state management. Connectors communicate with the host via gRPC, shared memory, or language-native plugin API.

**Industry precedent**: Cloudquery (Go plugins via gRPC), Telegraf (Go plugin model), Grafana data sources.

* Good, because shared services (DB, cache, identity) are provided once — connectors don't reimplement them
* Good, because strong typing via gRPC/protobuf — schema mismatches caught at compile time
* Good, because potentially lower latency — no process spawn overhead, no JSON serialization
* Bad, because plugins must be written in the host language or use FFI — violates the multi-language requirement
* Bad, because plugin crashes can destabilize the host process — reduced isolation compared to subprocess model
* Bad, because gRPC/IPC adds operational complexity — protocol buffers, service discovery, version management
* Bad, because plugin model is less portable — can't run a connector as a standalone CLI tool for testing
* Bad, because Cloudquery's experience shows this model works well for Go-only ecosystems but creates friction in polyglot environments

### Option 5: Sidecar Pattern

Connector runs as a standalone thin extractor (stdout), but a co-deployed sidecar process handles Bronze writes, basic enrichment, and state management. Connector pipes stdout to the sidecar. The sidecar is a shared component deployed alongside every connector.

**Industry precedent**: Kubernetes sidecar pattern, Envoy proxy model, some Airbyte destination implementations.

* Good, because connector remains thin and language-agnostic (stdout)
* Good, because sidecar can provide common services (Bronze write, state read/write) without coupling to the connector
* Good, because sidecar can be updated independently of connectors
* Neutral, because this is effectively Option 1 with the orchestrator/runner co-located — architecturally similar
* Bad, because two processes per connector — operational overhead (deployment, monitoring, resource allocation)
* Bad, because sidecar-connector communication adds a failure mode — pipe breaks, sidecar crashes
* Bad, because the sidecar needs database drivers and credentials — same security concern as Option 3, just moved to a different process
* Bad, because in practice, this converges to the runner/orchestrator model from Option 1 — the sidecar IS the runner

## More Information

### Comparison Matrix

| Criterion | Thin Extractor | Smart Connector | Bronze-Aware | Plugin (gRPC) | Sidecar |
|-----------|:-:|:-:|:-:|:-:|:-:|
| Connector complexity | Low | High | Medium | Medium | Low |
| Language-agnostic | Yes | No (needs DB driver) | No (needs DB driver) | No (host language) | Yes |
| Replay from Bronze | Yes | No | Yes | Depends | Yes |
| Independent transform evolution | Yes | No | Yes | Partial | Yes |
| Testing without infrastructure | Yes | No | No | No | Yes |
| Multi-instance simplicity | High (stream naming) | Low | Low | Medium | High |
| Data freshness latency | Higher (2-hop) | Lowest (direct) | Medium (1-hop) | Lowest | Higher (2-hop) |
| Connector author barrier | Lowest | Highest | Medium | Medium | Lowest |
| Existing industry adoption | Highest | Legacy | Niche | Growing (Go) | Emerging |

### Why Not Smart Connector?

The "smart connector" approach seems appealing because it delivers queryable data immediately. However, at scale (20+ sources, multiple teams, multiple languages), the costs dominate:

- **Transformation logic duplication**: Identity resolution, field normalization, and schema mapping must be reimplemented in every connector in every language. A bug in one connector's mapping produces incorrect data silently.
- **No safety net**: Without Bronze, a transformation bug means re-extracting from the source API — which may be slow, rate-limited, or have already purged the data.
- **Deployment coupling**: A Silver schema change forces redeployment of all connectors simultaneously. With thin extractors, only dbt models need updating.
- **The Bitbucket lesson**: The Bitbucket Server connector was originally designed as a smart connector (v1.0 DESIGN) — it included `FieldMapper`, `IdentityResolver`, and direct Silver table writes. Refactoring to a thin extractor (v2.0 DESIGN) reduced the component count from 5 to 2 and eliminated all database dependencies.

### Relationship to ADR-0001

ADR-0001 decided the **delivery mechanism** (stdout JSON-per-line protocol). This ADR decides the **responsibility scope** (what the connector does before emitting to stdout). Together they define the connector architecture: a thin, language-agnostic subprocess that extracts raw data and emits it as structured messages, with all downstream processing handled by the orchestrator (routing) and dbt (transformation).

## Traceability

- **Domain DESIGN**: [Connector Framework DESIGN](../DESIGN.md)
- **ADR-0001**: [Stdout Protocol](./0001-connector-integration-protocol.md)
- **Bitbucket PRD**: [PRD v1.3](../../../components/connectors/git/bitbucket-server/specs/PRD.md)
- **Bitbucket DESIGN**: [DESIGN v2.0](../../../components/connectors/git/bitbucket-server/specs/DESIGN.md)

This decision directly addresses the following requirements and design elements:

* `cpt-insightspec-nfr-bb-schema-compliance` — Connector emits RECORD messages; does not own Bronze/Silver schemas
* `cpt-insightspec-constraint-bb-stdout-only` — Connector has no database dependencies; stdout is the only output channel
* `cpt-insightspec-principle-bb-unified-schema` — Unified Silver schema is dbt's responsibility, not the connector's
* `cpt-insightspec-principle-bb-incremental` — STATE messages enable incremental sync without connector-owned state storage
* `cpt-insightspec-adr-connector-integration-protocol` — This ADR builds on the stdout protocol decision, defining what flows through it
