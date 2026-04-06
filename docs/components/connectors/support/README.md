# Support Connector Specification (Multi-Source)

> Version 1.1 — March 2026
> Based on: Zendesk (Source 21) and JSM (Source 22)

Data-source agnostic specification for support and helpdesk connectors. Defines unified Bronze schemas that work across Zendesk and Jira Service Management (JSM) using a `data_source` discriminator column.

**Primary analytics focus**: support team performance — MTTR, SLA compliance, agent workload, first-response time, CSAT scores, and ticket volume trends.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`support_tickets` — Ticket metadata and current state](#supporttickets-ticket-metadata-and-current-state)
  - [`support_ticket_events` — Append-only audit log](#supportticketevents-append-only-audit-log)
  - [`support_agents` — Agent directory](#supportagents-agent-directory)
  - [`support_collection_runs` — Connector execution log](#supportcollectionruns-connector-execution-log)
  - [`support_sla` — SLA policy status per ticket (JSM only)](#supportsla-sla-policy-status-per-ticket-jsm-only)
- [Source Mapping](#source-mapping)
  - [Zendesk](#zendesk)
  - [JSM](#jsm)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-SUP-1: SLA threshold configuration](#oq-sup-1-sla-threshold-configuration)
  - [OQ-SUP-2: Timing field source — pre-computed vs. derived](#oq-sup-2-timing-field-source-pre-computed-vs-derived)
  - [OQ-SUP-3: JSM agent role detection](#oq-sup-3-jsm-agent-role-detection)

<!-- /toc -->

---

## Overview

**Category**: Support / Helpdesk

**Supported Sources**:
- Zendesk (`data_source = "insight_zendesk"`)
- Jira Service Management (`data_source = "insight_jsm"`)

**Authentication**:
- Zendesk: API token (email/token Basic Auth) or OAuth 2.0. Token created under Admin → Apps & Integrations → Zendesk API.
- JSM: Basic Auth (`{email}:{api_token}` Base64-encoded) or OAuth 2.0 (3LO). Token created under Atlassian Account → Security → API tokens. Base URL: `https://{domain}.atlassian.net`.

**Identity**: `support_agents.email` — support agents resolved to canonical `person_id` via Identity Manager. External customers (ticket requesters) are **not** resolved to `person_id`.

**Design principle**: `support_tickets` stores the current ticket state (snapshot) — identifiers, metadata, and latest values for status, assignee, and timing fields. `support_ticket_events` is an append-only audit log capturing every status change, reassignment, and comment — the source of truth for MTTR, SLA compliance, and first-response time calculations.

**`insight_source_id`**: present in all tables — required to disambiguate multiple tool instances (e.g. two Zendesk tenants or multiple JSM organizations in the same Bronze store).

**Terminology mapping**:

| Concept | Zendesk | JSM | Unified |
|---------|---------|-----|---------|
| Request | Ticket | Service request / Issue | `support_tickets` |
| Workflow group | Group | Queue | `support_agents.group_id` |
| Handler | Agent | Assignee | `support_agents` |
| Status change / comment | Audit | Changelog / Comment | `support_ticket_events` |
| Customer rating | Satisfaction rating | Customer satisfaction | `satisfaction_score` |
| SLA policy status | (pre-computed on ticket `metric_set`) | SLA policy object with breach status | `support_sla` (JSM only) |

---

## Bronze Tables

### `support_tickets` — Ticket metadata and current state

Current snapshot of each ticket. Updated on every collection run. Identifiers and mutable state fields (status, assignee, priority) reflect the latest value from the source. Timing fields (`first_reply_time_seconds`, `full_resolution_time_seconds`) are pre-computed by the source and stored directly.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier, e.g. `zendesk-acme`, `jsm-team-alpha` |
| `ticket_id` | String | REQUIRED | Source-specific ticket ID |
| `subject` | String | NULLABLE | Ticket title / summary |
| `status` | String | REQUIRED | Normalised status: `new` / `open` / `pending` / `hold` / `solved` / `closed` |
| `priority` | String | NULLABLE | Normalised priority: `low` / `normal` / `high` / `urgent`; NULL if not set |
| `ticket_type` | String | NULLABLE | Ticket type: `question` / `incident` / `problem` / `task`; NULL if not categorised |
| `assignee_id` | String | NULLABLE | Current assignee — source agent ID — joins to `support_agents.agent_id` |
| `group_id` | String | NULLABLE | Current group / queue assignment — source group ID |
| `requester_id` | String | NULLABLE | External requester (customer) — source user ID; **not** resolved to `person_id` |
| `organization_id` | String | NULLABLE | Requester's organization / company ID |
| `created_at` | DateTime64(3) | REQUIRED | Ticket creation timestamp |
| `updated_at` | DateTime64(3) | REQUIRED | Last update — cursor for incremental sync |
| `solved_at` | DateTime64(3) | NULLABLE | When ticket was first marked solved; NULL if not yet solved |
| `first_reply_time_seconds` | Int64 | NULLABLE | Time from creation to first agent reply, in seconds; NULL if no reply yet |
| `full_resolution_time_seconds` | Int64 | NULLABLE | Time from creation to solved/closed, in seconds; NULL if unresolved |
| `satisfaction_score` | String | NULLABLE | CSAT rating: `good` / `bad`; NULL if not rated or not applicable |
| `tags` | String | NULLABLE | Comma-separated tags / labels applied to the ticket |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `custom_str_attrs` | Map(String, String) | DEFAULT {} | Workspace-specific string custom fields promoted from `zendesk_ticket_ext` / `jsm_ticket_ext` per Custom Attributes Configuration |
| `custom_num_attrs` | Map(String, Float64) | DEFAULT {} | Workspace-specific numeric custom fields (e.g. urgency scores, SLA tier) |
| `data_source` | String | DEFAULT '' | Source discriminator: `insight_zendesk` / `insight_jsm` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_support_ticket_lookup`: `(insight_source_id, ticket_id, data_source)`
- `idx_support_ticket_assignee`: `(assignee_id, data_source)`
- `idx_support_ticket_updated`: `(updated_at)`
- `idx_support_ticket_status`: `(status, data_source)`

**`status` normalisation**:
- Zendesk: native values (`new` / `open` / `pending` / `hold` / `solved` / `closed`) — mapped directly
- JSM: `To Do` → `new`; `In Progress` / `Waiting for customer` / `Waiting for support` → `open` / `pending`; `Done` / `Resolved` → `solved`; `Closed` → `closed`

---

### `support_ticket_events` — Append-only audit log

Every status change, reassignment, SLA breach event, and public comment is a separate row. This is the append-only event log — source of truth for MTTR, SLA compliance, first-response time verification, and agent workload history.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `ticket_id` | String | REQUIRED | Parent ticket ID — joins to `support_tickets.ticket_id` |
| `event_id` | String | REQUIRED | Source-specific event / audit ID — unique per row |
| `event_type` | String | REQUIRED | Normalised type: `status_change` / `assignment` / `comment` / `satisfaction_update` / `sla_breach` / `field_change` |
| `author_id` | String | NULLABLE | Agent or system who triggered the event — source agent ID; NULL for system-generated events |
| `created_at` | DateTime64(3) | REQUIRED | When the event occurred |
| `field_name` | String | NULLABLE | Which field changed (for `field_change` events), e.g. `status`, `assignee_id`, `priority` |
| `value_from` | String | NULLABLE | Previous field value; NULL for new tickets or non-field events |
| `value_to` | String | NULLABLE | New field value |
| `comment_body` | String | NULLABLE | Comment text (for `comment` events); NULL for non-comment events |
| `is_public` | Int64 | NULLABLE | 1 if public comment / reply visible to requester; 0 for internal note; NULL for non-comment events |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_support_event_ticket`: `(insight_source_id, ticket_id, data_source)`
- `idx_support_event_author`: `(author_id, data_source)`
- `idx_support_event_created`: `(created_at)`
- `idx_support_event_type`: `(event_type, data_source)`

**`event_type` normalisation**:
- Zendesk audits contain `events[]` of subtypes (`Change`, `Comment`, `SatisfactionRatingEvent`) — each subtype maps to one `event_type` row
- JSM changelog entries map to `field_change` or `status_change`; JSM comments map to `comment`

**Why append-only**: event logs must never be updated in place — corrections in the source produce new audit entries. This ensures MTTR and SLA calculations are reproducible from the log.

---

### `support_agents` — Agent directory

Identity anchor for support analytics. Maps to `person_id` via Identity Manager.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `agent_id` | String | REQUIRED | Source-specific agent / user ID |
| `email` | String | REQUIRED | Email — primary identity key → `person_id` |
| `display_name` | String | NULLABLE | Agent display name |
| `role` | String | NULLABLE | Agent role: `agent` / `admin` / `light_agent` (Zendesk); `agent` / `admin` (JSM) |
| `group_id` | String | NULLABLE | Primary group / team assignment — source group ID |
| `group_name` | String | NULLABLE | Primary group / team name |
| `is_active` | Int64 | DEFAULT 1 | 1 if active; 0 if suspended or deactivated |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_support_agent_lookup`: `(insight_source_id, agent_id, data_source)`
- `idx_support_agent_email`: `(email)`

---

### `support_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `tickets_collected` | Int64 | NULLABLE | Rows collected for `support_tickets` |
| `events_collected` | Int64 | NULLABLE | Rows collected for `support_ticket_events` |
| `agents_collected` | Int64 | NULLABLE | Rows collected for `support_agents` |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Number of errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (instance URL, lookback window, incremental cursor) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

Monitoring table — not an analytics source.

---

### `support_sla` — SLA policy status per ticket (JSM only)

JSM-specific table — not produced by the Zendesk connector. Captures SLA policy breach and compliance status per ticket at collection time. See `docs/connectors/support/jsm.md` for the full field definition.

JSM exposes explicit SLA policy objects (via `GET /rest/servicedeskapi/request/{id}/sla`) with breach status, remaining time, and goal targets. Zendesk pre-computes equivalent timing metrics directly on ticket objects (`metric_set`) and does not expose SLA policy objects via its API — so there is no Zendesk equivalent of this table.

**Silver target**: `class_support_sla` — planned; SLA compliance per ticket per policy, enables breach-rate and compliance-rate Gold metrics.

---

## Source Mapping

### Zendesk

**API**: Zendesk REST API v2 (`/api/v2/tickets`, `/api/v2/users`, `/api/v2/satisfaction_ratings`, `/api/v2/incremental/tickets.json`)

| Unified table | Zendesk source | Key mapping notes |
|---------------|---------------|-------------------|
| `support_tickets` | `GET /api/v2/tickets` or `GET /api/v2/incremental/tickets.json?start_time=` | `id` → `ticket_id`; `assignee_id` → `assignee_id`; `group_id` → `group_id`; `requester_id` → `requester_id`; `via.source.from.id` skipped; `metric_set.first_reply_time_in_minutes_within_business_hours` × 60 → `first_reply_time_seconds`; `metric_set.full_resolution_time_in_minutes_within_business_hours` × 60 → `full_resolution_time_seconds` |
| `support_ticket_events` | `GET /api/v2/tickets/{id}/audits` | Each audit contains `events[]`; each event entry maps to one row; `audit.author_id` → `author_id`; `audit.created_at` → `created_at`; `ChangeEvent` → `field_change` / `status_change` / `assignment`; `CommentEvent` → `comment`; `SatisfactionRatingEvent` → `satisfaction_update` |
| `support_agents` | `GET /api/v2/users?role=agent` | `id` → `agent_id`; `email` → `email`; `name` → `display_name`; `role` → `role`; `default_group_id` → `group_id`; `active` → `is_active` |
| `support_collection_runs` | Connector-generated | Written at start and end of each run |

**Incremental export**: `GET /api/v2/incremental/tickets.json?start_time={unix_ts}` exports tickets updated since the cursor — preferred over full scans for large accounts. Returns up to 1000 tickets per page. Side-loads (`metric_sets`, `users`) available to reduce extra round-trips.

**Satisfaction ratings**: `GET /api/v2/satisfaction_ratings` returns CSAT results per ticket. `score` values `"good"` / `"bad"` mapped directly to `satisfaction_score`. Ratings are backfilled onto `support_tickets.satisfaction_score` during collection.

---

### JSM

**API**: Atlassian REST API v3 (`https://{domain}.atlassian.net/rest/api/3/`) + Service Desk API v1 (`https://{domain}.atlassian.net/rest/servicedeskapi/`).

**`data_source`**: `"insight_jsm"`

**`insight_source_id`**: Atlassian domain slug, e.g. `jsm-acme-prod`.

| Unified table | JSM source | Key mapping notes |
|---------------|-----------|-------------------|
| `support_tickets` | `GET /rest/api/3/search?jql=project+in+({keys})` + `GET /rest/api/3/issue/{id}` | `id` → `ticket_id`; `fields.summary` → `subject`; `fields.assignee.accountId` → `assignee_id`; JSM status → normalised `status` (see jsm.md mapping table); `fields.priority.name` → `priority`; `fields.issuetype.name` → `ticket_type`; `fields.reporter.accountId` → `requester_id`; `solved_at` and timing fields derived from changelog at Silver |
| `support_ticket_events` | `GET /rest/api/3/issue/{id}/changelog` + `GET /rest/api/3/issue/{id}/comment` | Each changelog item → one row (`status_change` / `assignment` / `field_change`); each comment → one row (`comment`); `author.accountId` → `author_id`; ADF comment body → `comment_body` |
| `support_agents` | `GET /rest/api/3/users/search?accountType=atlassian` | `accountId` → `agent_id`; `emailAddress` → `email`; `displayName` → `display_name`; `active` → `is_active` |
| `support_sla` | `GET /rest/servicedeskapi/request/{issueIdOrKey}/sla` | One row per SLA policy per ticket; `ongoingCycle.breached` → `is_breached`; `ongoingCycle.paused` → `is_paused`; `ongoingCycle.remainingTime.millis` ÷ 1000 → `remaining_seconds`; `completedCycles[-1].breachTime` → `breached_at` |
| `support_collection_runs` | Connector-generated | Written at start and end of each run |

**Incremental sync**: discover issues via JQL `updated >= "{cursor}"` scoped to service desk project keys. Changelog requires one API call per issue (`GET /rest/api/3/issue/{id}/changelog`, paginated). SLA collection via `GET /rest/servicedeskapi/request/{id}/sla` is an additional per-issue call — see OQ-JSM-2 for frequency trade-offs.

**JSM project discovery**: `GET /rest/api/3/project?typeKey=service_desk` returns all JSM projects. `service_desk_id` (from `GET /rest/servicedeskapi/servicedesk`) is required for SLA and queue API calls and differs from Jira's `project_id`.

---

## Identity Resolution

**Identity anchor**: `support_agents` — all internal agents who handle tickets.

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

**`requester_id` in `support_tickets`**: external customers — **not** resolved to `person_id`. Used for volume and routing analysis only.

**`insight_source_id` is required in all joins** — ticket IDs can collide across instances of the same source.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Notes |
|-------------|--------------|-------|
| `support_tickets` + `support_ticket_events` | `class_support_activity` | Per-agent per-day ticket metrics with resolved `person_id` |
| `support_agents` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `support_tickets` | Reference — ticket context | Used to enrich `class_support_activity` with ticket type, priority, satisfaction |
| `support_sla` | `class_support_sla` | JSM only — SLA compliance per ticket per policy; planned Silver stream |

**`class_support_activity`** — Silver target: per-agent per-day support activity metrics.

| Field | Type | Description |
|-------|------|-------------|
| `person_id` | String | Canonical agent identity |
| `date` | Date | Activity date |
| `tickets_resolved` | Int64 | Tickets the agent resolved on this date (first `status_change` to `solved`) |
| `first_response_time_seconds` | Int64 | Average first-response time across tickets replied to on this date |
| `full_resolution_time_seconds` | Int64 | Average full resolution time across tickets resolved on this date |
| `satisfaction_score` | Float64 | Average CSAT: fraction of `good` ratings out of rated tickets resolved this date |
| `comments_sent` | Int64 | Public replies (comments with `is_public = 1`) sent by agent on this date |
| `data_source` | String | Source discriminator |

**Gold metrics**:
- **MTTR** (Mean Time to Resolution): average `full_resolution_time_seconds` per agent / team / period
- **First-response SLA compliance**: fraction of tickets where `first_reply_time_seconds` < SLA threshold
- **Full-resolution SLA compliance**: fraction of tickets where `full_resolution_time_seconds` < SLA threshold
- **Agent workload**: `tickets_resolved` + `comments_sent` per agent per week
- **CSAT trend**: average `satisfaction_score` per agent / team over time
- **Ticket volume by type/priority**: breakdown of ticket inflow and resolution by `ticket_type` and `priority`
- **Backlog growth**: open tickets not yet resolved within SLA window

---

## Open Questions

### OQ-SUP-1: SLA threshold configuration

SLA thresholds (first-response, full-resolution) are organisation-specific and may differ by ticket priority or customer tier. Zendesk supports SLA Policies attached to tickets; JSM has SLA schemas per service desk.

**Question**: Should SLA thresholds be parameterized per connector instance (configuration) or fetched from the source API (Zendesk SLA Policies: `GET /api/v2/slas/policies`) and stored in an additional Bronze reference table?

### OQ-SUP-2: Timing field source — pre-computed vs. derived

Zendesk provides pre-computed `metric_set.first_reply_time_in_minutes_within_business_hours` on tickets. JSM does not expose equivalent pre-computed fields — timings must be derived from `support_ticket_events` by finding the first `comment` event with `is_public = 1`.

**Question**: Should `first_reply_time_seconds` and `full_resolution_time_seconds` in `support_tickets` use source pre-computed values where available (Zendesk) and computed values where not (JSM), or should all timing be derived uniformly from the event log for cross-source consistency?

### OQ-SUP-3: JSM agent role detection

JSM does not expose a direct "list all agents" endpoint. Agents must be identified by their role within a specific service desk project. When an organisation has multiple service desk projects, the same Atlassian account may be an agent in one and a reporter (customer) in another.

**Question**: Should `support_agents` be populated per-project (risking duplicates for multi-project agents) or deduplicated across all projects by `accountId`?
