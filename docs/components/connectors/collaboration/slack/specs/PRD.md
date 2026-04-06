# PRD — Slack Connector

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
  - [5.1 Chat Activity Extraction](#51-chat-activity-extraction)
  - [5.2 Meeting Activity Extraction](#52-meeting-activity-extraction)
  - [5.3 User Directory](#53-user-directory)
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
  - [UC-001 Configure Slack Connection](#uc-001-configure-slack-connection)
  - [UC-002 Incremental Sync Run](#uc-002-incremental-sync-run)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Resolved Questions](#13-resolved-questions)
- [14. Non-Applicable Requirements](#14-non-applicable-requirements)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Slack Connector extracts per-user daily chat message activity, huddle (audio/video meeting) participation, and user directory data from the Slack Web API and loads them into the Insight platform's Bronze layer using the unified collaboration schema (`collab_*` tables). It enables the platform to measure async communication intensity, meeting load from huddles, and cross-platform collaboration patterns alongside Microsoft 365 and Zulip data.

### 1.2 Background / Problem Statement

Slack is one of the most widely adopted team messaging platforms. Insight already supports Microsoft 365 and Zulip as collaboration sources, but many organizations rely on Slack as their primary async communication tool. To deliver a complete view of collaboration patterns, Insight must ingest Slack activity into the same unified collaboration pipeline.

The Slack Web API provides two distinct collection strategies depending on the deployment tier:

- **Standard workspaces**: The connector reads message history per channel via `conversations.history` and aggregates message counts by user per day. This provides per-channel-type granularity (DM, group DM, public channel, private channel) but requires high API call volume.
- **Enterprise Grid**: The `admin.analytics.getFile` endpoint returns pre-aggregated per-user per-day metrics (`messages_posted` total). This is far more efficient but sacrifices per-channel-type breakdown.

Unlike M365 which provides pre-aggregated daily reports, standard Slack collection requires the connector to read raw message history and aggregate it. This creates a fundamentally different operational profile — higher API call volume, rate limit sensitivity, and a need to cache channel metadata for message type attribution.

Slack has no internal email or document collaboration product. The `collab_email_activity` and `collab_document_activity` unified tables are not populated for `insight_slack`.

**Target Users**:

- Platform operators who configure Slack app credentials, OAuth scopes, and monitor extraction runs
- Data analysts who consume Slack activity data in Silver/Gold layers alongside M365 and Zulip for unified collaboration metrics
- Organization leaders who use communication metrics to understand async collaboration load, meeting culture, and cross-team communication patterns

**Key Problems Solved**:

- Lack of Slack data in the Insight platform, preventing unified collaboration analytics across Slack, M365, and Zulip teams
- No visibility into async communication intensity (chat volume, DM vs. channel balance) for Slack-using teams
- Missing huddle participation data needed to compare synchronous collaboration load across Slack and M365 Teams
- No cross-system identity resolution between Slack users and other Insight sources (Jira, GitHub, M365)
- Inability to measure Enterprise Grid collaboration at scale without the pre-aggregated analytics endpoint

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Slack chat activity extracted with no missed sync windows over a 90-day period (Baseline: no Slack extraction; Target: v1.0)
- Per-user Slack activity available for identity resolution within 24 hours of extraction (Baseline: N/A; Target: v1.0)
- Slack data unified with M365 and Zulip in the `collab_*` Silver tables for cross-source communication analytics (Baseline: M365 + Zulip only; Target: v1.0)

**Capabilities**:

- Extract per-user daily chat message counts across DMs, group DMs, and channels
- Extract huddle participation as meeting activity
- Support two collection strategies: standard workspace (per-channel history) and Enterprise Grid (pre-aggregated analytics)
- Identity resolution via `email` from Slack user directory
- Filter out bot users from activity metrics

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Slack Web API | Slack's REST API (`https://slack.com/api/`) providing access to channels, messages, users, and analytics data. |
| Bot Token | OAuth 2.0 token (`xoxb-*`) used by Slack apps to authenticate API requests. Scopes determine which data the token can access. |
| Channel Types | Slack supports four channel types: `im` (1:1 DM), `mpim` (group DM), `public_channel`, and `private_channel`. |
| Huddle | Slack's in-channel audio/video meeting feature. Treated as a synchronous collaboration signal mapped to `collab_meeting_activity`. |
| Enterprise Grid | Slack's enterprise deployment model with multi-workspace support and additional admin APIs including `admin.analytics.getFile` for pre-aggregated metrics. |
| Standard Workspace | A single Slack workspace without Enterprise Grid. Collection uses `conversations.history` per channel. |
| Bronze Table | Raw data table in the destination, preserving source-native field names and types without transformation. |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-slack-operator`

**Role**: Creates the Slack app, configures OAuth scopes, installs the app to the workspace, and monitors extraction runs.
**Needs**: Ability to configure the connector with Slack credentials, select the collection strategy (standard vs. Enterprise Grid), and verify that data is flowing correctly for all streams.

#### Data Analyst

**ID**: `cpt-insightspec-actor-slack-analyst`

**Role**: Consumes Slack chat and huddle activity data from Silver/Gold layers to build dashboards for communication intensity, async vs. sync balance, and cross-platform collaboration metrics — alongside M365 and Zulip data.
**Needs**: Complete, gap-free daily activity data with identity resolution to canonical person IDs for cross-platform aggregation.

### 2.2 System Actors

#### Slack Web API

**ID**: `cpt-insightspec-actor-slack-api`

**Role**: External REST API providing message history, channel metadata, user directory, and analytics data. Enforces rate limits by tier (Tier 2: 20 req/min for users/channels; Tier 3: 50 req/min for message history) and requires OAuth 2.0 Bot Token authentication.

#### Identity Manager

**Ref**: `cpt-insightspec-actor-identity-manager`

**Role**: Resolves `email` from Slack user directory to canonical `person_id` in Silver step 2. Enables cross-system joins (Slack + M365 + Zulip + Jira + GitHub, etc.).

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires a Slack app installed to the target workspace with the following OAuth scopes: `channels:history`, `channels:read`, `groups:history`, `groups:read`, `im:history`, `im:read`, `mpim:history`, `mpim:read`, `users:read`, `users:read.email`
- Enterprise Grid collection additionally requires admin-level token and `admin.analytics:read` scope
- The connector operates as a batch collector; the recommended run frequency is daily
- Slack API enforces tiered rate limits: Tier 2 (20 req/min) for user and channel listing, Tier 3 (50 req/min) for message history; the connector must handle HTTP 429 responses with `Retry-After` header
- For standard workspaces, API call volume scales with the number of channels — large workspaces with thousands of channels may require extended collection windows
- Enterprise Grid mode significantly reduces API call volume by using pre-aggregated analytics, but loses per-channel-type message breakdown

## 4. Scope

### 4.1 In Scope

- Extraction of per-user daily chat message counts (DMs, group DMs, channel posts, channel replies) into `collab_chat_activity`
- Extraction of per-user daily huddle participation into `collab_meeting_activity`
- Extraction of Slack user directory into `collab_users`
- Two collection strategies: standard workspace (conversations.history) and Enterprise Grid (admin.analytics.getFile)
- Bot user filtering — exclude `is_bot = true` users from activity metrics and user directory
- Connector execution monitoring via `slack_collection_runs` stream
- Incremental sync using date-based lookback window
- Identity resolution via `email` from user directory
- All timestamps normalized to UTC
- `insight_source_id` and `tenant_id` stamped on every record

### 4.2 Out of Scope

- Silver/Gold layer transformations — responsibility of the collaboration domain pipeline
- Silver step 2 (identity resolution: `email` → `person_id`) — responsibility of the Identity Manager
- Real-time streaming — this connector operates in batch mode
- Slack email activity — Slack has no internal email product; `collab_email_activity` is not populated
- Slack document activity — file sharing is not modelled as document collaboration; `collab_document_activity` is not populated
- Slack Calls API — voice/video calls outside of huddles are a separate product and not in scope
- Message content extraction — only aggregate counts are collected, not message body text
- Slack Connect (cross-organization channels) — deferred to a future release
- Webhook or Events API integration — this connector uses polling, not event-driven collection

## 5. Functional Requirements

### 5.1 Chat Activity Extraction

#### Extract Chat Activity — Standard Workspace

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-chat-standard`

For standard Slack workspaces, the connector **MUST** extract per-user daily chat message counts by reading `conversations.history` for all accessible channels and aggregating messages by user, date, and channel type. The connector **MUST** populate `direct_messages` (from `im` channels), `group_chat_messages` (from `mpim` channels), `channel_posts` (from `public_channel` and `private_channel`), `channel_replies` (threaded replies), and `total_chat_messages` (sum of all).

**Rationale**: Per-channel-type granularity is essential for distinguishing async communication patterns (DM-heavy vs. channel-centric teams). Standard workspace collection is the only way to obtain this breakdown.

**Actors**: `cpt-insightspec-actor-slack-api`, `cpt-insightspec-actor-slack-analyst`

#### Handle Thread Reply Collection (N+1 Mitigation)

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-thread-batching`

The connector **MUST** collect thread reply counts and author attribution by calling `conversations.replies` for each parent message with `reply_count > 0`. Because `conversations.history` returns only parent messages, this is the only way to populate the `channel_replies` field and attribute replies to individual users.

**Architectural constraint**: The Airbyte Declarative Connector framework (YAML) executes parent-child stream relationships synchronously — the parent stream (`conversations.history`) yields records, and the child stream (`conversations.replies`) processes each record sequentially before the parent advances. True async workers or parallel queues are not supported in Declarative YAML.

The connector **MUST** enforce rate-limit-safe reply collection that:
1. Preserves the primary channel scanning progress — thread reply fetching **MUST NOT** monopolize the shared Tier 3 rate limit budget.
2. Supports partial completion — if reply volume exceeds the available rate limit budget, the connector **MUST** log skipped threads for potential retry in a follow-up run rather than failing the entire sync.
3. Prioritizes channels with higher message volume when budget is constrained.

**Architectural constraint**: The Airbyte Declarative Connector framework executes parent-child stream relationships synchronously. Concrete throttling parameters, batching strategy, and the decision on whether to migrate to Python CDK for async support are deferred to DESIGN.

**Rationale**: In active workspaces, thousands of messages per day may have threaded replies. Each requires a separate `conversations.replies` call sharing the Tier 3 rate limit (50 req/min) with `conversations.history`. Without explicit throttling, thread collection will monopolize the rate limit budget and stall channel scanning.

**Actors**: `cpt-insightspec-actor-slack-api`, `cpt-insightspec-actor-slack-operator`

#### Extract Chat Activity — Enterprise Grid (Hybrid Strategy)

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-chat-enterprise`

For Enterprise Grid workspaces, the connector **MUST** implement a hybrid collection strategy:

1. **Primary (fast path)**: Extract `total_chat_messages` from `admin.analytics.getFile` with `type=member`. This provides per-user daily totals with minimal API cost.
2. **Optional deep enrichment**: When the operator enables "Deep Channel Analytics" in the connection configuration, a **separate Airbyte connection** (using the same connector configured as a Standard-mode sync targeting the same workspace) runs on a slower schedule to enrich the data with per-channel-type breakdown (`direct_messages`, `group_chat_messages`, `channel_posts`, `channel_replies`). This is an independent connection with its own schedule and rate limit budget — not a background thread within the primary sync.
3. When deep enrichment has not yet run for a given date, per-channel-type fields remain `null` while `total_chat_messages` is populated from the analytics file. Once the enrichment connection processes the same date, it upserts the per-type breakdown via the same deduplication key.

**Architectural constraint**: The Airbyte Declarative framework does not support async background jobs within a single connector run. The hybrid strategy is implemented as two separate Airbyte connections — one for fast Enterprise Grid totals (daily), one for slow per-channel enrichment (weekly/on-demand) — writing to the same Bronze table with upsert semantics.

**Rationale**: Enterprise clients are the highest-paying segment, and the DM-vs-channel balance metric ("how much of our communication is in closed DMs vs. open channels") is one of the most valuable collaboration insights. Losing this granularity entirely for Enterprise Grid is an unacceptable product trade-off. The dual-connection strategy delivers fast totals immediately while the enrichment connection gradually backfills per-type breakdown on a separate schedule without risking rate limit bans on the primary sync.

**Actors**: `cpt-insightspec-actor-slack-api`, `cpt-insightspec-actor-slack-analyst`, `cpt-insightspec-actor-slack-operator`

#### Select Collection Strategy

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-strategy-selection`

The connector **MUST** support explicit selection of the collection strategy during connection configuration:

1. **Standard** — `conversations.history` per channel (full per-type granularity, high API cost)
2. **Enterprise Grid — Totals Only** — `admin.analytics.getFile` (fast, no per-type breakdown)
3. **Enterprise Grid — Hybrid** — analytics file for totals + throttled deep enrichment for per-type breakdown (recommended for Enterprise Grid)

The connector **SHOULD** auto-detect Enterprise Grid capability via the `auth.test` response and default to Hybrid mode when Enterprise Grid is detected. The operator **MUST** be able to override this selection.

**Rationale**: The three strategies represent different points on the speed-vs-granularity trade-off. Enterprise Grid Hybrid is the recommended default because it delivers fast totals without sacrificing the per-type breakdown that analysts need for DM-vs-channel analysis. Operators with extreme scale or strict rate limit budgets can downgrade to Totals Only.

**Actors**: `cpt-insightspec-actor-slack-operator`

### 5.2 Meeting Activity Extraction

#### Extract Huddle Participation

- [ ] `p2` - **ID**: `cpt-insightspec-fr-slack-huddle-activity`

The connector **MUST** extract per-user daily huddle participation by identifying huddle events in `conversations.history` (messages with `subtype = "huddle_thread"`). The connector **MUST** populate `meetings_attended` and `adhoc_meetings_attended` (all Slack huddles are ad-hoc). The connector **SHOULD** populate `audio_duration_seconds` when the API provides per-user duration metadata. Fields not applicable to Slack huddles (`calls_count`, `meetings_organized`, `scheduled_meetings_organized`, `scheduled_meetings_attended`, `video_duration_seconds`, `screen_share_duration_seconds`) **MUST** be set to `null`.

**Rationale**: Huddles are Slack's synchronous collaboration signal. Measuring huddle participation alongside M365 Teams meetings provides a complete picture of synchronous communication load.

**Actors**: `cpt-insightspec-actor-slack-api`, `cpt-insightspec-actor-slack-analyst`

### 5.3 User Directory

#### Extract User Directory

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-user-directory`

The connector **MUST** extract the Slack user directory from `users.list`, including: Slack user ID, email (requires `users:read.email` scope), display name, active status, and role (derived from `is_owner`, `is_admin`, `is_restricted`, `is_ultra_restricted` flags).

**Rationale**: The user directory provides the email identity key for cross-system resolution and the membership roster for understanding workspace composition.

**Actors**: `cpt-insightspec-actor-slack-api`, `cpt-insightspec-actor-identity-manager`

#### Preserve User Directory History (SCD Type 2)

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-user-scd`

The `collab_users` table **MUST** preserve historical state changes using the SCD Type 2 pattern. Each user record **MUST** include `valid_from` (timestamp when this state became effective) and `valid_to` (timestamp when this state was superseded, or `null` for the current record). When the connector detects a change in a user's attributes (email, role, active status, display name) between the current `users.list` response and the most recent stored record, it **MUST** close the previous record (set `valid_to = collected_at`) and insert a new record with `valid_from = collected_at`.

The Airbyte sync mode for `collab_users` **MUST** be **Full Refresh | Append** (not overwrite), so that each run appends the current snapshot. SCD Type 2 versioning **MUST** be applied so that superseded records are closed (`valid_to` set) and new records are opened (`valid_from` set). The implementation approach (destination-level MERGE logic vs. connector-level change detection) is deferred to DESIGN; note that Declarative YAML does not natively support stateful change detection, so destination-level MERGE is the expected path unless the connector migrates to Python CDK.

**Rationale**: `users.list` is a full refresh endpoint — it returns current state only. Without SCD Type 2, a user's email change (e.g., name change after marriage) or role change (promoted to admin) silently overwrites history. Historical analytics ("how many admins did we have 6 months ago?", "which email was this person using when they sent those messages?") require point-in-time user state.

**Actors**: `cpt-insightspec-actor-slack-analyst`, `cpt-insightspec-actor-identity-manager`

#### Filter Bot Users

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-bot-filtering`

The connector **MUST** exclude users with `is_bot = true` from the `collab_users` table and from all activity aggregations. Bot messages do not represent human collaboration and must not inflate communication metrics.

**Rationale**: Slack workspaces commonly have dozens of integration bots (CI/CD, alerting, workflow automation). Including bot activity would corrupt per-user communication metrics and distort async vs. sync analysis.

**Actors**: `cpt-insightspec-actor-slack-analyst`

### 5.4 Connector Operations

#### Track Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-slack-collection-runs`

The connector **MUST** produce a collection run log entry for each execution, recording: run ID, start/end time, status, per-stream record counts, channels scanned, API call count, and error count.

**Rationale**: Operational visibility into connector health. Enables alerting on failed runs and tracking data completeness over time. API call count is especially important for monitoring rate limit pressure.

**Actors**: `cpt-insightspec-actor-slack-operator`

### 5.5 Data Integrity

#### Deduplicate by Primary Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-deduplication`

Each stream **MUST** define a primary key that ensures re-running the connector for an overlapping date range does not produce duplicate records. Chat and meeting activity records use `(insight_source_id, email, date, data_source)` as the composite dedup key.

The Airbyte sync mode for all activity streams **MUST** be configured as **Incremental | Append + Deduped** (upsert/merge semantics). When the connector re-calculates aggregates for a past date within the lookback window (e.g., because messages were deleted since the last run), the new values **MUST** overwrite the previously stored row for the same dedup key, not append a duplicate.

**Rationale**: The configurable lookback window causes intentional overlap between consecutive runs. Without upsert semantics, a 7-day lookback would produce up to 7 duplicate rows per user per day. Additionally, message deletions or edits between runs would create conflicting aggregates — the latest re-calculated value must always win.

**Actors**: `cpt-insightspec-actor-slack-api`

#### Support Incremental Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-incremental-sync`

The connector **MUST** support incremental collection using a configurable date-based lookback window (recommended default: 7 days). The `conversations.history` endpoint accepts `oldest` and `latest` Unix timestamp parameters for date-range filtering. Enterprise Grid `admin.analytics.getFile` accepts a `date` parameter for single-day retrieval.

**Rationale**: Slack does not provide a cursor-based incremental API for activity data. A date-based lookback window with deduplication on write is the standard pattern for daily batch collection.

**Actors**: `cpt-insightspec-actor-slack-operator`

#### Stamp Instance and Tenant Context

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-instance-context`

Every record emitted by the connector **MUST** include `insight_source_id` (identifying the specific Slack workspace) and `tenant_id` (identifying the Insight tenant). The `data_source` field **MUST** be set to `insight_slack` for all records.

**Rationale**: Multiple Slack workspaces may feed into the same Bronze store. `insight_source_id` disambiguates workspaces; `tenant_id` is required by the platform's tenant isolation model.

**Actors**: `cpt-insightspec-actor-slack-operator`

#### Resolve Channel Types via Cached Directory

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-channel-type-cache`

The connector **MUST** resolve channel types from authoritative Slack metadata (`conversations.list`) and **MUST NOT** rely on channel ID prefix conventions (e.g., `C` for public, `G` for private, `D` for DM) for type determination. The channel directory **MUST** be refreshed at the start of each sync run and used to attribute channel type to every collected message.

**Rationale**: Slack's internal ID prefix conventions have changed over time and are not contractually stable — Slack Connect further blurred the boundaries between channel types. Only the `conversations.list` response provides authoritative `channel_type` metadata.

**Actors**: `cpt-insightspec-actor-slack-api`

#### Normalize Timestamps to UTC

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-utc-timestamps`

All timestamps persisted in the Bronze layer **MUST** be stored in UTC (ISO 8601 format). Slack message timestamps (`ts` field) are Unix epoch seconds and **MUST** be converted to UTC datetime. Activity dates **MUST** be bucketed to calendar day in UTC.

**Rationale**: Consistent UTC normalization prevents timezone-related errors in cross-platform communication metrics, especially for distributed teams spanning multiple timezones.

**Actors**: `cpt-insightspec-actor-slack-analyst`

### 5.6 Identity Resolution

#### Expose Identity Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-slack-identity-key`

All activity streams **MUST** include `email` as a non-null identity field, joined from the user directory via Slack `user_id`. The `users:read.email` OAuth scope is required for this. The Identity Manager resolves `email` to canonical `person_id` in Silver step 2.

**Rationale**: Cross-system identity resolution is the foundation of the Insight platform's analytics. Email is the canonical cross-system key shared across Slack, M365, Jira, GitHub, and other enterprise systems.

**Actors**: `cpt-insightspec-actor-identity-manager`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Data Freshness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-slack-freshness`

The connector **MUST** deliver extracted data to the Bronze layer within 24 hours of the connector's scheduled run.

**Threshold**: Data available in Bronze ≤ 24h after scheduled collection time.

**Rationale**: Timely chat and huddle data enables near-real-time collaboration dashboards. Stale data reduces the value of communication pattern analysis.

#### Extraction Completeness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-slack-completeness`

The connector **MUST** extract activity for all non-bot users in the workspace on each successful run. Failed or partial runs must be detectable and retryable without data loss.

**Rationale**: Incomplete extraction leads to understated communication metrics and unreliable cross-platform comparisons.

### 6.2 NFR Exclusions

- **Real-time streaming latency**: Not applicable — this connector operates in batch mode with daily collection.
- **Throughput / high-volume optimization**: Standard workspace collection scales with channel count; Enterprise Grid avoids this via pre-aggregated analytics. Rate limit handling is covered in Section 3.1.
- **Availability**: Batch connector — availability is determined by the orchestrator's scheduling, not by this connector.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Slack Stream Contract

- [ ] `p1` - **ID**: `cpt-insightspec-interface-slack-streams`

**Type**: Data format (Bronze table schemas)

**Stability**: stable

**Description**: Four Bronze streams using the unified collaboration schema — `collab_chat_activity`, `collab_meeting_activity`, `collab_users` (all with `data_source = 'insight_slack'`), and `slack_collection_runs`. Activity streams use `email` as the identity key and `date` as the cursor field.

**Breaking Change Policy**: Adding new fields is non-breaking. Removing or renaming fields requires a migration.

### 7.2 External Integration Contracts

#### Slack Web API

- [ ] `p1` - **ID**: `cpt-insightspec-contract-slack-web-api`

**Direction**: required from external system

**Protocol/Format**: REST / JSON

| Endpoint | Purpose | Rate Limit | Strategy |
|----------|---------|------------|----------|
| `users.list` | User directory — email, role, active status | Tier 2 (20/min) | Full refresh |
| `conversations.list` | Channel directory — type, name, member count | Tier 2 (20/min) | Full refresh |
| `conversations.history` | Messages per channel — paginated by date | Tier 3 (50/min) | Standard workspace only |
| `conversations.replies` | Threaded replies for a given message | Tier 3 (50/min) | Standard workspace only |
| `admin.analytics.getFile` | Pre-aggregated per-user per-day metrics | Admin API | Enterprise Grid only |
| `auth.test` | Validate token and detect workspace type | Tier 4 (100/min) | Configuration |

**Authentication**: OAuth 2.0 Bot Token (`xoxb-*`)

**Compatibility**: Slack Web API. Response format is JSON with cursor-based pagination. Field additions are non-breaking.

## 8. Use Cases

### UC-001 Configure Slack Connection

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-slack-configure`

**Actor**: `cpt-insightspec-actor-slack-operator`

**Preconditions**:

- Slack app created with required OAuth scopes
- App installed to the target workspace
- Bot Token (`xoxb-*`) available

**Main Flow**:

1. Operator provides the Bot Token
2. System validates the token against `auth.test`
3. System detects workspace type (standard vs. Enterprise Grid)
4. If Enterprise Grid detected: system recommends Enterprise Grid collection strategy; operator confirms or overrides to standard
5. System lists accessible channels to verify scope coverage
6. System initializes the connection with empty state and configured lookback window (default: 7 days)

**Postconditions**:

- Connection is ready for first sync run
- Collection strategy (standard / Enterprise Grid) is locked for this connection

**Alternative Flows**:

- **Invalid token**: System reports authentication failure; operator corrects the token
- **Missing scopes**: System reports which scopes are missing (e.g., `users:read.email`); operator updates the app permissions
- **Enterprise Grid without admin token**: System falls back to standard collection strategy with a warning about scale limitations
- **Enterprise Grid with Deep Channel Analytics**: Operator enables "Deep Channel Analytics" during primary connection setup. System provides instructions to create a second Airbyte connection: (1) use the same Slack connector and credentials, (2) configure as Standard Workspace strategy, (3) set schedule to weekly or on-demand, (4) target the same Bronze tables (upserts per-type breakdown via the same dedup key). System validates that both connections share the same `insight_source_id` for dedup key alignment

### UC-002 Incremental Sync Run

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-slack-incremental-sync`

**Actor**: `cpt-insightspec-actor-slack-operator`

**Preconditions**:

- Connection configured and token valid
- Previous state available (or empty for first run)

**Main Flow (Standard Workspace)**:

1. Orchestrator triggers the connector
2. Connector refreshes user directory from `users.list`, filtering out bots; applies SCD Type 2 versioning for attribute changes
3. Connector refreshes channel list from `conversations.list` and caches as in-memory hash map (`channel_id → channel_type`) for message type attribution
4. For each channel in the lookback window: read `conversations.history`, count parent messages per user per day per channel type
5. For each parent message with `reply_count > 0`: fetch `conversations.replies` with rate-limit-aware throttling (shared Tier 3 budget); count reply authors per user per day
6. Parse huddle events (`subtype = "huddle_thread"`) for meeting activity
7. Aggregate counts into `collab_chat_activity` and `collab_meeting_activity` records
8. Write records with upsert semantics (Incremental | Append + Deduped)
9. Collection run log entry written (including thread completion status and skipped thread count if rate limit budget exhausted)

**Main Flow (Enterprise Grid — Hybrid)**:

1. Orchestrator triggers the primary Enterprise Grid connection
2. Connector refreshes user directory from `users.list`, filtering out bots; applies SCD Type 2 versioning
3. For each day in the lookback window: call `admin.analytics.getFile` with `type=member`
4. Map `messages_posted` to `total_chat_messages`; set per-type fields to null
5. Write records with upsert semantics (Incremental | Append + Deduped)
6. Collection run log entry written
7. *(Separate schedule)* If "Deep Channel Analytics" is enabled: the orchestrator triggers a second Airbyte connection (configured as Standard-mode sync) on a slower schedule (e.g., weekly). This connection reads `conversations.history` per channel and upserts per-type breakdown fields into the same Bronze table using the same dedup key

**Postconditions**:

- Bronze tables contain new activity records
- Collection run log records success/failure, record counts, channels scanned, and API call count

**Alternative Flows**:

- **First run**: Connector processes the full lookback window (default 7 days)
- **API throttling (HTTP 429)**: Connector respects `Retry-After` header and retries
- **Channel inaccessible**: Connector logs the channel as skipped and continues with remaining channels
- **Enterprise Grid analytics file unavailable for a date**: Connector logs the gap and continues with available dates

## 9. Acceptance Criteria

- [ ] Chat activity extracted from a live Slack workspace with per-user daily message counts
- [ ] Standard workspace collection produces per-channel-type breakdown (DMs, group DMs, channel posts, replies)
- [ ] Enterprise Grid collection produces `total_chat_messages` with per-type fields set to null
- [ ] Huddle participation extracted as meeting activity records
- [ ] User directory extracted with email, role, and active status
- [ ] Bot users excluded from user directory and activity metrics
- [ ] Incremental sync with lookback window produces no duplicate records on consecutive runs
- [ ] `email` is present and non-null in every activity record (joined from user directory)
- [ ] `insight_source_id`, `tenant_id`, and `data_source = 'insight_slack'` present in all records
- [ ] All timestamps stored in UTC
- [ ] Collection run log records success, record counts, channels scanned, and API call count

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Slack Web API | Message history, channel metadata, user directory, and analytics endpoints | `p1` |
| Slack Bot Token | OAuth 2.0 authentication credential with required scopes | `p1` |
| Airbyte Declarative Connector framework | Execution model for running the connector | `p1` |
| Identity Manager | Resolves `email` to `person_id` in Silver step 2 | `p2` |
| Destination store (PostgreSQL / ClickHouse) | Target for Bronze tables | `p1` |

## 11. Assumptions

- The Slack app is installed to the target workspace with all required OAuth scopes granted by a workspace admin
- `users:read.email` scope is available and provides email for the majority of workspace users
- Enterprise Grid workspaces provide the `admin.analytics.getFile` endpoint with `type=member` for per-user daily metrics
- Slack message timestamps (`ts`) are Unix epoch seconds with microsecond precision and do not include timezone offsets — UTC conversion is trivial
- Bot users are reliably identified by the `is_bot = true` flag in the `users.list` response
- Huddle events are identifiable in `conversations.history` via `subtype = "huddle_thread"` message markers
- The `conversations.history` rate limit (Tier 3: 50 req/min) is sufficient for daily collection of workspaces with up to ~2000 active channels within a reasonable collection window (< 4 hours)
- Enterprise Grid `admin.analytics.getFile` does not provide per-channel-type message breakdown — only `messages_posted` total is available; per-type enrichment requires the optional hybrid deep channel analytics job
- Channel ID prefix conventions (`C`, `G`, `D`) are not reliable for type determination — the connector must resolve types exclusively via cached `conversations.list` response
- `audio_duration_seconds` for huddles is available in Pro tier and above; Free tier workspaces may not expose this metadata in the API — the field is nullable by design
- Thread reply collection via `conversations.replies` shares the Tier 3 rate limit budget with `conversations.history` — the connector must coordinate these calls to avoid mutual rate limit exhaustion
- The Airbyte Declarative Connector framework (YAML) executes parent-child stream relationships synchronously — true async workers and parallel queues are not available; all concurrency patterns must be modelled as separate Airbyte connections or deferred to Python CDK migration
- The Airbyte sync mode for activity streams is Incremental | Append + Deduped (upsert) — re-calculated aggregates for past dates overwrite previously stored rows rather than appending duplicates
- Enterprise Grid deep channel enrichment is implemented as a separate Airbyte connection (Standard-mode sync) on a slower schedule, not as a background thread within the primary Enterprise Grid sync
- The `collab_users` table uses SCD Type 2 pattern with `valid_from` / `valid_to` to preserve user attribute history across full refresh cycles

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Rate limit exhaustion on large standard workspaces | `conversations.history` calls scale with channel count; workspaces with thousands of channels may exhaust Tier 3 limits (50 req/min) and extend collection beyond acceptable windows | Switch to Enterprise Grid collection strategy for large workspaces; implement aggressive backoff with `Retry-After` compliance; monitor API call counts in collection run logs |
| Enterprise Grid sacrifices per-channel-type granularity | Only `total_chat_messages` is available; analysts cannot distinguish DM-heavy vs. channel-centric communication patterns | Document the trade-off clearly; consider hybrid approach for smaller Enterprise Grid workspaces where standard collection is still viable |
| Huddle duration not available in all Slack tiers | `audio_duration_seconds` may be null if the Slack subscription does not expose per-user huddle duration metadata | Mark `audio_duration_seconds` as nullable; document tier dependency; huddle count (`meetings_attended`) remains available regardless |
| Thread reply N+1 request explosion | `conversations.history` returns only parent messages; counting `channel_replies` requires a separate synchronous `conversations.replies` call per threaded parent, sharing the Tier 3 rate limit (50 req/min) | Self-throttle thread reply requests (10–15 req/min cap); prioritize high-volume channels; accept partial reply data if budget exhausted — see FR `cpt-insightspec-fr-slack-thread-batching`. If bottleneck is unacceptable, migrate to Python CDK |
| Declarative YAML limits prevent async collection patterns | Thread batching and Enterprise Grid deep enrichment cannot use parallel workers or background queues within a single Airbyte Declarative connector run | Thread collection modelled as synchronous child stream with throttling; Enterprise Grid enrichment modelled as a separate Airbyte connection on its own schedule. Python CDK migration is the escape hatch if scale demands exceed what synchronous execution can deliver |
| Lookback window re-aggregation produces stale data without upsert | 7-day lookback means the connector recalculates aggregates for past dates; if destination does not merge, up to 7 duplicate rows per user per day accumulate | Require Incremental Append + Deduped (upsert) sync mode — see FR `cpt-insightspec-fr-slack-deduplication` |
| User directory full refresh overwrites history | `users.list` returns current state only; email changes, role changes, and deactivations silently overwrite previous records | Implement SCD Type 2 with `valid_from` / `valid_to` — see FR `cpt-insightspec-fr-slack-user-scd` |
| Slack app scope changes or revocation | Workspace admin revokes a required scope (e.g., `groups:history`); private channel messages silently stop being collected | Monitor per-run channel coverage and record counts; alert on significant drops in channels scanned or records collected |
| Guest and external users in shared channels | Slack Connect channels may include users from other organizations whose email does not resolve in the Identity Manager | Filter external users based on workspace membership; document coverage limitations for shared channels |
| Message edits and deletions after collection | Messages edited or deleted after the connector has processed them will not be reflected in the aggregated counts | Accept as a known limitation for daily aggregation; the impact on daily counts is typically minimal |

## 13. Resolved Questions

All open questions from the initial draft have been resolved and incorporated into the PRD as concrete requirements:

| ID | Summary | Resolution | Incorporated In |
|----|---------|------------|-----------------|
| OQ-SLACK-1 | Enterprise Grid vs. standard collection strategy | Hybrid strategy: analytics file for fast totals + optional throttled deep enrichment via `conversations.history` for per-channel-type breakdown. Three explicit modes (Standard / Totals Only / Hybrid) selectable during configuration. | FR `cpt-insightspec-fr-slack-chat-enterprise`, FR `cpt-insightspec-fr-slack-strategy-selection` |
| OQ-SLACK-2 | Huddle duration availability across Slack tiers | Confirmed: `audio_duration_seconds` available in Pro tier and above; Free tier does not reliably expose it. Field is nullable by design. | FR `cpt-insightspec-fr-slack-huddle-activity` (SHOULD populate when available), Assumptions |
| OQ-SLACK-3 | Channel type resolution strategy | Exclusively via cached `conversations.list` hash map. Channel ID prefix conventions (`C`/`G`/`D`) are unreliable — Slack Connect blurred boundaries, and internal routing has changed over time. | FR `cpt-insightspec-fr-slack-channel-type-cache` |

## 14. Non-Applicable Requirements

The following checklist domains have been evaluated and determined not applicable for this connector:

| Domain | Reason |
|--------|--------|
| **Security (SEC)** | The connector handles a single Bot Token, stored as `airbyte_secret` by the Airbyte framework. No custom authentication, authorization, or encryption logic exists in the connector. Credential storage and secret management are delegated to the Airbyte platform. |
| **Safety (SAFE)** | Pure data extraction pipeline. No interaction with physical systems, no potential for harm to people, property, or environment. |
| **Performance (PERF)** | Batch connector where rate-limit management is the primary performance concern. Request throttling, `Retry-After` compliance, and thread reply rate budget allocation are covered in Section 3.1 and FRs `cpt-insightspec-fr-slack-thread-batching`, `cpt-insightspec-fr-slack-chat-standard`. No additional caching, pooling, or latency optimization beyond rate-limit controls is required. |
| **Reliability (REL)** | Idempotent extraction via deduplication keys. No distributed state, no transactions. Recovery is handled by re-running the sync with the same lookback window (Airbyte framework manages state). |
| **Usability (UX)** | No user-facing interface. Configuration is a token and strategy selection in the Airbyte UI. No accessibility, internationalization, or inclusivity requirements apply. |
| **Compliance (COMPL)** | Slack user emails are personal data under GDPR. Message content is NOT extracted — only aggregate counts. Retention, deletion, and data subject rights are delegated to the Airbyte platform and destination operator. The connector must not store credentials outside the platform's secret management. |
| **Maintainability (MAINT)** | Initial implementation targets Declarative YAML manifest. If thread collection bottleneck requires migration to Python CDK, maintainability increases but remains within the Airbyte connector development framework. Schema changes are handled by updating field or stream definitions. |
| **Testing (TEST)** | Connector behavior must satisfy PRD acceptance criteria (Section 9). Validation includes: Airbyte framework connection check, schema validation, and connector-specific acceptance tests. No custom unit tests required — the declarative manifest is validated by the framework. |
