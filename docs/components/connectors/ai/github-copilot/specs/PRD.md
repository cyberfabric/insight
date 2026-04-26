# PRD — GitHub Copilot Connector

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Seat Roster Collection](#51-seat-roster-collection)
  - [5.2 Per-User Metrics Collection](#52-per-user-metrics-collection)
  - [5.3 Org-Level Metrics Collection](#53-org-level-metrics-collection)
  - [5.4 Connector Operations](#54-connector-operations)
  - [5.5 Data Integrity](#55-data-integrity)
  - [5.6 Identity Resolution](#56-identity-resolution)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [Configure GitHub Copilot Connection](#configure-github-copilot-connection)
  - [Incremental Sync Run](#incremental-sync-run)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)
- [14. Non-Applicable Requirements](#14-non-applicable-requirements)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The GitHub Copilot connector extracts seat assignments and per-user/org-level daily usage metrics from the GitHub REST API and loads them into the Insight Bronze layer. The connector covers:

- **Seat roster** — who holds a Copilot seat, plan type, last activity timestamp, and primary editor
- **Per-user daily metrics** — code acceptance activity, lines of code added, and feature usage (IDE chat, agent mode, CLI) at daily granularity per GitHub user login
- **Org-level daily metrics** — organization-wide aggregates (acceptance counts, lines of code added, active user counts, feature engagement breakdown by channel)

### 1.2 Background / Problem Statement

Organizations adopting GitHub Copilot for Business or Enterprise need analytics on developer adoption and engagement alongside other AI dev tools (Cursor, Claude Code, Windsurf). Three gaps motivate this connector:

1. **Seat utilization** — which seats are active vs. stale; who has been assigned Copilot but never used it.
2. **Per-developer adoption** — daily code acceptance activity, lines of AI-generated code added per developer, and engagement with specific Copilot features (chat, agent mode, CLI).
3. **Cross-tool benchmarking** — aggregating Copilot adoption metrics alongside Cursor and Claude Code in the unified `class_ai_dev_usage` Silver view for cross-tool productivity analysis.

The GitHub Copilot Metrics API introduced per-user daily data at granularity that was not available from the prior `/orgs/{org}/copilot/metrics` endpoint (org-level aggregates only). That endpoint was shut down on 2026-04-02. This connector targets the replacement reports API (`/orgs/{org}/copilot/metrics/reports/users-1-day` and `/orgs/{org}/copilot/metrics/reports/organization-1-day`), which provides richer per-user signals via NDJSON payloads delivered through pre-signed download URLs.

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Seat roster extracted daily with complete coverage (all assigned seats) — Baseline: none; Target: daily, Q2 2026
- Per-user daily Copilot usage available in `class_ai_dev_usage` within 48h of end-of-day — Baseline: none; Target: daily, Q2 2026
- Org-level daily Copilot metrics available in `class_ai_org_usage` (deferred, pending Silver view creation) — Target: Q3 2026
- Single `data_source = 'insight_github_copilot'` discriminator enables cross-provider AI adoption analytics

**Capabilities**:

- Extract seat roster from `GET /orgs/{org}/copilot/billing/seats` with full pagination
- Extract per-user daily usage incrementally from the Copilot reports API, resolving `login` → `user_email` via seat join for identity resolution
- Extract org-level daily usage incrementally from the Copilot reports API
- Incremental sync on `day` cursor for metrics streams; full refresh for seat roster

### 1.4 Glossary

| Term | Definition |
|------|------------|
| GitHub Copilot for Business / Enterprise | GitHub's AI coding assistant product tier available to organizations. Requires org-level enablement and a PAT with `manage_billing:copilot` scope for admin access. |
| PAT (classic) | Personal Access Token (classic) — the only GitHub auth mechanism supporting `manage_billing:copilot` scope. Fine-grained PATs do not support this scope. |
| `manage_billing:copilot` | PAT scope required for all Copilot Admin API endpoints. Only Organization Owners can create PATs with this scope. |
| Signed URL | Pre-authenticated HTTPS URL returned by the metrics endpoint, hosted on `copilot-reports.github.com`. The connector downloads NDJSON data from this URL without an `Authorization` header; URLs expire shortly after issuance. |
| NDJSON | Newline-delimited JSON — response format from signed download URLs. Each line is a separate JSON object; the entire payload is not valid JSON. |
| Seat | An assigned Copilot subscription slot for a specific GitHub user. Identified by `user_login` and `user_email`. |
| `class_ai_dev_usage` | Silver unified stream for per-developer AI tool daily usage (Cursor, Claude Code, GitHub Copilot, Windsurf). |
| `class_ai_org_usage` | Silver unified stream for org-level AI tool aggregates. Planned — does not yet exist in the codebase. |
| `data_source` | Discriminator field set to `insight_github_copilot` in all Bronze rows emitted by this connector. |
| `person_id` | Canonical cross-system person identifier resolved by the Identity Manager in Silver step 2. |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-ghcopilot-operator`

**Role**: Obtains the GitHub PAT (classic) from an Organization Owner, configures the connector, monitors extraction runs, and handles credential rotation.

**Needs**: Clear error reporting on authentication or rate-limit failures; documented PAT creation steps; single credential (PAT) covers all streams.

#### Organization Owner

**ID**: `cpt-insightspec-actor-ghcopilot-org-owner`

**Role**: Manages the GitHub organization's Copilot subscription and provisions seats. Creates the PAT with `manage_billing:copilot` scope required for the connector.

**Needs**: Evidence that the connector does not write to GitHub; confirmation that the PAT scope is read-only.

#### Data Analyst

**ID**: `cpt-insightspec-actor-ghcopilot-analyst`

**Role**: Consumes Bronze/Silver data to build Copilot adoption dashboards and cross-tool AI adoption analyses combining GitHub Copilot with Cursor, Claude Code, and Windsurf.

**Needs**: Per-user daily metrics in `class_ai_dev_usage` with stable schema; org-level aggregates in `class_ai_org_usage` (deferred); `user_email` as identity key for cross-system joins.

#### Engineering Manager

**ID**: `cpt-insightspec-actor-ghcopilot-manager`

**Role**: Consumes Gold-layer reports on Copilot seat utilization, acceptance rates, and team-level AI adoption.

**Needs**: Reliable seat roster freshness; per-developer activity signals for seat utilization review; stable metrics for trend analysis.

### 2.2 System Actors

#### GitHub REST API

**ID**: `cpt-insightspec-actor-ghcopilot-github-api`

**Role**: External REST API providing seat roster, per-user daily metrics, and org-level daily metrics. Enforces rate limits (5,000 req/hr per authenticated user) and requires PAT authentication via `Authorization: Bearer {token}`. Returns pre-signed HTTPS download URLs for metrics payloads; those URLs are hosted on `copilot-reports.github.com` and are downloaded without an `Authorization` header.

#### Identity Manager

**ID**: `cpt-insightspec-actor-ghcopilot-identity-mgr`

**Role**: Resolves `user_email` (obtained from `copilot_seats` via the Silver login→email join) to canonical `person_id` in Silver step 2. Enables cross-system joins with HR/directory, version control, and other AI dev tool connectors.

#### ETL Scheduler / Orchestrator

**ID**: `cpt-insightspec-actor-ghcopilot-scheduler`

**Role**: Triggers connector runs on a configured schedule (default: daily at 02:00 UTC) and monitors collection run outcomes.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires outbound HTTPS access to `api.github.com` (authentication + metrics envelope fetch) and `copilot-reports.github.com` (NDJSON payload download).
- Authentication to `api.github.com` via PAT (classic) with `manage_billing:copilot` scope, sent via `Authorization: Bearer {token}`. Only Organization Owners can create tokens with this scope; fine-grained PATs do not support it.
- Download requests to `copilot-reports.github.com` **MUST NOT** include an `Authorization` header — the URLs are pre-authenticated; sending auth headers may cause request failures.
- The metrics API returns a `{"download_links": [...], "report_day": "YYYY-MM-DD"}` envelope; the connector downloads each URL in `download_links` as NDJSON (one JSON object per line).
- The old `/orgs/{org}/copilot/metrics` endpoint was decommissioned on 2026-04-02 and **MUST NOT** be used. This connector references only the replacement reports API endpoints.
- Seat roster stream uses classic pagination: `page` + `per_page` (max 100 rows per page).
- Primary rate limit: 5,000 requests/hour per authenticated user (GitHub REST API). The connector implements exponential backoff on HTTP 429, honouring `Retry-After` and `X-RateLimit-Reset` headers.
- All endpoints are HTTP GET — no mutation calls.
- `tenant_id`, `insight_source_id`, `data_source`, and `collected_at` are injected into every Bronze row by the connector at extraction time; they are not returned by the GitHub API.

## 4. Scope

### 4.1 In Scope

- Collection of current Copilot seat assignments (login, email, plan type, last activity timestamp, editor)
- Collection of per-user daily usage metrics (login, code acceptance count, lines of code added, feature engagement flags) via the Copilot reports API
- Collection of org-level daily usage metrics (total acceptance counts, total lines added, active user counts, feature engagement breakdown) via the Copilot reports API
- Incremental sync for metrics streams (`copilot_user_metrics`, `copilot_org_metrics`) using `day` cursor
- Full refresh for seat roster (`copilot_seats`)
- Two-step metrics fetch: envelope request to GitHub API → NDJSON download from signed URL
- Identity resolution via `copilot_user_metrics.login` → `user_email` through Silver join with `copilot_seats.user_login`
- Bronze-layer table schemas for all 3 data streams
- Silver staging model `copilot__ai_dev_usage` → `class_ai_dev_usage`
- Silver staging model `copilot__ai_org_usage` (deferred — `class_ai_org_usage` Silver view does not yet exist; model tagged for future activation)

### 4.2 Out of Scope

- GitHub repository data (commits, PRs, reviews) — covered by the `github-v2` connector
- Silver step 2 (identity resolution: `user_email` → `person_id`) — responsibility of the Identity Manager
- Gold-layer aggregations and cross-source productivity metrics
- Copilot Chat on GitHub.com (separate product surface; not in the reports API)
- IDE-level editor breakdown per user (not available from the new per-user metrics API)
- Language-level code acceptance breakdown (not available from the new per-user metrics API)
- Real-time or sub-daily granularity — the reports API provides daily aggregates only
- `class_ai_org_usage` Silver view creation — tracked separately; this connector defines the staging model
- Class-level Silver tags (`silver:class_ai_dev_usage`, `silver:class_ai_org_usage`) — to be added alongside Silver framework changes

## 5. Functional Requirements

### 5.1 Seat Roster Collection

#### Extract Seat Assignments

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-seats-collect`

The connector **MUST** extract all current Copilot seat assignments from `GET /orgs/{org}/copilot/billing/seats`, capturing each seat's `user_login`, `user_email`, `plan_type`, `pending_cancellation_date`, `last_activity_at`, `last_activity_editor`, `created_at`, and `updated_at`.

**Rationale**: The seat roster enables utilization reporting and is the canonical source of `user_email` — the identity key for cross-system resolution. `copilot_user_metrics` uses GitHub login as the identifier; mapping to email requires joining with this stream.

**Actors**: `cpt-insightspec-actor-ghcopilot-analyst`, `cpt-insightspec-actor-ghcopilot-manager`

#### Paginate Seat Results

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-seats-paginate`

The connector **MUST** paginate through all seat pages using `page` and `per_page=100` query parameters, continuing until the API returns an empty page or fewer than 100 items.

**Rationale**: Organizations may have hundreds or thousands of Copilot seats. Truncating at the first page would silently undercount the seat roster.

**Actors**: `cpt-insightspec-actor-ghcopilot-github-api`

### 5.2 Per-User Metrics Collection

#### Extract Per-User Daily Usage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-user-metrics-collect`

The connector **MUST** extract per-user daily Copilot usage for each day since `github_start_date` from the user metrics reports endpoint. For each user row in the NDJSON payload, it **MUST** capture: `login`, `day`, `loc_added_sum`, `code_acceptance_activity_count`, `user_initiated_interaction_count`, `used_chat`, `used_agent`, and `used_cli`.

**Rationale**: Per-user daily metrics are the primary signal for `class_ai_dev_usage` — enabling acceptance rate, lines-added, and feature engagement analytics alongside Cursor and Claude Code for cross-tool AI adoption analysis.

**Actors**: `cpt-insightspec-actor-ghcopilot-analyst`, `cpt-insightspec-actor-ghcopilot-manager`

#### Two-Step Metrics Fetch

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-signed-url-fetch`

For each day requested, the connector **MUST** obtain metrics data via the pre-authenticated two-step pattern: an initial API call to the GitHub metrics endpoint returns a signed URL envelope (`{"download_links": [...], "report_day": "YYYY-MM-DD"}`); the connector **MUST** then fetch each URL in the envelope **without** an `Authorization` header; each URL's NDJSON response **MUST** be parsed record-by-record. Processing all URLs in the envelope is required to avoid silent data loss from sharded payloads.

**Rationale**: The reports API delivers metric payloads via pre-authenticated signed URLs on `copilot-reports.github.com`. Sending the PAT auth header to this domain is unnecessary and may cause request failures. Processing all URLs in `download_links` is required to avoid silent data loss for large organizations that may receive sharded payloads.

**Actors**: `cpt-insightspec-actor-ghcopilot-github-api`

#### Incremental Sync for User Metrics

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-user-metrics-incremental`

The connector **MUST** support incremental sync for user metrics using `day` (YYYY-MM-DD) as the cursor field. On each run, it **MUST** advance from `max(day)` in the destination to yesterday (UTC). First-run start is configurable via `github_start_date` (default: 90 days ago).

**Rationale**: Metrics data is daily — re-fetching history on each run is wasteful and increases rate-limit exposure for organizations with long history windows.

**Actors**: `cpt-insightspec-actor-ghcopilot-operator`, `cpt-insightspec-actor-ghcopilot-scheduler`

### 5.3 Org-Level Metrics Collection

#### Extract Org-Level Daily Usage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-org-metrics-collect`

The connector **MUST** extract org-level daily Copilot usage for each day since `github_start_date` from the organization metrics reports endpoint, following the same two-step signed URL fetch pattern as `cpt-insightspec-fr-ghcopilot-signed-url-fetch`. For each org row in the NDJSON payload, it **MUST** capture all available aggregate fields including: `day`, total code acceptance activity counts, total lines of code added, total active user counts, and per-feature engagement breakdowns.

**Rationale**: Org-level aggregates feed `class_ai_org_usage` for trend and adoption reporting without requiring individual user attribution. These metrics complement per-user data for executive-level AI adoption dashboards.

**Actors**: `cpt-insightspec-actor-ghcopilot-analyst`, `cpt-insightspec-actor-ghcopilot-manager`

#### Incremental Sync for Org Metrics

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-org-metrics-incremental`

The connector **MUST** support incremental sync for org metrics using `day` as the cursor field, following the same pattern as `cpt-insightspec-fr-ghcopilot-user-metrics-incremental`.

**Rationale**: Consistent incremental approach across all metrics streams; avoids redundant refetching of historical data.

**Actors**: `cpt-insightspec-actor-ghcopilot-operator`, `cpt-insightspec-actor-ghcopilot-scheduler`

### 5.4 Connector Operations

#### Track Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-ghcopilot-collection-runs`

> **Phase 1 deferral**: The `copilot_collection_runs` stream is **not** emitted by the Airbyte connector in Phase 1. Operational monitoring is provided by the Argo orchestrator pipeline (one workflow run record per pipeline execution). Per-stream record counts and API call metrics are deferred to Phase 2, consistent with the `claude-enterprise`, `claude-admin`, and `confluence` connectors.

> **[DEFERRED to Phase 2]** The following MUST obligation is a Phase 2 target; it does not apply in Phase 1.

The connector **MUST** produce a collection-run log entry for each execution, recording `run_id`, `started_at`, `completed_at`, `status`, per-stream record counts, `api_calls`, `errors`, and `settings`.

**Rationale**: Operational visibility into connector health. Enables alerting on failed runs and tracking data completeness over time.

**Actors**: `cpt-insightspec-actor-ghcopilot-operator`

### 5.5 Data Integrity

#### Deduplicate by Primary Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-deduplication`

Each stream **MUST** use a primary key to ensure that re-running the connector for an overlapping date range does not produce duplicate records:

- `copilot_seats`: key = `user_login` (one active seat per GitHub user, scoped per Airbyte connection)
- `copilot_user_metrics`: key = `unique` (composite: `day|login`, scoped per Airbyte connection)
- `copilot_org_metrics`: key = `unique` (composite: `insight_source_id|day` — `insight_source_id` discriminates between multiple org connections within the same tenant)

**Rationale**: Incremental sync may revisit dates already fetched. Primary keys ensure idempotent extraction and prevent duplicate rows in the Bronze layer.

**Actors**: `cpt-insightspec-actor-ghcopilot-github-api`

#### Tenant Tagging and Provenance

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-tenant-tagging`

Every Bronze row **MUST** carry `tenant_id` (from connector configuration), `insight_source_id` (identifying the specific connector instance), `data_source = 'insight_github_copilot'`, and `collected_at` (UTC ISO-8601 timestamp of the extraction run).

**Rationale**: Tenant tagging is a platform-wide invariant for multi-tenant isolation. The `insight_github_copilot` discriminator enables downstream Silver/Gold queries to filter and join on this source without ambiguity.

**Actors**: `cpt-insightspec-actor-ghcopilot-operator`

### 5.6 Identity Resolution

#### Expose Identity Keys

- [ ] `p1` - **ID**: `cpt-insightspec-fr-ghcopilot-identity-key`

The `copilot_seats` stream **MUST** include `user_email` as the primary identity field and `user_login` as the GitHub username. The `copilot_user_metrics` stream **MUST** include `login`, which the Silver staging model joins with `copilot_seats.user_login` to obtain `user_email`. These fields are used by the Identity Manager to resolve users to canonical `person_id` values in Silver step 2.

**Rationale**: Email is the stable cross-platform identity key shared across GitHub Copilot, Cursor, Claude Code, HR systems, and version control. GitHub login alone is insufficient for cross-system resolution.

**Actors**: `cpt-insightspec-actor-ghcopilot-identity-mgr`

#### Email as Sole Cross-System Identity Key

- [ ] `p2` - **ID**: `cpt-insightspec-fr-ghcopilot-identity-email-only`

The Silver staging model **MUST** use `user_email` (resolved from `copilot_seats`) as the sole cross-system identity key. GitHub's numeric internal user ID **MUST NOT** be used for cross-system identity resolution, though it may be retained in Bronze for debugging.

**Rationale**: GitHub numeric IDs are meaningless outside the GitHub ecosystem. Email is the stable cross-platform identity key shared across all Insight connectors.

**Actors**: `cpt-insightspec-actor-ghcopilot-identity-mgr`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Authentication via Personal Access Token

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-ghcopilot-auth`

The connector **MUST** authenticate to `api.github.com` using `Authorization: Bearer {token}` with a PAT (classic) that has `manage_billing:copilot` scope. Download requests to `copilot-reports.github.com` **MUST NOT** include the `Authorization` header.

#### Rate Limit Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-ghcopilot-rate-limiting`

The connector **MUST** implement exponential backoff on HTTP 429 responses and **SHOULD** honour `Retry-After` and `X-RateLimit-Reset` when present. Transient 5xx errors **MUST** trigger retry with exponential backoff.

#### Data Freshness

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-ghcopilot-freshness`

Usage data for day `D` **MUST** be available in Bronze within 48 hours of end-of-day `D` UTC. The seat roster (full refresh) **MUST** reflect the organization's current state as of the last sync run.

#### Data Source Discriminator

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-ghcopilot-data-source`

All rows written by this connector **MUST** carry `data_source = 'insight_github_copilot'`.

#### Idempotent Writes

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-ghcopilot-idempotent`

Repeated collection of the same date range **MUST NOT** create duplicate rows. The connector **MUST** use upsert semantics keyed on `user_login` (seats), composite `day|login` (user metrics), or composite `insight_source_id|day` (org metrics).

#### Schema Stability

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-ghcopilot-schema-stability`

Bronze table schemas **MUST** remain stable across connector versions. Additive changes (new fields from the GitHub API) are non-breaking. Removing or renaming fields requires a migration. The Bronze namespace is `bronze_github_copilot`; stream names use the `copilot_` prefix.

### 6.2 NFR Exclusions

- **Real-time latency SLA**: Not applicable — batch pull mode only; sub-daily granularity is not available from the Copilot reports API.
- **GPU / high-compute NFRs**: Not applicable — I/O-bound API collection.
- **Safety (SAFE)**: Not applicable — pure data-extraction pipeline with no interaction with physical systems.
- **Usability / UX**: Not applicable — the connector is configured via K8s Secret and Airbyte form; no user-facing interface.
- **Availability SLA (REL)**: Not applicable — scheduled batch job; availability is delegated to the orchestrator.
- **Regulatory compliance (COMPL)**: Work emails are personal data; retention, deletion, and access controls are delegated to the destination operator. The connector itself enforces no retention policy.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### GitHub Copilot Stream Contract

- [ ] `p1` - **ID**: `cpt-insightspec-interface-ghcopilot-streams`

**Type**: Data format (Bronze table schemas)

**Stability**: stable

**Description**: Three Bronze streams with defined schemas — `copilot_seats`, `copilot_user_metrics`, `copilot_org_metrics`. Identity keys: `copilot_seats.user_email` (primary), `copilot_user_metrics.login` resolved to `user_email` via Silver join with `copilot_seats.user_login`. Incremental streams use `day` cursor.

**Breaking Change Policy**: Adding new fields is non-breaking. Removing or renaming fields requires a migration. Bronze namespace and stream names are stable (`bronze_github_copilot.copilot_*`).

### 7.2 External Integration Contracts

#### GitHub REST API

- [ ] `p1` - **ID**: `cpt-insightspec-contract-ghcopilot-github-api`

**Direction**: required from external system

**Protocol/Format**: REST / JSON (seats) + REST / NDJSON via signed URL (metrics)

| Stream | Endpoint | Method | Sync Mode |
|--------|----------|--------|-----------|
| `copilot_seats` | `GET /orgs/{org}/copilot/billing/seats?page={p}&per_page=100` | GET | Full refresh |
| `copilot_user_metrics` | `GET /orgs/{org}/copilot/metrics/reports/users-1-day?day=YYYY-MM-DD` → signed URL | GET | Incremental |
| `copilot_org_metrics` | `GET /orgs/{org}/copilot/metrics/reports/organization-1-day?day=YYYY-MM-DD` → signed URL | GET | Incremental |

**Authentication**: `Authorization: Bearer {github_token}` to `api.github.com`. No auth header on signed-URL downloads to `copilot-reports.github.com`.

**Compatibility**: GitHub REST API v3. Field additions from GitHub are non-breaking. The decommissioned `/orgs/{org}/copilot/metrics` endpoint is not referenced.

#### Identity Manager

- [ ] `p2` - **ID**: `cpt-insightspec-contract-ghcopilot-identity-mgr`

**Direction**: required from client (Identity Manager service)

**Protocol/Format**: Internal service call; input is `email` / `name` / `source_label = "github_copilot"`; output is canonical `person_id` or NULL.

**Compatibility**: Identity Manager must be available during Silver pipeline execution. Unresolved identities remain with `person_id = NULL` and do not block Silver writes.

## 8. Use Cases

### Configure GitHub Copilot Connection

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-ghcopilot-configure`

**Actor**: `cpt-insightspec-actor-ghcopilot-operator`

**Preconditions**:

- GitHub organization has Copilot for Business or Enterprise enabled.
- An Organization Owner has created a PAT (classic) with `manage_billing:copilot` scope at github.com → Settings → Developer settings → Personal access tokens → Tokens (classic).

**Main Flow**:

1. Operator creates a K8s Secret named `insight-github-copilot-{instance}` in the `data` namespace with `stringData.github_token` and `stringData.github_org` set.
2. Operator optionally sets `github_start_date` in `stringData` for a non-default backfill window.
3. Orchestrator picks up the Secret via the `insight.cyberfabric.com/connector: github-copilot` annotation.
4. On first sync, the connector validates credentials by fetching the first page of `copilot_seats`.
5. On success, the connection is saved and scheduled.

**Postconditions**:

- Connection is configured and ready for scheduled or manual sync.

**Alternative Flows**:

- **Invalid PAT**: Check fails with HTTP 401; operator recreates the token and updates the Secret.
- **Insufficient scope or non-Owner PAT**: Check fails with HTTP 403; operator requests an Organization Owner to recreate the PAT.
- **Copilot not enabled**: Seats endpoint returns empty list or 404; operator confirms Copilot product is active for the organization.

### Incremental Sync Run

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-ghcopilot-incremental-sync`

**Actor**: `cpt-insightspec-actor-ghcopilot-scheduler`

**Preconditions**:

- At least one prior successful sync exists (or `github_start_date` configured for first run).
- PAT is valid and has `manage_billing:copilot` scope.

**Main Flow**:

1. Scheduler triggers a sync run (default: daily at 02:00 UTC).
2. Full-refresh stream (`copilot_seats`): connector fetches all pages, replacing the existing seat roster.
3. Incremental streams (`copilot_user_metrics`, `copilot_org_metrics`): connector reads cursor state (`max(day)`), iterates over each missing day from cursor to yesterday (UTC), fetches a signed URL envelope per day, downloads and parses NDJSON line by line, and emits records.
4. All records pass through field additions (tenant_id, insight_source_id, collected_at, data_source, composite deduplication keys) before hitting the destination.
5. Cursor state is persisted after each stream completes.

**Postconditions**:

- All Bronze tables are up-to-date through the last successful cursor date.

**Alternative Flows**:

- **API rate limiting (HTTP 429)**: Connector backs off exponentially and retries.
- **Signed URL expiry**: Connector requests a fresh envelope for the affected day; URLs are not cached across runs.
- **Empty metrics day**: API returns an empty NDJSON payload or `download_links: []`; connector emits zero records and advances the cursor.
- **Login not in seats**: Silver join produces NULL `user_email`; row is retained in Bronze, excluded from Silver identity resolution.

## 9. Acceptance Criteria

- All 3 Bronze streams are populated on first run against a live GitHub organization with `tenant_id`, `insight_source_id`, `data_source = 'insight_github_copilot'`, and `collected_at` on every row.
- `copilot_seats.user_email` is non-null for all seats with a linked GitHub account email.
- `copilot_user_metrics.unique` (`day|login`) deduplicates correctly across overlapping incremental syncs — no duplicate composite keys after re-running the same date range.
- `copilot_org_metrics` deduplicates correctly by composite key `insight_source_id|day` — no duplicate rows for the same organization connection and day after re-running overlapping date ranges.
- Seat roster (`copilot_seats`) is fully paginated — all seats are returned when the organization exceeds 100 seats.
- Per-user metrics for a given day are parsed correctly from NDJSON — each line produces a valid record with all expected fields.
- A second sync run for an overlapping date range completes without creating duplicate rows in any stream.
- Full-refresh stream (`copilot_seats`) correctly replaces stale seat roster data.
- Download step issues GET requests to signed URLs **without** an `Authorization` header.
- `check` succeeds against `copilot_seats` with a valid PAT; fails with HTTP 401 for an invalid token and HTTP 403 for an insufficiently scoped token.

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| GitHub REST API (Copilot endpoints) | Source data for all 3 streams | `p1` |
| PAT (classic) with `manage_billing:copilot` scope | Authentication credential | `p1` |
| `copilot_seats` stream | Required by Silver staging model to resolve `login` → `user_email` for `copilot_user_metrics` | `p1` |
| Identity Manager | Resolves `user_email` to `person_id` in Silver step 2 | `p2` |
| Destination store (ClickHouse / PostgreSQL) | Target for Bronze tables | `p1` |
| dbt (Silver transformation runtime) | Executes `copilot__ai_dev_usage` and `copilot__ai_org_usage` staging models | `p2` |
| `class_ai_org_usage` Silver view | Required for `copilot__ai_org_usage` to be queryable; does not yet exist — deferred to Phase 2 | `p2` |

## 11. Assumptions

- The organization has GitHub Copilot for Business or Enterprise enabled; the connector does not check for plan tier.
- The PAT (classic) with `manage_billing:copilot` scope is created by an Organization Owner and rotated before expiry.
- Fine-grained PATs are not used — they do not support `manage_billing:copilot`.
- The `download_links` array in the metrics envelope may contain more than one URL (e.g. sharded payloads for large organizations); the connector processes all URLs in the array.
- Signed NDJSON download URLs remain valid for the duration of a single connector run; they are not cached across runs.
- `user_email` from `copilot_seats` is a stable, work email address suitable for cross-system identity resolution.
- A GitHub user appearing in `copilot_user_metrics` without a matching row in `copilot_seats` is a transient race condition (seat removed between seat fetch and metrics fetch); the Silver model tolerates NULL `user_email` in such rows.
- Daily usage data for day `D` is finalized by the following day (`D+1`); the connector fetches up to yesterday (UTC) to avoid collecting partial-day data.

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Signed URL hostname changes from `copilot-reports.github.com` | Connector cannot download NDJSON; all metrics streams fail | Monitor GitHub API changelog; parameterize the download domain rather than hardcoding it |
| PAT revoked or expired | All streams fail with HTTP 401 | Monitor sync status; alert on authentication failures; document token rotation procedure in platform runbook |
| GitHub Copilot metrics policy gating (feature disabled for subset of org) | `copilot_user_metrics` silently excludes affected users; seat roster remains complete | Document limitation in Silver model; seat roster provides a baseline for detecting gaps |
| `download_links` array structure not fully documented | Connector processes only first URL if array handling is incomplete, silently missing data for large orgs | Implement iteration over all `download_links` items; log item count at debug level for observability |
| `user_email` NULL for users without a verified email in GitHub account | Silver join cannot resolve identity; row excluded from `class_ai_dev_usage` | Accept as upstream limitation; document in Silver model; seat roster NULL rate is a known metric |
| GitHub API schema change — NDJSON field added or removed | Bronze schema drifts from API reality | Accept new fields (non-breaking); monitor GitHub API changelog for removals; `additionalProperties: true` in schema |
| `class_ai_org_usage` Silver view creation delay | `copilot__ai_org_usage` staging model produces Bronze data that cannot be queried at Silver level until the view exists | Tag model as `silver:class_ai_org_usage`; deferred activation is documented in §4.2; org metrics data is preserved in Bronze |

## 13. Open Questions

| ID | Summary | Owner | Target |
|----|---------|-------|--------|
| OQ-COP-1 | `login` → `user_email` join edge case: if a user appears in `copilot_user_metrics` but their seat was removed before the run completes, the Silver join produces NULL `user_email`. Should such rows be dropped in Silver or retained as unresolved pending next full-refresh cycle? | Data Architecture | Q3 2026 |
| OQ-COP-2 | `class_ai_org_usage` Silver view creation — when should the unified Silver view be created and which other connectors will feed it alongside GitHub Copilot? Impacts deferred `copilot__ai_org_usage` activation. | Data Architecture | Q3 2026 |
| OQ-COP-3 | `download_links` array size — GitHub documentation does not specify the maximum number of signed URLs per envelope. Is the array always length 1, or can it be sharded for large organizations? Impacts idempotency and fetch complexity. | Connector Team | Q2 2026 |

## 14. Non-Applicable Requirements

The following checklist domains have been evaluated and determined not applicable for this connector:

| Domain | Reason |
|--------|--------|
| **Security (SEC)** | SEC-PRD-001 (Authentication Requirements) is addressed in §6.1 NFR `cpt-insightspec-nfr-ghcopilot-auth`. SEC-PRD-002 (Authorization) is not applicable — no authorization layers beyond the PAT scope enforced by GitHub. SEC-PRD-003 (Data Classification) is addressed via the COMPL entry: work emails are PII; handling is delegated to the destination operator. SEC-PRD-004 (Audit logging) is not applicable — the connector is stateless and read-only; no user actions to log. SEC-PRD-005 (Privacy by Design) is addressed in the COMPL entry below. The PAT is stored as an Airbyte secret and never logged or exposed. |
| **Safety (SAFE)** | Pure data-extraction pipeline. No interaction with physical systems, no safety-critical operations. |
| **Performance (PERF)** | Batch connector with one HTTP call per day per metrics stream plus paginated seat fetch. Rate-limit compliance is the only performance concern, documented in §3.1 and §6.1. |
| **Reliability (REL)** | Idempotent extraction via deduplication keys. Recovery = re-run the sync; the connector framework manages cursor state and retry. No custom availability SLA required. |
| **Usability (UX)** | No user-facing interface. Configuration is a K8s Secret. |
| **Compliance (COMPL) / Privacy by Design (SEC-PRD-005)** | Work emails and GitHub usernames are personal data under GDPR. Collection scope is limited to the fields required for the Bronze→Silver pipeline (data minimization, GDPR Art. 5(1)(c)). Data is collected solely for AI adoption analytics (purpose limitation, GDPR Art. 5(1)(b)). Retention, deletion, and access controls are delegated to the destination operator (storage limitation, GDPR Art. 5(1)(e)). The connector must not store credentials outside the platform's secret management. |
| **Data (DATA)** | DATA-PRD-001 (ownership): the destination operator is the data controller; this connector acts as a data processor on their behalf. DATA-PRD-002 (quality — freshness and accuracy/completeness): freshness is addressed in §6.1 NFR `cpt-insightspec-nfr-ghcopilot-freshness`; accuracy and completeness are accepted as-is from the GitHub API without transformation or validation beyond type coercion. DATA-PRD-003 (retention, archival, purging): delegated to the destination operator's data governance policies. Field-level enumeration in §5.1–§5.2 follows accepted project convention (consistent with `claude-admin` and `cursor` PRDs); full Bronze schema definitions are a DESIGN artifact. |
| **Maintainability (MAINT)** | Connector follows standard Airbyte CDK patterns; schema changes are handled by updating stream field definitions. No unusual maintenance burden. |
| **Testing (TEST) — custom test tooling only** | Acceptance criteria (TEST-PRD-001) are in §9 with MUST/MUST NOT language (TEST-PRD-002). Airbyte framework checks plus §9 acceptance criteria are sufficient. |
| **Operations — deployment (OPS-PRD-001)** | Deployment is delegated to the orchestrator (Argo Workflows) per the Insight platform model. |
| **Operations — monitoring (OPS-PRD-002)** | Connector-level monitoring is delegated to the orchestrator (see §5.4 Phase 1 deferral note). |
| **Integration — API requirements as producer (INT-PRD-002)** | The connector exposes no API. It is a pure data-extraction consumer. |
