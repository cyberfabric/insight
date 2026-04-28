---
status: proposed
date: 2026-04-23
---

# Decomposition: YouTrack Task-Tracker Connector (`tt-youtrack`)

<!-- toc -->

- [1. Overview](#1-overview)
- [2. Entries](#2-entries)
  - [2.1 Bronze Airbyte Manifest Skeleton — HIGH](#21-bronze-airbyte-manifest-skeleton--high)
  - [2.2 Bronze Directory Streams (Full-Refresh) — HIGH](#22-bronze-directory-streams-full-refresh--high)
  - [2.3 Bronze Incremental Issues & Substreams — HIGH](#23-bronze-incremental-issues--substreams--high)
  - [2.4 Project-Scoped Custom Field Ingestion — HIGH](#24-project-scoped-custom-field-ingestion--high)
  - [2.5 dbt Connector-Level Staging — HIGH](#25-dbt-connector-level-staging--high)
  - [2.6 Rust `youtrack-enrich` — Core (Replay Engine) — HIGH](#26-rust-youtrack-enrich--core-replay-engine--high)
  - [2.7 Rust `youtrack-enrich` — IO (ClickHouse) — HIGH](#27-rust-youtrack-enrich--io-clickhouse--high)
  - [2.8 Argo Workflow & CLI Integration — HIGH](#28-argo-workflow--cli-integration--high)
  - [2.9 Silver Plug-In Verification — MEDIUM](#29-silver-plug-in-verification--medium)
  - [2.10 Test Invariants & E2E Smoke — HIGH](#210-test-invariants--e2e-smoke--high)
- [3. Feature Dependencies](#3-feature-dependencies)
- [4. Coverage Reconciliation Note](#4-coverage-reconciliation-note)

<!-- /toc -->

---

## 1. Overview

The YouTrack task-tracker work is decomposed into ten features that together deliver a Bronze-to-Silver pipeline symmetric to the Jira pipeline delivered by PR #205. The decomposition follows the natural data-flow order: manifest → directory streams → incremental streams → per-project substreams → dbt staging → Rust enrich → Argo orchestration → silver union verification → testing.

**Decomposition strategy**:

- **Data-flow ordering**: features are ordered so each depends only on upstream primitives. Bronze Airbyte manifest is the foundation; dbt staging and Rust enrich consume bronze; Argo orchestrates enrich; silver union is a thin tag-based wrapper that validates plug-in.
- **Symmetry with Jira**: every Jira component in PR #205 has a YouTrack counterpart at the same path depth and with the same responsibility. Where YouTrack REST semantics differ (activitiesPage cursor vs `startAt`, project-scoped custom fields vs global registry, no project whitelist), a dedicated feature or ADR captures the divergence.
- **100% coverage target**: each feature enumerates the FRs, NFRs, principles, constraints, components, sequences, and data models it implements. Sum over all ten features must cover 100% of PRD + DESIGN.
- **No-whitelist scope**: ingestion covers everything the YouTrack permanent token can reach — no `youtrack_project_short_names` K8s Secret field exists.
- **Silver reuse**: the `silver/task-tracking/class_task_*` union models delivered by PR #205 are consumed unchanged; YouTrack plugs in via dbt tags (`silver:class_task_*`) on its per-source staging models.

**Key architectural decisions** (codified as ADRs, planned in the spec-generation plan at `cypilot/.plans/generate-youtrack-spec/`):

- ADR-001 (connector) — Project-scoped custom fields ingestion via per-project substream.
- ADR-002 (connector) — activitiesPage cursor pagination (not offset).
- ADR-003 (connector) — No-whitelist full-ingestion scope.
- ADR-001 (silver/enrich) — activitiesPage event-sourcing with backward replay.
- ADR-002 (silver/enrich) — Multi-value backward replay semantics.

**Inherited architectural ADRs** from Jira silver (applicable, not duplicated):

- Rust single-binary, core/io split, DDL-owned-by-dbt, cursorless-incremental, event-id-traceability, event-kind-column.

**Dependency on PR #205**: feature 2.5 (dbt staging) onward consumes the silver package (`src/ingestion/silver/task-tracking/class_task_*`), the `create_task_field_history_staging` dbt macro, and the `ingestion-pipeline` Argo template introduced in PR #205. No code-level feature can land until PR #205 is merged to `main`.

**Donor code references** (private repo, accessed by maintainers via the Phase 1 research notes — paths inside the donor repo are stable):

- v2 — `monitor` repo, path `sources/youtrack/src/` — `youtrack/types.ts`, `youtrack/client.ts`, `replay/*` (replay algorithm donor for feature 2.6).
- v1 — `monitor` repo, path `packages/cli/commands/youTrack/` — `fields/IssueActivities.ts` (activity category enumeration), `requests/fetchYouTrackUsers.ts` (users endpoint).
- v1 KB-capacity ignored — project-specific legacy, out of scope.

---

## 2. Entries

**Overall implementation status:**

- [ ] `p1` - **ID**: `cpt-insightspec-status-youtrack-overall`

### 2.1 [Bronze Airbyte Manifest Skeleton](feature-bronze-manifest/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-bronze-manifest`

- **Purpose**: Scaffold the declarative Airbyte source package at `src/ingestion/connectors/task-tracking/youtrack/` with `connector.yaml` (version, DeclarativeSource, auth, paginators, add_fields, error_handler), `descriptor.yaml` (name, version, schedule, `connection.namespace=bronze_youtrack`, empty `dbt_select`), `dbt/schema.yml` (Bronze source declarations), `README.md`, and the already-committed K8s Secret example. Provides the foundation all other Bronze features extend.

- **Depends On**: None (PR #205 merged is a cross-cutting prerequisite).

- **Scope**:
  - `connector.yaml` skeleton: `auth` (`BearerAuthenticator` with `youtrack_token`), `base_requester` (url_base from `youtrack_base_url`), `error_handler` (`Retry-After`, 429/503 RETRY, 401/403 FAIL), `add_fields` (`tenant_id`, `source_id` injection), three paginator definitions (offset for directory streams, cursor for activitiesPage, cursor for issue `$skip/$top` hybrid).
  - `descriptor.yaml` — `namespace: bronze_youtrack`, schedule `"0 3 * * *"` (align with jira), `dbt_select: tag:youtrack`.
  - `dbt/schema.yml` — source block `bronze_youtrack` with empty `tables:` (populated by feature 2.2/2.3/2.4).
  - `README.md` — full connector README (overview, prerequisites, K8s Secret, streams table placeholder, identity, silver targets, operational constraints).
  - Sanity check: `check.stream_names = ["youtrack_projects"]` (cheapest endpoint).

- **Out of scope**:
  - Any stream definitions beyond the `check` placeholder (features 2.2–2.4 own those).
  - Custom Python CDK code.

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-bronze-scaffold`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-bronze-auth-bearer`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-bronze-retry-policy`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-secret-rotation`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-no-log-token`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-declarative-first`
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-symmetry-with-jira`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-no-whitelist`
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-k8s-secret-identity`

- **Domain Model Entities**:
  - Airbyte Source Definition
  - K8s Secret (`insight-youtrack-{source-id}`)

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-airbyte-manifest`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-descriptor`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-dbt-source-decl`

- **API**:
  - `check`: `GET /api/admin/projects?$top=1` via Airbyte `check` handshake
  - K8s: `kubectl apply -f src/ingestion/secrets/connectors/youtrack.yaml`
  - CLI: `./airbyte-toolkit/connect.sh <tenant>` picks up the source definition

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-connector-check`
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-secret-discovery`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-db-youtrack-bronze-namespace`

---

### 2.2 [Bronze Directory Streams (Full-Refresh)](feature-bronze-directories/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-bronze-directories`

- **Purpose**: Implement the reference-data streams that need full-refresh semantics and no cursor: projects, users, agiles (with nested sprints), issue link types, optional `customFieldSettings` bundles. These feed identity resolution, sprint context, and link decoding.

- **Depends On**: `cpt-insightspec-feature-youtrack-bronze-manifest`

- **Scope**:
  - `youtrack_projects` — `GET /api/admin/projects?fields=id,shortName,name,description,archived`
  - `youtrack_user` — `GET /api/users?fields=id,login,fullName,email,banned,guest,avatarUrl`
  - `youtrack_agiles` — `GET /api/agiles?fields=id,name,projects(id,shortName)` + nested `youtrack_sprints` via `sprints(id,name,start,finish,archived,goal)` (substream by agile id)
  - `youtrack_issue_link_types` — `GET /api/issueLinkTypes?fields=id,name,sourceToTarget,targetToSource,directed,aggregation,readOnly`
  - All four streams: `sync_mode=full_refresh`, `destinationSyncMode=overwrite`, offset paginator (`$skip/$top`, `$top=50`).
  - `dbt/schema.yml` entries for each table.

- **Out of scope**:
  - Incremental sync for these streams (directories are small; overwrite is cheaper).
  - Hub users endpoint (`/hub/api/rest/users`) — reserved for self-hosted hub-integrated deployments; to be added as a follow-up if required.

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-projects`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-users`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-agiles-sprints`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-link-types`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-directory-overwrite`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-identity-by-email`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-no-whitelist`

- **Domain Model Entities**:
  - Project, User, Agile Board, Sprint, IssueLinkType

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-projects`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-users`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-agiles-sprints`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-link-types`

- **API**:
  - `GET /api/admin/projects`
  - `GET /api/users`
  - `GET /api/agiles` (+ substream `sprints`)
  - `GET /api/issueLinkTypes`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-directory-refresh`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_projects`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_user`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_agiles`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_sprints`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_issue_link_types`

---

### 2.3 [Bronze Incremental Issues & Substreams](feature-bronze-issues/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-bronze-issues`

- **Purpose**: Implement the incremental issue stream, plus three substream children (`youtrack_issue_history` derived from `activitiesPage`, `youtrack_comments`, `youtrack_worklogs`). Every substream uses `incremental_dependency=true` so only issues updated since the last sync have their children re-hit. Includes `youtrack_issue_links` emitted from the issue document itself.

- **Depends On**: `cpt-insightspec-feature-youtrack-bronze-manifest`, `cpt-insightspec-feature-youtrack-bronze-directories`

- **Scope**:
  - `youtrack_issue` — `GET /api/issues?query=updated:{from}..{to} order by: updated asc&fields={ISSUE_FIELDS}` with cursor via `$skip/$top` (page size 100 default, configurable). Incremental cursor on `updated`.
  - `youtrack_issue_history` — substream of `youtrack_issue`, `GET /api/issues/{id}/activitiesPage?fields={ACTIVITIES_FIELDS}&$top=200&categories={ACTIVITY_CATEGORIES}&reverse=true`. **Cursor pagination** via `afterCursor`/`hasAfter` — distinct from directory offset. Enumerate 23 categories per v1/v2.
  - `youtrack_comments` — substream of `youtrack_issue`, `GET /api/issues/{id}/comments?fields=id,text,textPreview,created,updated,author(...),deleted,visibility(...)`, offset pagination.
  - `youtrack_worklogs` — substream of `youtrack_issue`, `GET /api/issues/{id}/timeTracking/workItems?fields=...`, offset pagination.
  - `youtrack_issue_links` — extracted from `youtrack_issue.links[]` (no separate endpoint); emitted as its own Bronze table during dbt staging. Alternatively, modeled as a synthetic stream in declarative manifest via `RecordSelector` + flatten.
  - `ReplacingMergeTree` engine for `youtrack_issue`, `youtrack_issue_history`, `youtrack_comments`, `youtrack_worklogs` (dedup on `unique_key`).

- **Out of scope**:
  - `youtrack_issue_ext` custom-fields-as-rows flattening (owned by feature 2.5 dbt staging).
  - Activity replay (owned by feature 2.6 enrich core).

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-issue-incremental`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-activities-cursor`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-comments`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-worklogs`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-issue-links`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-incremental-dependency`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-cursor-for-activities`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-activitiespage-cursor` (ADR-002 connector)
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-no-whitelist`

- **Domain Model Entities**:
  - Issue, ActivityItem, Comment, WorkItem, IssueLink

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-issue`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-issue-history`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-comments`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-worklogs`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-issue-links`

- **API**:
  - `GET /api/issues?query={...}&fields={ISSUE_FIELDS}`
  - `GET /api/issues/{id}/activitiesPage?fields={ACTIVITIES_FIELDS}&categories={ACTIVITY_CATEGORIES}`
  - `GET /api/issues/{id}/comments`
  - `GET /api/issues/{id}/timeTracking/workItems`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-issue-incremental`
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-activities-cursor-walk`
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-substream-dependency`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_issue`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_issue_history`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_comments`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_worklogs`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_issue_links`

---

### 2.4 [Project-Scoped Custom Field Ingestion](feature-custom-fields/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-custom-fields`

- **Purpose**: Discover and ingest the per-project custom field registry via `/api/admin/projects/{id}/customFields` as a dedicated substream (parent = `youtrack_projects`). Populates `youtrack_project_custom_fields` with project-scoped field definitions, bundle values, cardinality flags. Drives Silver `class_task_field_metadata`.

- **Depends On**: `cpt-insightspec-feature-youtrack-bronze-directories` (projects stream must exist)

- **Scope**:
  - `youtrack_project_custom_fields` — substream of `youtrack_projects`. `GET /api/admin/projects/{id}/customFields?fields=id,field(id,name,localizedName,fieldType(id,valueType,isMultiValue)),bundle(id,values(id,name,description,archived,color(id,presentation),ordinal)),canBeEmpty,ordinal,emptyFieldText,isPublic`
  - `full_refresh`, offset pagination (`$skip/$top`).
  - `project_id` injected into every emitted row.
  - Raw per-issue custom field values are kept inside `youtrack_issue.custom_fields_json` (feature 2.3) — feature 2.4 only owns the **registry**.

- **Out of scope**:
  - Per-issue custom field value extraction (lives inside `youtrack_issue` blob; decoded in feature 2.5/2.6).
  - Global `customFieldSettings/bundles` endpoint (optional; only needed if project-scoped call omits bundle values — verified in Phase 1 research).

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-stream-project-custom-fields`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-custom-field-bundles`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-project-scoped-registry`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-project-scoped-fields` (ADR-001 connector)

- **Domain Model Entities**:
  - ProjectCustomField, FieldBundle, BundleValue

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-stream-project-custom-fields`

- **API**:
  - `GET /api/admin/projects/{id}/customFields`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-custom-field-discovery`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack_project_custom_fields`

---

### 2.5 [dbt Connector-Level Staging](feature-dbt-staging/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-dbt-staging`

- **Purpose**: Project the Bronze streams into the shape the silver `class_task_*` union models expect. Produce `youtrack__changelog_items.sql` (normalizes activitiesPage events — the enrich input), `youtrack__issue_field_snapshot.sql` (current state materialization), and seven `youtrack__task_*.sql` files (one per `class_task_*` tag: comments, worklogs, users, projects, sprints, field_metadata, field_history). A thin view `youtrack__task_field_history.sql` re-exposes the Rust-owned staging table into the dbt graph.

- **Depends On**: `cpt-insightspec-feature-youtrack-bronze-issues`, `cpt-insightspec-feature-youtrack-custom-fields`

- **Scope**:
  - `src/ingestion/connectors/task-tracking/youtrack/dbt/youtrack__changelog_items.sql` — flatten `youtrack_issue_history.activities[]`; emit one row per (issue_id, activity_id, field_id, added_item, removed_item) respecting v2 `applyBackward` semantics. `materialized='table'`, tagged `youtrack`.
  - `youtrack__issue_field_snapshot.sql` — current per-issue × per-field value from `youtrack_issue.customFields[]` + built-in fields (summary, description, resolved, reporter). `materialized='table'`, tagged `youtrack`.
  - `youtrack__task_comments.sql`, `_worklogs.sql`, `_users.sql`, `_projects.sql`, `_sprints.sql`, `_field_metadata.sql` — projections tagged `silver:class_task_*` and `youtrack`.
  - `youtrack__task_field_history.sql` — thin view over Rust-written `staging.youtrack__task_field_history`, tagged `silver:class_task_field_history` and `youtrack`.
  - `dbt/schema.yml` — add `sources.bronze_youtrack.tables` entries for every Bronze stream from features 2.2–2.4; add models with tests (`unique` on `unique_key`, `not_null` on identity columns).
  - `descriptor.yaml` — set `dbt_select: tag:youtrack`.

- **Out of scope**:
  - Rust-owned `staging.youtrack__task_field_history` DDL — owned by existing `create_task_field_history_staging` macro in `on-run-start` (delivered by PR #205).
  - Silver `class_task_*` models — unchanged from PR #205.

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-staging-projections`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-staging-changelog-items`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-staging-field-snapshot`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-silver-tag-plugin`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-symmetry-with-jira`
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-tag-based-union`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-ddl-owned-by-dbt`

- **Domain Model Entities**:
  - ChangelogItem, IssueFieldSnapshot, TaskComment, TaskWorklog, TaskUser, TaskProject, TaskSprint, TaskFieldMetadata, TaskFieldHistory

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-dbt-staging`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-dbt-source-decl`

- **API**:
  - `dbt run --select tag:youtrack`
  - `dbt test --select tag:youtrack`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-dbt-staging-run`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__changelog_items`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__issue_field_snapshot`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_comments`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_worklogs`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_users`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_projects`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_sprints`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_field_metadata`
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-youtrack__task_field_history` (view over Rust output)

---

### 2.6 [Rust `youtrack-enrich` — Core (Replay Engine)](feature-enrich-core/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-enrich-core`

- **Purpose**: Port the v2 `replay/*` TypeScript algorithm to Rust. Produces per-(issue × field × event) history rows with `synthetic_initial` bootstrap and multi-value backward semantics. Output schema matches the jira-enrich contract so the silver `class_task_field_history` union works transparently.

- **Depends On**: `cpt-insightspec-feature-youtrack-dbt-staging`

- **Scope**:
  - Cargo package `src/ingestion/connectors/task-tracking/youtrack/enrich/` — `Cargo.toml`, `Dockerfile`, `build.sh`, `README.md`.
  - `src/core/types.rs` — `YTActivityItem`, `YTIssue`, `IssueStateEntry`, `EventKind`, `ChangeSet<T>`, `FieldId` enum (CustomField / Builtin / TargetMember).
  - `src/core/youtrack.rs` — port of `applyBackward` single/multi-value; port of `deriveFieldId` fallback chain; port of `applyMultiValueBackward` with id-first dedup (JSON fallback).
  - `src/core/mod.rs` — orchestration: `build_initial_state(issue)`, `replay(issue, activities) -> Vec<IssueStateEntry>`, `synthetic_initial` emission, `_seq` disambiguation for same-timestamp activities.
  - `src/core/tests.rs` — unit tests covering every activity category, single/multi-value backward, edge cases from v2 `applyBackward.test.ts` + `replayIssue.test.ts`.
  - Event kind enum: mirror jira `EventKind` column (Add / Remove / Set / SyntheticInitial); map YouTrack activity `$type` → `EventKind`.

- **Out of scope**:
  - ClickHouse I/O (feature 2.7).
  - Argo workflow orchestration (feature 2.8).

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-replay-backward`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-synthetic-initial`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-multi-value-backward`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-field-id-fallback`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-seq-disambiguation`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-enrich-deterministic`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-event-sourcing`
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-core-io-split`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-activitiespage-event-sourcing` (ADR-001 silver)
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-multi-value-backward` (ADR-002 silver)

- **Domain Model Entities**:
  - IssueStateEntry, FieldMetadata, ChangeSet, EventKind

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-core`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-types`

- **API**:
  - Rust library API: `core::replay(issue: YTIssue, activities: Vec<YTActivityItem>) -> Vec<IssueStateEntry>`
  - Internal: `core::apply_backward(activity, &mut state) -> Option<ApplyResult>`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-replay-backward`
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-synthetic-initial-emit`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-db-youtrack-enrich-in-memory-state`

---

### 2.7 [Rust `youtrack-enrich` — IO (ClickHouse)](feature-enrich-io/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-enrich-io`

- **Purpose**: Provide the ClickHouse I/O layer for `youtrack-enrich`: read from `staging.youtrack__changelog_items` + `staging.youtrack__issue_field_snapshot`; write to `staging.youtrack__task_field_history` (DDL owned by the shared `create_task_field_history_staging` macro). Binary entrypoint `main.rs` wires CLI args, tenant scope, batching, timeouts, and observability.

- **Depends On**: `cpt-insightspec-feature-youtrack-enrich-core`

- **Scope**:
  - `src/io/ch_client.rs` — ClickHouse client with `with_validation(false)` (avoid DESCRIBE hang per jira silver ADR), per-batch INSERT timeout (default 60s configurable).
  - `src/io/reader.rs` — batched SELECT from `staging.youtrack__changelog_items` and `staging.youtrack__issue_field_snapshot`; group by `issue_id`; stream `(YTIssue, Vec<YTActivityItem>)` to core.
  - `src/io/writer.rs` — INSERT `IssueStateEntry` rows into `staging.youtrack__task_field_history` with tenant/source tagging.
  - `src/io/schema.rs` — assert staging table schema matches expected columns (fail-fast).
  - `src/io/mod.rs` — io surface.
  - `src/main.rs` — CLI: `--tenant`, `--issue-batch-size`, `--per-batch-timeout-secs`, `--log-progress-every-n`, `--dry-run`; env: ClickHouse creds from K8s Secret.
  - `src/ingestion/run-tt-enrich-youtrack.sh` — shell wrapper mirroring `run-tt-enrich-jira.sh`.

- **Out of scope**:
  - Core replay (owned by feature 2.6).
  - Schema migrations (owned by dbt macro, feature 2.5 consumer).

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-ch-reader`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-ch-writer`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-enrich-cli`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-enrich-fail-fast-schema`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-enrich-batch-timeout`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-enrich-observability`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-core-io-split`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-ch-with-validation-false`
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-ddl-owned-by-dbt`

- **Domain Model Entities**:
  - BatchedIssueStream, ClickHouseRow

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-io-reader`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-io-writer`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-io-ch-client`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-main`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-enrich-shell-wrapper`

- **API**:
  - CLI: `youtrack-enrich --tenant <name> [--issue-batch-size 500] [--per-batch-timeout-secs 60]`
  - CLI shell: `./src/ingestion/run-tt-enrich-youtrack.sh <tenant>`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-enrich-batch-loop`
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-enrich-schema-assert`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-dbtable-youtrack-staging-youtrack__task_field_history` (written by Rust, DDL by dbt)

---

### 2.8 [Argo Workflow & CLI Integration](feature-argo-workflow/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-argo-workflow`

- **Purpose**: Add a YouTrack branch to the Argo `ingestion-pipeline` template: `airbyte-sync(youtrack) → dbt(tag:youtrack) → youtrack-enrich → dbt(tag:silver)`. Deliver `tt-enrich-youtrack-run.yaml` (standalone WorkflowTemplate). Build and publish the `youtrack-enrich` container image via the existing toolbox.

- **Depends On**: `cpt-insightspec-feature-youtrack-dbt-staging`, `cpt-insightspec-feature-youtrack-enrich-io`

- **Scope**:
  - `src/ingestion/workflows/templates/tt-enrich-youtrack-run.yaml` — new WorkflowTemplate, symmetric to `tt-enrich-jira-run.yaml`.
  - Update `src/ingestion/workflows/templates/ingestion-pipeline.yaml` — add `youtrack` branch; raise `airbyte-sync` poll deadline if first-time sync exceeds default.
  - Update `src/ingestion/tools/toolbox/build.sh` — build `youtrack-enrich` image (add to connectors array or generalize).
  - Verify `run-sync.sh youtrack <tenant>` submits the full pipeline.

- **Out of scope**:
  - Registering the Airbyte source definition in the cluster (handled by existing `connect.sh` discovery).
  - Secret creation (user manages via `./secrets/apply.sh`).

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-argo-pipeline-branch`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-standalone-enrich-wf-template`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-container-image-build`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-symmetry-with-jira`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-argo-poll-deadline`

- **Domain Model Entities**:
  - WorkflowTemplate, Workflow Run

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-wf-tt-enrich-youtrack-run`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-wf-ingestion-pipeline-branch`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-image-build`

- **API**:
  - `argo submit ingestion-pipeline --parameter connector=youtrack --parameter tenant=<tenant>`
  - `./src/ingestion/run-sync.sh youtrack <tenant>`
  - `./src/ingestion/logs.sh -f latest`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-argo-pipeline-branch`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-db-youtrack-argo-run-metadata`

---

### 2.9 [Silver Plug-In Verification](feature-silver-plugin/) — MEDIUM

- [ ] `p2` - **ID**: `cpt-insightspec-feature-youtrack-silver-plugin`

- **Purpose**: Verify that the existing `src/ingestion/silver/task-tracking/class_task_*` union models (delivered by PR #205) correctly include YouTrack rows via `union_by_tag('silver:class_task_*')` without any modification. No schema changes — only validation and a short operational note added to `src/ingestion/silver/task-tracking/schema.yml` describing YouTrack-specific caveats (missing-email fallback, multi-value cardinality quirks).

- **Depends On**: `cpt-insightspec-feature-youtrack-dbt-staging`, `cpt-insightspec-feature-youtrack-enrich-io`

- **Scope**:
  - After Features 2.5 and 2.7 land, run `dbt run --select tag:silver` and verify every `class_task_*` table contains rows with `source='youtrack'`.
  - Update `src/ingestion/silver/task-tracking/schema.yml` — add notes (only) for YouTrack-specific caveats; do not add new models or change existing columns.
  - Document the plug-in contract in the connector `README.md` (already present via feature 2.1).

- **Out of scope**:
  - Any change to `class_task_*` model SQL.
  - Cross-source dedup logic.

- **Requirements Covered**:
  - [ ] `p2` — `cpt-insightspec-fr-youtrack-silver-tag-plugin`
  - [ ] `p2` — `cpt-insightspec-nfr-youtrack-silver-backward-compat`

- **Design Principles Covered**:
  - [ ] `p2` — `cpt-insightspec-principle-youtrack-tag-based-union`
  - [ ] `p2` — `cpt-insightspec-principle-youtrack-silver-ownership-boundary`

- **Design Constraints Covered**:
  - [ ] `p2` — `cpt-insightspec-constraint-youtrack-no-silver-schema-change`

- **Domain Model Entities**:
  - ClassTask{Comments,Worklogs,Users,Projects,Sprints,FieldMetadata,FieldHistory}

- **Design Components**:
  - [ ] `p2` — `cpt-insightspec-component-youtrack-silver-union-class-task-star`

- **API**:
  - `dbt test --select tag:silver --select tag:task`

- **Sequences**:
  - [ ] `p2` — `cpt-insightspec-seq-youtrack-silver-verify-rows`

- **Data**:
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_field_history`
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_comments`
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_worklogs`
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_users`
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_projects`
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_sprints`
  - [ ] `p2` — `cpt-insightspec-dbtable-youtrack-class_task_field_metadata`

---

### 2.10 [Test Invariants & E2E Smoke](feature-tests-e2e/) — HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-youtrack-tests-e2e`

- **Purpose**: Ensure correctness across the full pipeline. Reuse the eleven source-agnostic dbt invariants in `src/ingestion/dbt/tests/task/` without modification (they operate on `silver.class_task_*` and work for any tagged source). Add one youtrack-specific Rust unit test case catalog. Perform an E2E smoke run on the test-tenant following the jira E2E playbook: bronze counts, silver counts, idempotency check, schema drift check.

- **Depends On**: `cpt-insightspec-feature-youtrack-silver-plugin`, `cpt-insightspec-feature-youtrack-argo-workflow`

- **Scope**:
  - Rust unit tests — extend `src/ingestion/connectors/task-tracking/youtrack/enrich/src/core/tests.rs` with fixtures covering every activity category enumerated in Phase 1 research.
  - dbt tests — run `dbt test --select tag:task` — verify all 11 invariants pass for YouTrack rows.
  - E2E smoke on test-tenant:
    1. Apply K8s Secret with test-tenant creds.
    2. Submit `./src/ingestion/run-sync.sh youtrack <tenant>`.
    3. Record bronze counts: `youtrack_issue`, `youtrack_issue_history`, `youtrack_comments`, `youtrack_worklogs`.
    4. Record silver counts: every `class_task_*` table — row count where `source='youtrack'`.
    5. Second run → bronze/silver idempotency (counts unchanged).
    6. Retry scenario — kill one Argo step mid-run, resume, verify final state.
  - Write smoke-run report to `docs/components/connectors/task-tracking/youtrack/specs/test-scenarios.md` appendix.

- **Out of scope**:
  - Adding new silver-level dbt tests (unless a genuine YouTrack-only invariant surfaces).
  - Load testing.

- **Requirements Covered**:
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-dbt-invariants-pass`
  - [ ] `p1` — `cpt-insightspec-fr-youtrack-e2e-smoke`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-idempotency`
  - [ ] `p1` — `cpt-insightspec-nfr-youtrack-schema-drift-detection`

- **Design Principles Covered**:
  - [ ] `p1` — `cpt-insightspec-principle-youtrack-test-invariants-source-agnostic`

- **Design Constraints Covered**:
  - [ ] `p1` — `cpt-insightspec-constraint-youtrack-reuse-jira-invariants`

- **Domain Model Entities**:
  - Invariant, E2ERun, BronzeCount, SilverCount

- **Design Components**:
  - [ ] `p1` — `cpt-insightspec-component-youtrack-rust-unit-tests`
  - [ ] `p1` — `cpt-insightspec-component-youtrack-e2e-smoke-report`

- **API**:
  - `cargo test --package youtrack-enrich`
  - `dbt test --select tag:task`
  - `./src/ingestion/run-sync.sh youtrack <tenant>`
  - `./src/ingestion/logs.sh -f latest`

- **Sequences**:
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-e2e-smoke-run`
  - [ ] `p1` — `cpt-insightspec-seq-youtrack-idempotency-check`

- **Data**:
  - [ ] `p1` — `cpt-insightspec-db-youtrack-e2e-counts-report`

---

## 3. Feature Dependencies

```text
cpt-insightspec-feature-youtrack-bronze-manifest
    ↓
    ├─→ cpt-insightspec-feature-youtrack-bronze-directories
    │       ↓
    │       ├─→ cpt-insightspec-feature-youtrack-bronze-issues
    │       │       ↓
    │       │       └─→ cpt-insightspec-feature-youtrack-dbt-staging
    │       │               ↓
    │       │               ├─→ cpt-insightspec-feature-youtrack-enrich-core
    │       │               │       ↓
    │       │               │       └─→ cpt-insightspec-feature-youtrack-enrich-io
    │       │               │               ↓
    │       │               │               └─→ cpt-insightspec-feature-youtrack-argo-workflow
    │       │               │                       ↓
    │       │               │                       └─→ cpt-insightspec-feature-youtrack-tests-e2e
    │       │               │
    │       │               └─→ cpt-insightspec-feature-youtrack-silver-plugin
    │       │                       ↑
    │       │                       └── (also needs enrich-io to populate field_history)
    │       │
    │       └─→ cpt-insightspec-feature-youtrack-custom-fields
    │               ↓
    │               └─→ (feeds into feature-dbt-staging — see above)
    │
    └─→ (manifest underpins every subsequent feature)
```

**Dependency Rationale**:

- `cpt-insightspec-feature-youtrack-bronze-directories` requires `cpt-insightspec-feature-youtrack-bronze-manifest`: the declarative manifest skeleton provides the shared `auth`, `error_handler`, `add_fields`, and pagination primitives every directory stream inherits.
- `cpt-insightspec-feature-youtrack-bronze-issues` requires `cpt-insightspec-feature-youtrack-bronze-directories`: `youtrack_issue` depends on resolved `youtrack_user` references at identity-resolution time, and the activities substream resolves field metadata against `youtrack_project_custom_fields` (feature 2.4) and `youtrack_projects`.
- `cpt-insightspec-feature-youtrack-custom-fields` requires `cpt-insightspec-feature-youtrack-bronze-directories`: custom-field discovery is a substream of `youtrack_projects`.
- `cpt-insightspec-feature-youtrack-dbt-staging` requires both `cpt-insightspec-feature-youtrack-bronze-issues` and `cpt-insightspec-feature-youtrack-custom-fields`: staging projections reference Bronze tables from both lineages; `youtrack__task_field_metadata.sql` depends on the project-scoped registry.
- `cpt-insightspec-feature-youtrack-enrich-core` requires `cpt-insightspec-feature-youtrack-dbt-staging`: the core replay reads `staging.youtrack__changelog_items` and `staging.youtrack__issue_field_snapshot`.
- `cpt-insightspec-feature-youtrack-enrich-io` requires `cpt-insightspec-feature-youtrack-enrich-core`: IO is the wrapper around the core replay function; cannot exist without it.
- `cpt-insightspec-feature-youtrack-argo-workflow` requires `cpt-insightspec-feature-youtrack-enrich-io` and `cpt-insightspec-feature-youtrack-dbt-staging`: Argo chains dbt + enrich and needs both to be runnable.
- `cpt-insightspec-feature-youtrack-silver-plugin` requires `cpt-insightspec-feature-youtrack-dbt-staging` and `cpt-insightspec-feature-youtrack-enrich-io`: silver verification depends on tagged staging models and populated field history.
- `cpt-insightspec-feature-youtrack-tests-e2e` requires `cpt-insightspec-feature-youtrack-silver-plugin` and `cpt-insightspec-feature-youtrack-argo-workflow`: E2E smoke needs the full orchestrated pipeline plus silver verification.

**Parallelism opportunities**:

- `cpt-insightspec-feature-youtrack-custom-fields` and `cpt-insightspec-feature-youtrack-bronze-issues` can be developed in parallel after `cpt-insightspec-feature-youtrack-bronze-directories`.
- `cpt-insightspec-feature-youtrack-silver-plugin` and `cpt-insightspec-feature-youtrack-argo-workflow` can be developed in parallel once `cpt-insightspec-feature-youtrack-enrich-io` and `cpt-insightspec-feature-youtrack-dbt-staging` are done.
- All Rust unit-test authoring (inside `cpt-insightspec-feature-youtrack-enrich-core` and `cpt-insightspec-feature-youtrack-tests-e2e`) can proceed alongside the implementation.

---

## 4. Coverage Reconciliation Note

> **Status**: provisional — coverage IDs below are **forward-looking**.

The `cpt-insightspec-fr-youtrack-*`, `-nfr-*`, `-principle-*`, `-constraint-*`, `-component-*`, `-seq-*`, and `-db-*` identifiers referenced throughout Section 2 are placeholders that will be reconciled with the concrete PRD and DESIGN artifacts once they are generated by the spec-generation plan at `cypilot/.plans/generate-youtrack-spec/`.

Reconciliation tasks (executed as part of the spec-plan Phase 12 Review Gate):

1. Regenerate or confirm ID stems using the slugs emitted by the PRD/DESIGN (`cpt list-ids --artifact docs/components/connectors/task-tracking/youtrack/specs/PRD.md`).
2. For every placeholder ID in this DECOMPOSITION, verify the corresponding real ID exists in the PRD/DESIGN; replace placeholders with real IDs.
3. Ensure 100% PRD/DESIGN coverage: every FR, NFR, principle, constraint, component, and sequence in PRD/DESIGN appears in at least one feature's "Covered" list.
4. Update checklist status markers (`[ ]`) to mirror implementation progress as code lands (via PRs referencing these feature IDs).
5. Promote `status: proposed` → `status: accepted` once PRD and DESIGN are merged.

Until reconciliation completes, treat this DECOMPOSITION as an **executable blueprint for code work**, independent of the final spec IDs. The feature boundaries, scope, dependencies, and parallelism rationale do **not** depend on the final IDs and are stable.
