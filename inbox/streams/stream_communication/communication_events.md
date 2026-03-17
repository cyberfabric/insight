# Table: `communication_events`

## Overview

**Purpose**: Unified audit log of communication activities across all platforms. Normalizes messaging, email, meeting, and call events from multiple sources into a single stream for cross-platform communication analysis.

**Data Sources**:
- `raw_ms365/ms365_teams_activity` — Teams chats, channel posts, calls, meetings
- `raw_ms365/ms365_email_activity` — Email send/receive/read
- `raw_zulip/zulip_messages` — Zulip chat messages

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigint | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `ingestion_date` | timestamp | NOT NULL | When this record was ingested into the stream |
| `source_id` | text | NOT NULL | Unique identifier of the source record |
| `event_date` | date | NOT NULL | Date of the communication event |
| `source` | text | NOT NULL | Source platform identifier |
| `user_email` | text | NOT NULL | User email (unified identifier) |
| `user_display_name` | text | NULLABLE | User display name from source |
| `channel` | text | NOT NULL | Communication channel type |
| `direction` | text | NULLABLE | Communication direction |
| `count` | numeric | NOT NULL | Number of events/messages |
| `metadata` | jsonb | NULLABLE | Source-specific additional data |

**Indexes**:
- `idx_comm_events_ingestion`: `(ingestion_date)` — incremental sync
- `idx_comm_events_source_id`: `(source_id)` — source record lookup
- `idx_comm_events_date`: `(event_date)`
- `idx_comm_events_user`: `(user_email)`
- `idx_comm_events_source`: `(source)`
- `idx_comm_events_channel`: `(channel)`
- `(user_email, event_date)` — user activity over time
- `(source, channel, event_date)` — source/channel trends
- `(source, source_id)` — UNIQUE, prevents duplicate ingestion from same source record

---

## Field Semantics

### Core Identifiers

**`id`** (bigint, PRIMARY KEY)
- **Purpose**: Auto-increment primary key
- **Usage**: Unique record identification

**`ingestion_date`** (timestamp, NOT NULL)
- **Purpose**: Timestamp of when this record was ingested into the communication stream
- **Format**: PostgreSQL timestamp (e.g., "2026-02-23 14:30:00")
- **Usage**: Incremental synchronization — downstream consumers query `WHERE ingestion_date > last_sync_timestamp` to pick up only new records since last run
- **Note**: This is NOT the event date. A record may be ingested days after the event occurred (e.g., when backfilling historical data or when a source report becomes available with delay)

**`source_id`** (text, NOT NULL)
- **Purpose**: Unique identifier of the original record in the source system, enabling traceability back to the raw data
- **Format**: Composite key as `{source}:{unique_id}:{channel}` to ensure uniqueness across sources and channels
- **Derived from**:
  - MS365 Teams: `ms365_teams:{unique}:{channel}` (e.g., `ms365_teams:abc123:chat_group`)
  - MS365 Email: `ms365_email:{unique}:{channel}` (e.g., `ms365_email:def456:email_sent`)
  - Zulip: `zulip:{uniq}` (e.g., `zulip:msg_789`)
- **Usage**: Trace back to source record, deduplication, reprocessing detection
- **Note**: Combined with `source`, forms a unique constraint to prevent duplicate ingestion

**`event_date`** (date, NOT NULL)
- **Purpose**: Date when the communication occurred
- **Format**: YYYY-MM-DD
- **Derived from**:
  - MS365: `reportRefreshDate`
  - Zulip: `DATE(created_at)`
- **Usage**: Time-series analysis, daily aggregations

**`user_email`** (text, NOT NULL)
- **Purpose**: Unified user identifier across all platforms
- **Format**: Lowercase email address
- **Derived from**:
  - MS365: `LOWER(userPrincipalName)`
  - Zulip: `LOWER(zulip_users.email)` via `sender_id` join
- **Usage**: Cross-platform user correlation, identity resolution

**`user_display_name`** (text, NULLABLE)
- **Purpose**: Human-readable user name from the source system
- **Derived from**:
  - MS365 Teams: not available (use email)
  - MS365 Email: `displayName`
  - Zulip: `zulip_users.full_name`
- **Usage**: Display purposes

### Event Classification

**`source`** (text, NOT NULL)
- **Purpose**: Identifies the originating platform
- **Values**:
  - `"ms365_teams"` — Microsoft Teams
  - `"ms365_email"` — Microsoft Outlook/Exchange
  - `"zulip"` — Zulip chat
- **Usage**: Platform-level filtering and analysis

**`channel`** (text, NOT NULL)
- **Purpose**: Communication channel type within the platform
- **Values**:

| source | channel | Description | Mapped from |
|--------|---------|-------------|-------------|
| `ms365_teams` | `chat_group` | Team/group chat messages | `teamChatMessageCount` |
| `ms365_teams` | `chat_private` | Private 1:1 chat messages | `privateChatMessageCount` |
| `ms365_teams` | `channel_post` | Channel post creation | `postMessages` |
| `ms365_teams` | `channel_reply` | Channel post replies | `replyMessages` |
| `ms365_teams` | `call` | Audio/video calls | `callCount` |
| `ms365_teams` | `meeting` | Meetings attended | `meetingsAttendedCount` |
| `ms365_email` | `email_sent` | Emails sent | `sendCount` |
| `ms365_email` | `email_received` | Emails received | `receiveCount` |
| `ms365_email` | `email_read` | Emails read | `readCount` |
| `zulip` | `chat` | Zulip messages | `zulip_messages.count` |

- **Usage**: Granular activity type filtering

**`direction`** (text, NULLABLE)
- **Purpose**: Direction of communication
- **Values**:
  - `"outbound"` — sent/posted by user (chats, emails sent, channel posts, calls made)
  - `"inbound"` — received by user (emails received)
  - `"engagement"` — interaction with existing content (emails read, meetings attended)
  - `NULL` — direction not applicable
- **Usage**: Distinguishing active vs passive communication

### Metrics

**`count`** (numeric, NOT NULL)
- **Purpose**: Number of communication events
- **Format**: Positive integer
- **Usage**: Activity volume, aggregation

### Metadata

**`metadata`** (jsonb, NULLABLE)
- **Purpose**: Source-specific context not captured in normalized fields
- **Examples**:
  - Teams: `{"urgentMessages": 2, "audioDuration": "01:30:00", "reportPeriod": "7"}`
  - Email: `{"meetingCreatedCount": 5, "reportPeriod": "7"}`
  - Zulip: `{}`
- **Usage**: Platform-specific deep-dive analysis

---

## Data Transformation

### From `raw_ms365/ms365_teams_activity`

Each Teams activity row produces **up to 6 communication_events rows** (one per non-zero channel):

```sql
-- chat_group (outbound)
SELECT
    NOW() as ingestion_date,
    'ms365_teams:' || "unique" || ':chat_group' as source_id,
    reportRefreshDate as event_date,
    'ms365_teams' as source,
    LOWER(userPrincipalName) as user_email,
    NULL as user_display_name,
    'chat_group' as channel,
    'outbound' as direction,
    teamChatMessageCount as count
FROM raw_ms365.ms365_teams_activity
WHERE teamChatMessageCount > 0 AND isDeleted = false;

-- chat_private (outbound)
-- source_id = 'ms365_teams:' || unique || ':chat_private', count = privateChatMessageCount

-- channel_post (outbound)
-- source_id = 'ms365_teams:' || unique || ':channel_post', count = postMessages

-- channel_reply (outbound)
-- source_id = 'ms365_teams:' || unique || ':channel_reply', count = replyMessages

-- call (outbound)
-- source_id = 'ms365_teams:' || unique || ':call', count = callCount

-- meeting (engagement)
-- source_id = 'ms365_teams:' || unique || ':meeting', direction = 'engagement', count = meetingsAttendedCount
```

### From `raw_ms365/ms365_email_activity`

Each email activity row produces **up to 3 rows**:

```sql
-- email_sent (outbound)
SELECT
    NOW() as ingestion_date,
    'ms365_email:' || "unique" || ':email_sent' as source_id,
    reportRefreshDate as event_date,
    'ms365_email' as source,
    LOWER(userPrincipalName) as user_email,
    displayName as user_display_name,
    'email_sent' as channel,
    'outbound' as direction,
    sendCount as count
FROM raw_ms365.ms365_email_activity
WHERE sendCount > 0 AND isDeleted = false;

-- email_received (inbound)
-- source_id = 'ms365_email:' || unique || ':email_received', count = receiveCount

-- email_read (engagement)
-- source_id = 'ms365_email:' || unique || ':email_read', count = readCount
```

### From `raw_zulip/zulip_messages`

```sql
SELECT
    NOW() as ingestion_date,
    'zulip:' || m.uniq as source_id,
    DATE(m.created_at) as event_date,
    'zulip' as source,
    LOWER(u.email) as user_email,
    u.full_name as user_display_name,
    'chat' as channel,
    'outbound' as direction,
    m.count as count
FROM raw_zulip.zulip_messages m
JOIN raw_zulip.zulip_users u ON m.sender_id = u.id;
```

---

## Relationships

### Source Tables

| Source Table | `source_id` format | Join back to source |
|---|---|---|
| `raw_ms365.ms365_teams_activity` | `ms365_teams:{unique}:{channel}` | `WHERE "unique" = split_part(source_id, ':', 2)` |
| `raw_ms365.ms365_email_activity` | `ms365_email:{unique}:{channel}` | `WHERE "unique" = split_part(source_id, ':', 2)` |
| `raw_zulip.zulip_messages` | `zulip:{uniq}` | `WHERE uniq = split_part(source_id, ':', 2)` |

### Cross-Stream Correlation

- **Identity resolution**: `user_email` can be joined with `raw_git.git_author.email_lower` for developer-communication correlation
- **Task tracker**: Correlate communication volume with task lifecycle from `stream_task_tracker`

---

## Usage Examples

### Incremental sync — fetch new records since last run

```sql
SELECT *
FROM communication_events
WHERE ingestion_date > '2026-02-22 00:00:00'
ORDER BY ingestion_date;
```

### Trace back to source record

```sql
-- Find the original Teams activity record for a communication event
SELECT t.*
FROM raw_ms365.ms365_teams_activity t
WHERE t."unique" = split_part('ms365_teams:abc123:chat_group', ':', 2);
```

### Total communication volume per user (all platforms)

```sql
SELECT
    user_email,
    SUM(count) as total_events,
    SUM(CASE WHEN source = 'ms365_teams' THEN count ELSE 0 END) as teams_events,
    SUM(CASE WHEN source = 'ms365_email' THEN count ELSE 0 END) as email_events,
    SUM(CASE WHEN source = 'zulip' THEN count ELSE 0 END) as zulip_events
FROM communication_events
WHERE event_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY user_email
ORDER BY total_events DESC
LIMIT 20;
```

### Total messages sent per user (chat messages only, all platforms)

```sql
SELECT
    user_email,
    SUM(count) as total_messages_sent
FROM communication_events
WHERE direction = 'outbound'
  AND channel IN ('chat_group', 'chat_private', 'chat')
  AND event_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY user_email
ORDER BY total_messages_sent DESC;
```

### Daily communication trend by platform

```sql
SELECT
    event_date,
    source,
    SUM(count) as total_events,
    COUNT(DISTINCT user_email) as active_users
FROM communication_events
WHERE event_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY event_date, source
ORDER BY event_date DESC, source;
```

### Communication channel breakdown

```sql
SELECT
    source,
    channel,
    direction,
    SUM(count) as total_events,
    COUNT(DISTINCT user_email) as unique_users
FROM communication_events
WHERE event_date >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY source, channel, direction
ORDER BY total_events DESC;
```

### Developer communication profile

```sql
SELECT
    ce.user_email,
    SUM(CASE WHEN ce.channel IN ('chat_group', 'chat_private', 'chat') THEN ce.count ELSE 0 END) as chat_messages,
    SUM(CASE WHEN ce.channel = 'email_sent' THEN ce.count ELSE 0 END) as emails_sent,
    SUM(CASE WHEN ce.channel = 'meeting' THEN ce.count ELSE 0 END) as meetings,
    SUM(CASE WHEN ce.channel = 'call' THEN ce.count ELSE 0 END) as calls,
    COUNT(DISTINCT gc.id) as git_commits
FROM communication_events ce
LEFT JOIN raw_git.git_author a ON ce.user_email = a.email_lower
LEFT JOIN raw_git.git_commit gc ON a.id = gc.author_id
    AND gc.created_at >= CURRENT_DATE - INTERVAL '30 days'
WHERE ce.event_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY ce.user_email
ORDER BY chat_messages + emails_sent DESC;
```

### Outbound vs inbound ratio

```sql
SELECT
    user_email,
    SUM(CASE WHEN direction = 'outbound' THEN count ELSE 0 END) as outbound,
    SUM(CASE WHEN direction = 'inbound' THEN count ELSE 0 END) as inbound,
    ROUND(
        SUM(CASE WHEN direction = 'outbound' THEN count ELSE 0 END)::numeric /
        NULLIF(SUM(CASE WHEN direction = 'inbound' THEN count ELSE 0 END), 0),
    2) as out_in_ratio
FROM communication_events
WHERE event_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY user_email
HAVING SUM(CASE WHEN direction = 'inbound' THEN count ELSE 0 END) > 0
ORDER BY out_in_ratio DESC;
```

---

## Notes and Considerations

### Incremental Synchronization

The `ingestion_date` field enables incremental consumption by downstream systems. Consumers track their last sync timestamp and query `WHERE ingestion_date > last_sync` to get only new records. This is critical when new sources are added — historical data from a new source will have `ingestion_date` set to the backfill time, not the original `event_date`, so consumers will pick it up on their next sync.

### Source Traceability

The `source_id` field provides a stable link back to the original record. Format is `{source}:{unique_id}:{channel}` for MS365 (since one source row fans out into multiple channels) and `{source}:{unique_id}` for Zulip. The unique constraint on `(source, source_id)` prevents the same source record from being ingested twice.

### Aggregation Granularity

Events are aggregated **per user per day per channel**. This means one row represents the total count of a specific communication type for one user on one day. This is not an event-level log of individual messages.

### Report Period Alignment

MS365 data comes in report periods (typically 7 days). When comparing with Zulip data (which is per-message), be aware that MS365 counts are cumulative for the report period while Zulip records are more granular.

### Total Messages Definition

For total chat message count across all platforms, filter by:
- `channel IN ('chat_group', 'chat_private', 'chat')` AND `direction = 'outbound'`

Do NOT include `channel_post` and `channel_reply` in total messages — these are channel activity (content publishing), not direct messaging.

### Identity Resolution

The `user_email` field is the unification key across platforms. All emails are lowercased. For users with multiple email addresses across platforms, external identity resolution (from `stream_task_tracker` or a separate identity mapping) may be needed.

### Missing Platforms

Currently tracked: Teams, Outlook, Zulip. Other communication platforms (Slack, etc.) can be added as new `source` values following the same pattern.
