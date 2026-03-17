# PRD — Design Tools Silver Layer

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background-problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
    - [Design Team Lead](#design-team-lead)
    - [Analytics Engineer](#analytics-engineer)
    - [Workspace Administrator](#workspace-administrator)
  - [2.2 System Actors](#22-system-actors)
    - [Silver Pipeline Service](#silver-pipeline-service)
    - [Identity Manager](#identity-manager)
    - [Bronze Tables](#bronze-tables)
    - [Gold Query Layer](#gold-query-layer)
    - [Orchestration Layer](#orchestration-layer)
- [3. Operational Concept & Environment](#3-operational-concept-environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Activity Aggregation](#51-activity-aggregation)
    - [Version Activity Aggregation](#version-activity-aggregation)
    - [Comment Activity Aggregation](#comment-activity-aggregation)
    - [File Activity Counting](#file-activity-counting)
  - [5.2 Identity Resolution](#52-identity-resolution)
    - [User-to-Person Resolution](#user-to-person-resolution)
    - [Unresolvable User Handling](#unresolvable-user-handling)
    - [Unresolved Queue Reprocessing](#unresolved-queue-reprocessing)
  - [5.3 Tenant Isolation](#53-tenant-isolation)
    - [Workspace ID Injection](#workspace-id-injection)
  - [5.4 Multi-Source Support](#54-multi-source-support)
    - [Source Discriminator](#source-discriminator)
  - [5.5 Data Consistency](#55-data-consistency)
    - [Stale Record Handling](#stale-record-handling)
    - [Incremental Processing](#incremental-processing)
    - [Idempotent Transformation](#idempotent-transformation)
  - [5.6 Data Privacy](#56-data-privacy)
    - [PII Propagation Control](#pii-propagation-control)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
    - [Transformation Latency](#transformation-latency)
    - [Data Freshness](#data-freshness)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
  - [6.3 Non-Applicable Quality Domains](#63-non-applicable-quality-domains)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
    - [Silver Output Schema Interface](#silver-output-schema-interface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
    - [Bronze Tables Contract](#bronze-tables-contract)
    - [Identity Manager Contract](#identity-manager-contract)
    - [Gold Query Layer Contract](#gold-query-layer-contract)
    - [Orchestration Layer Contract](#orchestration-layer-contract)
- [8. Use Cases](#8-use-cases)
    - [Initial Silver Build from Full Bronze Snapshot](#initial-silver-build-from-full-bronze-snapshot)
    - [Incremental Daily Silver Update](#incremental-daily-silver-update)
    - [New Design Tool Source Added](#new-design-tool-source-added)
    - [Deferred Resolution of New Employee](#deferred-resolution-of-new-employee)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Design Tools Silver Layer transforms raw Bronze records from design tool connectors (Figma, and in future Sketch, Adobe XD) into a unified, person-centric activity stream. It aggregates individual version and comment records into per-person per-day activity metrics, resolves source-native user identifiers to canonical person identifiers, and enforces workspace-level tenant isolation.

The output is a unified Silver table for design activity — the single source of truth for design team productivity metrics consumed by the Gold query layer.

> **Supersedes**: This PRD replaces the former `docs/connectors/design/README.md` which described unified Bronze schemas with aggregation at collection time. That approach has been deprecated in favour of raw Bronze records with Silver-layer aggregation.

### 1.2 Background / Problem Statement

Design tool connectors (starting with Figma) store raw version and comment records in Figma-specific Bronze tables. These raw records are granular (one row per version, one row per comment) and use source-native identifiers (Figma user ID, email). They cannot be queried directly at the Gold level because:

- They lack canonical person identifiers (`person_id`) — cross-tool correlation (design ↔ git ↔ task) is impossible without identity resolution
- They lack workspace isolation (`workspace_id`) — multi-tenant access control cannot be enforced
- Activity metrics (versions per day, files edited) must be aggregated from individual records — Gold dashboards expect pre-aggregated data at the Silver level
- Multiple design tool sources will eventually write to different Bronze tables — a unified Silver table is required to present a single design activity view regardless of source

The platform's medallion architecture mandates that Bronze data is never queried at Gold level. All data must pass through Silver for identity resolution, tenant isolation, and normalization before Gold can consume it.

### 1.3 Goals (Business Outcomes)

- Design team activity is queryable at the Gold level with full identity resolution: each activity record is attributed to a canonical `person_id`, enabling cross-tool analytics (design ↔ git ↔ task tracking)
- Multi-tenant workspace isolation is enforced: users see only design activity within their permitted scope
- Adding a new design tool source (Sketch, Adobe XD) requires only a new connector and Bronze mapping — the Silver pipeline processes it without structural changes

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Silver layer | The normalized, identity-resolved, tenant-isolated data layer in the Insight medallion architecture; sits between Bronze (raw) and Gold (analytics) |
| Design activity Silver table | The unified Silver table for per-person per-day design activity metrics; concrete table name defined in DESIGN document |
| `person_id` | Canonical person identifier assigned by the Identity Manager; unique across all data sources |
| `workspace_id` | Tenant isolation key; all Silver and Gold queries are scoped by workspace |
| Identity resolution | The process of mapping source-native identifiers (email, user ID) to a canonical `person_id` via the Identity Manager |
| Bronze records | Raw version and comment records stored by design tool connectors (e.g., Figma) |
| Source discriminator | The `data_source` column that identifies which design tool produced a given Silver record (e.g., `insight_figma`) |

## 2. Actors

### 2.1 Human Actors

#### Design Team Lead

**ID**: `cpt-insightspec-actor-design-lead`

**Role**: Primary consumer of design activity analytics in Gold dashboards. Needs aggregated per-person per-day activity data with correct identity attribution.

**Needs**: Reliable daily metrics showing who is actively designing (versions), who is reviewing (comments), and which files are getting attention — all attributed to real people, not source-native IDs.

---

#### Analytics Engineer

**ID**: `cpt-insightspec-actor-analytics-engineer`

**Role**: Builds and maintains Gold-level queries and dashboards that consume the design activity Silver table. Needs a stable, well-documented Silver schema.

**Needs**: A predictable Silver table structure with clear semantics for each column; breaking changes communicated in advance.

---

#### Workspace Administrator

**ID**: `cpt-insightspec-actor-workspace-admin`

**Role**: Manages workspace configuration including which connectors feed into the Silver pipeline. Monitors pipeline health.

**Needs**: Visibility into Silver pipeline status; confidence that tenant isolation is enforced.

### 2.2 System Actors

#### Silver Pipeline Service

**ID**: `cpt-insightspec-actor-silver-pipeline`

**Role**: Scheduled ETL service that reads Bronze tables, performs identity resolution, aggregates activity records, injects workspace isolation, and writes to the design activity Silver table. Orchestrated by the platform orchestration layer.

---

#### Identity Manager

**ID**: `cpt-insightspec-actor-identity-manager`

**Role**: Platform service that maps email addresses to canonical `person_id` values. Consumed during Silver step 2 (identity resolution). Provides the person registry and alias mappings.

---

#### Bronze Tables

**ID**: `cpt-insightspec-actor-bronze-tables`

**Role**: Source data stores populated by design tool connectors. For Figma: raw version records, raw comment records, file directory, user directory. Each connector writes to its own Bronze tables.

---

#### Gold Query Layer

**ID**: `cpt-insightspec-actor-gold-query`

**Role**: Downstream consumer of the design activity Silver table. Reads Silver data exclusively — never Bronze. Enforces additional access control and serves dashboard queries.

---

#### Orchestration Layer

**ID**: `cpt-insightspec-actor-orchestrator`

**Role**: Platform orchestration service (AirByte/Dagster) that schedules and monitors Silver pipeline runs. Triggers Silver transformation after Bronze data is updated.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- The Silver pipeline runs after Bronze connectors have completed their scheduled collection; it must tolerate Bronze data arriving at different times from different connectors
- Identity resolution depends on the Identity Manager's person registry being up to date; newly onboarded employees may not be resolvable until their HR record is processed
- Workspace isolation (`workspace_id`) is injected by the Silver pipeline based on the connector instance's workspace assignment; the pipeline must never write records without a valid `workspace_id`
- The pipeline operates within ClickHouse; transformations must be expressible as SQL or dbt models

## 4. Scope

### 4.1 In Scope

- Aggregation of raw Bronze version records into per-person per-day version counts
- Aggregation of raw Bronze comment records into per-person per-day comment counts
- Computation of derived metrics (distinct files edited, distinct files with activity)
- Identity resolution: source-native user ID → email → canonical `person_id` via Identity Manager
- Workspace isolation: `workspace_id` injection based on connector instance configuration
- Multi-source support: unified Silver table accepting data from any design tool connector via `data_source` discriminator
- Handling of stale/deleted Bronze records
- Incremental and idempotent processing
- PII handling at Silver level (email not propagated; only `person_id`)

### 4.2 Out of Scope

- Bronze-level data collection (connector PRDs: Figma, future Sketch, Adobe XD)
- Bronze table schema definitions (connector DESIGN documents)
- Gold-level metrics, dashboards, and cross-domain joins (design ↔ git correlation is a Gold concern)
- Admin UI for Silver pipeline configuration
- Identity Manager implementation (separate module)
- Semantic Dictionary / Data Catalog population (handled by Unifier Schema Registry integration)

## 5. Functional Requirements

### 5.1 Activity Aggregation

#### Version Activity Aggregation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-version-agg`

The Silver pipeline **MUST** aggregate raw version records from Bronze into a count of versions created per person per day. For each unique `(person_id, date)` combination, the pipeline **MUST** produce a `versions_created` count representing the total number of file versions created by that person on that date across all files.

**Rationale**: Version creation is the primary proxy for active design editing. Per-person per-day granularity is the standard Silver aggregation level across all Insight domains.

**Actors**: `cpt-insightspec-actor-silver-pipeline`, `cpt-insightspec-actor-bronze-tables`

---

#### Comment Activity Aggregation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-comment-agg`

The Silver pipeline **MUST** aggregate raw comment records from Bronze into a count of comments posted per person per day. For each unique `(person_id, date)` combination, the pipeline **MUST** produce a `comments_posted` count representing the total number of comments posted by that person on that date across all files.

**Rationale**: Comment activity is the primary proxy for async design review and collaboration.

**Actors**: `cpt-insightspec-actor-silver-pipeline`, `cpt-insightspec-actor-bronze-tables`

---

#### File Activity Counting

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-file-count`

The Silver pipeline **MUST** compute the following derived file-level metrics per `(person_id, date)`:
- `files_edited`: count of distinct files where the person created at least one version on that date
- `files_with_activity`: count of distinct files where the person created a version or posted a comment on that date

**Rationale**: File-level counts provide a measure of breadth of design work (how many files touched) in addition to volume (total versions/comments).

**Actors**: `cpt-insightspec-actor-silver-pipeline`

### 5.2 Identity Resolution

#### User-to-Person Resolution

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-identity`

The Silver pipeline **MUST** resolve source-native user identifiers to canonical `person_id` values using a two-step process:
1. Join Bronze activity records with the Bronze user directory to obtain the user's email address
2. Map the email address to a canonical `person_id` via the Identity Manager

Email normalization (lowercase, trim whitespace) **MUST** be applied before Identity Manager lookup.

**Rationale**: Cross-tool analytics (design ↔ git ↔ task) require a single person identifier. Source-native IDs (Figma user ID) are meaningless outside their source system.

**Actors**: `cpt-insightspec-actor-silver-pipeline`, `cpt-insightspec-actor-identity-manager`

---

#### Unresolvable User Handling

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-unresolvable`

When the Silver pipeline encounters a Bronze record whose user cannot be resolved to a `person_id` (email not found in Identity Manager), it **MUST** exclude the record from the design activity Silver table and **MUST** add the record's identifying coordinates (`data_source`, `user_id`, `file_key`, `date`) to the unresolved queue. The pipeline **MUST** log the count of excluded records per run. The pipeline **MUST NOT** fail due to unresolvable users.

**Rationale**: Guest users, external collaborators, and newly onboarded employees may not yet have a person record. Excluding rather than failing ensures the pipeline continues to process resolvable records. The unresolved queue enables deferred resolution (see below).

**Actors**: `cpt-insightspec-actor-silver-pipeline`

---

#### Unresolved Queue Reprocessing

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-unresolved-queue`

The Silver pipeline **MUST** maintain an unresolved queue of Bronze records that could not be resolved to a `person_id` on their initial processing run. On each subsequent run, the pipeline **MUST** re-attempt identity resolution for all entries in the unresolved queue before processing new Bronze records. When a previously unresolvable user becomes resolvable (e.g., new employee added to Identity Manager, manual alias mapping created), the pipeline **MUST** resolve the queued records, write them to the design activity Silver table, and remove them from the queue.

The unresolved queue **MUST** store sufficient information to re-read the original Bronze records without relying on the incremental sync cursor.

Queue entries that remain unresolved for more than 90 days **SHOULD** be flagged for manual review and **MAY** be purged if confirmed as permanently unresolvable (e.g., external guest with no organisation email).

**Rationale**: The incremental sync cursor advances past unresolvable records. Without a reprocessing mechanism, activity from newly onboarded employees or manually mapped users would be permanently lost from Silver despite existing in Bronze. The unresolved queue ensures eventual consistency between Bronze and Silver.

**Actors**: `cpt-insightspec-actor-silver-pipeline`, `cpt-insightspec-actor-identity-manager`

### 5.3 Tenant Isolation

#### Workspace ID Injection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-workspace`

The Silver pipeline **MUST** assign a `workspace_id` to every record in the design activity Silver table based on the connector instance's workspace assignment. The pipeline **MUST NOT** write any record without a valid `workspace_id`. Records from connector instances with no workspace assignment **MUST** be rejected with an error.

**Rationale**: Workspace isolation is the foundation of multi-tenant access control in Insight. All Silver and Gold queries are scoped by `workspace_id`. A record without a workspace is a data governance violation.

**Actors**: `cpt-insightspec-actor-silver-pipeline`

### 5.4 Multi-Source Support

#### Source Discriminator

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-multi-source`

The Silver pipeline **MUST** include a `data_source` discriminator in every record of the design activity Silver table, indicating which design tool connector produced the source data (e.g., `insight_figma`). The pipeline **MUST** support multiple design tool sources writing to the same Silver table without schema changes. Adding a new source **MUST** require only a new Bronze-to-Silver mapping, not a schema migration.

**Rationale**: The Design Tools domain is designed for multi-source unification. Figma is the first source; Sketch and Adobe XD are planned. The Silver table must accommodate all without structural changes.

**Actors**: `cpt-insightspec-actor-silver-pipeline`

### 5.5 Data Consistency

#### Stale Record Handling

- [ ] `p2` - **ID**: `cpt-insightspec-fr-design-silver-stale-records`

The Silver pipeline **MUST** document that Bronze records for deleted Figma entities (files, users, comments) are not automatically removed. The pipeline **SHOULD** support a periodic reconciliation mechanism to detect and soft-delete Silver records whose corresponding Bronze entities no longer exist in the source system. Until reconciliation is implemented, stale records remain in Silver and contribute to activity counts.

**Rationale**: Design tool connectors do not detect deletions. Without reconciliation, activity counts may include contributions from deleted files or removed users. This is an accepted trade-off documented for transparency.

**Actors**: `cpt-insightspec-actor-silver-pipeline`

---

#### Incremental Processing

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-incremental`

The Silver pipeline **MUST** support incremental processing: only Bronze records created or updated since the last Silver run need to be transformed. The pipeline **MUST** track the last-processed Bronze timestamp to determine which records are new.

**Rationale**: Full reprocessing of all Bronze records on every run would be expensive for large tenants. Incremental processing keeps Silver transformation time proportional to new data volume.

**Actors**: `cpt-insightspec-actor-silver-pipeline`

---

#### Idempotent Transformation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-idempotent`

The Silver pipeline **MUST** produce identical results when re-run against the same Bronze input. Re-running the pipeline for a given date range **MUST NOT** produce duplicate records in the design activity Silver table.

**Rationale**: Idempotency enables safe retries after failures and ensures data consistency. It is a platform-wide requirement for all Silver pipelines.

**Actors**: `cpt-insightspec-actor-silver-pipeline`

### 5.6 Data Privacy

#### PII Propagation Control

- [ ] `p1` - **ID**: `cpt-insightspec-fr-design-silver-pii`

The Silver pipeline **MUST NOT** propagate email addresses or display names into the design activity Silver table. The only person identifier in the Silver table **MUST** be `person_id` (an opaque canonical identifier). Email is used during identity resolution but **MUST NOT** be stored in the Silver output.

**Rationale**: Minimizing PII in Silver reduces the data privacy surface. Email addresses remain in Bronze (where they are needed for identity resolution) but do not propagate to the analytics layer.

**Actors**: `cpt-insightspec-actor-silver-pipeline`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Transformation Latency

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-design-silver-latency`

The Silver pipeline **MUST** complete transformation of new Bronze records within 30 minutes of pipeline trigger.

**Threshold**: ≤30 minutes from trigger to Silver table update

**Rationale**: Design activity analytics are consumed at daily granularity. A 30-minute processing window ensures data is available well within the daily freshness target.

---

#### Data Freshness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-design-silver-freshness`

Silver data **MUST** reflect Bronze data that is no more than 1 hour old under normal operation. This means the Silver pipeline must run at least once after each Bronze connector run.

**Threshold**: Silver data ≤1 hour behind latest Bronze data

**Rationale**: Gold dashboards expect near-current data. A 1-hour lag between Bronze and Silver ensures that daily analytics reflect the latest collection run.

### 6.2 NFR Exclusions

- **Sub-second query latency**: Not applicable to the Silver pipeline itself — query performance is a Gold/ClickHouse concern
- **Real-time streaming**: Not applicable — Silver transformation is batch-oriented, triggered after Bronze collection

### 6.3 Non-Applicable Quality Domains

The following quality domains are explicitly not applicable to this Silver pipeline module:

- **Safety (ISO 25010 §4.2.9)**: Not applicable — the pipeline is a data transformation service with no physical interaction or potential for harm.
- **Usability / Interaction Capability (ISO 25010 §4.2.4)**: Not applicable — the pipeline has no user interface. It is configured via dbt models and orchestrator settings.
- **Accessibility (WCAG 2.2)**: Not applicable — no user interface.
- **Internationalization**: Not applicable — the pipeline processes machine-readable data; no human-facing text.
- **Compliance — HIPAA, PCI DSS**: Not applicable — the pipeline does not process healthcare or payment card data. GDPR applicability is addressed in section 5.6 (PII Propagation Control). Platform-level compliance (SOC 2, ISO 27001) is governed globally, not per-pipeline.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Silver Output Schema Interface

- [ ] `p1` - **ID**: `cpt-insightspec-interface-design-silver-schema`

**Type**: Data schema (Silver table structure)

**Stability**: stable

**Description**: The Silver pipeline produces data conforming to the design activity Silver table schema. The schema defines per-person per-day design activity metrics consumed by the Gold query layer.

**Breaking Change Policy**: Adding new nullable columns is non-breaking. Renaming, removing, or changing the type of existing columns is a breaking change requiring a major version bump and coordination with Gold query consumers.

### 7.2 External Integration Contracts

#### Bronze Tables Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-design-silver-bronze`

**Direction**: required from upstream (connectors)

**Protocol/Format**: Bronze tables containing raw version records, comment records, file directory, and user directory. Each connector writes to its own source-specific tables.

**Compatibility**: The Silver pipeline reads Bronze tables produced by registered design tool connectors. Adding a new connector requires a new Bronze-to-Silver mapping but no Silver schema changes.

---

#### Identity Manager Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-design-silver-identity`

**Direction**: required from platform

**Protocol/Format**: Email-to-person_id lookup via the Identity Manager's person registry and alias mappings.

**Compatibility**: The Silver pipeline depends on the Identity Manager providing up-to-date email → person_id mappings. Changes to the Identity Manager's interface would require pipeline updates.

---

#### Gold Query Layer Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-design-silver-gold`

**Direction**: provided by pipeline (downstream)

**Protocol/Format**: The design activity Silver table, queryable by workspace, person, date, and data source.

**Compatibility**: The Gold layer depends on the Silver table schema being stable. Breaking changes require advance coordination.

---

#### Orchestration Layer Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-design-silver-orchestrator`

**Direction**: required from platform

**Protocol/Format**: Orchestrator triggers Silver pipeline after Bronze collection completes. Pipeline reports completion status and row counts.

**Compatibility**: The pipeline conforms to the orchestrator's standard ETL lifecycle.

## 8. Use Cases

#### Initial Silver Build from Full Bronze Snapshot

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-design-silver-initial`

**Actor**: `cpt-insightspec-actor-analytics-engineer`

**Preconditions**:
- At least one design tool connector has completed a full Bronze sync
- Identity Manager has person records for the workspace

**Main Flow**:
1. Analytics engineer triggers full Silver build
2. Pipeline reads all Bronze version and comment records
3. Pipeline resolves user IDs to person IDs via Identity Manager
4. Pipeline aggregates into per-person per-day records
5. Pipeline injects workspace_id and writes to the design activity Silver table

**Postconditions**:
- Design activity Silver table populated with historical activity data
- Unresolvable user count logged

**Alternative Flows**:
- **Identity Manager unavailable**: Pipeline fails; no partial data written

---

#### Incremental Daily Silver Update

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-design-silver-incremental`

**Actor**: `cpt-insightspec-actor-silver-pipeline` (scheduled)

**Preconditions**:
- Initial Silver build has completed
- Bronze connectors have run since last Silver update

**Main Flow**:
1. Orchestrator triggers Silver pipeline after Bronze collection completes
2. Pipeline re-attempts identity resolution for entries in the unresolved queue; resolved entries are written to Silver and removed from the queue
3. Pipeline identifies new Bronze records created since last Silver run
4. Pipeline resolves identities and aggregates new records; unresolvable records are added to the queue
5. Pipeline upserts into the design activity Silver table

**Postconditions**:
- Silver table updated with new activity and any newly resolved deferred records
- Processing time proportional to new Bronze records plus unresolved queue size

---

#### New Design Tool Source Added

- [ ] `p3` - **ID**: `cpt-insightspec-usecase-design-silver-new-source`

**Actor**: `cpt-insightspec-actor-analytics-engineer`

**Preconditions**:
- A new design tool connector (e.g., Sketch) has been deployed and is writing to Bronze tables
- Bronze-to-Silver mapping for the new source has been defined

**Main Flow**:
1. Analytics engineer adds the new source mapping to the Silver pipeline configuration
2. Pipeline begins reading new source's Bronze tables on the next run
3. Records from the new source appear in the design activity Silver table with the appropriate `data_source` value
4. No schema migration required

**Postconditions**:
- Silver table contains data from both old and new sources
- Gold queries automatically include new source data (filtered by `data_source` if needed)

#### Deferred Resolution of New Employee

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-design-silver-deferred`

**Actor**: `cpt-insightspec-actor-silver-pipeline` (scheduled)

**Preconditions**:
- A Figma user created versions/comments last week but was not yet in the Identity Manager
- Their Bronze records were processed, excluded from Silver, and added to the unresolved queue
- The employee's HR record has now been processed by the Identity Manager and a `person_id` mapping exists

**Main Flow**:
1. Silver pipeline starts scheduled run
2. Pipeline checks unresolved queue — finds entries for this user
3. Pipeline re-attempts identity resolution — email now resolves to a `person_id`
4. Pipeline reads original Bronze records, aggregates, and writes to Silver
5. Pipeline removes resolved entries from the queue

**Postconditions**:
- The employee's historical design activity appears in Silver, attributed to their `person_id`
- No data was lost despite the delayed identity resolution
- Unresolved queue is smaller

**Alternative Flows**:
- **Still unresolvable**: Entries remain in queue for the next run
- **Entry older than 90 days**: Flagged for manual review

## 9. Acceptance Criteria

- [ ] Silver pipeline correctly aggregates raw Bronze version and comment records into per-person per-day counts
- [ ] `person_id` in Silver records matches the Identity Manager's canonical person for the corresponding email
- [ ] Every Silver record has a valid `workspace_id`; no records exist without workspace isolation
- [ ] Email addresses and display names are not present in the design activity Silver table
- [ ] Re-running the pipeline for the same date range produces identical results with no duplicates
- [ ] Incremental processing transforms only new Bronze records; processing time scales with new data, not total data
- [ ] Records from unresolvable users are excluded from Silver, added to the unresolved queue, and logged with a warning count
- [ ] When a previously unresolvable user is added to the Identity Manager, the next Silver pipeline run resolves their queued records and writes them to Silver
- [ ] Adding a Sketch or Adobe XD Bronze source requires only a new mapping — no Silver schema changes
- [ ] Silver transformation completes within 30 minutes of trigger
- [ ] Silver data is no more than 1 hour behind the latest Bronze data

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Figma Connector Bronze tables | Raw version records, comment records, file directory, user directory from the Figma connector | `p1` — primary data source for the Silver pipeline |
| Identity Manager | Person registry and email → person_id alias mappings | `p1` — identity resolution is impossible without it |
| Design domain Unifier schema | Unified field definitions and semantic metadata registered in the Unifier Schema Registry | `p1` — Silver schema must align with the registered domain |
| Orchestration Layer | Scheduling and triggering of Silver pipeline runs after Bronze collection | `p1` — pipeline cannot run in production without orchestrator |
| Workspace configuration | Mapping of connector instances to workspace IDs | `p1` — required for tenant isolation |
| ClickHouse | Storage engine for both Bronze and Silver tables | `p1` — pipeline operates within ClickHouse (SQL/dbt models) |

## 11. Assumptions

- Bronze connectors complete their scheduled runs before the Silver pipeline is triggered; the orchestrator ensures correct ordering
- The Identity Manager's person registry is reasonably up to date; newly onboarded employees may experience a delay of up to 24 hours before their activity appears in Silver
- The the design activity Silver table schema follows the same SCD (Slowly Changing Dimensions) patterns used by other Silver tables in Insight
- Bronze data is never queried directly at the Gold level; all Gold queries read exclusively from Silver tables (per CONNECTORS_ARCHITECTURE)
- Workspace assignment for connector instances is managed at the platform level and is available to the Silver pipeline at runtime
- The volume of raw Bronze records for design tools is small relative to other domains (code, communication); full reprocessing is feasible as a fallback if incremental processing fails

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Identity Manager not up to date for new employees | New designers' activity deferred to unresolved queue until their person record is created; Silver data incomplete until resolved | Unresolved queue ensures eventual resolution; 90-day TTL with manual review for permanently unresolvable entries |
| Unresolved queue grows unbounded | Large number of guest/external users fill the queue with permanently unresolvable entries, increasing reprocessing overhead | 90-day TTL with auto-flag for manual review; purge confirmed-unresolvable entries |
| Stale Bronze records from deleted Figma files/users | Silver activity counts include contributions from entities that no longer exist in Figma | Document as known limitation; implement periodic reconciliation in a future iteration |
| Multiple connectors for same workspace | If a workspace has two Figma connectors covering overlapping teams, Silver may double-count activity | Validate connector instance scopes at workspace configuration time; deduplicate on `(person_id, data_source, date)` |
| Bronze schema changes without coordination | A connector updates its Bronze schema without notifying the Silver pipeline, causing transformation failures | Bronze output schema interface (from connector PRD) mandates versioning and breaking change policy; Silver pipeline validates Bronze schema on startup |
| Silver transformation exceeds latency threshold on large tenants | Gold dashboards show stale data | Monitor transformation duration; alert on threshold breach; optimize aggregation queries if needed |
| Cross-source person_id conflicts | The same person may have different emails across design tools, leading to separate person_id values | Rely on Identity Manager's alias merging; document as a known limitation until cross-source alias resolution is implemented |
