# Zoom Connector Specification

> Version 2.0 — March 2026
> Based on: [`docs/components/connectors/collaboration/zoom/specs/PRD.md`](./specs/PRD.md), [`docs/components/connectors/collaboration/zoom/specs/DESIGN.md`](./specs/DESIGN.md), Collaboration domain unified schema (`docs/connectors/collaboration/README.md`)

Standalone specification for the Zoom (Collaboration) connector. This document aligns to the current Zoom connector PRD and DESIGN: the connector is meeting-first, preserves per-meeting and per-participant evidence as the authoritative synchronous activity model, treats message activity as mandatory through a separate user-scoped async flow, and uses Zoom users only for identity and attribution support.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`zoom_meetings` — Meeting instances](#zoommeetings--meeting-instances)
  - [`zoom_meeting_participants` — Participant attendance evidence](#zoommeetingparticipants--participant-attendance-evidence)
  - [`zoom_message_activity` — Message activity](#zoommessageactivity--message-activity)
  - [`zoom_users` — User directory support](#zoomusers--user-directory-support)
  - [`zoom_collection_runs` — Connector execution log](#zoomcollectionruns--connector-execution-log)
- [Source Mapping to Unified Bronze](#source-mapping-to-unified-bronze)
- [Non-Mapped Unified Tables](#non-mapped-unified-tables)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver--gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-ZOOM-1: Message activity endpoint stability](#oq-zoom-1-message-activity-endpoint-stability)
  - [OQ-ZOOM-2: Meeting identity consistency across endpoints](#oq-zoom-2-meeting-identity-consistency-across-endpoints)
  - [OQ-ZOOM-3: `meetings_organized` gap](#oq-zoom-3-meetingsorganized-gap)
  - [OQ-ZOOM-4: Webinar vs. meeting distinction](#oq-zoom-4-webinar-vs-meeting-distinction)

<!-- /toc -->

---

## Overview

**API**: Zoom REST APIs for meeting discovery, meeting detail, participant attendance, user directory support, and message activity where available.

**Category**: Collaboration

**Identity**: `zoom_user_id` and `email` from `GET /users` and embedded meeting or message payloads — resolved to canonical `person_id` via Identity Manager.

**Authentication**: OAuth 2.0 — Server-to-Server OAuth app using `account_id`, `client_id`, and `client_secret`. JWT is deprecated as of 2023 and must not be used for new integrations.

**Required OAuth scopes**: must cover `GET /users`, `GET /metrics/meetings`, `GET /metrics/meetings/{meeting_uuid}/participants`, and `GET /chat/users/{zoom_user_id}/messages` for the connector's implemented collection paths.

**Field naming**: snake_case — Zoom API returns mixed naming styles; fields are normalised to snake_case at Bronze level.

**Why multiple tables**: Zoom exposes distinct synchronous and asynchronous activity shapes. `zoom_meetings` stores authoritative meeting instances, `zoom_meeting_participants` stores participant-level attendance evidence needed for duration metrics, `zoom_message_activity` stores mandatory async activity using the implemented separate user-scoped path, `zoom_users` provides lightweight attribution support, and `zoom_collection_runs` records observability state.

**Manifest stream names**: The declarative source manifest uses concise stream names `users`, `meetings`, `participants`, and `message_activities`. These are source-stream identifiers only; Bronze tables remain `zoom_*`.

> **Collection policy**
> Ongoing incremental collection is mandatory. Every newly discovered meeting must trigger meeting-scoped enrichment for detail and participants. Historical backfill is best-effort. Message activity is mandatory and is collected through a separate user-scoped message flow, not through meeting enrichment.

---

## Bronze Tables

### `zoom_meetings` — Meeting instances

Authoritative meeting-scoped Bronze table. Collected from the configured Zoom meeting discovery and detail flows. This table is the source of truth for which meetings happened.

| Field | Type | Description |
|-------|------|-------------|
| `meeting_instance_key` | String | Canonical non-null Bronze identity for the concrete meeting instance |
| `meeting_series_id` | String | Source-native logical meeting or series identifier |
| `meeting_occurrence_id` | String | Source occurrence identifier for a concrete recurring instance when available |
| `meeting_uuid` | String | Source UUID for a concrete realized meeting instance when available |
| `identity_strength` | String | `uuid`, `occurrence`, or `fallback` depending on normalization quality |
| `host_user_id` | String | Zoom host user identifier when provided |
| `topic` | String | Meeting title or topic |
| `meeting_type` | String | Source-provided meeting classification |
| `scheduled_start_at` | DateTime | Scheduled start time when provided |
| `actual_start_at` | DateTime | Actual start time when provided |
| `actual_end_at` | DateTime | Actual end time when provided |
| `duration_seconds` | Int | Meeting duration in seconds when derivable from source evidence |
| `discovered_at` | DateTime | Timestamp when the connector first discovered the meeting |
| `enrichment_status` | String | `pending`, `in_progress`, `complete`, `limited` |
| `limitation_code` | String | Explicit source-side limitation when not fully enriched |
| `source_endpoint` | String | Endpoint or source flow that produced the record |
| `run_id` | String | Collection run identifier |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (monotonic replay marker) |
| `metadata` | String (JSON) | Full API response |

**Indexes**:
- `idx_zoom_meetings_instance`: `(meeting_instance_key)`
- `idx_zoom_meetings_series`: `(meeting_series_id)`
- `idx_zoom_meetings_start`: `(actual_start_at)`

**Identity note**: `meeting_instance_key` is normalized from the strongest available source identifier:
1. `meeting_uuid` when available
2. `meeting_series_id + meeting_occurrence_id` when occurrence identity is available
3. deterministic fallback from `meeting_series_id` plus strongest available source timestamp when stronger identifiers are unavailable

The fallback path is explicitly weaker and is surfaced through `identity_strength = "fallback"`.

---

### `zoom_meeting_participants` — Participant attendance evidence

Participant-level attendance table collected from the per-meeting participant flow. This table is required because participant duration is a hard `p1` requirement in the current PRD.

| Field | Type | Description |
|-------|------|-------------|
| `meeting_instance_key` | String | Canonical parent meeting instance identity |
| `participant_key` | String | Stable participant key from user ID, email, or source participant ID |
| `zoom_user_id` | String | Zoom internal user ID when known |
| `email` | String | Participant email when known |
| `display_name` | String | Participant display name |
| `join_at` | DateTime | Join timestamp |
| `leave_at` | DateTime | Leave timestamp |
| `attendance_duration_seconds` | Int | Participant duration derived from source attendance evidence |
| `attendance_status` | String | `present`, `partial`, `unknown` |
| `run_id` | String | Collection run identifier |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (monotonic replay marker) |
| `metadata` | String (JSON) | Full API response |

**Indexes**:
- `idx_zoom_meeting_participants_meeting`: `(meeting_instance_key)`
- `idx_zoom_meeting_participants_user`: `(zoom_user_id, email)`

**Note**: participant rows always link to `zoom_meetings` through `meeting_instance_key`. Duration is derived only from explicit source attendance evidence and is never inferred from user-day summary rows.

---

### `zoom_message_activity` — Message activity

Async activity table collected from the implemented separate user-scoped Zoom message path. Message content is never stored.

| Field | Type | Description |
|-------|------|-------------|
| `message_activity_id` | String | Stable unique identifier from source event ID or a deterministic derived source key |
| `zoom_user_id` | String | Zoom internal user ID when known |
| `email` | String | User email when known |
| `activity_date` | DateTime | Activity timestamp or aggregation date |
| `channel_type` | String | Source-supported message surface classification |
| `message_count` | Int | Count represented by this row |
| `aggregation_level` | String | Source-supported message grain from the implemented message flow |
| `collection_mode` | String | Always `separate_chat_flow` in the current implementation |
| `linked_meeting_instance_key` | String | Nullable canonical meeting link only when provided reliably by source |
| `linked_meeting_series_id` | String | Nullable source meeting series identifier preserved for traceability |
| `linked_meeting_occurrence_id` | String | Nullable source meeting occurrence identifier preserved for traceability |
| `linked_meeting_uuid` | String | Nullable source meeting UUID preserved for traceability |
| `source_endpoint` | String | Endpoint or source flow used to collect this row |
| `run_id` | String | Collection run identifier |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (monotonic replay marker) |
| `metadata` | String (JSON) | Full API response without message content |

**Indexes**:
- `idx_zoom_message_activity_user`: `(zoom_user_id, email, activity_date)`
- `idx_zoom_message_activity_meeting`: `(linked_meeting_instance_key)`

**Linkage note**: message activity is mandatory, but it is not forced into per-meeting enrichment. `linked_meeting_instance_key` is nullable and is populated only when Zoom exposes reliable meeting-level linkage.

---

### `zoom_users` — User directory support

User support table collected from `GET /users`. This table is used for attribution and identity resolution only; it is not a source-of-truth workforce directory.

| Field | Type | Description |
|-------|------|-------------|
| `zoom_user_id` | String | Zoom internal user ID — source-native identifier |
| `email` | String | User email — primary identity key → `person_id` when available |
| `first_name` | String | First name |
| `last_name` | String | Last name |
| `display_name` | String | Display name |
| `type` | Int | Account type: `1` = Basic, `2` = Licensed, `3` = On-prem |
| `status` | String | Account status: `active` / `inactive` / `pending` |
| `timezone` | String | User timezone setting |
| `collected_at` | DateTime | Collection timestamp |
| `run_id` | String | Collection run identifier |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (monotonic replay marker) |
| `metadata` | String (JSON) | Full API response |

**Indexes**:
- `idx_zoom_users_email`: `(email)`
- `idx_zoom_users_id`: `(zoom_user_id)`

---

### `zoom_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier (UUID) |
| `started_at` | DateTime | Run start timestamp |
| `completed_at` | DateTime | Run end timestamp |
| `status` | String | `running`, `completed`, `completed_with_limitations`, `failed` |
| `run_type` | String | `scheduled_incremental`, `replay`, `backfill`, `manual_repair` |
| `discovery_window_start` | DateTime | Meeting discovery window start |
| `discovery_window_end` | DateTime | Meeting discovery window end |
| `message_window_start` | DateTime | Message collection window start |
| `message_window_end` | DateTime | Message collection window end |
| `meetings_discovered` | Int | Newly discovered meetings |
| `meetings_enriched` | Int | Meetings completed in this run |
| `meetings_limited` | Int | Meetings limited by source capability |
| `participants_collected` | Int | Rows written to `zoom_meeting_participants` |
| `messages_collected` | Int | Rows written to `zoom_message_activity` |
| `users_collected` | Int | Rows written to `zoom_users` |
| `retries_triggered` | Int | Retried enrichment or message work |
| `api_calls` | Int | Total API calls made |
| `errors` | Int | Errors encountered |
| `limitation_summary` | String (JSON) | Aggregated source limitations and endpoint gaps |
| `settings` | String (JSON) | Effective collection configuration |
| `data_source` | String | Always `insight_zoom` |
| `_version` | Int | Deduplication version (monotonic replay marker) |

Monitoring table — not an analytics source.

---

## Source Mapping to Unified Bronze

Zoom data maps into the shared collaboration Bronze schema defined in `docs/connectors/collaboration/README.md`. The `data_source` discriminator is `insight_zoom`.

| Unified table | Zoom source table | Key mapping notes |
|---------------|------------------|-------------------|
| `collab_users` | `zoom_users` | `zoom_user_id` → `user_id`; `email` → `email`; `display_name` → `display_name`; `status` → `is_active` (1 if `active`, 0 otherwise) |
| `collab_meeting_activity` | Derived from `zoom_meetings` + `zoom_meeting_participants` | Meeting counts and participation duration are derived from meeting-first evidence instead of `/report/users` daily summaries |
| `collab_chat_activity` | `zoom_message_activity` | User-attributed Zoom async message activity; linkage to meetings remains optional and nullable |

**`collab_meeting_activity` field mapping**:

| Unified field | Zoom source | Notes |
|---------------|-------------|-------|
| `source_instance_id` | configured at collection | Connector instance, e.g. `zoom-acme` |
| `user_id` | `zoom_user_id` from `zoom_meeting_participants` | Source-native participant identity |
| `email` | `email` from `zoom_meeting_participants` or `zoom_users` | Identity key |
| `date` | `actual_start_at` from `zoom_meetings` | Normalized to reporting date downstream |
| `meetings_attended` | count distinct `meeting_instance_key` per user-date | Derived from participant evidence |
| `audio_duration_seconds` | `attendance_duration_seconds` | Participant-level synchronous duration |
| `meetings_organized` | derived only when organizer semantics are explicitly supported | Otherwise NULL |
| `calls_count` | NULL | Zoom scope treats calls as meetings and does not force a separate call semantic |
| `adhoc_meetings_organized` | NULL unless source semantics support derivation | Source-faithful null by default |
| `adhoc_meetings_attended` | NULL unless source semantics support derivation | Source-faithful null by default |
| `scheduled_meetings_organized` | NULL unless source semantics support derivation | Source-faithful null by default |
| `scheduled_meetings_attended` | NULL unless source semantics support derivation | Source-faithful null by default |
| `video_duration_seconds` | NULL unless source semantics support derivation | Not assumed by default |
| `screen_share_duration_seconds` | NULL unless source semantics support derivation | Not assumed by default |
| `report_period` | NULL | The connector uses explicit windows and meeting evidence, not pre-labelled report periods |

**`collab_chat_activity` field mapping**:

| Unified field | Zoom source | Notes |
|---------------|-------------|-------|
| `source_instance_id` | configured at collection | Connector instance |
| `user_id` | `zoom_user_id` from `zoom_message_activity` | Source-native user identity |
| `email` | `email` from `zoom_message_activity` or `zoom_users` | Identity key |
| `date` | `activity_date` | Message event or aggregation date |
| `total_chat_messages` | `message_count` | Derived directly from message activity row |
| `channel_type` | `channel_type` | Source-supported message surface classification |
| `linked_meeting_id` | `linked_meeting_instance_key` | Nullable and present only when source-supported |

---

## Non-Mapped Unified Tables

The following unified Bronze tables are **not populated** by the Zoom connector:

| Unified table | Reason |
|---------------|--------|
| `collab_email_activity` | Zoom has no email product. |
| `collab_document_activity` | Zoom has no document storage equivalent in the current connector scope. |

---

## Identity Resolution

**Identity anchors**:
- `zoom_user_id` for Zoom-local attribution
- `email` for downstream cross-source identity resolution when present

**Resolution process**:
1. Collect `zoom_users` to preserve stable source-native user identifiers and normalized emails.
2. Join `zoom_meeting_participants` and `zoom_message_activity` to `zoom_users` when source payloads omit one of the identity fields.
3. Normalize `email` (lowercase, trim).
4. Map to canonical `person_id` via Identity Manager in Silver step 2.
5. Propagate `person_id` to downstream meeting and message metrics.

**Cross-platform note**: Employees commonly have meeting and chat activity in Zoom, Microsoft Teams, Slack, and other collaboration sources simultaneously. Because all these sources ultimately resolve to `person_id`, downstream Silver and Gold layers can compare synchronous and asynchronous collaboration across systems.

**Meeting identity note**: `meeting_instance_key` is a Zoom-specific Bronze identity used for meeting persistence and linkage. It is not a cross-system identity key.

---

## Silver / Gold Mappings

| Bronze table | Unified Bronze table | Silver target | Status |
|-------------|---------------------|--------------|--------|
| `zoom_users` | `collab_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `zoom_meetings` + `zoom_meeting_participants` | `collab_meeting_activity` | `class_communication_metrics` | ✓ Mapped — meetings channel via meeting-first derivation |
| `zoom_message_activity` | `collab_chat_activity` | `class_communication_metrics` | ✓ Mapped — chat channel |

**`class_communication_metrics`** — existing Silver stream. Zoom adds the `insight_zoom` source:

| `data_source` | `channel` | Bronze table | Bronze field |
|---------------|-----------|--------------|--------------|
| `insight_zoom` | `meetings` | `collab_meeting_activity` | `meetings_attended` |
| `insight_zoom` | `chat` | `collab_chat_activity` | `total_chat_messages` |

**Gold metrics** produced by including Zoom in `class_communication_metrics`:
- **Meeting load per person**: total meetings attended per week from participant-backed meeting evidence
- **Meeting time burden**: `audio_duration_seconds` aggregated per person per week from participant duration
- **Async vs. sync ratio**: meeting hours vs. Zoom message counts per person
- **Participation quality**: late-join or short-attendance patterns when downstream analytics choose to use participant-level evidence

---

## Open Questions

### OQ-ZOOM-1: Message activity endpoint stability

The current implementation uses a separate user-scoped message endpoint rather than switching among multiple message collection strategies.

**Question**: Are there tenant or plan-specific edge cases in the implemented message endpoint that require tighter handling for pagination, retention, or missing user coverage?

### OQ-ZOOM-2: Meeting identity consistency across endpoints

The DESIGN normalizes `meeting_series_id`, `meeting_occurrence_id`, and `meeting_uuid` into canonical `meeting_instance_key`. Different Zoom endpoints may expose different combinations of these identifiers for the same real-world meeting.

**Question**: Are there endpoint-specific edge cases where additional normalization rules are required to prevent split identity for recurring or restarted meetings?

### OQ-ZOOM-3: `meetings_organized` gap

The meeting-first design preserves host and organizer context when Zoom exposes it, but some collection paths may still be insufficient to derive trustworthy `meetings_organized` metrics.

**Impact**: cross-source comparison of meetings organized vs. attended may remain incomplete for `insight_zoom` until organizer semantics are validated across the chosen endpoints.

### OQ-ZOOM-4: Webinar vs. meeting distinction

Zoom separates meetings from webinars. The current PRD keeps webinars out of scope.

**Question**: When webinar support is added later, should it reuse parts of the `zoom_meetings` identity model or land as a separate Bronze entity family?
