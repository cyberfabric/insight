# Table: `ms365_teams_activity`

## Overview

**Purpose**: Store Microsoft Teams activity reports per user, including messaging, meeting, and call metrics across all Teams interaction types.

**Data Source**: Microsoft Graph API — Teams Activity Reports via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `unique` | text | PRIMARY KEY | Unique record identifier |
| `userId` | text | NOT NULL | Microsoft user ID |
| `callCount` | numeric | NOT NULL | Number of calls made |
| `isDeleted` | boolean | NOT NULL | Whether user account is deleted |
| `isExternal` | boolean | NOT NULL | Whether user is external |
| `isLicensed` | boolean | NOT NULL | Whether user has Teams license |
| `meetingCount` | numeric | NOT NULL | Total meetings count |
| `postMessages` | numeric | NOT NULL | Messages posted in channels |
| `reportPeriod` | text | NOT NULL | Report period duration |
| `audioDuration` | text | NOT NULL | Total audio duration |
| `replyMessages` | numeric | NOT NULL | Reply messages count |
| `videoDuration` | text | NOT NULL | Total video duration |
| `hasOtherAction` | boolean | NOT NULL | Whether user had other actions |
| `urgentMessages` | numeric | NOT NULL | Urgent messages sent |
| `assignedProducts` | jsonb | NOT NULL | M365 products assigned |
| `lastActivityDate` | date | NOT NULL | Last Teams activity date |
| `reportRefreshDate` | date | NOT NULL | Report refresh date |
| `tenantDisplayName` | text | NOT NULL | Tenant name |
| `userPrincipalName` | text | NOT NULL | User principal name (email) |
| `screenShareDuration` | text | NOT NULL | Total screen share duration |
| `teamChatMessageCount` | numeric | NOT NULL | Team chat messages |
| `meetingsAttendedCount` | numeric | NOT NULL | Meetings attended |
| `meetingsOrganizedCount` | numeric | NOT NULL | Meetings organized |
| `privateChatMessageCount` | numeric | NOT NULL | Private chat messages |
| `adHocMeetingsAttendedCount` | numeric | NOT NULL | Ad-hoc meetings attended |
| `adHocMeetingsOrganizedCount` | numeric | NOT NULL | Ad-hoc meetings organized |
| `sharedChannelTenantDisplayNames` | text | NOT NULL | Shared channel tenants |
| `scheduledOneTimeMeetingsAttendedCount` | numeric | NOT NULL | Scheduled one-time meetings attended |
| `scheduledOneTimeMeetingsOrganizedCount` | numeric | NOT NULL | Scheduled one-time meetings organized |
| `scheduledRecurringMeetingsAttendedCount` | numeric | NOT NULL | Recurring meetings attended |
| `scheduledRecurringMeetingsOrganizedCount` | numeric | NOT NULL | Recurring meetings organized |

**Indexes**:
- `idx_ms365_teams_activity_report_refresh_date`: `(reportRefreshDate)`
- `idx_ms365_teams_activity_user_principal_name`: `(userPrincipalName)`

---

## Field Semantics

### Core Identifiers

**`unique`** (text, PRIMARY KEY)
- **Purpose**: Unique record identifier
- **Usage**: Primary key, deduplication

**`userId`** (text, NOT NULL)
- **Purpose**: Microsoft internal user ID
- **Usage**: Alternative user identification

**`userPrincipalName`** (text, NOT NULL)
- **Purpose**: User principal name (email)
- **Format**: "user@company.com"
- **Usage**: Primary user identification, cross-report correlation

### Messaging Metrics

> **Total message count** = `teamChatMessageCount` + `privateChatMessageCount`. These are the only two fields that represent actual chat messages sent by the user. The `postMessages` and `replyMessages` fields track **channel activity** (posts and replies in team channels), which is a separate category from chat messages.

**`teamChatMessageCount`** (numeric, NOT NULL)
- **Purpose**: Messages sent in team/group chats
- **Usage**: Group chat activity, **part of total message count**

**`privateChatMessageCount`** (numeric, NOT NULL)
- **Purpose**: Messages sent in private (1:1) chats
- **Usage**: Direct communication metrics, **part of total message count**

**`postMessages`** (numeric, NOT NULL)
- **Purpose**: Posts published in team channels (not chat messages)
- **Usage**: Channel engagement, content creation

**`replyMessages`** (numeric, NOT NULL)
- **Purpose**: Replies to posts in team channels (not chat messages)
- **Usage**: Channel conversation engagement

**`urgentMessages`** (numeric, NOT NULL)
- **Purpose**: Messages sent with urgent priority
- **Usage**: Urgent communication patterns

### Meeting Metrics

**`meetingCount`** (numeric, NOT NULL)
- **Purpose**: Total meetings count
- **Usage**: Overall meeting activity

**`meetingsAttendedCount`** (numeric, NOT NULL)
- **Purpose**: Total meetings attended
- **Usage**: Meeting participation

**`meetingsOrganizedCount`** (numeric, NOT NULL)
- **Purpose**: Total meetings organized
- **Usage**: Meeting organization activity

**`adHocMeetingsAttendedCount`** / **`adHocMeetingsOrganizedCount`** (numeric, NOT NULL)
- **Purpose**: Ad-hoc (unscheduled) meeting counts
- **Usage**: Spontaneous meeting analysis

**`scheduledOneTimeMeetingsAttendedCount`** / **`scheduledOneTimeMeetingsOrganizedCount`** (numeric, NOT NULL)
- **Purpose**: One-time scheduled meeting counts
- **Usage**: Planned meeting analysis

**`scheduledRecurringMeetingsAttendedCount`** / **`scheduledRecurringMeetingsOrganizedCount`** (numeric, NOT NULL)
- **Purpose**: Recurring meeting counts
- **Usage**: Regular meeting analysis

### Communication Durations

**`audioDuration`** (text, NOT NULL)
- **Purpose**: Total audio call duration
- **Format**: Duration string (e.g., "01:30:00")
- **Usage**: Call time analysis

**`videoDuration`** (text, NOT NULL)
- **Purpose**: Total video call duration
- **Format**: Duration string
- **Usage**: Video meeting analysis

**`screenShareDuration`** (text, NOT NULL)
- **Purpose**: Total screen sharing duration
- **Format**: Duration string
- **Usage**: Collaboration intensity

**`callCount`** (numeric, NOT NULL)
- **Purpose**: Number of calls made
- **Usage**: Call activity tracking

### User Status

**`isDeleted`** (boolean, NOT NULL)
- **Purpose**: Whether user account is deleted

**`isExternal`** (boolean, NOT NULL)
- **Purpose**: Whether user is external (guest)

**`isLicensed`** (boolean, NOT NULL)
- **Purpose**: Whether user has Teams license

**`hasOtherAction`** (boolean, NOT NULL)
- **Purpose**: Whether user had other Teams actions not captured by specific metrics

### Report Metadata

**`reportPeriod`** (text, NOT NULL)
- **Purpose**: Report period duration in days

**`reportRefreshDate`** (date, NOT NULL)
- **Purpose**: Date of report data refresh

**`lastActivityDate`** (date, NOT NULL)
- **Purpose**: Date of last Teams activity

**`tenantDisplayName`** (text, NOT NULL)
- **Purpose**: Microsoft 365 tenant display name

**`assignedProducts`** (jsonb, NOT NULL)
- **Purpose**: Assigned M365 products

**`sharedChannelTenantDisplayNames`** (text, NOT NULL)
- **Purpose**: Tenant names for shared channels

---

## Relationships

This table is standalone. User correlation across MS365 reports is done via `userPrincipalName`.

---

## Usage Examples

### Total messages per user (chat messages only)

```sql
SELECT
    userPrincipalName,
    teamChatMessageCount + privateChatMessageCount as total_messages,
    teamChatMessageCount as group_chat,
    privateChatMessageCount as private_chat
FROM ms365_teams_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_teams_activity)
  AND isDeleted = false
ORDER BY total_messages DESC
LIMIT 20;
```

### Most active Teams users (all activity)

```sql
SELECT
    userPrincipalName,
    teamChatMessageCount + privateChatMessageCount as total_messages,
    postMessages + replyMessages as channel_activity,
    meetingsAttendedCount,
    callCount
FROM ms365_teams_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_teams_activity)
  AND isDeleted = false
ORDER BY total_messages DESC
LIMIT 20;
```

### Meeting vs messaging ratio

```sql
SELECT
    userPrincipalName,
    meetingsAttendedCount + meetingsOrganizedCount as total_meetings,
    teamChatMessageCount + privateChatMessageCount as total_messages,
    CASE WHEN (teamChatMessageCount + privateChatMessageCount) > 0
         THEN ROUND((meetingsAttendedCount + meetingsOrganizedCount)::numeric /
              (teamChatMessageCount + privateChatMessageCount), 2)
         ELSE 0 END as meeting_to_message_ratio
FROM ms365_teams_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_teams_activity)
  AND isDeleted = false
ORDER BY total_meetings DESC;
```

### External user activity

```sql
SELECT userPrincipalName, tenantDisplayName, lastActivityDate
FROM ms365_teams_activity
WHERE isExternal = true
  AND reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_teams_activity)
ORDER BY lastActivityDate DESC;
```

---

## Notes and Considerations

### Total Message Count

**Total messages = `teamChatMessageCount` + `privateChatMessageCount`**. Only these two fields count actual chat messages. The `postMessages` and `replyMessages` fields represent channel posts/replies and should NOT be included in total message count — they are a different category of activity (content publishing in channels vs direct messaging).

### Duration Format

Duration fields (`audioDuration`, `videoDuration`, `screenShareDuration`) are stored as text strings. Parse them for numeric analysis.

### Meeting Breakdown

Total meetings = ad-hoc attended + ad-hoc organized + scheduled one-time attended + scheduled one-time organized + scheduled recurring attended + scheduled recurring organized. Use this breakdown to understand meeting culture.

### External Users

External users (`isExternal = true`) are guest users from other tenants. Their activity may be limited compared to internal users.
