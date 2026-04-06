# PRD — Claude API Connector

> Version 2.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 13 (Claude API), Anthropic Admin API documentation

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
  - [5.1 API Usage Data](#51-api-usage-data)
  - [5.2 Cost Data](#52-cost-data)
  - [5.3 Keys & Workspaces](#53-keys--workspaces)
  - [5.4 Operations](#54-operations)
  - [5.5 Data Integrity](#55-data-integrity)
  - [5.6 Identity Resolution](#56-identity-resolution)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)
  - [OQ-CAPI-1: Cost report granularity and description field semantics](#oq-capi-1-cost-report-granularity-and-description-field-semantics)
  - [OQ-CAPI-2: Web search requests billing](#oq-capi-2-web-search-requests-billing)
- [14. Non-Applicable Requirements](#14-non-applicable-requirements)

<!-- /toc -->

---

## 1. Overview

### 1.1 Purpose

The Claude API connector collects programmatic API usage and cost data from the Anthropic Admin API. It ingests daily token usage aggregates (per model, API key, workspace, service tier, and other dimensions), daily cost reports, API key metadata, workspace definitions, and organization invites. The connector enables centralized visibility into API spend, per-key utilization, and per-workspace cost attribution for organizations using the Anthropic Claude API.

### 1.2 Background / Problem Statement

Organizations using the Anthropic Claude API for internal tooling, automations, or AI-powered product features lack centralized visibility into API spend, per-key utilization, and per-workspace cost attribution. The Anthropic Admin API provides several complementary data surfaces:

- **Messages Usage Report**: Daily token usage aggregates broken down by model, API key, workspace, service tier, context window size, inference geography, and speed tier.
- **Cost Report**: Daily cost aggregates broken down by workspace and description (cost category).
- **API Keys**: Metadata about provisioned API keys, including creation info and workspace assignment.
- **Workspaces**: Organizational workspace definitions with data residency information.
- **Invites**: Pending organization invitations with role and workspace assignments.

Unlike Claude Team Plan (conversational, flat-seat billing), the Claude API is programmatic, pay-per-token, and not associated with individual user sessions at the API level. Cost attribution is by API key and workspace, not by person.

### 1.3 Goals (Business Outcomes)

- Collect complete daily API token usage aggregates across all models, API keys, workspaces, and service tiers.
- Collect daily cost reports with workspace-level and category-level breakdowns.
- Collect API key metadata including creation context and workspace assignment.
- Collect workspace definitions and organization invite data for enrichment.
- Enable cost attribution by API key, workspace, model, and service tier.
- Feed `class_ai_api_usage` Silver stream for cross-provider programmatic API cost analytics.
- Support incremental sync for usage and cost data using date-range cursors with 31-day windows.

### 1.4 Glossary

| Term | Definition |
|------|------------|
| `api_key_id` | API key identifier assigned by Anthropic |
| `workspace_id` | Workspace identifier within the Anthropic organization |
| `service_tier` | API service tier (e.g., `scale`, `standard`) affecting pricing and rate limits |
| `context_window` | Maximum context window size used for the request batch |
| `inference_geo` | Geographic region where inference was performed |
| `bucket_width` | Aggregation granularity for usage/cost reports; always `1d` for this connector |
| `person_id` | Canonical cross-system person identifier resolved by the Identity Manager |
| `class_ai_api_usage` | Silver stream for programmatic API usage (Claude API + OpenAI API) |
| `data_source` | Discriminator field; always `insight_claude_api` for this connector |
| `cache_read_tokens` | Tokens served from Anthropic's prompt cache |
| `cache_creation_5m_tokens` | Tokens written to prompt cache with 5-minute TTL |
| `cache_creation_1h_tokens` | Tokens written to prompt cache with 1-hour TTL |
| `web_search_requests` | Number of web search tool invocations within the usage bucket |

---

## 2. Actors

### 2.1 Human Actors

#### Platform Engineer / Data Engineer

**ID**: `cpt-insightspec-actor-claude-api-platform-eng`

**Role**: Deploys and operates the Claude API connector; configures credentials, sync schedule, and lookback windows.
**Needs**: Clear configuration interface, visibility into collection status and errors, ability to re-run failed collections without data loss or duplication.

#### Analytics Engineer

**ID**: `cpt-insightspec-actor-claude-api-analytics-eng`

**Role**: Designs and maintains the Silver/Gold pipeline that consumes Claude API Bronze data.
**Needs**: Reliable Bronze tables with stable schemas, consistent cost fields, and clear attribution dimensions compatible with the OpenAI API Silver schema.

#### Engineering Manager / Finance

**ID**: `cpt-insightspec-actor-claude-api-manager`

**Role**: Consumes Gold-layer reports that aggregate Claude API spend alongside other AI API providers.
**Needs**: Accurate cost attribution by workspace, model, and API key; trend visibility.

### 2.2 System Actors

#### Anthropic Admin API

**ID**: `cpt-insightspec-actor-claude-api-anthropic-api`

**Role**: Source system -- provides usage reports, cost reports, API key metadata, workspace definitions, and invite data for the organization's Anthropic account.

#### Identity Manager

**ID**: `cpt-insightspec-actor-claude-api-identity-mgr`

**Role**: Maps API key creators (`created_by` on API keys) and invite recipients (`email` on invites) to canonical `person_id` for cross-system analytics.

#### ETL Scheduler / Orchestrator

**ID**: `cpt-insightspec-actor-claude-api-scheduler`

**Role**: Triggers connector runs on a configured schedule and monitors collection run outcomes.

---

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires outbound HTTPS access to `api.anthropic.com`.
- Authentication via Admin API key passed in the `x-api-key` header.
- All requests require the `anthropic-version: 2023-06-01` header.
- The connector operates in batch pull mode; it does not require an inbound network port or webhook endpoint.
- Usage and cost report endpoints enforce a maximum date range of 31 days per request; the connector must window longer lookback periods into 31-day chunks.
- All endpoints are GET requests; no mutation endpoints are used.
- API key and workspace endpoints are offset/limit paginated; usage and cost endpoints use cursor-based pagination with `next_page` tokens.

---

## 4. Scope

### 4.1 In Scope

- Collection of daily messages usage reports with full dimensional breakdown (model, API key, workspace, service tier, context window, inference geo, speed).
- Collection of daily cost reports with workspace and description breakdown.
- Collection of API key metadata (id, name, status, creation context, workspace assignment).
- Collection of workspace definitions (id, name, display name, timestamps, data residency).
- Collection of organization invites (id, email, role, status, timestamps, workspace).
- Incremental sync for usage and cost data using date-range cursors.
- Full refresh for API keys, workspaces, and invites.
- Connector execution logging for monitoring and observability.
- Feeding `class_ai_api_usage` Silver stream for cross-provider programmatic API cost analytics.

### 4.2 Out of Scope

- Conversational Claude Team Plan usage -- covered by the Claude Team connector (`class_ai_tool_usage`).
- Per-request event collection -- the Anthropic Admin API provides aggregated usage reports, not per-request logs.
- Real-time or sub-daily granularity -- the Admin API provides daily resolution only.
- Per-prompt or per-token content -- the connector collects metadata and counts, not prompt/response content.
- Organization member management or role changes -- the connector reads invites but does not manage membership.
- Gold-layer transformations -- owned by analytics pipeline, not this connector.

---

## 5. Functional Requirements

### 5.1 API Usage Data

#### Collect messages usage reports

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-messages-usage`

The connector **MUST** collect daily messages usage reports from `/v1/organizations/usage_report/messages`, capturing `date`, `model`, `api_key_id`, `workspace_id`, `service_tier`, `context_window`, `inference_geo`, `speed`, `uncached_input_tokens`, `cache_read_tokens`, `cache_creation_5m_tokens`, `cache_creation_1h_tokens`, `output_tokens`, and `web_search_requests` at one row per unique dimension combination per day.

Note: `inference_geo` and `speed` are collected as nullable fields but are not available as `group_by` dimensions (API limit of 5 dimensions) — see [ADR-001](./ADR/ADR-001-group-by-limit-inference-geo.md).

**Rationale**: Messages usage is the primary signal for API token consumption and cost attribution across all organizational dimensions.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`

#### Support date-range incremental sync for usage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-usage-incremental`

The connector **MUST** support incremental sync for messages usage using `starting_at` and `ending_at` date parameters with ISO 8601 format. Each sync window **MUST NOT** exceed 31 days as enforced by the API.

**Rationale**: Incremental sync minimizes API calls and avoids re-fetching historical data on every run.
**Actors**: `cpt-insightspec-actor-claude-api-platform-eng`

#### Handle cursor-based pagination for usage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-usage-pagination`

The connector **MUST** follow cursor-based pagination using the `next_page` token in usage report responses until all pages are consumed.

**Rationale**: Usage reports may span multiple pages when the organization has many API keys, models, and workspaces.
**Actors**: `cpt-insightspec-actor-claude-api-platform-eng`

### 5.2 Cost Data

#### Collect cost reports

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-cost-report`

The connector **MUST** collect daily cost reports from `/v1/organizations/cost_report`, capturing `date`, `workspace_id`, `description`, `amount`, `currency`, and additional dimension fields (`cost_type`, `model`, `service_tier`, `context_window`, `token_type`, `inference_geo`) at one row per `(date, workspace_id, description)`. Note: the API returns `amount` (string, USD) not `amount_cents` (integer) — see [ADR-002](./ADR/ADR-002-api-response-structure.md).

**Rationale**: Cost reports provide financial attribution by workspace and cost category, complementing the token-level usage data.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`, `cpt-insightspec-actor-claude-api-manager`

#### Support date-range incremental sync for cost

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-cost-incremental`

The connector **MUST** support incremental sync for cost reports using the same `starting_at` / `ending_at` date-range mechanism as usage, with 31-day maximum windows.

**Rationale**: Cost data follows the same temporal pattern as usage data and benefits from the same incremental approach.
**Actors**: `cpt-insightspec-actor-claude-api-platform-eng`

### 5.3 Keys & Workspaces

#### Collect API key metadata

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-keys`

The connector **MUST** collect API key metadata from `/v1/organizations/api_keys`, capturing `id`, `name`, `status`, `created_at`, `created_by` (nested: `id`, `name`, `type`), `workspace_id`, and `partial_key_hint`. This stream uses full refresh with offset-based pagination.

**Rationale**: API key metadata enables attribution of usage to specific keys and their workspace assignments, and identifies who created each key.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`

#### Collect workspace definitions

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-workspaces`

The connector **MUST** collect workspace definitions from `/v1/organizations/workspaces`, capturing `id`, `name`, `display_name`, `created_at`, `archived_at`, and `data_residency` (nested). This stream uses full refresh with offset/limit pagination.

**Rationale**: Workspace definitions provide the dimension table for workspace-level cost attribution and organizational structure.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`

#### Collect organization invites

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-api-invites`

The connector **MUST** collect organization invites from `/v1/organizations/invites`, capturing `id`, `email`, `role`, `status`, `created_at`, `expires_at`, and `workspace_id`. This stream uses full refresh with offset/limit pagination.

**Rationale**: Invite data provides organizational context and supports identity resolution by mapping email addresses to workspace access.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`

### 5.4 Operations

#### Log connector execution

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-collection-runs`

The connector **MUST** record each execution run with `run_id`, `started_at`, `completed_at`, `status`, per-stream record counts, `api_calls`, `errors`, and `settings` in the `claude_api_collection_runs` Bronze table.

**Rationale**: Execution logs are required for monitoring data freshness, diagnosing failures, and tracking collection volume.
**Actors**: `cpt-insightspec-actor-claude-api-platform-eng`

### 5.5 Data Integrity

#### Inject framework fields on all records

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-framework-fields`

All records across all streams **MUST** include `tenant_id` (from config), `insight_source_id` (from config, default empty string), `collected_at` (collection timestamp), `data_source` (`insight_claude_api`), `_version` (deduplication version), and `metadata` (full API response as JSON string).

**Rationale**: Framework fields enable multi-tenant isolation, deduplication, and forward-compatible schema evolution.
**Actors**: `cpt-insightspec-actor-claude-api-platform-eng`

#### Generate composite unique keys for usage records

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-usage-unique-key`

The connector **MUST** generate a composite `unique` key for each messages usage record from `(date, model, api_key_id, workspace_id, service_tier, context_window)` to enable deduplication. Note: `inference_geo` and `speed` were removed from the key due to API constraints — see [ADR-001](./ADR/ADR-001-group-by-limit-inference-geo.md).

**Rationale**: Usage records have no natural primary key from the API; a composite key is required for upsert semantics.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`

#### Generate composite unique keys for cost records

- [ ] `p1` - **ID**: `cpt-insightspec-fr-claude-api-cost-unique-key`

The connector **MUST** generate a composite `unique` key for each cost report record from `(date, workspace_id, description)` to enable deduplication.

**Rationale**: Cost records have no natural primary key from the API; a composite key is required for upsert semantics.
**Actors**: `cpt-insightspec-actor-claude-api-analytics-eng`

### 5.6 Identity Resolution

#### Resolve API key creators to person_id

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-api-identity-key-creator`

The Silver pipeline **SHOULD** resolve `created_by.id` and `created_by.name` from API key records to canonical `person_id` via the Identity Manager when the `created_by.type` is `user`.

**Rationale**: Attributing API key creation to a person enables accountability and organizational analytics.
**Actors**: `cpt-insightspec-actor-claude-api-identity-mgr`

#### Resolve invite emails to person_id

- [ ] `p2` - **ID**: `cpt-insightspec-fr-claude-api-identity-invite`

The Silver pipeline **SHOULD** resolve `email` from invite records to canonical `person_id` via the Identity Manager.

**Rationale**: Invite email addresses provide identity resolution signals for the Identity Manager.
**Actors**: `cpt-insightspec-actor-claude-api-identity-mgr`

---

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Authentication via Admin API Key

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-claude-api-auth`

The connector **MUST** authenticate using a Bearer token via the `x-api-key` header (Anthropic Admin API key). All requests **MUST** include the `anthropic-version: 2023-06-01` header.

#### Rate Limit Compliance

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-claude-api-rate-limiting`

The connector **MUST** implement exponential backoff on HTTP 429 responses. The connector **SHOULD** respect rate limit headers when present.

**Threshold**: Default inter-request delay configurable; exponential backoff on transient errors.

#### Data Freshness

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-claude-api-freshness`

The connector **MUST** be executable on a daily schedule such that daily usage and cost data for day D is available within 48 hours of the end of day D.

**Threshold**: Less than or equal to 48 hours end-to-end latency from API activity to Bronze availability.

#### Data Source Discriminator

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-claude-api-data-source`

All rows written by this connector **MUST** carry `data_source = 'insight_claude_api'` to enable source-level filtering in cross-provider queries.

#### Idempotent Writes

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-claude-api-idempotent`

Repeated collection of the same date range **MUST NOT** create duplicate rows. The connector **MUST** use upsert semantics keyed on the composite `unique` key for usage and cost records, and natural `id` keys for API keys, workspaces, and invites.

### 6.2 NFR Exclusions

- **Real-time latency SLA**: Not applicable -- the connector operates in scheduled batch pull mode only.
- **GPU / high-compute NFRs**: Not applicable -- the connector performs I/O-bound API collection with no computational requirements.
- **Safety (SAFE)**: Not applicable -- this connector is a data collection pipeline with no physical or safety-critical interactions.
- **Usability / UX**: Not applicable -- the connector exposes a declarative YAML manifest for platform engineers; end-user accessibility standards do not apply.
- **Availability / Reliability SLA (REL)**: Not applicable -- the connector is a scheduled batch job; availability SLAs apply to the scheduling infrastructure, not to the connector itself.
- **Regulatory compliance (COMPL)**: Not applicable -- the connector collects API usage metadata (token counts, costs, key names) from the organization's own Anthropic account; no PII or prompt content is collected.
- **Maintainability documentation (MAINT)**: Not applicable -- API and admin documentation requirements are owned by the platform-level PRD.
- **Operations (OPS)**: Not applicable -- deployment and monitoring requirements are owned by the platform infrastructure team.

---

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Connector Entry Point

- [ ] `p1` - **ID**: `cpt-insightspec-interface-claude-api-entrypoint`

**Type**: Airbyte Declarative Source (YAML manifest)

**Stability**: stable

**Description**: The connector is defined as an Airbyte `DeclarativeSource` manifest (`connector.yaml`) that declares all streams, authentication, pagination, and schema inline. It is executed by the Airbyte CDK runtime.

**Breaking Change Policy**: Configuration schema changes require a version bump.

### 7.2 External Integration Contracts

#### Anthropic Admin API Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-claude-api-anthropic`

**Direction**: required from client (Anthropic)

**Protocol/Format**: HTTP/REST JSON

**Base URL**: `https://api.anthropic.com`

**Authentication**: `x-api-key: {admin_api_key}` + `anthropic-version: 2023-06-01`

**Compatibility**: Anthropic Admin API; versioned via `anthropic-version` header

#### Identity Manager Contract

- [ ] `p2` - **ID**: `cpt-insightspec-contract-claude-api-identity-mgr`

**Direction**: required from client (Identity Manager service)

**Protocol/Format**: Internal service call; input is email + name + source label; output is canonical `person_id`

**Compatibility**: Identity Manager must be available and responsive during Silver pipeline execution

---

## 8. Use Cases

#### Configure Connection

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-claude-api-configure`

**Actor**: `cpt-insightspec-actor-claude-api-platform-eng`

**Preconditions**:
- Platform Engineer has an Anthropic Admin API key with read access to the organization.
- The Airbyte platform is deployed and accessible.

**Main Flow**:
1. Platform Engineer creates a new connection in Airbyte, selecting the `claude-api` source type.
2. Engineer provides `tenant_id`, `admin_api_key`, and optionally `insight_source_id` and `start_date`.
3. Airbyte executes the check connection flow by reading the `claude_api_workspaces` stream.
4. On success, the connection is saved and scheduled.

**Postconditions**:
- Connection is configured and ready for scheduled or manual sync.

**Alternative Flows**:
- **Invalid API key**: Check fails with 401; engineer is prompted to correct credentials.
- **Insufficient permissions**: Check fails with 403; engineer must use an Admin-level API key.

#### Incremental Sync Run

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-claude-api-sync`

**Actor**: `cpt-insightspec-actor-claude-api-scheduler`

**Preconditions**:
- At least one prior successful sync exists (or `start_date` is configured for first run).
- Admin API key is valid and has read access.

**Main Flow**:
1. Scheduler triggers a sync run.
2. For `claude_api_messages_usage` and `claude_api_cost_report`: connector reads the cursor (last synced date), computes the date range from cursor to today (windowed into 31-day chunks), and fetches all pages for each window.
3. For `claude_api_keys`, `claude_api_workspaces`, and `claude_api_invites`: connector performs a full refresh, fetching all pages.
4. All records are written to Bronze tables with framework fields injected.
5. Collection run metadata is recorded.

**Postconditions**:
- All Bronze tables are up-to-date through the current date.
- Incremental cursors are advanced for the next run.

**Alternative Flows**:
- **API rate limiting**: Connector backs off exponentially and retries.
- **Partial failure**: Failed streams are retried; successful streams retain their data.

---

## 9. Acceptance Criteria

- [ ] All messages usage records for a 7-day test period are present in `claude_api_messages_usage` with correct dimensional breakdown.
- [ ] All cost report records for the same period are present in `claude_api_cost_report` with correct workspace and description breakdown.
- [ ] All API keys are present in `claude_api_keys` with `created_by` nested fields intact.
- [ ] All workspaces are present in `claude_api_workspaces` with `data_residency` nested fields intact.
- [ ] All invites are present in `claude_api_invites`.
- [ ] `data_source = 'insight_claude_api'` is set on every row written by this connector.
- [ ] `tenant_id` and `insight_source_id` are present on every row.
- [ ] A second sync run (incremental) for usage/cost completes without creating duplicate rows.
- [ ] An incremental sync fetches only data for dates not yet collected.
- [ ] Full refresh streams (keys, workspaces, invites) correctly overwrite stale data.
- [ ] Collection run log records correct start time, end time, and per-stream record counts.
- [ ] The `unique` composite key on usage records correctly deduplicates records across overlapping sync windows.

---

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Anthropic Admin API | Source data -- all collected data originates from these endpoints | `p1` |
| `class_ai_api_usage` Silver table | Target schema for Silver pipeline | `p1` |
| Identity Manager | Resolves API key creators and invite emails to canonical `person_id` | `p2` |
| ETL Scheduler / Orchestrator | Triggers collection runs on schedule | `p2` |
| Airbyte CDK | Runtime for declarative connector execution | `p1` |

---

## 11. Assumptions

- The Anthropic Admin API is accessible from the connector's deployment environment over HTTPS.
- The provided Admin API key has read access to usage reports, cost reports, API keys, workspaces, and invites.
- The Anthropic Admin API returns daily-aggregated data with `bucket_width=1d`; sub-daily granularity is not available.
- API usage data is finalized daily; no billing period boundary adjustments or retroactive corrections are needed (unlike some other providers).
- The `anthropic-version: 2023-06-01` header remains valid for all endpoints used by this connector.
- The 31-day maximum date range per request is a stable API constraint.

---

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| API rate limiting | Collection slows or stalls for large organizations | Exponential backoff; configurable inter-request delay |
| Admin API key rotation | Collection fails with 401/403 | Alert on auth failures; document credential rotation procedure |
| API version deprecation | Requests fail or return unexpected schemas | Pin `anthropic-version` header; monitor Anthropic changelog |
| Large organizations with many API keys and workspaces | Usage reports may be very large | Cursor-based pagination handles arbitrary result sizes; 31-day windows limit per-request data volume |
| Cost data retroactive adjustments | Historical cost records may change after initial collection | Overlapping sync windows (configurable lookback) allow re-collection of recent dates |
| New usage dimensions added by Anthropic | New fields not captured | `metadata` field stores full API response for forward compatibility; `additionalProperties: true` in schemas |

---

## 13. Open Questions

### OQ-CAPI-1: Cost report granularity and description field semantics

**Question**: What are the possible values of the `description` field in cost reports? Is this a stable enumeration or a free-text field?

**Current approach**: Store as-is; treat as opaque string for now.

**Owner**: Platform / Data Engineering team lead
**Target resolution**: Before Silver pipeline implementation

### OQ-CAPI-2: Web search requests billing

**Question**: How are `web_search_requests` billed? Are they included in `amount_cents` from the cost report, or billed separately?

**Current approach**: Collect the field; defer billing interpretation to Gold analytics.

**Owner**: Platform / Data Engineering team lead
**Target resolution**: Before Gold-layer cost analytics implementation

See DESIGN.md for additional technical open questions.

---

## 14. Non-Applicable Requirements

| Requirement Area | Disposition | Reason |
|-----------------|-------------|--------|
| Per-request event collection | Not applicable | The Anthropic Admin API provides aggregated usage reports, not per-request logs. There is no equivalent of `X-Anthropic-User-Id` instrumentation at the Admin API level. |
| Person-level usage attribution | Not directly applicable | Usage is attributed to API keys and workspaces, not to individual persons. Identity resolution applies only to API key creators and invite recipients. |
| Dual-schedule sync | Not applicable | API data is finalized daily; no billing period boundary issues require separate resync schedules (unlike some IDE-based connectors). |
| IDE context / session analytics | Not applicable | This is a programmatic API connector, not an IDE tool connector. There are no completions, sessions, or editor context. |
