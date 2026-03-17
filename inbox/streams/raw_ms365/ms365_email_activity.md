# Table: `ms365_email_activity`

## Overview

**Purpose**: Store Microsoft 365 email activity reports per user, including send/receive/read counts and meeting interaction metrics.

**Data Source**: Microsoft Graph API — Email Activity Reports via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `unique` | text | PRIMARY KEY | Unique record identifier |
| `isDeleted` | boolean | NOT NULL | Whether the user account is deleted |
| `readCount` | numeric | NOT NULL | Number of emails read |
| `sendCount` | numeric | NOT NULL | Number of emails sent |
| `displayName` | text | NOT NULL | User display name |
| `receiveCount` | numeric | NOT NULL | Number of emails received |
| `reportPeriod` | text | NOT NULL | Report period duration (e.g., "7") |
| `assignedProducts` | jsonb | NOT NULL | M365 products assigned to user |
| `lastActivityDate` | date | NULLABLE | Last email activity date |
| `reportRefreshDate` | date | NOT NULL | Report data refresh date |
| `userPrincipalName` | text | NOT NULL | User principal name (email) |
| `meetingCreatedCount` | numeric | NOT NULL | Meetings created via email |
| `meetingInteractedCount` | numeric | NOT NULL | Meeting interactions via email |

**Indexes**:
- `idx_ms365_email_activity_report_refresh_date`: `(reportRefreshDate)`
- `idx_ms365_email_activity_user_principal_name`: `(userPrincipalName)`

---

## Field Semantics

### Core Identifiers

**`unique`** (text, PRIMARY KEY)
- **Purpose**: Unique record identifier
- **Usage**: Primary key, deduplication

**`userPrincipalName`** (text, NOT NULL)
- **Purpose**: Microsoft 365 user principal name
- **Format**: Email-like format (e.g., "user@company.com")
- **Usage**: User identification, cross-report correlation

**`displayName`** (text, NOT NULL)
- **Purpose**: User's display name in Microsoft 365
- **Example**: "John Smith"
- **Usage**: Display, user identification

### Email Metrics

**`sendCount`** (numeric, NOT NULL)
- **Purpose**: Number of emails sent during the report period
- **Usage**: Email activity tracking, productivity metrics

**`receiveCount`** (numeric, NOT NULL)
- **Purpose**: Number of emails received during the report period
- **Usage**: Email volume analysis

**`readCount`** (numeric, NOT NULL)
- **Purpose**: Number of emails read during the report period
- **Usage**: Email engagement tracking

### Meeting Metrics

**`meetingCreatedCount`** (numeric, NOT NULL)
- **Purpose**: Number of meetings created via email
- **Usage**: Meeting scheduling activity

**`meetingInteractedCount`** (numeric, NOT NULL)
- **Purpose**: Number of meeting interactions via email
- **Usage**: Meeting engagement tracking

### Report Metadata

**`reportPeriod`** (text, NOT NULL)
- **Purpose**: Duration of the report period in days
- **Example**: "7" (7-day report)
- **Usage**: Normalizing metrics across different report periods

**`reportRefreshDate`** (date, NOT NULL)
- **Purpose**: Date when the report data was last refreshed
- **Usage**: Data freshness tracking, time-series analysis

**`lastActivityDate`** (date, NULLABLE)
- **Purpose**: Date of last email activity
- **Note**: NULL if no activity in reporting period
- **Usage**: User engagement analysis

### User Status

**`isDeleted`** (boolean, NOT NULL)
- **Purpose**: Whether the user account has been deleted
- **Usage**: Filtering active vs deleted users

**`assignedProducts`** (jsonb, NOT NULL)
- **Purpose**: M365 product licenses assigned to the user
- **Format**: JSON array of product names
- **Usage**: License analysis, feature availability

---

## Relationships

This table is standalone. User correlation across MS365 reports is done via `userPrincipalName`.

---

## Usage Examples

### Top email senders

```sql
SELECT
    userPrincipalName,
    displayName,
    sendCount,
    receiveCount,
    readCount
FROM ms365_email_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_email_activity)
  AND isDeleted = false
ORDER BY sendCount DESC
LIMIT 20;
```

### Email activity trend

```sql
SELECT
    reportRefreshDate,
    SUM(sendCount) as total_sent,
    SUM(receiveCount) as total_received,
    COUNT(DISTINCT userPrincipalName) as active_users
FROM ms365_email_activity
WHERE isDeleted = false
  AND lastActivityDate IS NOT NULL
GROUP BY reportRefreshDate
ORDER BY reportRefreshDate DESC;
```

### Inactive email users

```sql
SELECT userPrincipalName, displayName, lastActivityDate
FROM ms365_email_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_email_activity)
  AND lastActivityDate IS NULL
  AND isDeleted = false;
```

---

## Notes and Considerations

### Report Period

Metrics are cumulative for the `reportPeriod` (typically 7 days). When comparing across time, use `reportRefreshDate` for the time axis.

### Deleted Users

Records for deleted users (`isDeleted = true`) are kept for historical analysis. Filter with `isDeleted = false` for current user analysis.
