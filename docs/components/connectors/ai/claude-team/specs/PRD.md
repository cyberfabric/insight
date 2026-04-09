# PRD — Claude Team Connector

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
  - [5.1 Seat Data Collection](#51-seat-data-collection)
  - [5.2 Code Usage Collection](#52-code-usage-collection)
  - [5.3 Workspace Management](#53-workspace-management)
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
  - [Configure Claude Team Connection](#configure-claude-team-connection)
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

The Claude Team connector extracts team seat assignments, Claude Code usage reports, workspace structures, workspace membership, and pending invitations from the Anthropic Admin API for Claude Team/Enterprise workspaces. It loads this data into the Insight platform's Bronze layer, enabling analytics teams to track AI assistant adoption across the organization's Claude subscription. The connector feeds two Silver targets: `class_ai_dev_usage` (Claude Code activity) and `class_ai_tool_usage` (web/mobile activity, currently a placeholder pending API availability).

### 1.2 Background / Problem Statement

Organizations running Claude Team or Enterprise subscriptions have no centralized visibility into who is actively using Claude, how developers use Claude Code for AI-assisted coding, how workspaces are structured, and which invitations are pending. The Anthropic Admin API exposes this data through five endpoint groups, but it must be ingested, identity-resolved, and routed to the appropriate Silver streams.

The Anthropic Admin API provides five data areas:

- **Users (Seats)** -- team member directory with role, status, and activity timestamps
- **Code Usage** -- daily Claude Code usage per user: tokens, tool calls, sessions
- **Workspaces** -- organizational workspace structure
- **Workspace Members** -- user-to-workspace assignments with roles
- **Invites** -- pending seat invitations with status and expiry

Unlike the Claude API connector (programmatic access, pay-per-token), Claude Team is flat per-seat -- different billing model, different clients, different analytics purpose.

**Target Users**:

- Platform operators who configure the Anthropic Admin API key and monitor extraction runs
- Data analysts who consume Claude Team usage data in Silver/Gold layers alongside Cursor and Windsurf
- Workspace administrators who monitor seat utilization and workspace structure

**Key Problems Solved**:

- Continuous extraction of Claude Team seat and usage data into the Insight Bronze layer
- Per-user Claude Code usage metrics (tokens, tool calls, sessions) for developer AI adoption tracking
- Workspace structure and membership for organizational visibility
- Identity resolution via `email` enabling joins with other source systems (Cursor, Windsurf, GitHub Copilot)

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Seat roster and workspace structure extracted daily with complete coverage (Baseline: no extraction; Target: Q2 2026)
- Claude Code usage data available for identity resolution within 48 hours of activity (Baseline: N/A; Target: Q2 2026)
- Claude Code data integrated with Cursor and Windsurf in the unified `class_ai_dev_usage` Silver stream (Baseline: Claude Team only; Target: Q3 2026)

**Capabilities**:

- Extract team member directory from `GET /v1/organizations/users` for identity resolution and seat utilization
- Extract daily Claude Code usage from `GET /v1/organizations/usage_report/claude_code` with token metrics and tool call counts
- Extract workspace structures from `GET /v1/organizations/workspaces`
- Extract workspace membership from `GET /v1/organizations/workspaces/{id}/members` (iterates over all workspaces)
- Extract pending invitations from `GET /v1/organizations/invites`
- Incremental extraction for code usage using date-based cursor
- Identity resolution via `email` (from users table and `actor_identifier` in code usage)

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Anthropic Admin API | Anthropic's REST API for Team/Enterprise workspace administration. Endpoints under `https://api.anthropic.com/v1/organizations/` provide user management, usage reports, and workspace operations. |
| Admin API Key | Authentication credential for the Anthropic Admin API. Sent via `x-api-key` header with `anthropic-version: 2023-06-01`. |
| Seat | An assigned Claude Team subscription slot for a specific user. |
| Claude Code | CLI-based AI coding assistant from Anthropic. Generates developer-style usage patterns: high tool call counts, large token volumes, multi-turn sessions. |
| Code Usage | Daily aggregated Claude Code usage per user, per terminal type. Contains token metrics (input, output, cache read, cache write), tool call counts, and session counts. |
| Workspace | An organizational unit within a Claude Team/Enterprise account that groups users and controls access. |
| `actor_identifier` | The `email` address of the user in code usage reports (when `actor_type = 'user'`). |
| `person_id` | Canonical cross-system person identifier resolved by the Identity Manager. |
| `class_ai_dev_usage` | Silver stream for developer/IDE AI tool usage (Cursor, Windsurf, Claude Code). |
| `class_ai_tool_usage` | Silver stream for conversational AI tool usage (Claude Team web/mobile, ChatGPT Team). Currently a placeholder for Claude Team -- the Admin API does not expose web/mobile activity separately. |
| Bronze Table | Raw data table in the destination, preserving source-native field names and types without transformation. |
| `data_source` | Discriminator field set to `insight_claude_team` in all Bronze rows. |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-claude-team-operator`

**Role**: Obtains the Anthropic Admin API key from the Anthropic Console, provides it to the connector, and monitors extraction runs.
**Needs**: Ability to configure the connector with the API key and verify that data is flowing correctly for all streams.

#### Workspace Administrator

**ID**: `cpt-insightspec-actor-claude-team-admin`

**Role**: Manages the Claude Team subscription, grants/revokes seat access, manages workspaces, and monitors usage.
**Needs**: Visibility into seat utilization, inactive seats, workspace structure, pending invitations, and overall adoption trends.

#### Data Analyst

**ID**: `cpt-insightspec-actor-claude-team-analyst`

**Role**: Consumes Claude Team usage data from Silver/Gold layers to build dashboards combining AI dev tool metrics across Claude Code, Cursor, and Windsurf.
**Needs**: Complete, gap-free usage data with identity resolution to canonical person IDs for cross-platform aggregation.

### 2.2 System Actors

#### Anthropic Admin API

**ID**: `cpt-insightspec-actor-claude-team-anthropic-api`

**Role**: External REST API providing user management, usage reports, workspace structure, and invitation data. Enforces rate limits and requires API key authentication via `x-api-key` header.

#### Identity Manager

**ID**: `cpt-insightspec-actor-claude-team-identity-mgr`

Resolves `email` from Claude Team Bronze tables to canonical `person_id` in Silver step 2. Enables cross-system joins (Claude Code + Cursor + Windsurf + GitHub + Jira, etc.).

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires a Claude Team or Enterprise account with Admin API access and a valid Admin API key
- The Admin API key must have organization-level read permissions (users, usage, workspaces, invites)
- Authentication uses `x-api-key` header with `anthropic-version: 2023-06-01` required on all requests
- The connector **SHOULD** run daily -- all streams are daily or current-state snapshots
- The Anthropic Admin API enforces rate limits; the connector must add a 1-second delay between paginated pages for users and between workspace iterations for workspace members
- Code usage data uses a date-only parameter `starting_at` (format `YYYY-MM-DD`); the `claude_code` endpoint does not accept `ending_at` or `bucket_width`
- Workspace members requires iterating over all workspaces first (SubstreamPartitionRouter pattern)

## 4. Scope

### 4.1 In Scope

- Collection of current seat assignments (users: role, status, activity timestamps)
- Collection of daily Claude Code usage per user, per terminal type
- Collection of workspace structures and workspace-level membership
- Collection of pending invitations
- Connector execution monitoring via a collection runs stream
- Identity resolution via `email` and `actor_identifier`
- Bronze-layer table schemas for all streams
- Silver routing: Claude Code usage to `class_ai_dev_usage`
- Silver placeholder: `class_ai_tool_usage` (web/mobile activity not available from current API)

### 4.2 Out of Scope

- Programmatic Claude API usage -- covered by the Claude API connector (`class_ai_api_usage`)
- Web/mobile Claude usage metrics -- the Admin API's code usage endpoint is specifically for Claude Code; web/mobile activity data may come from a separate messages_usage mechanism in a future connector
- Real-time or sub-daily granularity -- the Admin API provides daily aggregates only
- Per-request cost attribution -- under Team Plan billing, per-token cost is not meaningful
- Versioning or history of seat assignment changes (current-state only)
- Gold layer transformations and cross-source aggregation -- responsibility of the AI dev tool domain pipeline
- Silver step 2 (identity resolution: `email` to `person_id`) -- responsibility of the Identity Manager

## 5. Functional Requirements

### 5.1 Seat Data Collection

#### Extract Users (Seat Roster)

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-team-users-collect`

The connector **MUST** extract all current seat assignments from the `GET /v1/organizations/users` endpoint, capturing each user's `id`, `email`, `name`, `role` (owner/admin/member), `status` (active/inactive/pending), `added_at`, and `last_active_at`.

**Rationale**: The seat roster enables utilization reporting -- identifying inactive seats, tracking adoption growth, and providing the `email` identity key for cross-system resolution.

**Actors**: `cpt-insightspec-actor-claude-team-admin`, `cpt-insightspec-actor-claude-team-analyst`

#### Represent Seat Data as Current-State Snapshot

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-team-users-snapshot`

The user collection **MUST** represent current-state only (one row per user, no historical versioning), consistent with the source API's snapshot model.

**Rationale**: The Anthropic Admin API does not provide user change history; the Bronze table must accurately reflect its capabilities.

**Actors**: `cpt-insightspec-actor-claude-team-analyst`

#### Extract Pending Invitations

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-team-invites-collect`

The connector **MUST** extract all pending invitations from the `GET /v1/organizations/invites` endpoint, capturing `id`, `email`, `role`, `status`, `invited_at`, `expires_at`, and `workspace_id`.

**Rationale**: Invitations complement the seat roster by showing planned but not-yet-accepted seats. Combined with user data, they provide a complete picture of license allocation.

**Actors**: `cpt-insightspec-actor-claude-team-admin`

### 5.2 Code Usage Collection

#### Extract Daily Claude Code Usage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-team-code-usage-collect`

The connector **MUST** extract daily Claude Code usage records from the `GET /v1/organizations/usage_report/claude_code` endpoint, capturing: `date`, `actor_type`, `actor_identifier` (email for users), `terminal_type`, and all available metrics (input tokens, output tokens, cache read/write tokens, tool calls, sessions, etc.).

**Rationale**: Claude Code usage is the primary data source feeding the `class_ai_dev_usage` Silver stream, enabling cross-platform comparison with Cursor and Windsurf. The granularity is one row per `(date, actor_type, actor_identifier, terminal_type)`.

**Actors**: `cpt-insightspec-actor-claude-team-analyst`, `cpt-insightspec-actor-claude-team-admin`

#### Incremental Sync for Code Usage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-team-code-usage-incremental`

The connector **MUST** support incremental sync for code usage using a date-based cursor (`date` field). On each run, only new days since the last cursor position are fetched. On first run, the connector fetches from a configurable `start_date` (default: 90 days ago) forward to today.

**Rationale**: Incremental sync avoids re-fetching the entire usage history on each run. The fixed lookback window is configurable via `start_date` for organizations needing deeper history.

**Actors**: `cpt-insightspec-actor-claude-team-operator`

### 5.3 Workspace Management

#### Extract Workspaces

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-team-workspaces-collect`

The connector **MUST** extract all workspaces from the `GET /v1/organizations/workspaces` endpoint, capturing `id`, `name`, `display_name`, `created_at`, `archived_at`, and `data_residency` (nested object).

**Rationale**: Workspaces provide the organizational structure for workspace-level analytics and are the parent entity for workspace membership.

**Actors**: `cpt-insightspec-actor-claude-team-admin`

#### Extract Workspace Members

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-team-workspace-members-collect`

The connector **MUST** extract workspace membership by iterating over all workspaces and fetching members from `GET /v1/organizations/workspaces/{id}/members` for each workspace. Each record captures `user_id`, `workspace_id`, and `workspace_role`. The composite primary key is `{user_id}:{workspace_id}`.

**Rationale**: Workspace membership enables per-workspace utilization analysis and access auditing. The iteration pattern requires a SubstreamPartitionRouter keyed on workspace IDs from the `claude_team_workspaces` stream.

**Actors**: `cpt-insightspec-actor-claude-team-admin`

### 5.4 Connector Operations

#### Track Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-team-collection-runs`

The connector **MUST** produce a collection run log entry for each execution, recording: `run_id`, `started_at`, `completed_at`, `status`, per-stream record counts, `api_calls`, `errors`, and `settings`.

**Rationale**: Operational visibility into connector health. Enables alerting on failed runs and tracking data completeness over time.

**Actors**: `cpt-insightspec-actor-claude-team-operator`

### 5.5 Data Integrity

#### Deduplicate by Primary Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-team-deduplication`

Each stream **MUST** use a primary key to ensure that re-running the connector for an overlapping date range does not produce duplicate records:

- `claude_team_users`: key = `id`
- `claude_team_code_usage`: key = `unique` (computed composite)
- `claude_team_workspaces`: key = `id`
- `claude_team_workspace_members`: key = `unique` (computed as `{user_id}:{workspace_id}`)
- `claude_team_invites`: key = `id`
- `claude_team_collection_runs`: key = `run_id`

**Rationale**: Full-refresh streams overwrite completely, but incremental streams (code usage) may overlap with previously fetched dates. Deduplication ensures idempotent extraction.

**Actors**: `cpt-insightspec-actor-claude-team-anthropic-api`

### 5.6 Identity Resolution

#### Expose Identity Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-team-identity-key`

The `claude_team_users` stream **MUST** include `email` as a non-null identity field. The `claude_team_code_usage` stream **MUST** include `actor_identifier` (which contains email when `actor_type = 'user'`). These fields are used by the Identity Manager to resolve Claude Team users to canonical `person_id` values in the Silver layer.

**Exemption**: The monitoring stream `claude_team_collection_runs` does not carry a user identity field. Workspace and invite streams carry `user_id` (Anthropic-internal) and `email` respectively, but identity resolution is primarily driven by the users and code usage streams.

**Rationale**: Cross-system identity resolution is the foundation of the Insight platform's analytics. Email is a reliable, stable identifier shared across Claude Team, Cursor, Windsurf, and most enterprise systems.

**Actors**: `cpt-insightspec-actor-claude-team-identity-mgr`

#### Use Email as the Sole Identity Key

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-team-identity-email-only`

The connector **MUST** treat `email` as the primary identity key for cross-system resolution. The Anthropic-internal `id` field (user ID) **MUST NOT** be used for cross-system identity resolution.

**Rationale**: `id` is an Anthropic-platform-internal identifier not meaningful outside the Anthropic ecosystem. `email` is the stable cross-platform identity key.

**Actors**: `cpt-insightspec-actor-claude-team-identity-mgr`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Data Freshness

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-claude-team-freshness`

The connector **MUST** be executable on a daily schedule such that activity data for day D is available by the start of day D+2.

**Threshold**: Data available in Bronze within 48 hours of activity occurrence.

**Rationale**: Daily AI tool adoption reports require timely data; a 48-hour window accommodates known Anthropic API reporting delays.

#### Extraction Completeness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-claude-team-completeness`

The connector **MUST** extract 100% of records reported by the Anthropic Admin API for each stream on each run, with zero record loss.

**Threshold**: Records extracted = records available in API (per stream, per date range).

**Rationale**: Partial extraction leads to incorrect per-user metrics, understated adoption, and unreliable cross-tool comparisons.

#### Schema Stability

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-claude-team-schema-stability`

Bronze table schemas **MUST** remain stable across connector versions. Breaking schema changes **MUST** be versioned with migration guidance.

**Threshold**: Zero unannounced breaking changes to field names or types across all Bronze tables.

**Rationale**: Downstream Silver/Gold pipelines -- including two separate Silver targets -- depend on stable Bronze schemas.

### 6.2 NFR Exclusions

- **Throughput / latency**: Not applicable -- all streams are low-volume (tens to hundreds of records per sync for typical teams).
- **Availability**: Batch connector -- availability is determined by the orchestrator's scheduling, not by this connector.
- **Cost accuracy**: Not applicable -- Claude Team is flat per-seat pricing; no per-request cost fields exist.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Claude Team Stream Contract

- [ ] `p1` - **ID**: `cpt-insightspec-interface-claude-team-streams`

**Type**: Data format (Bronze table schemas)

**Stability**: stable

**Description**: Six Bronze streams with defined schemas -- `claude_team_users`, `claude_team_code_usage`, `claude_team_workspaces`, `claude_team_workspace_members`, `claude_team_invites`, `claude_team_collection_runs`. The users stream uses `email` as the identity key; the code usage stream uses `actor_identifier`. The `date` field is the cursor for incremental sync on code usage.

**Breaking Change Policy**: Adding new fields is non-breaking. Removing or renaming fields requires a migration.

**Migration (PR #142)**: The config spec renamed `tenant_id` → `insight_tenant_id` and added `insight_source_id` as required. This is a breaking change for existing Airbyte sources. Deployment procedure: (1) ensure K8s Secrets have `insight.cyberfabric.com/source-id` annotation, (2) run `register.sh` to update the Airbyte definition, (3) run `connect.sh` to update existing source configs. Step 3 auto-injects `insight_tenant_id` and `insight_source_id` from tenant YAML and Secret annotation. Without step 3, existing sources will fail validation on next sync.

### 7.2 External Integration Contracts

#### Anthropic Admin API

- [ ] `p1` - **ID**: `cpt-insightspec-contract-claude-team-admin-api`

**Direction**: required from external system

**Protocol/Format**: REST / JSON

| Stream | Endpoint | Method |
|--------|----------|--------|
| `claude_team_users` | `GET /v1/organizations/users?limit=100` | Full refresh |
| `claude_team_code_usage` | `GET /v1/organizations/usage_report/claude_code?starting_at=YYYY-MM-DD` | Incremental |
| `claude_team_workspaces` | `GET /v1/organizations/workspaces?limit={n}` | Full refresh |
| `claude_team_workspace_members` | `GET /v1/organizations/workspaces/{id}/members` | Full refresh (iterates workspaces) |
| `claude_team_invites` | `GET /v1/organizations/invites?limit={n}` | Full refresh |

**Authentication**: API key via `x-api-key` header, with required `anthropic-version: 2023-06-01` header.

**Compatibility**: Anthropic Admin API. Response format is JSON; pagination varies by stream (cursor-based for users, next-page token for code_usage, offset for workspaces/invites). See [DESIGN.md](./DESIGN.md) §3.3 for details. Field additions are non-breaking. Pagination parameter details are documented in [DESIGN.md](./DESIGN.md) §3.3.

## 8. Use Cases

### Configure Claude Team Connection

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-claude-team-configure`

**Actor**: `cpt-insightspec-actor-claude-team-operator`

**Preconditions**:

- Claude Team or Enterprise account with Admin API access
- Admin API key generated from the Anthropic Console

**Main Flow**:

1. Operator provides the Anthropic Admin API key and tenant ID
2. System validates credentials against the Anthropic API (`GET /v1/organizations/users`)
3. System initializes the connection with empty state

**Postconditions**:

- Connection is ready for first sync run

**Alternative Flows**:

- **Invalid API key**: System reports authentication failure (HTTP 401); operator corrects API key
- **Missing anthropic-version header**: API returns error; system retries with correct header
- **Rate limited on check**: System retries after backoff; reports success if retry succeeds

### Incremental Sync Run

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-claude-team-incremental-sync`

**Actor**: `cpt-insightspec-actor-claude-team-operator`

**Preconditions**:

- Connection configured and credentials valid
- Previous state available (or empty for first run)

**Main Flow**:

1. Orchestrator triggers the connector with current state
2. Connector fetches users from `GET /v1/organizations/users` (full refresh, cursor-paginated)
3. Connector fetches code usage from `GET /v1/organizations/usage_report/claude_code` for the date range from last cursor to now
4. Connector fetches workspaces from `GET /v1/organizations/workspaces` (full refresh)
5. Connector fetches workspace members by iterating over each workspace ID and calling `GET /v1/organizations/workspaces/{id}/members`
6. Connector fetches invites from `GET /v1/organizations/invites` (full refresh)
7. For each stream: paginate through all pages, emit records with deduplication keys
8. Updated cursor positions captured after successful write

**Postconditions**:

- Bronze tables contain new records
- State updated with latest cursor position for code usage stream

**Alternative Flows**:

- **First run (code usage)**: Connector fetches from configurable `start_date` (default: 90 days ago) forward to today
- **API throttling (HTTP 429)**: Connector retries with exponential backoff
- **Empty date range**: No new data to fetch; sync completes with zero records
- **Workspace iteration**: If workspace list is empty, workspace members stream emits zero records

## 9. Acceptance Criteria

- Users stream extracts all members from a live Claude Team account with `email`, `role`, and `status` fields populated
- Code usage stream extracts daily Claude Code usage records with `actor_identifier` (email), `date`, and token metrics
- Workspaces stream extracts all workspaces with `id`, `name`, and `created_at`
- Workspace members stream extracts membership for all workspaces, with correct `{user_id}:{workspace_id}` composite keys
- Invites stream extracts all pending invitations with `email`, `role`, and `status`
- Incremental sync on second run extracts only new code usage data (no duplicates)
- Full-refresh streams (users, workspaces, workspace members, invites) replace their complete dataset on each run
- `email` is present in users records; `actor_identifier` is present in code usage records
- Pagination is exhausted for all paginated endpoints (no truncated results)
- API key authentication with `x-api-key` header and `anthropic-version: 2023-06-01` works correctly
- `tenant_id` is present in every record emitted by the connector (injected via `AddFields` transformation)
- `data_source` is set to `insight_claude_team` in every record

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Anthropic Admin API | Users, code usage, workspaces, workspace members, invites endpoints | `p1` |
| Anthropic Admin API key | Authentication credential (Team/Enterprise workspace) | `p1` |
| Airbyte Declarative Connector framework (latest) | Execution model for running the connector | `p1` |
| Identity Manager | Resolves `email`/`actor_identifier` to `person_id` in Silver | `p2` |
| Destination store (PostgreSQL / ClickHouse) | Target for Bronze tables | `p1` |

## 11. Assumptions

- The Claude Team account is on a Team or Enterprise plan with Admin API access enabled
- The Admin API key has been generated by an organization admin from the Anthropic Console
- The Anthropic Admin API response format remains stable across minor versions
- `email` in the users endpoint and `actor_identifier` in the code usage endpoint are stable, non-null fields for user-type actors
- Code usage data granularity is one row per `(date, actor_type, actor_identifier, terminal_type)`
- Endpoints use mixed pagination: cursor-based (`after_id`) for users, next-page token for code_usage, offset for workspaces/workspace_members/invites. Parameter names are configured in the connector manifest
- The `anthropic-version: 2023-06-01` header is required on all requests and will remain stable
- Workspace members can be fetched by iterating over workspace IDs from the workspaces endpoint
- Daily usage data is available with D+1 lag (same day or next day)

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| API key revoked or rotated by admin | All streams fail | Monitor sync status; alert on authentication failures; document key rotation procedure |
| Admin API rate limiting | Extraction takes longer; risk of timeout | Handle rate limiting with 1s inter-page delay and exponential backoff on 429 |
| `actor_identifier` null for non-user actor types | Identity resolution fails for API-key actors | Filter to `actor_type = 'user'` rows in Silver; document that API-key actors are excluded from identity resolution |
| Workspace membership iteration is slow for many workspaces | Sync time proportional to workspace count | Add 1s delay between workspace requests; accept linear scaling |
| Code usage API does not expose web/mobile activity | `class_ai_tool_usage` Silver target has no data from this connector | Create placeholder dbt model; document the gap; monitor Anthropic API for future endpoints |
| Admin API versioning changes | Request format or response schema may change | Pin `anthropic-version: 2023-06-01`; monitor Anthropic release notes |

## 13. Open Questions

Open questions are tracked in the DESIGN document ([DESIGN.md](./DESIGN.md) -- Open Questions). Key items requiring resolution:

| ID | Summary | Owner | Target |
|----|---------|-------|--------|
| OQ-CT-1 | Web/mobile usage data -- the current code_usage endpoint is Claude Code only; web/mobile activity requires a separate mechanism | Data Architecture | Q2 2026 |
| OQ-CT-2 | Relationship between Claude Team and Claude API for the same user (same `person_id`, different Silver streams) | Data Architecture | Q2 2026 |
| OQ-CT-3 | `class_ai_dev_usage` unified schema -- Claude Code metrics differ from Cursor/Windsurf (no completions_accepted, has tool_use_count) | Data Architecture | Q2 2026 |
| OQ-CT-4 | Backfill depth -- how far back should the connector probe on first run before stopping? | Connector Team | Q2 2026 |

## 14. Non-Applicable Requirements

The following checklist domains have been evaluated and determined not applicable for this connector:

| Domain | Reason |
|--------|--------|
| **Security (SEC)** | The connector handles a single API key, marked `airbyte_secret` by the Airbyte framework. No custom authentication, authorization, or data protection logic exists in the declarative manifest. Security architecture is delegated to the Airbyte platform. |
| **Safety (SAFE)** | Pure data extraction pipeline. No interaction with physical systems, no potential for harm to people, property, or environment. |
| **Performance (PERF)** | Batch connector with native API pagination. No caching, pooling, or latency optimization needed. Rate limit handling (1s inter-page delay) is the only performance concern, documented in SS3.1. |
| **Reliability (REL)** | Idempotent extraction via deduplication keys. No distributed state, no transactions, no saga patterns. Recovery is handled by re-running the sync (Airbyte framework manages state). |
| **Usability (UX)** | No user-facing interface. Configuration is two fields (tenant_id, admin_api_key) in the Airbyte UI. |
| **Compliance (COMPL)** | Work emails are personal data under GDPR. Retention, deletion, and access controls are delegated to the Airbyte platform and destination operator. The connector must not store credentials outside the platform's secret management. |
| **Maintainability (MAINT)** | Declarative YAML manifest -- no custom code to maintain. Schema changes are handled by updating field definitions in the manifest. |
| **Testing (TEST)** | Connector behaviour must satisfy PRD acceptance criteria (SS9). Validation includes: Airbyte framework connection check, schema validation, and connector-specific acceptance tests. No custom unit tests required -- the declarative manifest is validated by the framework. |
