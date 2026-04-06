# Zendesk Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/connectors/support/README.md` (Support domain schema)

Standalone specification for the Zendesk (Support / Helpdesk) connector.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`support_tickets` — Ticket metadata and current state](#supporttickets-ticket-metadata-and-current-state)
  - [`support_ticket_events` — Append-only audit log](#supportticketevents-append-only-audit-log)
  - [`support_agents` — Agent directory](#supportagents-agent-directory)
  - [`zendesk_ticket_ext` — Custom ticket fields (key-value)](#zendesk_ticket_ext--custom-ticket-fields-key-value)
  - [`support_collection_runs` — Connector execution log](#supportcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-ZD-1: Incremental audit collection strategy](#oq-zd-1-incremental-audit-collection-strategy)
  - [OQ-ZD-2: `satisfaction_score` backfill frequency](#oq-zd-2-satisfactionscore-backfill-frequency)
  - [OQ-ZD-3: Business-hours vs. calendar-hours timing](#oq-zd-3-business-hours-vs-calendar-hours-timing)

<!-- /toc -->

---

## Overview

**API**: Zendesk REST API v2 (`https://{subdomain}.zendesk.com/api/v2/`)

**Category**: Support / Helpdesk

**Authentication**:
- **API token** (preferred for service accounts): HTTP Basic Auth with `{email}/token:{api_token}` encoded as Base64. Token created under Admin → Apps & Integrations → Zendesk API.
- **OAuth 2.0**: Authorization Code flow — requires a Zendesk OAuth client. Scopes: `tickets:read`, `users:read`, `satisfaction_ratings:read`.

**Identity**: `support_agents.email` — resolved to canonical `person_id` via Identity Manager. Zendesk `user.id` (numeric) is Zendesk-internal; `email` is the cross-system key.

**`data_source`**: `"insight_zendesk"` — used as the source discriminator in all unified Bronze tables.

**`insight_source_id`**: set to the Zendesk subdomain slug, e.g. `zendesk-acme`. Required to disambiguate multiple Zendesk tenants in the same Bronze store.

**Design principle**: `support_tickets` stores the current ticket state. `support_ticket_events` captures every audit entry from `/api/v2/tickets/{id}/audits` as an append-only event log. This pattern mirrors the task-tracking domain (`task_tracker_issues` + `task_tracker_history`).

**Incremental export**: Zendesk provides `GET /api/v2/incremental/tickets.json?start_time={unix_ts}` for efficient bulk export. Use this endpoint for scheduled collection runs — the cursor advances only when the full page is consumed. Full ticket audits must be fetched individually via `/api/v2/tickets/{id}/audits` (no bulk audit export).

---

## Bronze Tables

### `support_tickets` — Ticket metadata and current state

Maps to the unified `support_tickets` table defined in `docs/connectors/support/README.md`. Current state snapshot, updated on each collection run.

**API**: `GET /api/v2/tickets` (initial load) or `GET /api/v2/incremental/tickets.json?start_time=` (incremental). Side-load `metric_sets` to retrieve timing fields without extra calls.

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier, e.g. `zendesk-acme` |
| `ticket_id` | String | Zendesk ticket `id` (numeric, stored as string) |
| `subject` | String | Ticket `subject` |
| `status` | String | `status` field — values: `new` / `open` / `pending` / `hold` / `solved` / `closed` — mapped directly |
| `priority` | String | `priority` field — `low` / `normal` / `high` / `urgent`; NULL if not set |
| `ticket_type` | String | `type` field — `question` / `incident` / `problem` / `task`; NULL if not set |
| `assignee_id` | String | `assignee_id` — numeric Zendesk user ID (agent); NULL if unassigned — joins to `support_agents.agent_id` |
| `group_id` | String | `group_id` — numeric group ID; NULL if unassigned |
| `requester_id` | String | `requester_id` — numeric Zendesk user ID (customer); **not** resolved to `person_id` |
| `organization_id` | String | `organization_id` — numeric org ID; NULL if requester has no organisation |
| `created_at` | DateTime64(3) | `created_at` (ISO 8601 string → DateTime64) |
| `updated_at` | DateTime64(3) | `updated_at` — cursor for incremental sync |
| `solved_at` | DateTime64(3) | `metric_set.solved_at`; NULL if not yet solved |
| `first_reply_time_seconds` | Int64 | `metric_set.reply_time_in_minutes.business` × 60; NULL if no reply yet |
| `full_resolution_time_seconds` | Int64 | `metric_set.full_resolution_time_in_minutes.business` × 60; NULL if unresolved |
| `satisfaction_score` | String | From `GET /api/v2/satisfaction_ratings` joined on `ticket_id`; `good` / `bad`; NULL if unrated |
| `tags` | String | `tags` array joined as comma-separated string |
| `metadata` | String | Full API response as JSON |
| `data_source` | String | `"insight_zendesk"` |
| `_version` | UInt64 | Collection timestamp in milliseconds — deduplication version |

**Indexes**:
- `idx_support_ticket_lookup`: `(insight_source_id, ticket_id, data_source)`
- `idx_support_ticket_assignee`: `(assignee_id, data_source)`
- `idx_support_ticket_updated`: `(updated_at)`
- `idx_support_ticket_status`: `(status, data_source)`

**Note on `first_reply_time_seconds`**: Zendesk returns business-hours metrics in `metric_set.reply_time_in_minutes.business`. Calendar-hours equivalent is available in `metric_set.reply_time_in_minutes.calendar`. Store business-hours value in `first_reply_time_seconds` (aligns with SLA Policy evaluation); calendar-hours variant available in `metadata`.

**Note on `satisfaction_score`**: CSAT ratings are returned by a separate endpoint — `GET /api/v2/satisfaction_ratings` (paginated). Ratings are backfilled onto `support_tickets.satisfaction_score` by joining on `satisfaction_rating.ticket_id` during the collection run.

---

### `support_ticket_events` — Append-only audit log

Every audit on every ticket is collected from `GET /api/v2/tickets/{id}/audits`. Each Zendesk audit contains an `events[]` array — each entry in the array produces one row in `support_ticket_events`.

**API**: `GET /api/v2/tickets/{id}/audits` — paginated per ticket. For high-volume accounts, use the incremental cursor to limit the set of tickets whose audits need fetching.

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier |
| `ticket_id` | String | Zendesk ticket `id` — joins to `support_tickets.ticket_id` |
| `event_id` | String | Composite key: `{audit.id}_{event_index}` — unique per row (Zendesk audit `id` is unique per audit, not per event within the audit) |
| `event_type` | String | Normalised event type (see mapping below) |
| `author_id` | String | `audit.author_id` — Zendesk user ID of agent or automation; NULL for system events — joins to `support_agents.agent_id` |
| `created_at` | DateTime64(3) | `audit.created_at` — when this audit (batch of events) was recorded |
| `field_name` | String | For `field_change` / `status_change` / `assignment`: the field that changed (e.g. `status`, `assignee_id`, `priority`, `group_id`); NULL for `comment` events |
| `value_from` | String | Previous field value; NULL for new tickets or non-field events |
| `value_to` | String | New field value |
| `comment_body` | String | Comment text (plain text extracted from HTML); NULL for non-comment events |
| `is_public` | Int64 | 1 if public reply visible to requester; 0 if internal note; NULL for non-comment events |
| `data_source` | String | `"insight_zendesk"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

**Indexes**:
- `idx_support_event_ticket`: `(insight_source_id, ticket_id, data_source)`
- `idx_support_event_author`: `(author_id, data_source)`
- `idx_support_event_created`: `(created_at)`
- `idx_support_event_type`: `(event_type, data_source)`

**Zendesk `event_type` mapping**:

| Zendesk audit event type | Unified `event_type` | Notes |
|--------------------------|---------------------|-------|
| `ChangeEvent` with `field_name = "status"` | `status_change` | `value_from` / `value_to` = raw status strings |
| `ChangeEvent` with `field_name = "assignee_id"` | `assignment` | `value_from` / `value_to` = numeric agent IDs as strings |
| `ChangeEvent` (all other fields) | `field_change` | `field_name` preserved from the event |
| `CommentEvent` (public) | `comment` | `is_public = 1`; `comment_body` from `body` stripped of HTML |
| `CommentEvent` (private) | `comment` | `is_public = 0`; `comment_body` set |
| `SatisfactionRatingEvent` | `satisfaction_update` | `value_to` = `good` / `bad` / `offered`; `field_name = "satisfaction"` |
| `NotificationEvent`, `CcEvent`, etc. | `field_change` | Non-analytics events; captured for completeness |

**Note on `author_id` for automations**: Zendesk Triggers and Automations produce audits with a system `author_id` (e.g. the trigger's user ID, which may not appear in `support_agents`). These are stored as-is; `author_id` will not resolve to a `person_id` for system-generated events.

---

### `support_agents` — Agent directory

Identity anchor for support analytics. Maps to `person_id` via Identity Manager.

**API**: `GET /api/v2/users?role=agent` — returns only users with the `agent` or `admin` role. Paginate with `page[after]` cursor. Use `include=groups` to retrieve group memberships without extra calls.

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier |
| `agent_id` | String | Zendesk `user.id` (numeric, stored as string) |
| `email` | String | `user.email` — primary identity key → `person_id` |
| `display_name` | String | `user.name` |
| `role` | String | `user.role` — `agent` / `admin` / `light_agent` |
| `group_id` | String | `user.default_group_id` — numeric primary group ID; NULL if not set |
| `group_name` | String | Display name of the group at `default_group_id`; NULL if not set |
| `is_active` | Int64 | `user.active` — 1 if active; 0 if suspended (`user.suspended = true`) |
| `collected_at` | DateTime64(3) | Collection timestamp |
| `data_source` | String | `"insight_zendesk"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

**Indexes**:
- `idx_support_agent_lookup`: `(insight_source_id, agent_id, data_source)`
- `idx_support_agent_email`: `(email)`

**Note on `role`**: Zendesk has three agent-tier roles — `agent` (standard), `admin` (full access), `light_agent` (read-only with comment access). The `GET /api/v2/users?role=agent` endpoint returns all three tiers. Fetch admins separately with `?role=admin` if needed.

**Note on `group_name`**: `default_group_id` references a Zendesk Group. Group names can be fetched via `GET /api/v2/groups` and joined at collection time to populate `group_name`.

---

### `zendesk_ticket_ext` — Custom ticket fields (key-value)

Zendesk tickets support custom fields configured per account via `GET /api/v2/ticket_fields`. Each custom field value appears in `ticket.custom_fields[]` array in the ticket response. Non-standard fields not in the core `support_tickets` schema are written here.

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier, e.g. `zendesk-acme` |
| `ticket_id` | String | Parent ticket ID — joins to `support_tickets.ticket_id` |
| `field_id` | String | Zendesk custom field ID (numeric, stored as string) |
| `field_title` | String | Custom field display title (from `GET /api/v2/ticket_fields`) |
| `field_value` | String | Field value as string |
| `value_type` | String | Type hint: `string` / `number` / `enumeration` / `date` / `json` |
| `collected_at` | DateTime64(3) | Collection timestamp |

**Discovery**: `GET /api/v2/ticket_fields` returns all custom field definitions for the account. The connector fetches field metadata at startup and maps `field_id` to `field_title` when writing rows.

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
| `api_calls` | Int64 | Total API calls made during the run |
| `errors` | Int64 | Number of errors encountered |
| `settings` | String | Collection configuration as JSON: `subdomain`, `incremental_cursor`, `lookback_days`, `fetch_audits` flag |
| `data_source` | String | `"insight_zendesk"` |
| `_version` | UInt64 | Collection timestamp in milliseconds |

Monitoring table — not an analytics source.

---

## Identity Resolution

**Identity anchor**: `support_agents` — internal agents who respond to tickets.

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

**`requester_id` in `support_tickets`**: external customers — **not** resolved to `person_id`. Used for volume analytics and routing only.

**`insight_source_id` is required in all joins** — numeric Zendesk IDs (ticket IDs, user IDs) are scoped to one subdomain; they collide across different Zendesk tenants.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Notes |
|-------------|--------------|-------|
| `support_tickets` + `support_ticket_events` | `class_support_activity` | Per-agent per-day metrics with resolved `person_id` |
| `support_agents` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `support_tickets` | Reference — ticket context | Enriches `class_support_activity` with `ticket_type`, `priority`, `satisfaction_score` |

**`class_support_activity`** derivation from Zendesk Bronze:

| `class_support_activity` field | Derived from |
|-------------------------------|--------------|
| `person_id` | `support_ticket_events.author_id` → `support_agents.email` → Identity Manager |
| `date` | `support_ticket_events.created_at` (date part) |
| `tickets_resolved` | Count of `status_change` events with `value_to = "solved"` per agent per date |
| `first_response_time_seconds` | Average of `support_tickets.first_reply_time_seconds` for tickets where the agent sent the first `comment` (`is_public = 1`) on this date |
| `full_resolution_time_seconds` | Average of `support_tickets.full_resolution_time_seconds` for tickets resolved by agent on this date |
| `satisfaction_score` | Average CSAT fraction (`good` / total rated) for tickets resolved by agent on this date |
| `comments_sent` | Count of `comment` events with `is_public = 1` by agent on this date |

**Gold metrics**:
- **MTTR**: average `full_resolution_time_seconds` per agent / group / period
- **First-response SLA compliance**: fraction of tickets where `first_reply_time_seconds` ≤ SLA threshold
- **Full-resolution SLA compliance**: fraction of tickets where `full_resolution_time_seconds` ≤ SLA threshold
- **Agent workload**: `tickets_resolved` + `comments_sent` per agent per week
- **CSAT trend**: average `satisfaction_score` per agent and team over rolling 30 days
- **Ticket volume trends**: inflow (new tickets created), resolution rate, backlog (open tickets without `solved_at`)

---

## Open Questions

### OQ-ZD-1: Incremental audit collection strategy

Fetching audits requires one API call per ticket (`GET /api/v2/tickets/{id}/audits`). For large accounts with millions of tickets, fetching all audits on the first run is expensive. Zendesk does not provide a bulk audit export endpoint.

**Question**: Should the initial collection only fetch audits for tickets updated within the lookback window (e.g. last 90 days), and accept that older tickets have no event history in Bronze? Or should the connector offer a configurable full-history backfill mode (rate-limited, resumable)?

**Current approach**: Collect audits for all tickets returned by the incremental export cursor. On first run, the lookback window is configurable (default: 90 days).

### OQ-ZD-2: `satisfaction_score` backfill frequency

Satisfaction ratings arrive asynchronously — a requester may rate a ticket days after it was resolved. The current design fetches all ratings via `GET /api/v2/satisfaction_ratings` on each run and backfills `support_tickets.satisfaction_score`.

**Question**: Should ratings be stored in a separate `support_satisfaction_ratings` Bronze table (preserving the full rating history including score changes) rather than overwriting `support_tickets.satisfaction_score` on each run?

### OQ-ZD-3: Business-hours vs. calendar-hours timing

`metric_set.reply_time_in_minutes.business` reflects time within configured business hours only. `metric_set.reply_time_in_minutes.calendar` is wall-clock time. SLA thresholds are typically defined in business hours, but cross-source comparison (e.g. Zendesk vs. JSM) requires a consistent baseline.

**Question**: Should both business-hours and calendar-hours variants be stored in Bronze (as separate fields), or only the business-hours value with the calendar variant available in `metadata`?
