# Slack Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/connectors/collaboration/README.md` unified schema, OQ-COLLAB-4

Standalone specification for the Slack (Chat) connector. Maps Slack API data to the unified Bronze collaboration schema (`collab_*` tables) defined in [`README.md`](README.md).

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`collab_chat_activity` — Chat messages per user per date (Slack mapping)](#collabchatactivity-chat-messages-per-user-per-date-slack-mapping)
  - [`collab_meeting_activity` — Huddles per user per date (Slack mapping)](#collabmeetingactivity-huddles-per-user-per-date-slack-mapping)
  - [`collab_users` — User directory (Slack mapping)](#collabusers-user-directory-slack-mapping)
  - [`slack_collection_runs` — Connector execution log](#slackcollectionruns-connector-execution-log)
- [API Reference](#api-reference)
  - [Standard Workspaces](#standard-workspaces)
  - [Enterprise Grid](#enterprise-grid)
- [Source Mapping](#source-mapping)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-SLACK-1: Enterprise Grid analytics granularity vs. standard workspace events](#oq-slack-1-enterprise-grid-analytics-granularity-vs-standard-workspace-events)
  - [OQ-SLACK-2: Huddle duration availability per user](#oq-slack-2-huddle-duration-availability-per-user)
  - [OQ-SLACK-3: Message type distinction at aggregation level](#oq-slack-3-message-type-distinction-at-aggregation-level)

<!-- /toc -->

---

## Overview

**API**: Slack Web API — `https://slack.com/api/`

**Category**: Chat

**data_source**: `insight_slack`

**Authentication**: OAuth 2.0, Bot Token (`xoxb-*`)

**Required OAuth scopes**:
- `channels:history` — read public channel messages
- `channels:read` — list public channels
- `groups:history` — read private channel messages
- `im:history` — read direct messages
- `mpim:history` — read group DMs
- `users:read` — list workspace users
- `users:read.email` — read user email addresses (required for identity resolution)

**Identity**: `email` from `users.list` — resolved to canonical `person_id` via Identity Manager.

**Channel types**: `im` (1:1 DM), `mpim` (group DM), `public_channel`, `private_channel`.

**Huddles**: Slack's in-channel audio/video meetings. Treated as meetings in `collab_meeting_activity`.

**No email equivalent**: Slack has no internal email product. `collab_email_activity` is not populated for `insight_slack`.

**No document equivalent**: Slack file sharing is not modelled as document activity. `collab_document_activity` is not populated for `insight_slack`.

**Enterprise Grid note**: Large Slack deployments may use Enterprise Grid, which exposes an additional analytics endpoint (`admin.analytics.getFile`) that returns pre-aggregated workspace-level metrics per user per day. For Enterprise Grid workspaces, the connector uses this endpoint as the primary source; for standard workspaces, metrics are derived by aggregating `conversations.history` per user.

**Why two entity tables**: `collab_chat_activity` covers all async messaging (DMs, group DMs, channel messages). `collab_meeting_activity` covers synchronous huddles. Merging would confuse async and sync signals, which have distinct analytics interpretations.

---

## Bronze Tables

> All Slack data is inserted into the shared `collab_*` tables with `data_source = 'insight_slack'`. The schema is defined in [`README.md`](README.md). This section documents which fields are populated and how Slack API values map to unified fields.

### `collab_chat_activity` — Chat messages per user per date (Slack mapping)

Daily aggregated message counts per Slack user. Populated from `conversations.history` (standard) or `admin.analytics.getFile` (Enterprise Grid).

| Field | Type | Slack value | Notes |
|-------|------|-------------|-------|
| `insight_source_id` | String | connector config | e.g. `slack-acme` |
| `user_id` | String | `messages[].user` | Slack user ID (e.g. `U0123ABC`) |
| `email` | String | `users.list[].profile.email` | Joined via `users.list`; primary identity key |
| `date` | Date | `messages[].ts` (date part) | Bucketed to calendar day UTC |
| `direct_messages` | Int64 | count of `im` channel messages | NULL if Enterprise Grid (not disaggregated) |
| `group_chat_messages` | Int64 | count of `mpim` channel messages | NULL if Enterprise Grid |
| `total_chat_messages` | Int64 | total messages across all channel types | REQUIRED; non-null |
| `channel_posts` | Int64 | count of `public_channel` + `private_channel` messages | NULL if Enterprise Grid |
| `channel_replies` | Int64 | count of threaded replies in channels | NULL if Enterprise Grid |
| `urgent_messages` | Int64 | NULL | Slack has no urgent priority equivalent |
| `report_period` | String | NULL | Not applicable for Slack |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_slack` | |
| `_version` | UInt64 | ms timestamp | |

**Aggregation strategy**:
- **Standard workspace**: collector reads `conversations.list` to get all channels, then `conversations.history` per channel with a date filter, groups messages by `(user, date, channel_type)`.
- **Enterprise Grid**: collector calls `admin.analytics.getFile` with `type=member` and `date={date}` — returns one row per user per day with `messages_posted` total. Only `total_chat_messages` is populated; per-channel-type breakdown is not available from this endpoint.

---

### `collab_meeting_activity` — Huddles per user per date (Slack mapping)

Daily aggregated huddle participation per user. Slack huddles are audio/video sessions initiated within a channel or DM.

| Field | Type | Slack value | Notes |
|-------|------|-------------|-------|
| `insight_source_id` | String | connector config | |
| `user_id` | String | huddle participant user ID | |
| `email` | String | from `users.list` | |
| `date` | Date | huddle start date (UTC) | |
| `calls_count` | Int64 | NULL | Slack calls API is separate; not in scope |
| `meetings_organized` | Int64 | NULL | Huddle initiator not reliably identifiable |
| `meetings_attended` | Int64 | huddle sessions joined | 1 per huddle attended per day |
| `adhoc_meetings_organized` | Int64 | NULL | Not applicable |
| `adhoc_meetings_attended` | Int64 | same as `meetings_attended` | All huddles are ad-hoc |
| `scheduled_meetings_organized` | Int64 | NULL | Slack has no scheduled huddle concept |
| `scheduled_meetings_attended` | Int64 | NULL | |
| `audio_duration_seconds` | Int64 | huddle audio seconds | If available from API; see OQ-SLACK-2 |
| `video_duration_seconds` | Int64 | NULL | Slack huddle API does not expose per-user video duration |
| `screen_share_duration_seconds` | Int64 | NULL | Not available |
| `report_period` | String | NULL | |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_slack` | |
| `_version` | UInt64 | ms timestamp | |

**Note**: Huddle data requires `conversations.history` on channels where huddles occur. The `subtype = "huddle_thread"` message type marks huddle events. Per-user duration may not be available in all API tiers — see OQ-SLACK-2.

---

### `collab_users` — User directory (Slack mapping)

Populated from `users.list` endpoint.

| Field | Type | Slack field | Notes |
|-------|------|------------|-------|
| `insight_source_id` | String | connector config | |
| `user_id` | String | `users[].id` | Slack user ID (e.g. `U0123ABC`) |
| `email` | String | `users[].profile.email` | Requires `users:read.email` scope |
| `display_name` | String | `users[].profile.display_name` or `real_name` | |
| `is_active` | Int64 | `!users[].deleted` | 1 = active, 0 = deactivated |
| `role` | String | `owner`/`admin`/`member`/`guest` | Derived from `users[].is_owner`, `is_admin`, `is_restricted`, `is_ultra_restricted` |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_slack` | |
| `_version` | UInt64 | ms timestamp | |

**Role mapping**:

| Slack flags | Unified `role` |
|-------------|---------------|
| `is_owner = true` | `owner` |
| `is_admin = true` | `admin` |
| `is_ultra_restricted = true` | `guest` |
| `is_restricted = true` | `guest` |
| default | `member` |

**Bots**: `users[].is_bot = true` rows are excluded from `collab_users` — bot activity does not represent human collaboration.

---

### `slack_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `chat_records_collected` | Int64 | NULLABLE | Rows written to `collab_chat_activity` for `insight_slack` |
| `meeting_records_collected` | Int64 | NULLABLE | Rows written to `collab_meeting_activity` for `insight_slack` |
| `users_collected` | Int64 | NULLABLE | Rows written to `collab_users` for `insight_slack` |
| `channels_scanned` | Int64 | NULLABLE | Number of channels processed |
| `api_calls` | Int64 | NULLABLE | Total Slack API calls made |
| `errors` | Int64 | NULLABLE | Errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (workspace, lookback days, Enterprise Grid flag, enabled scopes) |
| `data_source` | String | DEFAULT 'insight_slack' | Always `insight_slack` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

Monitoring table — not an analytics source.

---

## API Reference

### Standard Workspaces

| Endpoint | Purpose | Rate limit tier |
|----------|---------|-----------------|
| `users.list` | User directory — email, role, active status | Tier 2 (20 req/min) |
| `conversations.list` | Channel directory — type, name, member count | Tier 2 |
| `conversations.history` | Messages per channel — paginated by date | Tier 3 (50 req/min) |
| `conversations.replies` | Threaded replies for a given message | Tier 3 |

**Pagination**: All list endpoints use cursor-based pagination (`next_cursor` in response metadata). The collector must follow cursors until exhausted.

**Lookback**: Default lookback window is configurable (recommended: 7 days for daily runs). `conversations.history` uses `oldest` and `latest` Unix timestamp parameters.

### Enterprise Grid

| Endpoint | Purpose | Notes |
|----------|---------|-------|
| `admin.analytics.getFile` (`type=member`) | Pre-aggregated per-user per-day metrics | Requires Enterprise Grid + admin token |

**Enterprise Grid response fields** (per user per day):
- `user_id` — Slack user ID
- `date_claimed` — activity date
- `messages_posted` — total messages → `total_chat_messages`
- (other fields not mapped to this schema)

When Enterprise Grid mode is detected (configurable or auto-detected via `auth.test`), the connector switches to `admin.analytics.getFile` for chat metrics and skips `conversations.history` to avoid rate limit exhaustion on large workspaces.

---

## Source Mapping

| Unified table | Slack source | Key mapping notes |
|---------------|-------------|-------------------|
| `collab_chat_activity` | `conversations.history` (standard) or `admin.analytics.getFile` (Enterprise Grid) | Message counts grouped by `(user, date, channel_type)`. Enterprise Grid: only `total_chat_messages` available. |
| `collab_meeting_activity` | `conversations.history` with `subtype = "huddle_thread"` | Huddle events parsed from channel history; `meetings_attended` = huddle sessions joined |
| `collab_users` | `users.list` | `profile.email` → `email`; `id` → `user_id`; role derived from boolean flags |
| `collab_email_activity` | — | Not populated — Slack has no email product |
| `collab_document_activity` | — | Not populated — file sharing not modelled as document activity |

**Terminology mapping**:

| Slack concept | Unified field | Notes |
|--------------|--------------|-------|
| Direct message (`im` channel) | `direct_messages` | 1:1 DM messages |
| Group DM (`mpim` channel) | `group_chat_messages` | Multi-party DM messages |
| Channel message (`public_channel` / `private_channel`) | `channel_posts` | Non-threaded channel posts |
| Threaded reply | `channel_replies` | Thread replies in channels |
| Huddle | `collab_meeting_activity` | Audio/video session in channel or DM |
| Workspace | `insight_source_id` | One connector instance per Slack workspace |

---

## Identity Resolution

**Identity anchor**: `email` from `collab_users` (sourced from `users.list` with `users:read.email` scope).

**Resolution process**:
1. Collect `users.list` → populate `collab_users` with `email` for all active users.
2. Join `conversations.history` messages by `user_id` to `collab_users.user_id` to resolve `email`.
3. Normalize email (lowercase, trim).
4. Map to canonical `person_id` via Identity Manager in Silver step 2.
5. Propagate `person_id` to all Silver activity rows.

**Slack `user_id`** (e.g. `U0123ABC`) is a Slack-internal identifier — not used for cross-system identity resolution. `email` takes precedence.

**Bots and apps**: filter out `is_bot = true` users before populating `collab_users` and before aggregating message counts — bot messages do not represent human activity.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `collab_chat_activity` (insight_slack) | `class_communication_metrics` | ✓ Mapped — chat channel |
| `collab_meeting_activity` (insight_slack) | `class_communication_metrics` | ✓ Mapped — meetings channel |
| `collab_users` (insight_slack) | Identity Manager (`email` → `person_id`) | ✓ Used for identity resolution |
| `collab_email_activity` | — | Not applicable — Slack has no email |
| `collab_document_activity` | — | Not applicable — file sharing not modelled |

**`class_communication_metrics`** channel mapping for `insight_slack`:

| `data_source` | `channel` | Bronze table | Bronze field |
|---------------|-----------|--------------|--------------|
| `insight_slack` | `chat` | `collab_chat_activity` | `total_chat_messages` |
| `insight_slack` | `meetings` | `collab_meeting_activity` | `meetings_attended` |

**Gold metrics** (derived from unified `class_communication_metrics` across all sources):
- Communication load: total messages + huddle sessions per person per week
- Async vs. sync ratio: chat messages vs. huddle minutes
- Channel breadth: distinct channel types a person is active in (DM, group DM, channel)

---

## Open Questions

### OQ-SLACK-1: Enterprise Grid analytics granularity vs. standard workspace events

`admin.analytics.getFile` (Enterprise Grid) returns only `messages_posted` total — no breakdown by channel type (DM / group DM / channel). Standard workspace collection via `conversations.history` provides per-channel-type granularity but is expensive at scale.

**Question**: Should the connector always attempt `conversations.history` for per-type breakdown, falling back to `admin.analytics.getFile` totals only when rate limits are hit? Or should Enterprise Grid mode always use the analytics file and sacrifice per-type granularity for reliability?

### OQ-SLACK-2: Huddle duration availability per user

Slack's `conversations.history` marks huddle start/end via `subtype = "huddle_thread"` messages, but per-user audio duration may not be available in all API tiers or subscription levels. The `audio_duration_seconds` field depends on metadata in huddle thread messages.

**Question**: Confirm whether `audio_duration_seconds` is reliably available for huddle events across all Slack subscription tiers (Free, Pro, Business+, Enterprise Grid). If not, mark it NULLABLE with a note that it requires Business+ or higher.

### OQ-SLACK-3: Message type distinction at aggregation level

When using `conversations.history`, threaded replies (`thread_ts != null AND thread_ts != ts`) can be distinguished from top-level posts. However, distinguishing DMs from group DMs from channel messages requires knowing the channel type at the time of collection.

**Question**: Should the connector resolve channel type at collection time (requiring `conversations.list` to be fully cached) or at aggregation time (using the `channel_type` embedded in the Slack event)? Confirm which approach is used in the implementation.
