# PRD — Figma Connector

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background-problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
    - [Workspace Administrator](#workspace-administrator)
    - [Design Team Lead](#design-team-lead)
  - [2.2 System Actors](#22-system-actors)
    - [Figma Connector Service](#figma-connector-service)
    - [Identity Manager](#identity-manager)
    - [Figma REST API](#figma-rest-api)
    - [Orchestration Layer](#orchestration-layer)
    - [Unifier Schema Registry](#unifier-schema-registry)
- [3. Operational Concept & Environment](#3-operational-concept-environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Authentication & Configuration](#51-authentication-configuration)
    - [Personal Access Token Authentication](#personal-access-token-authentication)
    - [OAuth 2.0 Authentication](#oauth-20-authentication)
    - [Team ID Configuration](#team-id-configuration)
  - [5.2 Data Collection — File & Project Directory](#52-data-collection-file-project-directory)
    - [Project Enumeration](#project-enumeration)
    - [File Enumeration](#file-enumeration)
  - [5.3 Data Collection — User Directory](#53-data-collection-user-directory)
    - [Team Member Collection](#team-member-collection)
  - [5.4 Data Collection — Activity Records](#54-data-collection-activity-records)
    - [Version History Collection](#version-history-collection)
    - [Comment Collection](#comment-collection)
    - [Deleted Data Handling](#deleted-data-handling)
  - [5.5 Incremental Sync](#55-incremental-sync)
    - [Cursor-Based Incremental Collection](#cursor-based-incremental-collection)
  - [5.6 Rate Limit Handling](#56-rate-limit-handling)
    - [Rate Limit Compliance](#rate-limit-compliance)
  - [5.7 Collection Run Logging](#57-collection-run-logging)
    - [Run Metadata Recording](#run-metadata-recording)
  - [5.8 Error Handling](#58-error-handling)
    - [Authentication Failure Detection](#authentication-failure-detection)
    - [Unresolvable User Handling](#unresolvable-user-handling)
  - [5.9 Data Privacy & Content Boundaries](#59-data-privacy-content-boundaries)
    - [Metadata-Only Collection](#metadata-only-collection)
    - [PII Handling](#pii-handling)
  - [5.10 Data Integrity](#510-data-integrity)
    - [Idempotent Collection](#idempotent-collection)
    - [Partial Failure Handling](#partial-failure-handling)
  - [5.11 Platform Integration](#511-platform-integration)
    - [Connector Contract Compliance](#connector-contract-compliance)
    - [Design Domain Registration](#design-domain-registration)
    - [Semantic Metadata Provision](#semantic-metadata-provision)
    - [Orchestration Layer Registration](#orchestration-layer-registration)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
    - [Rate Limit Safety Margin](#rate-limit-safety-margin)
    - [Large Team Scalability](#large-team-scalability)
    - [Collection Cadence](#collection-cadence)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
  - [6.3 Non-Applicable Quality Domains](#63-non-applicable-quality-domains)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
    - [Connector Configuration Interface](#connector-configuration-interface)
    - [Bronze Output Schema Interface](#bronze-output-schema-interface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
    - [Figma REST API Contract](#figma-rest-api-contract)
    - [Identity Manager Contract](#identity-manager-contract)
    - [Connector Contract](#connector-contract)
    - [Orchestration Layer Contract](#orchestration-layer-contract)
    - [Unifier Schema Registry Contract](#unifier-schema-registry-contract)
- [8. Use Cases](#8-use-cases)
    - [Initial Full Sync of Figma Team](#initial-full-sync-of-figma-team)
    - [Incremental Daily Collection](#incremental-daily-collection)
    - [OAuth Token Refresh Failure](#oauth-token-refresh-failure)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Figma Connector collects design team activity data from Figma and stores it in the Insight Bronze layer. It provides visibility into how designers collaborate — who edits files, who comments on designs, and which projects are active — enabling productivity and collaboration analytics downstream.

This connector is the first implementation in a new **Design Tools** connector class — a domain not yet registered in the Insight Unifier Schema Registry. It requires the registration of a new "design" domain alongside the existing domains (code, task, communication, organization, ai_tools, quality). The connector populates Figma-specific Bronze tables with raw data from the Figma API. Unification across design tool sources (Figma, Sketch, Adobe XD) happens at the Silver layer.

### 1.2 Background / Problem Statement

Design team activity is currently invisible to engineering and product leadership in Insight. Figma is the primary design tool across Constructor's customer organisations, but there is no automated way to answer questions like "which design files saw the most collaboration this sprint?" or "which designers are actively contributing to project X?"

Unlike git-based tools, Figma does not provide a native activity feed. Activity must be inferred from version history (proxy for editing) and comments (proxy for design review). The connector collects these raw records into Bronze; aggregation into per-user per-file per-day activity happens at the Silver layer.

The standard Figma REST API is available on all paid plans (Starter, Professional, Organisation). The Enterprise Analytics API, which provides richer per-user activity data, has no public REST endpoint as of March 2026. The connector must work within the constraints of the standard API.

### 1.3 Goals (Business Outcomes)

- Workspace administrators can configure Figma collection for one or more teams in under 5 minutes using either PAT or OAuth credentials
- Design team activity (versions created, comments posted) is collected daily and available for Silver/Gold analytics
- Activity data is attributable to individual designers via email-based identity resolution, enabling cross-tool correlation (design ↔ git ↔ task tracking)

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Team | Top-level organisational unit in Figma; the connector is scoped to one or more teams |
| Project | A grouping of files within a Figma team |
| File | A single design document in Figma, identified by a unique key |
| Version | A named or auto-generated save point in a Figma file's history; the primary signal for editing activity |
| PAT | Personal Access Token — a user-scoped API credential generated in Figma account settings |
| Bronze layer | The raw data landing zone in the Insight medallion architecture; stores source-specific data before unification |
| Activity inference | The process of deriving per-user per-file per-day activity metrics from raw version history and comment records; performed at the Silver layer since Figma has no native activity feed |

## 2. Actors

### 2.1 Human Actors

#### Workspace Administrator

**ID**: `cpt-insightspec-actor-workspace-admin`

**Role**: Configures the Figma connector instance — provides credentials, selects team IDs, and monitors collection status. Responsible for ensuring valid authentication remains in place.

**Needs**: Simple configuration with clear feedback on collection success/failure; ability to add or remove team IDs without re-creating the connector.

---

#### Design Team Lead

**ID**: `cpt-insightspec-actor-design-lead`

**Role**: End consumer of design activity analytics in Silver/Gold dashboards. Does not interact with the connector directly, but their needs drive what data the connector must collect.

**Needs**: Visibility into team design activity — who is editing which files, comment volume as a proxy for design review engagement, active vs. idle files.

### 2.2 System Actors

#### Figma Connector Service

**ID**: `cpt-insightspec-actor-figma-connector`

**Role**: Scheduled service that authenticates against the Figma API, iterates configured teams, collects file/user/activity data, aggregates activity records, and writes results to Bronze tables.

---

#### Identity Manager

**ID**: `cpt-insightspec-actor-identity-manager`

**Role**: External system (defined in Identity Resolution spec) that maps email addresses to canonical person identifiers at the Silver layer. Read-only downstream dependency.

---

#### Figma REST API

**ID**: `cpt-insightspec-actor-figma-api`

**Role**: External API provided by Figma that exposes team, project, file, member, version, and comment data. Rate-limited per authentication token.

---

#### Orchestration Layer

**ID**: `cpt-insightspec-actor-orchestrator`

**Role**: Platform orchestration service (AirByte/Dagster) that schedules, triggers, and monitors connector runs. The Figma connector is registered and executed by this layer.

---

#### Unifier Schema Registry

**ID**: `cpt-insightspec-actor-schema-registry`

**Role**: Platform service that maintains unified domain schemas with semantic metadata. The Figma connector must register its field mappings and semantic annotations in this registry to enable downstream Data Catalog and Semantic Dictionary propagation.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Figma REST API enforces per-token rate limits; the connector must pace its requests accordingly
- The API provides no server-side date filtering on version history or comments; incremental sync must be implemented client-side
- OAuth tokens have a finite lifetime; the connector must store and refresh tokens automatically
- Guest and external collaborators may not have their email exposed by the team members endpoint; activity from these users cannot be attributed

## 4. Scope

### 4.1 In Scope

- Authentication via Personal Access Token (PAT) or OAuth 2.0
- Collection of Figma team projects and files
- Collection of Figma team members with email for identity resolution
- Collection of raw version history and comment records (aggregation into per-user per-file per-day activity is a Silver-layer concern)
- Metadata-only collection — no user-generated content (comment text, design content) is stored
- Incremental sync to avoid re-processing previously collected data
- Idempotent collection with safe partial failure recovery
- Rate limit handling with backoff
- Collection run logging for observability
- Error handling for authentication failures and unresolvable users
- Conformance to platform Connector Contract, Unifier Schema Registry, and Orchestration Layer

### 4.2 Out of Scope

- Figma Enterprise Analytics API integration (no public REST endpoint available as of March 2026; file view counts will not be collected)
- Sketch or Adobe XD connector implementations (planned separately under the Design Tools domain)
- Activity aggregation (per-user per-file per-day counts derived from raw version and comment records — performed at the Silver layer, not in the connector)
- Other Silver/Gold transformation logic (identity resolution, workspace isolation — handled by the Silver layer pipeline)
- Webhook-based real-time collection (future consideration; current model is scheduled batch)
- Figma file content extraction or design token analysis
- Admin UI for connector configuration (separate deliverable)

## 5. Functional Requirements

### 5.1 Authentication & Configuration

#### Personal Access Token Authentication

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-pat-auth`

The connector **MUST** support authentication via Figma Personal Access Token. The connector **MUST** validate the token on startup and **MUST** fail with a clear error if the token is invalid or expired.

**Rationale**: PAT is the simplest authentication method and required for non-OAuth deployments.

**Actors**: `cpt-insightspec-actor-workspace-admin`, `cpt-insightspec-actor-figma-connector`

---

#### OAuth 2.0 Authentication

- [ ] `p2` - **ID**: `cpt-insightspec-fr-figma-oauth`

The connector **MUST** support authentication via OAuth 2.0. The connector **MUST** store the refresh token securely and **MUST** automatically renew the access token before it expires.

**Rationale**: OAuth is preferred for production deployments as it supports org-level access and is not tied to a single user account.

**Actors**: `cpt-insightspec-actor-workspace-admin`, `cpt-insightspec-actor-figma-connector`

---

#### Team ID Configuration

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-team-config`

The connector **MUST** accept one or more Figma team identifiers in its configuration. All data collection is scoped to the configured teams. The connector **MUST** validate that at least one team is provided and **MUST** report an error if any configured team is inaccessible with the provided credentials.

**Rationale**: Figma's API is team-scoped; there is no organisation-level endpoint to enumerate all teams automatically.

**Actors**: `cpt-insightspec-actor-workspace-admin`

### 5.2 Data Collection — File & Project Directory

#### Project Enumeration

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-project-enum`

The connector **MUST** enumerate all projects for each configured team. For each project, the connector **MUST** capture the project identifier and project name.

**Rationale**: Projects are the grouping unit for files; needed to associate files with their organisational context.

**Actors**: `cpt-insightspec-actor-figma-connector`

---

#### File Enumeration

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-file-enum`

The connector **MUST** enumerate all files within each project. For each file, the connector **MUST** capture the file identifier, file name, and last modification timestamp.

**Rationale**: The file directory is the dimension table for all activity data and is required for downstream enrichment.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.3 Data Collection — User Directory

#### Team Member Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-user-collection`

The connector **MUST** collect all team members for each configured team. For each member, the connector **MUST** capture the user identifier, email address, display name, and team role.

**Rationale**: The user directory provides the email identity anchor required for Silver-layer identity resolution to a canonical person identifier.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.4 Data Collection — Activity Records

#### Version History Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-version-collection`

The connector **MUST** fetch the version history for each collected file. For each version, the connector **MUST** store the raw version record in Bronze: version identifier, creation timestamp, file identifier, and the identifier of the user who created it. The connector **MUST NOT** aggregate version records — aggregation into per-user per-file per-day activity is performed at the Silver layer.

**Rationale**: Version creation is the primary proxy for active design editing in Figma. Storing raw records preserves full granularity for Silver-layer transformations and avoids embedding aggregation logic in the connector.

**Actors**: `cpt-insightspec-actor-figma-connector`

---

#### Comment Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-comment-collection`

The connector **MUST** fetch all comments for each collected file. For each comment, the connector **MUST** store the raw comment record in Bronze: comment identifier, creation timestamp, file identifier, and the identifier of the user who posted it. The connector **MUST NOT** aggregate comment records.

**Rationale**: Comment activity is the primary proxy for async design review and collaboration. Raw records enable accurate re-aggregation at Silver if the aggregation logic changes.

**Actors**: `cpt-insightspec-actor-figma-connector`

#### Deleted Data Handling

- [ ] `p2` - **ID**: `cpt-insightspec-fr-figma-deleted-data`

The connector **MUST** document that it does not detect deletions in Figma (deleted files, removed users, deleted comments). Records collected before deletion remain in Bronze indefinitely. The connector **MUST NOT** attempt to reconcile Bronze with current Figma state — deletion detection and soft-delete marking, if needed, is a Silver-layer concern.

**Rationale**: The Figma API does not provide a deletion event stream or a "deleted since" filter. Attempting deletion detection at the connector level would require full-state comparison on every run, negating the benefits of incremental sync. Accepting stale records in Bronze is the standard trade-off for API-based connectors.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.5 Incremental Sync

#### Cursor-Based Incremental Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-incremental-sync`

The connector **MUST** support incremental collection by tracking the most recent record timestamp from the previous run. On subsequent runs, the connector **MUST** skip version and comment records that were already collected. Full refresh of the file and user directories is acceptable on each run (these are small, dimension-like datasets).

**Rationale**: Full version and comment history can be large for files with long histories; incremental sync reduces API calls and processing time.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.6 Rate Limit Handling

#### Rate Limit Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-rate-limit`

The connector **MUST** enforce request pacing to stay within the Figma API rate limit. The connector **MUST** implement exponential backoff when rate-limited by the API.

**Rationale**: Exceeding rate limits causes API errors and may lead to temporary token suspension.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.7 Collection Run Logging

#### Run Metadata Recording

- [ ] `p2` - **ID**: `cpt-insightspec-fr-figma-run-logging`

The connector **MUST** record metadata for each execution, including: start and end timestamps, completion status (running/completed/failed), row counts for each collected entity type, total API calls made, error count, and the configuration used for the run.

**Rationale**: Collection run logs are the primary observability mechanism for connector health monitoring.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.8 Error Handling

#### Authentication Failure Detection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-auth-failure`

The connector **MUST** detect authentication failures and **MUST** set the collection run status to failed with a clear error message. For OAuth, the connector **MUST** attempt token refresh before declaring failure.

**Rationale**: Silent authentication failure leads to stale data with no operator visibility.

**Actors**: `cpt-insightspec-actor-figma-connector`

---

#### Unresolvable User Handling

- [ ] `p2` - **ID**: `cpt-insightspec-fr-figma-unresolvable-user`

When the connector encounters a version or comment record from a user not present in the user directory, it **MUST** still store the raw record in Bronze (with the source-native user identifier). The connector **MUST** increment a warning counter in the collection run log for unresolvable users. The connector **MUST NOT** fail the entire run due to unresolvable users. Resolution of these records to a person is a Silver-layer concern.

**Rationale**: Guest and external collaborators may not appear in the team members endpoint. Omitting these rows is preferable to failing the collection.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.9 Data Privacy & Content Boundaries

#### Metadata-Only Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-metadata-only`

The connector **MUST NOT** collect comment text content, file design content, or any other user-generated content from Figma. The connector **MUST** collect only structural metadata: identifiers, timestamps, counts, names, email addresses, and roles. This aligns with the platform-wide principle: "Private message content never extracted (only metadata)."

**Rationale**: Collecting content would introduce significant privacy and data classification risks without proportional analytics value. Activity counts are sufficient for productivity and collaboration metrics.

**Actors**: `cpt-insightspec-actor-figma-connector`

---

#### PII Handling

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-pii-handling`

The connector collects the following personally identifiable information (PII): employee email addresses, display names, and per-user activity records that constitute employee productivity monitoring data. The connector **MUST** treat this data as PII throughout the collection pipeline. PII **MUST** only be stored in Bronze tables that are subject to the platform's data retention and access control policies.

**Rationale**: Email addresses and individual activity records are personal data under GDPR (Article 4). Employee productivity monitoring data has additional protections in some jurisdictions (GDPR Article 88, German BDSG §26). The platform must handle this data accordingly.

**Actors**: `cpt-insightspec-actor-figma-connector`, `cpt-insightspec-actor-workspace-admin`

### 5.10 Data Integrity

#### Idempotent Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-idempotent`

The connector **MUST** produce identical results when re-run with the same cursor position. Re-running the connector against the same time range **MUST NOT** produce duplicate records in Bronze tables.

**Rationale**: Idempotency is a platform connector contract requirement. It enables safe retries after failures and ensures data consistency.

**Actors**: `cpt-insightspec-actor-figma-connector`

---

#### Partial Failure Handling

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-partial-failure`

If the connector fails mid-run (e.g., API error on file N of M), it **MUST NOT** advance the sync cursor. Data already written during the failed run **MUST** be safe to overwrite on the next run (idempotent upsert). The connector **MUST** record the failure in the collection run log with sufficient detail to identify where the failure occurred.

**Rationale**: Advancing the cursor on a partial run would skip uncollected data on the next run, causing permanent data gaps.

**Actors**: `cpt-insightspec-actor-figma-connector`

### 5.11 Platform Integration

#### Connector Contract Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-connector-contract`

The connector **MUST** conform to the platform Connector Contract as defined in CONNECTORS_ARCHITECTURE. This includes providing a connector manifest declaring source type, capabilities (incremental sync, full refresh), and endpoint definitions. The connector **MUST** extend the platform base connector class.

**Rationale**: All Insight connectors implement a standardized interface to enable orchestration, monitoring, and schema discovery. Non-compliant connectors cannot be registered in the platform.

**Actors**: `cpt-insightspec-actor-figma-connector`, `cpt-insightspec-actor-orchestrator`

---

#### Design Domain Registration

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-domain-registration`

The connector **MUST** register a new "design" domain in the Unifier Schema Registry. The domain **MUST** define unified entities for design tool data (file activity, files, users) with source mappings for Figma. The domain registration **MUST** be extensible for future design tool sources (Sketch, Adobe XD).

**Rationale**: The "design" domain does not yet exist in the platform's Unifier layer. Without domain registration, collected data cannot be normalized or propagated to the Semantic Dictionary.

**Actors**: `cpt-insightspec-actor-figma-connector`, `cpt-insightspec-actor-schema-registry`

---

#### Semantic Metadata Provision

- [ ] `p2` - **ID**: `cpt-insightspec-fr-figma-semantic-metadata`

The connector **MUST** provide semantic metadata for each collected field in its Unifier mapping. Semantic metadata **MUST** include: display name, description, aggregation type, applicable teams, and related business concepts. This metadata propagates automatically to the Data Catalog and Semantic Dictionary.

**Rationale**: Connector-level semantic metadata is the single source of truth for field descriptions across the platform. Without it, analysts must manually define every metric in the Semantic Dictionary.

**Actors**: `cpt-insightspec-actor-figma-connector`, `cpt-insightspec-actor-schema-registry`

---

#### Orchestration Layer Registration

- [ ] `p1` - **ID**: `cpt-insightspec-fr-figma-orchestrator-registration`

The connector **MUST** be registerable in the platform orchestration layer for scheduled execution. The connector **MUST** support the orchestrator's standard lifecycle: trigger, progress reporting, completion/failure signaling, and cursor persistence.

**Rationale**: All connectors are scheduled and monitored through the orchestration layer. Without registration, the connector cannot run in production.

**Actors**: `cpt-insightspec-actor-figma-connector`, `cpt-insightspec-actor-orchestrator`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Rate Limit Safety Margin

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-figma-rate-safety`

The connector **MUST** maintain a safety margin below the Figma API rate limit ceiling to avoid hitting undocumented thresholds.

**Threshold**: Sustained request rate must not exceed 80% of the observed rate limit

**Rationale**: Figma's exact rate limits are not publicly documented; a safety margin prevents hitting undocumented thresholds.

---

#### Large Team Scalability

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-figma-large-team`

The connector **MUST** be able to collect data for teams with up to 500 files within a single scheduled run window. For teams exceeding 500 files, the connector **SHOULD** support distributing collection across multiple runs.

**Threshold**: 500 files within 60 minutes for a single run

**Rationale**: Large enterprise design teams may have hundreds of active Figma files; the connector must not time out or fail for these organisations.

#### Collection Cadence

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-figma-cadence`

The connector **MUST** be scheduled to run at least once every 24 hours. If a scheduled run is missed or fails, the orchestration layer **MUST** alert the workspace administrator. Two consecutive missed runs (data staleness exceeding 48 hours) **MUST** be treated as a collection health incident.

**Threshold**: Data freshness ≤24 hours under normal operation; ≤48 hours maximum before alert escalation

**Rationale**: Design activity analytics are consumed at daily granularity. Data older than 48 hours loses relevance for sprint-level collaboration analysis.

### 6.2 NFR Exclusions

- **Sub-second latency**: Not applicable — the connector is a batch collection service, not a real-time API

### 6.3 Non-Applicable Quality Domains

The following quality domains from ISO/IEC 25010:2023 are explicitly not applicable to this connector. Each is listed here to satisfy DOC-PRD-001 (no silent omissions).

- **Safety (ISO 25010 §4.2.9)**: Not applicable — the connector is a data collection service with no physical interaction, no control of physical systems, and no potential for harm to people or property.
- **Usability / Interaction Capability (ISO 25010 §4.2.4)**: Not applicable — the connector has no user interface. Configuration is handled through the platform admin UI (separate deliverable) or configuration files.
- **Accessibility (WCAG 2.2)**: Not applicable — no user interface.
- **Internationalization**: Not applicable — the connector processes machine-readable data; no human-facing text or locale-dependent formatting.
- **Maintainability — Documentation (ISO 25010 §4.2.7)**: Deferred to platform-level connector SDK documentation requirements. No connector-specific documentation requirements beyond what the Connector Contract mandates.
- **Compliance — Regulatory (GDPR, HIPAA, PCI DSS)**: GDPR applicability is addressed in section 5.9 (PII Handling). HIPAA and PCI DSS are not applicable — the connector does not process healthcare or payment card data. Broader compliance requirements (SOC 2, ISO 27001) are governed at the platform level, not per-connector.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Connector Configuration Interface

- [ ] `p1` - **ID**: `cpt-insightspec-interface-figma-config`

**Type**: Configuration schema (data format)

**Stability**: stable

**Description**: The connector accepts a configuration specifying: which Figma teams to collect from, the authentication method (PAT or OAuth), and the corresponding credentials. OAuth deployments additionally require client application credentials and a refresh token.

**Breaking Change Policy**: Adding new optional configuration fields is non-breaking; removing or renaming existing fields requires major version bump.

#### Bronze Output Schema Interface

- [ ] `p1` - **ID**: `cpt-insightspec-interface-figma-output-schema`

**Type**: Data schema (Bronze table structure)

**Stability**: stable

**Description**: The connector produces data conforming to a versioned Bronze output schema. The schema defines the structure of raw records written to Bronze tables (files, users, versions, comments, collection runs). The schema version **MUST** be tracked in the connector manifest.

**Breaking Change Policy**: Adding new nullable columns is non-breaking. Renaming, removing, or changing the type of existing columns is a breaking change requiring a major version bump and coordination with the Silver-layer pipeline that consumes Bronze data.

### 7.2 External Integration Contracts

#### Figma REST API Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-figma-api`

**Direction**: required from external system

**Protocol/Format**: HTTPS REST, JSON responses

**Compatibility**: The connector depends on the Figma REST API for team, project, file, member, version, and comment data. Breaking changes to the API would require connector updates. Figma has maintained API stability since its introduction.

---

#### Identity Manager Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-figma-identity`

**Direction**: provided by connector (downstream)

**Protocol/Format**: Email addresses collected from the Figma user directory, consumed by Identity Manager at Silver layer for resolution to canonical person identifiers.

**Compatibility**: The connector guarantees email is populated for all team members whose email is exposed by the Figma API. Guest users with no email are excluded.

---

#### Connector Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-figma-platform`

**Direction**: required from platform

**Protocol/Format**: Connector manifest (connector.yaml), base connector class, extraction API interface as defined in CONNECTORS_ARCHITECTURE.

**Compatibility**: The connector implements the platform's standardized connector interface. Changes to the connector contract would require connector updates.

---

#### Orchestration Layer Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-figma-orchestrator`

**Direction**: required from platform

**Protocol/Format**: Orchestrator registration and lifecycle management (scheduling, triggering, cursor persistence, status reporting).

**Compatibility**: The connector conforms to the orchestrator's standard connector lifecycle. Changes to the orchestration interface would require connector updates.

---

#### Unifier Schema Registry Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-figma-unifier`

**Direction**: provided by connector (to platform)

**Protocol/Format**: Unifier domain definition with field mappings and semantic metadata (display name, description, aggregation type, concepts, applicable teams), registered in the Schema Registry.

**Compatibility**: The connector registers a new "design" domain. Adding new fields or sources is non-breaking; removing fields requires coordination with downstream consumers.

## 8. Use Cases

#### Initial Full Sync of Figma Team

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-figma-full-sync`

**Actor**: `cpt-insightspec-actor-workspace-admin`

**Preconditions**:
- Workspace administrator has configured connector with valid credentials and at least one team
- No previous collection runs exist for this connector instance

**Main Flow**:
1. Connector validates credentials
2. Connector enumerates all projects and files for configured teams
3. Connector collects all team members
4. Connector fetches full version history and comments for all files, storing raw records in Bronze
5. Connector records collection run as completed

**Postconditions**:
- All Bronze tables populated with current Figma data
- Sync cursor set to the most recent record timestamp

**Alternative Flows**:
- **Invalid credentials**: Run fails at step 1; status set to failed with authentication error

---

#### Incremental Daily Collection

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-figma-incremental`

**Actor**: `cpt-insightspec-actor-figma-connector` (scheduled)

**Preconditions**:
- At least one successful full sync has completed
- Sync cursor is available from the previous run

**Main Flow**:
1. Connector refreshes file and user directories (full refresh — small datasets)
2. Connector fetches versions and comments for all files, skipping previously collected records
3. Connector stores new raw records in Bronze
4. Connector updates sync cursor

**Postconditions**:
- Only new activity since last run is processed; existing records unaffected
- API call count proportional to number of files, not total history depth

---

#### OAuth Token Refresh Failure

- [ ] `p3` - **ID**: `cpt-insightspec-usecase-figma-token-failure`

**Actor**: `cpt-insightspec-actor-figma-connector`

**Preconditions**:
- Connector configured with OAuth 2.0
- Refresh token has expired or been revoked

**Main Flow**:
1. Connector attempts token refresh
2. Token refresh fails
3. Connector attempts API call — receives authentication error
4. Connector sets run status to failed with clear error message indicating re-authorization required

**Postconditions**:
- Collection stops; no partial data written
- Error visible in collection run log

**Alternative Flows**:
- **Refresh succeeds**: Normal collection continues; no user action required

## 9. Acceptance Criteria

- [ ] Connector successfully collects projects, files, users, raw version records, and raw comment records from a configured Figma team using PAT authentication
- [ ] Collected version and comment records match the data visible in the Figma UI for a test file (correct count, correct user attribution, correct timestamps)
- [ ] Incremental sync collects only new records after the first full run
- [ ] Connector respects rate limits and is not rate-limited by the API under normal operation
- [ ] Collection run log accurately reflects success/failure status and row counts
- [ ] Raw records from unresolvable users (guest contributors) are stored in Bronze with source-native user ID; a warning is logged without failing the run
- [ ] Email addresses collected for team members match the values shown in Figma team settings
- [ ] No comment text content or file design content is stored in Bronze tables — only metadata (identifiers, timestamps, counts, names, emails)
- [ ] Re-running the connector with the same cursor produces identical results with no duplicate records
- [ ] A run that fails mid-collection does not advance the sync cursor; the next run re-collects from the same position without data loss
- [ ] Connector conforms to the platform Connector Contract and is successfully registered in the orchestration layer

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Figma REST API | External API providing team, project, file, member, version, and comment data | `p1` — connector cannot function without it |
| Connector Contract & Base Class | Platform connector interface defined in CONNECTORS_ARCHITECTURE; provides standardized manifest, extraction API, and base class | `p1` — connector must conform to this contract |
| Orchestration Layer | Platform orchestration service (AirByte/Dagster) for scheduling, triggering, and monitoring connector runs | `p1` — connector cannot run in production without orchestrator registration |
| Unifier Schema Registry | Platform service for registering unified domain schemas with semantic metadata; "design" domain must be created | `p1` — collected data cannot be normalized without domain registration |
| Identity Manager | Silver-layer service that maps email addresses to canonical person identifiers | `p2` — not required for Bronze collection, but required for downstream analytics |
| Figma Connector Bronze schema | Figma-specific Bronze table definitions (defined in DESIGN document) | `p1` — connector writes to these tables |
| Secret Manager | Secure storage for OAuth credentials | `p2` — required for OAuth deployments |

## 11. Assumptions

- Figma REST API remains stable and available; Figma has not announced deprecation as of March 2026
- Team members endpoint returns email for all users within the organisation's team (not guaranteed for guest/external collaborators)
- Version creation in Figma is a reasonable proxy for active editing (acknowledging that autosave edits without explicit version creation are not captured)
- Comment counts are a reasonable proxy for design review engagement
- The scheduled collection cadence (daily) is sufficient for design activity analytics; near-real-time collection is not required
- The platform Connector Contract, Orchestration Layer, and Unifier Schema Registry are available and accept new connector/domain registrations
- Bronze data is never queried directly at the Gold level; all data must pass through the Silver layer before reaching Gold (per CONNECTORS_ARCHITECTURE)

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Figma rate limits are not publicly documented and may change | Connector may hit undocumented limits, causing errors and failed runs | Maintain safety margin; implement exponential backoff; monitor error frequency in collection logs |
| Version history is an incomplete proxy for editing activity | Activity undercounting for designers who edit without triggering a version save | Document as known limitation; recommend Figma org settings that increase version creation frequency |
| File view counts unavailable on non-Enterprise plans | Key engagement metric not collectable for most customers | Revisit when Figma provides public Analytics API |
| Guest user email unavailable | Activity from external collaborators lost (not attributable to a person) | Track omitted rows in error count; acceptable trade-off for data quality |
| OAuth token expiry with no automated re-auth | Collection silently stops if refresh token expires | Detect authentication errors early; surface in collection run status; alert operator |
| Large teams (>500 files) may exceed run time window | Incomplete collection in a single run | Distribute collection across multiple runs |
| "Design" domain is new and unproven in the platform | Unifier schema may need iteration as more design tools are added; semantic metadata may not fit existing patterns | Start with Figma-only entities; design domain schema for extensibility from the start; iterate based on Sketch/Adobe XD requirements |
| Deleted files/users/comments in Figma are not detected by the connector | Bronze contains stale records for entities that no longer exist in Figma; Silver aggregates may overcount if not handled | Document as known limitation; Silver pipeline should implement soft-delete detection via full-refresh comparison if needed |
| Employee productivity monitoring data subject to GDPR | Per-user activity data (who edited what, when) is personal data; some EU jurisdictions require works council approval for employee monitoring | Collect metadata only (no content); rely on platform-level data retention and access control policies; workspace administrators responsible for obtaining necessary consent/approval before enabling the connector |
