# Collaboration Connector Specification (Multi-Source)

> Version 1.0 — March 2026
> Based on: Microsoft 365 (Source 6) and Zulip (Source 7)

Data-source agnostic specification for collaboration connectors. Defines unified Bronze schemas that work across M365, Zulip, and Slack using a `data_source` discriminator column.

**Primary analytics focus**: employee collaboration patterns — communication intensity, meeting load, document sharing, and async vs. synchronous work balance.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`collab_chat_activity` — Chat messages per user per date](#collab_chat_activity--chat-messages-per-user-per-date)
  - [`collab_meeting_activity` — Meetings and calls per user per date](#collab_meeting_activity--meetings-and-calls-per-user-per-date)
  - [`collab_email_activity` — Email activity per user per date](#collab_email_activity--email-activity-per-user-per-date)
  - [`collab_document_activity` — Document and file activity per user per date](#collab_document_activity--document-and-file-activity-per-user-per-date)
  - [`collab_users` — User directory](#collab_users--user-directory)
  - [`collab_collection_runs` — Connector execution log](#collab_collection_runs--connector-execution-log)
- [Source Mapping](#source-mapping)
  - [Microsoft 365](#microsoft-365)
  - [Zulip](#zulip)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver--gold-mappings)
- [Open Questions](#open-questions)

<!-- /toc -->

---

## Overview

**Category**: Collaboration

**Supported Sources**:
- Microsoft 365 (`data_source = "insight_m365"`)
- Zulip (`data_source = "insight_zulip"`)
- Slack (`data_source = "insight_slack"`)

**Authentication**:
- M365: OAuth 2.0 (Azure AD application, `Reports.Read.All` scope)
- Zulip: HTTP Basic Auth — bot email + API key per realm
- Slack: OAuth 2.0, Bot Token (`xoxb-*`)

**Data model note**: All data at this layer is **pre-aggregated by day**. M365 Graph API exposes activity reports as daily rollups per user — there are no individual event records. Zulip similarly provides aggregated message counts. This is fundamentally different from event-log connectors (git, task tracking) — Bronze tables here are metric tables, not event tables.

> **Critical: M365 Data Retention Window**
> M365 Graph API returns only the **last 7–30 days** of activity. Data cannot be re-fetched once the window passes — loss is permanent. The collector must run at minimum every 7 days to avoid gaps.

**Why four analytics tables**: M365 Teams combines chat and meeting metrics in one API endpoint, but these are distinct collaboration signals with different analytics uses. The unified schema separates them by domain — chat, meetings, email, documents — so each table has a coherent semantic meaning and Silver targets can be designed independently.

**M365 Copilot**: `ms365_copilot_usage` is not included here. Office Copilot (AI assistance in Word, Excel, Outlook, Teams) is categorised under AI tools alongside Cursor and Windsurf — see [`../ai/`](../ai/).

**Terminology mapping**:

| Concept | M365 | Zulip | Slack | Unified |
|---------|------|-------|-------|---------|
| Chat message | Teams chat (`privateChatMessageCount`, `teamChatMessageCount`) | `zulip_messages.count` | message (`conversations.history`) | `collab_chat_activity` |
| Channel post | Teams channel (`postMessages`, `replyMessages`) | stream message | channel message | `collab_chat_activity` |
| Meeting | Teams meeting (`meetingsAttendedCount`, etc.) | — | huddle | `collab_meeting_activity` |
| Call | Teams call (`callCount`) | — | — | `collab_meeting_activity` |
| Email | Outlook (`sendCount`, `receiveCount`) | — | — | `collab_email_activity` |
| File edit | OneDrive / SharePoint (`viewedOrEditedFileCount`) | — | — | `collab_document_activity` |
| File share | OneDrive / SharePoint (`sharedInternallyFileCount`) | — | — | `collab_document_activity` |

---

## Bronze Tables

### `collab_chat_activity` — Chat messages per user per date

Daily aggregated message counts per user. Covers direct messages, group chats, and channel posts/replies.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier, e.g. `m365-acme`, `zulip-main` |
| `user_id` | String | REQUIRED | Source-specific user identifier (M365 UPN / Zulip numeric ID) |
| `email` | String | REQUIRED | User email — primary identity key → `person_id` |
| `date` | Date | REQUIRED | Activity date (report date for M365, message date for Zulip) |
| `direct_messages` | Int64 | NULLABLE | Messages in 1:1 and group DMs (M365 `privateChatMessageCount`; NULL for Zulip — no DM/channel distinction) |
| `group_chat_messages` | Int64 | NULLABLE | Messages in group chats / team chats (M365 `teamChatMessageCount`; NULL for Zulip) |
| `total_chat_messages` | Int64 | REQUIRED | Total chat messages: DM + group. For Zulip: `zulip_messages.count` |
| `channel_posts` | Int64 | NULLABLE | Posts published to channels / streams (M365 `postMessages`; NULL for Zulip) |
| `channel_replies` | Int64 | NULLABLE | Replies to channel posts (M365 `replyMessages`; NULL for Zulip) |
| `urgent_messages` | Int64 | NULLABLE | Messages sent with urgent priority (M365 Teams only; NULL otherwise) |
| `report_period` | String | NULLABLE | Report window used to generate the metric, e.g. `"7"` (M365 only) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator: `insight_m365` / `insight_zulip` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_collab_chat_user`: `(source_instance_id, email, date)`
- `idx_collab_chat_date`: `(date, data_source)`

**`total_chat_messages` computation**:
- M365: `privateChatMessageCount + teamChatMessageCount`
- Zulip: `zulip_messages.count` directly

**Note**: Zulip does not distinguish DM vs. channel messages at the aggregation level — only `total_chat_messages` is populated. `channel_posts`/`channel_replies` are M365 Teams channel activity (content publishing), not direct messaging — separate signals with different analytics meaning.

---

### `collab_meeting_activity` — Meetings and calls per user per date

Daily aggregated meeting and call participation per user. M365 Teams only at launch; Slack huddles and other sources planned.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `user_id` | String | REQUIRED | Source-specific user identifier |
| `email` | String | REQUIRED | User email — identity key |
| `date` | Date | REQUIRED | Activity date |
| `calls_count` | Int64 | NULLABLE | Calls made (M365 `callCount`) |
| `meetings_organized` | Int64 | NULLABLE | Total meetings organized (M365 `meetingsOrganizedCount`) |
| `meetings_attended` | Int64 | NULLABLE | Total meetings attended (M365 `meetingsAttendedCount`) |
| `adhoc_meetings_organized` | Int64 | NULLABLE | Ad-hoc (unscheduled) meetings organized |
| `adhoc_meetings_attended` | Int64 | NULLABLE | Ad-hoc meetings attended |
| `scheduled_meetings_organized` | Int64 | NULLABLE | Scheduled meetings organized (one-time + recurring) |
| `scheduled_meetings_attended` | Int64 | NULLABLE | Scheduled meetings attended |
| `audio_duration_seconds` | Int64 | NULLABLE | Total audio call time in seconds (M365 `audioDuration` converted) |
| `video_duration_seconds` | Int64 | NULLABLE | Total video time in seconds (M365 `videoDuration` converted) |
| `screen_share_duration_seconds` | Int64 | NULLABLE | Total screen share time in seconds (M365 `screenShareDuration` converted) |
| `report_period` | String | NULLABLE | Report window, e.g. `"7"` (M365 only) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_collab_meeting_user`: `(source_instance_id, email, date)`
- `idx_collab_meeting_date`: `(date, data_source)`

**Duration normalisation**: M365 returns `audioDuration`, `videoDuration`, `screenShareDuration` as ISO 8601 duration strings (e.g. `PT1H30M`) — convert to seconds at collection time.

---

### `collab_email_activity` — Email activity per user per date

Daily aggregated email activity per user. M365 Outlook only; no Zulip equivalent.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `user_id` | String | REQUIRED | Source-specific user identifier (UPN for M365) |
| `email` | String | REQUIRED | User email — identity key |
| `date` | Date | REQUIRED | Activity date |
| `sent_count` | Int64 | NULLABLE | Emails sent (`sendCount`) |
| `received_count` | Int64 | NULLABLE | Emails received (`receiveCount`) |
| `read_count` | Int64 | NULLABLE | Emails read (`readCount`) |
| `meetings_created` | Int64 | NULLABLE | Meetings created via email invitation (`meetingCreatedCount`) |
| `meetings_interacted` | Int64 | NULLABLE | Meeting invitations accepted/declined via email (`meetingInteractedCount`) |
| `report_period` | String | NULLABLE | Report window, e.g. `"7"` |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_collab_email_user`: `(source_instance_id, email, date)`
- `idx_collab_email_date`: `(date, data_source)`

---

### `collab_document_activity` — Document and file activity per user per date

Daily aggregated file and document activity per user. Covers OneDrive and SharePoint — merged with a `product` discriminator.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `user_id` | String | REQUIRED | Source-specific user identifier |
| `email` | String | REQUIRED | User email — identity key |
| `date` | Date | REQUIRED | Activity date |
| `product` | String | REQUIRED | `onedrive` / `sharepoint` — which M365 product |
| `viewed_or_edited_count` | Int64 | NULLABLE | Files viewed or edited |
| `synced_count` | Int64 | NULLABLE | Files synced via desktop client |
| `shared_internally_count` | Int64 | NULLABLE | Files shared with internal users |
| `shared_externally_count` | Int64 | NULLABLE | Files shared outside the organisation |
| `visited_page_count` | Int64 | NULLABLE | Pages visited (SharePoint only; NULL for OneDrive) |
| `report_period` | String | NULLABLE | Report window, e.g. `"7"` |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator: always `insight_m365` at launch |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_collab_doc_user`: `(source_instance_id, email, date, product)`
- `idx_collab_doc_date`: `(date, product)`

**Note**: One user produces two rows per day — one for OneDrive, one for SharePoint. `product` distinguishes them. When aggregating total file activity, sum across both products.

---

### `collab_users` — User directory

Identity anchor for collaboration analytics. M365 does not expose a standalone user directory through report endpoints — user identity comes from `userPrincipalName` (UPN) embedded in each activity row, which is also the corporate email. Zulip provides an explicit user directory endpoint.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `user_id` | String | REQUIRED | Source-specific user identifier (Zulip numeric ID / M365 UPN) |
| `email` | String | REQUIRED | Email — primary identity key → `person_id` |
| `display_name` | String | NULLABLE | Display name |
| `is_active` | Int64 | DEFAULT 1 | 1 if account is active; 0 if banned / deleted |
| `role` | String | NULLABLE | User role (Zulip: `owner` / `admin` / `member` / `guest`; NULL for M365) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_collab_user_email`: `(email)`
- `idx_collab_user_lookup`: `(source_instance_id, user_id, data_source)`

**M365 note**: For M365, `collab_users` rows are populated from UPNs observed in activity reports — not from a dedicated users API. `user_id = email = userPrincipalName`. `display_name` is available in email and Copilot reports (`displayName` field) but absent from Teams, OneDrive, and SharePoint reports.

---

### `collab_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `chat_records_collected` | Int64 | NULLABLE | Rows collected for `collab_chat_activity` |
| `meeting_records_collected` | Int64 | NULLABLE | Rows collected for `collab_meeting_activity` |
| `email_records_collected` | Int64 | NULLABLE | Rows collected for `collab_email_activity` |
| `document_records_collected` | Int64 | NULLABLE | Rows collected for `collab_document_activity` |
| `users_collected` | Int64 | NULLABLE | Rows collected for `collab_users` |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (tenant, realm, report period, enabled endpoints) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

---

## Source Mapping

### Microsoft 365

All data collected via Microsoft Graph API v1.0 report endpoints (`/reports/get*ActivityUserDetail`).

| Unified table | M365 endpoint | Key mapping notes |
|---------------|--------------|-------------------|
| `collab_chat_activity` | `getTeamsUserActivityUserDetail` | `privateChatMessageCount` + `teamChatMessageCount` → `total_chat_messages`; `postMessages` → `channel_posts`; `replyMessages` → `channel_replies`; `reportRefreshDate` → `date` |
| `collab_meeting_activity` | `getTeamsUserActivityUserDetail` | `meetingsOrganizedCount`, `meetingsAttendedCount`, `callCount` → meeting fields; ISO 8601 durations → `*_seconds` |
| `collab_email_activity` | `getEmailActivityUserDetail` | `sendCount`, `receiveCount`, `readCount` → direct; `reportRefreshDate` → `date` |
| `collab_document_activity` (OneDrive) | `getOneDriveActivityUserDetail` | `viewedOrEditedFileCount`, `syncedFileCount`, `sharedInternallyFileCount`, `sharedExternallyFileCount` → doc fields; `product = "onedrive"` |
| `collab_document_activity` (SharePoint) | `getSharePointActivityUserDetail` | same fields + `visitedPageCount`; `product = "sharepoint"` |
| `collab_users` | Derived from activity report rows | `userPrincipalName` → `email` and `user_id`; `displayName` where available |

**Note**: `getTeamsUserActivityUserDetail` is a single endpoint that returns both chat and meeting metrics — split into two Bronze tables (`collab_chat_activity` and `collab_meeting_activity`) at collection time.

### Zulip

| Unified table | Zulip endpoint | Key mapping notes |
|---------------|---------------|-------------------|
| `collab_chat_activity` | `GET /api/v1/messages` (aggregated) | `count` → `total_chat_messages`; `created_at` → `date`; `sender_id` → `user_id` via `zulip_users` join |
| `collab_users` | `GET /api/v1/users` | `user_id` → `user_id`; `email` → `email`; `full_name` → `display_name`; role numeric → string; `is_active` → `is_active` |

**Zulip chat fields**: only `total_chat_messages` is populated. `direct_messages`, `group_chat_messages`, `channel_posts`, `channel_replies`, `urgent_messages` are all NULL — Zulip's aggregation does not distinguish message types.

### Slack

See full spec: [`slack.md`](slack.md)

| Unified table | Slack source | Key mapping notes |
|---------------|-------------|-------------------|
| `collab_chat_activity` | `conversations.history` (standard) or `admin.analytics.getFile` (Enterprise Grid) | Message counts grouped by `(user, date, channel_type)`. Enterprise Grid: only `total_chat_messages` available. `direct_messages` ← `im` channel; `group_chat_messages` ← `mpim` channel; `channel_posts` ← `public_channel` + `private_channel` |
| `collab_meeting_activity` | `conversations.history` with `subtype = "huddle_thread"` | Huddle events parsed; `meetings_attended` = huddle sessions joined; all huddles treated as ad-hoc |
| `collab_users` | `users.list` | `profile.email` → `email`; `id` → `user_id`; role derived from boolean flags; `is_bot = true` rows excluded |
| `collab_email_activity` | — | Not populated — Slack has no email product |
| `collab_document_activity` | — | Not populated — file sharing not modelled |

**Slack chat fields**: `total_chat_messages` always populated. Per-channel-type breakdown (`direct_messages`, `group_chat_messages`, `channel_posts`, `channel_replies`) populated for standard workspaces; NULL for Enterprise Grid workspaces using `admin.analytics.getFile`.

---

## Identity Resolution

**Identity anchor**: `collab_users` and `email` embedded in each activity table.

**Resolution process**:
1. Extract `email` from `collab_users` (or `userPrincipalName` from M365 activity rows directly)
2. Normalize (lowercase, trim)
3. Map to canonical `person_id` via Identity Manager in Silver step 2
4. Propagate `person_id` to all Silver activity rows

**M365 UPN** = corporate email address in most tenants — a reliable cross-system identity key.

**Zulip**: `email` from `zulip_users` is the identity key; Zulip numeric `user_id` is not used for cross-system resolution.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `collab_chat_activity` | `class_communication_metrics` | ✓ Mapped — chat channel |
| `collab_meeting_activity` | `class_communication_metrics` | ✓ Mapped — meetings channel |
| `collab_email_activity` | `class_communication_metrics` | ✓ Mapped — email channel |
| `collab_document_activity` | `class_document_metrics` | Planned — not yet defined |
| `collab_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |

**`class_communication_metrics`** — existing Silver stream, covers chat + meetings + email across all sources:

| `data_source` | `channel` | Bronze table | Bronze field |
|---------------|-----------|--------------|--------------|
| `insight_m365` | `chat` | `collab_chat_activity` | `total_chat_messages` |
| `insight_m365` | `email` | `collab_email_activity` | `sent_count` |
| `insight_m365` | `meetings` | `collab_meeting_activity` | `meetings_attended` |
| `insight_zulip` | `chat` | `collab_chat_activity` | `total_chat_messages` |
| `insight_slack` | `chat` | `collab_chat_activity` | `total_chat_messages` |
| `insight_slack` | `meetings` | `collab_meeting_activity` | `meetings_attended` |

**`class_document_metrics`** — planned Silver stream for file collaboration:
- Sources: `collab_document_activity` (OneDrive + SharePoint)
- Key fields: `person_id`, `date`, `product`, `viewed_or_edited_count`, `shared_internally_count`, `shared_externally_count`

**Gold metrics**:
- **Communication load**: total messages + meetings per person per week
- **Async vs. sync ratio**: chat messages vs. meeting hours
- **Meeting overload**: meetings organized + attended, broken down by ad-hoc vs. scheduled
- **Email volume**: sent/received trend per person
- **Document collaboration**: file edits and shares per person — proxy for cross-team work
- **Collaboration breadth**: number of distinct channels/sources a person is active in

---

## Open Questions

### OQ-COLLAB-1: M365 `report_period` and date semantics

M365 report endpoints accept a `period` parameter (`D7`, `D30`, `D90`, `D180`). The returned `reportRefreshDate` is the date when the report was generated, not the individual activity date. For `D7`, one row covers 7 days of activity.

**Question**: Should the connector always use `D7` (minimum window, highest resolution) and store one row per `reportRefreshDate`? Or use `D1` daily reports where available? Not all endpoints support `D1`.

### OQ-COLLAB-2: Zulip message aggregation granularity

`zulip_messages.created_at` is ambiguous — it may be a raw message timestamp or a bucketed period. This affects how `total_chat_messages` maps to a `date` in `collab_chat_activity` and whether it is comparable to M365 daily counts.

**Current approach**: treat `created_at` as the message date for daily bucketing. Confirm with connector implementation.

### OQ-COLLAB-3: `class_document_metrics` Silver stream scope

OneDrive and SharePoint file activity is collected but has no Silver target. Before defining `class_document_metrics`:
- Is file-level activity (edits, shares) in scope for Gold productivity metrics?
- Should it be unified with other document sources (e.g. Google Drive, Confluence page edits)?
- Or is it sufficient as a Bronze-only reference until a use case is confirmed?

### OQ-COLLAB-4: Slack as a future source — RESOLVED

**Status**: RESOLVED — Slack connector spec added in [`slack.md`](slack.md).

`data_source = "insight_slack"`. Chat messages per channel type (im / mpim / public_channel / private_channel) map to existing `collab_chat_activity` fields. Slack huddles map to `collab_meeting_activity` (`meetings_attended`, `audio_duration_seconds`). No email or document equivalent — `collab_email_activity` and `collab_document_activity` are not populated for `insight_slack`.
