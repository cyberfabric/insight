# Jira Service Management (JSM) Connector Specification

> Version 2.0 — March 2026
> Based on: `docs/connectors/support/README.md` (Support domain schema)

Standalone specification for the Jira Service Management (ITSM / Service Desk) connector. JSM is a distinct Atlassian product from Jira Software — focused on inbound support and ITSM workflows rather than development project management.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`support_tickets` — Ticket metadata and current state](#supporttickets-ticket-metadata-and-current-state)
  - [`support_ticket_events` — Append-only audit log](#supportticketevents-append-only-audit-log)
  - [`support_agents` — Agent directory](#supportagents-agent-directory)
  - [`support_sla` — SLA policy status per ticket](#supportsla-sla-policy-status-per-ticket)
  - [`jsm_ticket_ext` — Custom ticket fields (key-value)](#jsm_ticket_ext--custom-ticket-fields-key-value)
  - [`support_collection_runs` — Connector execution log](#supportcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-JSM-1: Customer account email suppression](#oq-jsm-1-customer-account-email-suppression)
  - [OQ-JSM-2: SLA collection frequency](#oq-jsm-2-sla-collection-frequency)
  - [OQ-JSM-3: Queue-based vs project-based collection](#oq-jsm-3-queue-based-vs-project-based-collection)
  - [OQ-JSM-4: `class_support_sla` — Silver schema design](#oq-jsm-4-classsupportsla-silver-schema-design)

<!-- /toc -->

---

## Overview

**API**: Atlassian REST API v3 (`https://{domain}.atlassian.net/rest/api/3/`) for core issue data; Atlassian Service Desk API v1 (`https://{domain}.atlassian.net/rest/servicedeskapi/`) for JSM-specific entities (queues, SLA).

**Category**: Support / Helpdesk

**`data_source`**: `"insight_jsm"` — used as the source discriminator in all unified Bronze tables.

**Authentication**:
- **Basic Auth** (preferred for service accounts): HTTP Basic Auth with `{email}:{api_token}` encoded as Base64. API token created under Atlassian Account → Security → API tokens.
- **OAuth 2.0** (3LO): Authorization Code flow for delegated access. Scopes: `read:servicedesk-request`, `read:jira-work`, `read:jira-user`.

**Identity**: `support_agents.email` — resolved to canonical `person_id` via Identity Manager. JSM distinguishes two user classes: **agents** (`accountType = "atlassian"`) who work issues, and **customers** (`accountType = "customer"`) who raise them. Only agents are resolved to `person_id`; customers are tracked by `requester_id` for volume analytics but are **not** linked to the internal HR roster.

**`source_instance_id`**: set to the Atlassian domain slug, e.g. `jsm-acme-prod`. Required to disambiguate multiple JSM instances in the same Bronze store.

**Design principle**: `support_tickets` stores the current ticket state (snapshot) — updated on each collection run. `support_ticket_events` is the append-only event log built from the Jira changelog and comments APIs — source of truth for MTTR, SLA compliance, and first-response time. `support_sla` is a JSM-specific table capturing SLA policy breach status per ticket at collection time (Zendesk has no equivalent Bronze SLA table; JSM's explicit SLA policies warrant dedicated capture).

**Issue type vocabulary**:

| JSM Issue Type | ITSM Concept | Typical Workflow |
|----------------|-------------|-----------------|
| `Service Request` | Customer asks for something | Request → In Progress → Resolved |
| `Incident` | Unplanned disruption | Triage → Investigation → Resolved |
| `Change` | Planned modification to IT systems | CAB Review → Scheduled → Implemented |
| `Problem` | Root cause of recurring incidents | Investigation → Root Cause Identified → Closed |

**Key difference from Zendesk**: JSM exposes explicit SLA policies with real-time breach status via `GET /rest/servicedeskapi/request/{id}/sla`. Zendesk provides pre-computed timing fields on tickets (`metric_set`) rather than SLA policy objects. This difference motivates the `support_sla` Bronze table in JSM.

**Key difference from Jira Software**: JSM issue queues replace Agile boards and sprints. Analytics focus is ITSM performance (MTTR, SLA compliance, first-response time, agent workload) rather than sprint velocity or development cycle time.

**Incremental collection**: `GET /rest/api/3/issue/{id}` with `updatedSince` or JQL `updated >= "-Xd"` for incremental runs. Changelog requires per-issue calls — `GET /rest/api/3/issue/{id}/changelog` (paginated).

---

## Bronze Tables

**Why five tables**: JSM issues are the core entity, but four separable concerns justify dedicated tables:
- `support_tickets`: current state snapshot — one row per ticket, updated on every run
- `support_ticket_events`: append-only event log — one row per changelog entry or comment; never updated
- `support_agents`: agent directory — identity anchor for `person_id` resolution
- `support_sla`: SLA policy status — one row per SLA policy per ticket at collection time; JSM-specific
- `support_collection_runs`: monitoring table — not an analytics source

### `support_tickets` — Ticket metadata and current state

Maps to the unified `support_tickets` table defined in `docs/connectors/support/README.md`. Current state snapshot, updated on each collection run.

**API**: `GET /rest/api/3/issue/{id}` — full issue detail. For initial load and incremental sync, discover issues via JQL: `GET /rest/api/3/search?jql=project+in+({project_keys})+AND+updated>={cursor}`. Use `GET /rest/servicedeskapi/servicedesk/{id}/queue/{queueId}/issue` as a supplemental discovery path per queue.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | String | Connector instance identifier, e.g. `jsm-acme-prod` |
| `ticket_id` | String | Jira internal numeric ID (stored as string), e.g. `10042` |
| `subject` | String | Ticket summary — from `fields.summary` |
| `status` | String | Normalised status (see mapping below): `new` / `open` / `pending` / `hold` / `solved` / `closed` |
| `priority` | String | Normalised priority: `low` / `normal` / `high` / `urgent`; NULL if not set — from `fields.priority.name` |
| `ticket_type` | String | ITSM issue type: `Service Request` / `Incident` / `Change` / `Problem` — from `fields.issuetype.name` |
| `assignee_id` | String | Current assignee — `fields.assignee.accountId`; NULL if unassigned — joins to `support_agents.agent_id` |
| `group_id` | String | Current queue/group assignment — from `fields.customfield_10020` (service desk queue ID); NULL if not set |
| `requester_id` | String | Customer who raised the request — `fields.reporter.accountId`; **not** resolved to `person_id` |
| `organization_id` | String | Customer's organisation ID — from JSM Organisation API; NULL if not set |
| `created_at` | DateTime64(3) | Ticket creation timestamp — from `fields.created` |
| `updated_at` | DateTime64(3) | Last update — from `fields.updated`; cursor for incremental sync |
| `solved_at` | DateTime64(3) | When ticket was first transitioned to `Resolved` / `Done` — derived from changelog; NULL if not yet resolved |
| `first_reply_time_seconds` | Int64 | Time from `created_at` to first public comment by an agent — derived from `support_ticket_events`; NULL if no reply yet |
| `full_resolution_time_seconds` | Int64 | Time from `created_at` to `solved_at` — derived from `support_ticket_events`; NULL if unresolved |
| `satisfaction_score` | String | Customer satisfaction rating: `good` / `bad`; NULL if not rated — from `fields.satisfaction.rating` |
| `tags` | String | Labels applied — from `fields.labels` joined as comma-separated string |
| `metadata` | String | Full API response as JSON |
| `data_source` | String | `"insight_jsm"` |
| `_version` | UInt64 | Collection timestamp in milliseconds — deduplication version |

**Indexes**:
- `idx_support_ticket_lookup`: `(source_instance_id, ticket_id, data_source)`
- `idx_support_ticket_assignee`: `(assignee_id, data_source)`
- `idx_support_ticket_updated`: `(updated_at)`
- `idx_support_ticket_status`: `(status, data_source)`

**`status` normalisation** — JSM workflow statuses mapped to the unified support status vocabulary:

| JSM Status | Unified `status` |
|------------|-----------------|
| `To Do` / `Open` / `New` | `new` |
| `In Progress` / `Being Investigated` | `open` |
| `Waiting for Customer` | `pending` |
| `Waiting for Support` / `On Hold` | `hold` |
| `Resolved` / `Done` | `solved` |
| `Closed` | `closed` |

**Note on `first_reply_time_seconds` and `full_resolution_time_seconds`**: JSM does not expose pre-computed timing fields equivalent to Zendesk's `metric_set`. Both values are derived from `support_ticket_events` at Silver processing time — `first_reply_time_seconds` from the first `comment` event with `is_public = 1`; `full_resolution_time_seconds` from the first `status_change` event with `value_to` in `{Resolved, Done}`. Stored as NULL in Bronze; populated by the Silver job.

---

### `support_ticket_events` — Append-only audit log

Every status transition, reassignment, field change, and public or internal comment is collected as a separate row. This is the append-only event log — source of truth for MTTR, SLA compliance, first-response time, and agent workload history.

**API**:
- Changelog: `GET /rest/api/3/issue/{id}/changelog` — paginated. Each changelog entry contains one or more items (field changes). Each item produces one row.
- Comments: `GET /rest/api/3/issue/{id}/comment` — paginated. Each comment produces one row.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | String | Connector instance identifier |
| `ticket_id` | String | Parent ticket ID — joins to `support_tickets.ticket_id` |
| `event_id` | String | Composite key: `{changelog_id}_{item_index}` for changelog items; `comment_{comment_id}` for comments — unique per row |
| `event_type` | String | Normalised type (see mapping below): `status_change` / `assignment` / `comment` / `satisfaction_update` / `sla_breach` / `field_change` |
| `author_id` | String | Atlassian `accountId` of agent or automation who triggered the event; NULL for system-generated entries — joins to `support_agents.agent_id` |
| `created_at` | DateTime64(3) | When the event occurred — from changelog `created` or comment `created` |
| `field_name` | String | Which field changed (for `field_change` / `status_change` / `assignment` events), e.g. `status`, `assignee`, `priority`; NULL for `comment` events |
| `value_from` | String | Previous field value (raw ID or key) — from changelog `from`; NULL if field was empty |
| `value_to` | String | New field value (raw ID or key) — from changelog `to` |
| `comment_body` | String | Comment text (plain text extracted from Atlassian Document Format); NULL for non-comment events |
| `is_public` | Int64 | 1 if public comment visible to requester; 0 if internal note; NULL for non-comment events |
| `data_source` | String | `"insight_jsm"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

**Indexes**:
- `idx_support_event_ticket`: `(source_instance_id, ticket_id, data_source)`
- `idx_support_event_author`: `(author_id, data_source)`
- `idx_support_event_created`: `(created_at)`
- `idx_support_event_type`: `(event_type, data_source)`

**`event_type` mapping** — JSM changelog and comment sources:

| JSM source | Unified `event_type` | Notes |
|------------|---------------------|-------|
| Changelog item with `field = "status"` | `status_change` | `value_from` / `value_to` = raw JSM status strings (before normalisation) |
| Changelog item with `field = "assignee"` | `assignment` | `value_from` / `value_to` = Atlassian `accountId` strings |
| Changelog item with `field = "satisfaction"` | `satisfaction_update` | `value_to` = `good` / `bad` |
| Changelog item (all other fields) | `field_change` | `field_name` preserved from changelog `field` |
| Comment (public) | `comment` | `is_public = 1`; `comment_body` from ADF body |
| Comment (internal) | `comment` | `is_public = 0`; `comment_body` set |

**Why append-only**: changelog entries and comments are immutable in JSM — corrections produce new entries. This ensures MTTR and SLA calculations are reproducible from the event log.

**Note on `author_id` for automations**: JSM automations produce changelog entries with system `accountId` values that may not appear in `support_agents`. These are stored as-is; they will not resolve to a `person_id`.

---

### `support_agents` — Agent directory

Identity anchor for support analytics. Maps to `person_id` via Identity Manager. Only Atlassian-internal agents (`accountType = "atlassian"`) are collected; customer portal accounts are excluded.

**API**: `GET /rest/api/3/users/search?accountType=atlassian` — returns internal Atlassian accounts. To identify which accounts are actively assigned to service desk projects, cross-reference with `GET /rest/servicedeskapi/servicedesk/{id}/member` per project.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | String | Connector instance identifier |
| `agent_id` | String | Atlassian `accountId` — e.g. `5b10a2844c20165700ede21g` |
| `email` | String | `emailAddress` — primary identity key → `person_id`; may be NULL for accounts with Atlassian privacy controls applied |
| `display_name` | String | `displayName` |
| `role` | String | Agent role: `agent` / `admin`; NULL if role not determinable from API |
| `group_id` | String | Primary queue / team assignment — from service desk member API; NULL if not set |
| `group_name` | String | Display name of the primary queue / team; NULL if not set |
| `is_active` | Int64 | 1 if `active = true`; 0 if deactivated |
| `collected_at` | DateTime64(3) | Collection timestamp |
| `data_source` | String | `"insight_jsm"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

**Indexes**:
- `idx_support_agent_lookup`: `(source_instance_id, agent_id, data_source)`
- `idx_support_agent_email`: `(email)`

**Note on `email` suppression**: Atlassian privacy controls may suppress `emailAddress` for customer-type accounts. For `accountType = "atlassian"` (agents), suppression is rare. When email is NULL for an agent, `agent_id` (`accountId`) can serve as a within-Atlassian stable identifier but will not resolve to `person_id` (see OQ-JSM-1).

**Note on `group_id` and `group_name`**: JSM does not expose a single "primary group" per user analogous to Zendesk's `default_group_id`. `group_id` is populated from the first service desk project membership found. For agents spanning multiple service desks, `metadata` contains the full membership list.

---

### `support_sla` — SLA policy status per ticket

JSM-specific table. Captures SLA policy breach and compliance status per ticket at collection time. One row per SLA policy per ticket per collection run. Source of truth for SLA compliance rate and breach detection.

**API**: `GET /rest/servicedeskapi/request/{issueIdOrKey}/sla` — returns all SLA policies configured for the ticket's service desk, with current breach/completion status.

**Why this table exists**: JSM exposes explicit SLA policy objects with breach status, remaining time, and goal targets. Zendesk pre-computes timing metrics directly on ticket objects (`metric_set`) and does not expose SLA policy objects via its API — so there is no Zendesk equivalent of this table. The `support_sla` table captures the JSM SLA signal that has no parallel in the Zendesk connector.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | String | Connector instance identifier |
| `ticket_id` | String | Ticket ID — joins to `support_tickets.ticket_id` |
| `sla_name` | String | SLA policy name, e.g. `Time to first response`, `Time to resolution` |
| `sla_field_id` | String | Jira custom field ID for this SLA, e.g. `customfield_10020` |
| `is_breached` | Int64 | 1 if the SLA has been breached; 0 if met or still within target |
| `is_paused` | Int64 | 1 if the SLA clock is currently paused (e.g. `Waiting for Customer` status); 0 otherwise |
| `remaining_seconds` | Int64 | Seconds remaining before breach; negative if already breached; NULL if SLA completed |
| `goal_seconds` | Int64 | SLA target in seconds, e.g. `28800` for 8 hours |
| `elapsed_seconds` | Int64 | Time elapsed against SLA (excluding paused periods); NULL if SLA is paused |
| `completed_at` | DateTime64(3) | When the SLA goal was met; NULL if still open or breached |
| `breached_at` | DateTime64(3) | When the breach occurred; NULL if not breached |
| `collected_at` | DateTime64(3) | Collection timestamp — enables point-in-time SLA snapshot analysis |
| `data_source` | String | `"insight_jsm"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

**Indexes**:
- `idx_support_sla_ticket`: `(source_instance_id, ticket_id, data_source)`
- `idx_support_sla_collected`: `(collected_at)`
- `idx_support_sla_breached`: `(is_breached, data_source)`

**Note on snapshot semantics**: the SLA API returns the current SLA status, not a history of SLA state transitions. SLA pause/resume events are inferred from `support_ticket_events` status transitions (e.g. `In Progress` → `Waiting for Customer` pauses the clock). `collected_at` enables trend analysis when SLA status is collected periodically (see OQ-JSM-2).

---

### `jsm_ticket_ext` — Custom ticket fields (key-value)

JSM tickets inherit Jira's custom field mechanism — custom fields use the `customfield_*` naming pattern. Any `customfield_*` field in the issue response that is not part of the core `support_tickets` schema is written here.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | String | Connector instance identifier, e.g. `jsm-acme-prod` |
| `ticket_id` | String | Parent ticket ID — joins to `support_tickets.ticket_id` |
| `field_id` | String | Jira custom field ID, e.g. `customfield_10200` |
| `field_name` | String | Custom field display name (from `GET /rest/api/3/field`) |
| `field_value` | String | Field value as string; JSON for complex types |
| `value_type` | String | Type hint: `string` / `number` / `user` / `enum` / `json` |
| `collected_at` | DateTime64(3) | Collection timestamp |

**Discovery**: `GET /rest/api/3/field` returns all field definitions including custom fields. The connector fetches field metadata at startup and maps `customfield_*` IDs to display names when writing rows.

---

### `support_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | Run start timestamp |
| `completed_at` | DateTime64(3) | Run end timestamp; NULL while running |
| `status` | String | `running` / `completed` / `failed` |
| `tickets_collected` | Int64 | Rows upserted into `support_tickets` |
| `events_collected` | Int64 | Rows appended to `support_ticket_events` |
| `agents_collected` | Int64 | Rows upserted into `support_agents` |
| `sla_records_collected` | Int64 | Rows written to `support_sla` |
| `api_calls` | Int64 | Total API calls made during the run |
| `errors` | Int64 | Number of errors encountered |
| `settings` | String | Collection configuration as JSON: `instance_url`, `project_keys`, `incremental_cursor`, `lookback_days`, `collect_sla` flag |
| `data_source` | String | `"insight_jsm"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

Monitoring table — not an analytics source.

---

## Identity Resolution

**Identity anchor**: `support_agents` — internal agents (`accountType = "atlassian"`) who handle tickets.

**Resolution process**:
1. Extract `email` from `support_agents`
2. Normalize (lowercase, trim)
3. Map to canonical `person_id` via Identity Manager in Silver step 2
4. Propagate `person_id` to `support_ticket_events` via `author_id` → `support_agents.agent_id` join

**Resolution chain**:
```
support_ticket_events.author_id
  → support_agents.agent_id
  → support_agents.email
  → person_id
```

**`requester_id` in `support_tickets`**: customer (`accountType = "customer"`) Atlassian account IDs — **not** resolved to `person_id`. Used for request volume and routing analysis only.

**`source_instance_id` is required in all joins** — Atlassian `accountId` values and `ticket_id` values are scoped to one Atlassian tenant; they collide across separate JSM instances.

**Atlassian email suppression**: Atlassian privacy controls may suppress `emailAddress` for customer-type accounts. For agents, suppression is rare. When email is NULL for an agent account, `agent_id` (`accountId`) can serve as a stable within-Atlassian identifier but will not map to `person_id` (see OQ-JSM-1).

---

## Silver / Gold Mappings

| Bronze table | Silver target | Notes |
|-------------|--------------|-------|
| `support_tickets` + `support_ticket_events` | `class_support_activity` | Per-agent per-day ticket metrics with resolved `person_id` |
| `support_agents` | Identity Manager (`email` → `person_id`) | Agents only (`accountType = "atlassian"`) |
| `support_tickets` | Reference — ticket context | Enriches `class_support_activity` with `ticket_type`, `priority`, `satisfaction_score` |
| `support_sla` | `class_support_sla` | Planned — SLA compliance per ticket per policy; JSM-specific Silver stream |

**`class_support_activity`** derivation from JSM Bronze:

| `class_support_activity` field | Derived from |
|-------------------------------|--------------|
| `person_id` | `support_ticket_events.author_id` → `support_agents.email` → Identity Manager |
| `date` | `support_ticket_events.created_at` (date part) |
| `tickets_resolved` | Count of `status_change` events per agent per date where `value_to` ∈ `{Resolved, Done}` |
| `first_response_time_seconds` | Average time from `support_tickets.created_at` to first `comment` event with `is_public = 1` per agent per date |
| `full_resolution_time_seconds` | Average of `support_tickets.full_resolution_time_seconds` for tickets resolved by agent on this date |
| `satisfaction_score` | Average CSAT fraction (`good` / total rated) for tickets resolved by agent on this date |
| `comments_sent` | Count of `comment` events with `is_public = 1` by agent on this date |

**`class_support_sla`** — planned JSM-specific Silver target:

| Field | Type | Description |
|-------|------|-------------|
| `person_id` | String | Agent assigned at SLA collection time |
| `ticket_id` | String | Source ticket ID |
| `source_instance_id` | String | Connector instance identifier |
| `sla_name` | String | SLA policy name |
| `is_breached` | Int64 | 1 if breached |
| `goal_seconds` | Int64 | SLA target |
| `elapsed_seconds` | Int64 | Time elapsed against SLA |
| `collected_at` | DateTime64(3) | Snapshot timestamp |
| `data_source` | String | `"insight_jsm"` |

**Gold metrics** (ITSM-focused):
- **MTTR (Mean Time to Resolve)**: average `full_resolution_time_seconds` per agent / team / period from `class_support_activity`
- **First-response SLA compliance**: fraction of tickets where `first_reply_time_seconds` ≤ SLA `goal_seconds` (from `support_sla` where `sla_name = "Time to first response"`)
- **Full-resolution SLA compliance**: fraction of tickets where `full_resolution_time_seconds` ≤ SLA `goal_seconds` (from `support_sla` where `sla_name = "Time to resolution"`)
- **SLA breach rate**: fraction of issues where `support_sla.is_breached = 1` at resolution, per policy per period
- **Agent workload**: `tickets_resolved` + `comments_sent` per agent per week from `class_support_activity`
- **CSAT trend**: average `satisfaction_score` per agent and team over rolling 30 days
- **Ticket volume by type/priority**: breakdown of inflow and resolution by `ticket_type` and `priority`
- **Incident frequency**: count of `ticket_type = "Incident"` per time bucket
- **Backlog growth**: open tickets not yet resolved within SLA window

---

## Open Questions

### OQ-JSM-1: Customer account email suppression

Atlassian privacy controls may suppress `emailAddress` for customer-type (`accountType = "customer"`) portal accounts. Options:
- Use `agent_id` (`accountId`) as a stable customer identifier within the same Atlassian tenant (does not cross-resolve to HR)
- Require email for analytics attribution and exclude customer-anonymous requests from per-reporter metrics
- Support opt-in customer email collection via the Service Desk Customer API where permitted

### OQ-JSM-2: SLA collection frequency

`support_sla` captures point-in-time SLA status at collection. For accurate breach-rate analysis, SLA state should be recorded at least hourly for open issues near their deadline. Options:
- **Incremental mode**: collect SLA for all open issues on every run (potentially expensive for large instances)
- **Event-driven mode**: collect SLA only when `support_ticket_events` shows a status transition on the ticket
- **Scheduled snapshots**: daily snapshot for all tickets; higher frequency for tickets with `remaining_seconds` < 3600

### OQ-JSM-3: Queue-based vs project-based collection

Issues can be discovered via two paths:
- `GET /rest/api/3/project?typeKey=service_desk` → JQL search per project (full coverage, recommended)
- `GET /rest/servicedeskapi/servicedesk/{id}/queue/{queueId}/issue` → queue membership (partial, depends on queue configuration)

The project-based path is recommended for completeness. The queue path is supplemental for queue depth tracking.

### OQ-JSM-4: `class_support_sla` — Silver schema design

The `support_sla` table introduces `class_support_sla`, a JSM-specific Silver target not produced by the Zendesk connector. Design of this table is planned but not finalised — it needs to accommodate multiple SLA policies per ticket and enable time-series breach analysis from periodic snapshots. Relevant prior art in `docs/connectors/support/README.md` OQ-SUP-1.
