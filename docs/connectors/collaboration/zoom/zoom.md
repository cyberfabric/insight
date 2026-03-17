# Zoom Connector Specification

> Version 1.0 — March 2026
> Based on: Collaboration domain unified schema (`docs/connectors/collaboration/README.md`)

Standalone specification for the Zoom (Collaboration) connector. Collects meeting activity data via the Zoom Reports API and maps it to the unified collaboration Bronze schema. Zoom is often deployed alongside Microsoft Teams and Slack — the same person may accumulate meeting minutes across all three platforms, so cross-source deduplication in Silver is essential.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`zoom_users` — User directory](#zoomusers-user-directory)
  - [`zoom_meeting_activity` — Meeting activity per user per date range](#zoommeetingactivity-meeting-activity-per-user-per-date-range)
  - [`zoom_collection_runs` — Connector execution log](#zoomcollectionruns-connector-execution-log)
- [Source Mapping to Unified Bronze](#source-mapping-to-unified-bronze)
- [Non-Mapped Unified Tables](#non-mapped-unified-tables)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-ZOOM-1: Per-meeting participant detail vs. daily summary](#oq-zoom-1-per-meeting-participant-detail-vs-daily-summary)
  - [OQ-ZOOM-2: `meetings_organized` gap](#oq-zoom-2-meetingsorganized-gap)
  - [OQ-ZOOM-3: Zoom Chat activity scope](#oq-zoom-3-zoom-chat-activity-scope)
  - [OQ-ZOOM-4: Webinar vs. meeting distinction](#oq-zoom-4-webinar-vs-meeting-distinction)

<!-- /toc -->

---

## Overview

**API**: Zoom Reports API v2 — `https://api.zoom.us/v2/`

**Category**: Collaboration

**Identity**: `email` from `GET /users` — resolved to canonical `person_id` via Identity Manager.

**Authentication**: OAuth 2.0 — Server-to-Server OAuth app (recommended). JWT is deprecated as of 2023 and must not be used for new integrations.

**Required OAuth scopes**: `report:read:admin`, `user:read:admin`, `meeting:read:admin`

**Field naming**: snake_case — Zoom API returns camelCase; fields are normalised to snake_case at Bronze level.

**Why three tables**: The Zoom Reports API separates user-level activity summaries (`/report/users`) from per-meeting participant data (`/report/meetings/{meetingId}/participants`). The user directory (`/users`) is a separate endpoint. Each data shape is stored in its own Bronze table. The collection run log is a fourth monitoring-only table.

> **Data Retention Window**
> Zoom Reports API returns data within a configurable `from`/`to` date range. Historical data is available for at least 12 months. Unlike M365, there is no hard 7-day expiry — however the collector should still run regularly (daily recommended) to maintain day-level granularity.

---

## Bronze Tables

### `zoom_users` — User directory

User accounts in the Zoom account. Collected from `GET /users`.

| Field | Type | Description |
|-------|------|-------------|
| `zoom_user_id` | String | Zoom internal user ID — source-native identifier |
| `email` | String | User email — primary identity key → `person_id` |
| `first_name` | String | First name |
| `last_name` | String | Last name |
| `display_name` | String | Display name (concatenated or provided by API) |
| `type` | Int | Account type: `1` = Basic, `2` = Licensed, `3` = On-prem |
| `status` | String | Account status: `active` / `inactive` / `pending` |
| `dept` | String | Department (if configured) |
| `timezone` | String | User's timezone setting |
| `last_login_time` | DateTime | Last login timestamp |
| `collected_at` | DateTime | Collection timestamp |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (millisecond timestamp) |
| `metadata` | String (JSON) | Full API response |

**Indexes**:
- `idx_zoom_users_email`: `(email)`
- `idx_zoom_users_id`: `(zoom_user_id)`

---

### `zoom_meeting_activity` — Meeting activity per user per date range

Daily aggregated meeting activity per user. Collected from `GET /report/users?from=&to=`. Each row covers one user for one reporting date as returned by the Zoom Reports API.

| Field | Type | Description |
|-------|------|-------------|
| `zoom_user_id` | String | Zoom internal user ID |
| `email` | String | User email — identity key |
| `date` | DateTime | Report date (from `date` field in Zoom Reports API response) |
| `meetings_count` | Int | Total meetings the user attended |
| `participants_count` | Int | Total participants across all meetings hosted by this user |
| `meeting_minutes` | Int | Total meeting minutes (sum across all attended meetings) |
| `collected_at` | DateTime | Collection timestamp |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (millisecond timestamp) |
| `metadata` | String (JSON) | Full API response row |

**Indexes**:
- `idx_zoom_meeting_user`: `(email, date)`
- `idx_zoom_meeting_date`: `(date)`

**Note**: `GET /report/users` returns a summary per user per day within the requested `from`/`to` window. One collection run covers a date range (typically 1–7 days back); rows are deduplicated by `(email, date)` using `_version`.

---

### `zoom_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier (UUID) |
| `started_at` | DateTime | Run start timestamp |
| `completed_at` | DateTime | Run end timestamp |
| `status` | String | `running` / `completed` / `failed` |
| `from_date` | DateTime | Start of the reporting window collected |
| `to_date` | DateTime | End of the reporting window collected |
| `users_collected` | Int | Rows collected for `zoom_users` |
| `meeting_activity_collected` | Int | Rows collected for `zoom_meeting_activity` |
| `api_calls` | Int | Total API calls made |
| `errors` | Int | Errors encountered |
| `settings` | String (JSON) | Collection configuration (date range, scopes, account ID) |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (millisecond timestamp) |

Monitoring table — not an analytics source.

---

## Source Mapping to Unified Bronze

Zoom data maps into the shared collaboration Bronze schema defined in `docs/connectors/collaboration/README.md`. The `data_source` discriminator is `insight_zoom`.

| Unified table | Zoom source table | Key mapping notes |
|---------------|------------------|-------------------|
| `collab_users` | `zoom_users` | `zoom_user_id` → `user_id`; `email` → `email`; `display_name` → `display_name`; `status` → `is_active` (1 if `active`, 0 otherwise) |
| `collab_meeting_activity` | `zoom_meeting_activity` | `zoom_user_id` → `user_id`; `email` → `email`; `meetings_count` → `meetings_attended`; `meeting_minutes * 60` → `audio_duration_seconds`; `date` → `date` |

**`collab_meeting_activity` field mapping**:

| Unified field | Zoom source | Notes |
|---------------|-------------|-------|
| `source_instance_id` | configured at collection | Connector instance, e.g. `zoom-acme` |
| `user_id` | `zoom_user_id` | Source-native ID |
| `email` | `email` | Identity key |
| `date` | `date` | Report date |
| `meetings_attended` | `meetings_count` | Total meetings attended |
| `audio_duration_seconds` | `meeting_minutes × 60` | Converted from minutes to seconds |
| `meetings_organized` | NULL | Not available in `/report/users` endpoint |
| `calls_count` | NULL | Zoom does not distinguish calls from meetings in report summary |
| `adhoc_meetings_organized` | NULL | Not available |
| `adhoc_meetings_attended` | NULL | Not available |
| `scheduled_meetings_organized` | NULL | Not available |
| `scheduled_meetings_attended` | NULL | Not available |
| `video_duration_seconds` | NULL | Not available in `/report/users` |
| `screen_share_duration_seconds` | NULL | Not available in `/report/users` |
| `report_period` | NULL | Zoom uses explicit `from`/`to`; no period label |

---

## Non-Mapped Unified Tables

The following unified Bronze tables are **not populated** by the Zoom connector:

| Unified table | Reason |
|---------------|--------|
| `collab_chat_activity` | Zoom Chat is a separate product; the Zoom Reports API (`/report/users`) does not include chat message counts. If Zoom Chat collection is added in future, it would require a dedicated endpoint. |
| `collab_email_activity` | Zoom has no email product. |
| `collab_document_activity` | Zoom has no document storage equivalent. |

---

## Identity Resolution

**Identity anchor**: `email` from `zoom_users` and embedded in `zoom_meeting_activity`.

**Resolution process**:
1. Extract `email` from `zoom_users` (confirmed via `GET /users`)
2. Normalise (lowercase, trim)
3. Map to canonical `person_id` via Identity Manager in Silver step 2
4. Propagate `person_id` to all Silver activity rows

**Cross-platform note**: Employees commonly have meeting activity in Zoom, Microsoft Teams, and Slack simultaneously. Because all three sources use `email` as the identity key and map to the same `collab_meeting_activity` table with `data_source` discriminators, Silver step 2 can aggregate total meeting load across all platforms per `person_id` without joins.

**`zoom_user_id`** is the source-native key for Zoom-internal lookups only; it is not used for cross-system identity resolution.

---

## Silver / Gold Mappings

| Bronze table | Unified Bronze table | Silver target | Status |
|-------------|---------------------|--------------|--------|
| `zoom_users` | `collab_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `zoom_meeting_activity` | `collab_meeting_activity` | `class_communication_metrics` | ✓ Mapped — meetings channel |

**`class_communication_metrics`** — existing Silver stream. Zoom adds the `insight_zoom` source:

| `data_source` | `channel` | Bronze table | Bronze field |
|---------------|-----------|--------------|--------------|
| `insight_zoom` | `meetings` | `collab_meeting_activity` | `meetings_attended` |

**Gold metrics** produced by including Zoom in `class_communication_metrics`:
- **Meeting load per person**: total meetings attended per week, combining Zoom + Teams (+ Slack huddles when added)
- **Meeting time burden**: `audio_duration_seconds` aggregated per person per week — cross-source time-in-meetings
- **Async vs. sync ratio**: meeting hours (Zoom + Teams) vs. chat messages (Teams/Slack/Zulip) per person

---

## Open Questions

### OQ-ZOOM-1: Per-meeting participant detail vs. daily summary

`GET /report/users` provides a daily summary per user. `GET /report/meetings/{meetingId}/participants` provides per-meeting participant records including join/leave timestamps, enabling exact duration per participant per meeting.

**Question**: Should the connector collect per-meeting participant detail in addition to the daily summary? The daily summary is sufficient for `collab_meeting_activity`. Per-meeting detail would enable richer analytics (e.g. actual participation duration, late joins, early leaves) but increases volume significantly in large organisations.

**Current approach**: collect daily summary only (`zoom_meeting_activity`). Define a separate Bronze table `zoom_meeting_participants` if per-meeting detail is needed.

### OQ-ZOOM-2: `meetings_organized` gap

The `/report/users` endpoint does not distinguish meetings the user organised from meetings they only attended — both are counted in `meetings_count`. `collab_meeting_activity.meetings_organized` will be NULL for all Zoom rows.

**Impact**: cross-source comparison of meetings organised vs. attended is incomplete — Teams data has both fields, Zoom only has attended count. Gold queries that rely on `meetings_organized` must handle NULL for `insight_zoom`.

### OQ-ZOOM-3: Zoom Chat activity scope

Zoom Chat (team messaging) is not included in this spec. If the product team decides to track Zoom Chat alongside Teams and Slack messages, a new endpoint (`/report/chat`) and a separate Bronze table `zoom_chat_activity` would be required, feeding `collab_chat_activity` with `data_source = "insight_zoom"`.

### OQ-ZOOM-4: Webinar vs. meeting distinction

Zoom separates meetings (`/report/meetings`) from webinars (`/report/webinars`). The current spec maps only meetings to `collab_meeting_activity`. Webinars have a different participation model (host + panellists + attendees) and are typically not internal collaboration signals.

**Question**: Should webinar attendance be included in `meetings_attended` or excluded from collaboration analytics? Recommend excluding by default unless a specific use case is confirmed.
