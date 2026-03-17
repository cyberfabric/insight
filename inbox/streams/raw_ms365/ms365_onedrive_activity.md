# Table: `ms365_onedrive_activity`

## Overview

**Purpose**: Store Microsoft OneDrive activity reports per user, including file sync, view/edit, and sharing metrics.

**Data Source**: Microsoft Graph API — OneDrive Activity Reports via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `unique` | text | PRIMARY KEY | Unique record identifier |
| `isDeleted` | boolean | NOT NULL | Whether user account is deleted |
| `reportPeriod` | text | NOT NULL | Report period duration |
| `syncedFileCount` | numeric | NOT NULL | Files synced |
| `assignedProducts` | jsonb | NOT NULL | M365 products assigned |
| `lastActivityDate` | date | NOT NULL | Last OneDrive activity date |
| `reportRefreshDate` | date | NOT NULL | Report refresh date |
| `userPrincipalName` | text | NOT NULL | User principal name (email) |
| `viewedOrEditedFileCount` | numeric | NOT NULL | Files viewed or edited |
| `sharedExternallyFileCount` | numeric | NOT NULL | Files shared externally |
| `sharedInternallyFileCount` | numeric | NOT NULL | Files shared internally |

**Indexes**:
- `idx_ms365_onedrive_activity_report_refresh_date`: `(reportRefreshDate)`
- `idx_ms365_onedrive_activity_user_principal_name`: `(userPrincipalName)`

---

## Field Semantics

### Core Identifiers

**`unique`** (text, PRIMARY KEY)
- **Purpose**: Unique record identifier
- **Usage**: Primary key, deduplication

**`userPrincipalName`** (text, NOT NULL)
- **Purpose**: User principal name (email)
- **Format**: "user@company.com"
- **Usage**: User identification, cross-report correlation

### Activity Metrics

**`viewedOrEditedFileCount`** (numeric, NOT NULL)
- **Purpose**: Number of files the user viewed or edited
- **Usage**: File interaction metrics, productivity

**`syncedFileCount`** (numeric, NOT NULL)
- **Purpose**: Number of files synced via OneDrive client
- **Usage**: Sync usage tracking, client adoption

**`sharedInternallyFileCount`** (numeric, NOT NULL)
- **Purpose**: Number of files shared with internal users
- **Usage**: Internal collaboration metrics

**`sharedExternallyFileCount`** (numeric, NOT NULL)
- **Purpose**: Number of files shared with external users
- **Usage**: External collaboration tracking, security monitoring

### Report Metadata

**`reportPeriod`** (text, NOT NULL)
- **Purpose**: Report period duration in days

**`reportRefreshDate`** (date, NOT NULL)
- **Purpose**: Date of report data refresh

**`lastActivityDate`** (date, NOT NULL)
- **Purpose**: Date of last OneDrive activity

### User Status

**`isDeleted`** (boolean, NOT NULL)
- **Purpose**: Whether user account is deleted

**`assignedProducts`** (jsonb, NOT NULL)
- **Purpose**: Assigned M365 products

---

## Relationships

This table is standalone. User correlation across MS365 reports is done via `userPrincipalName`.

---

## Usage Examples

### Top OneDrive users

```sql
SELECT
    userPrincipalName,
    viewedOrEditedFileCount,
    syncedFileCount,
    sharedInternallyFileCount + sharedExternallyFileCount as total_shared
FROM ms365_onedrive_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_onedrive_activity)
  AND isDeleted = false
ORDER BY viewedOrEditedFileCount DESC
LIMIT 20;
```

### External sharing activity

```sql
SELECT
    userPrincipalName,
    sharedExternallyFileCount,
    lastActivityDate
FROM ms365_onedrive_activity
WHERE sharedExternallyFileCount > 0
  AND reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_onedrive_activity)
ORDER BY sharedExternallyFileCount DESC;
```

---

## Notes and Considerations

### Security Monitoring

The `sharedExternallyFileCount` field is useful for monitoring external file sharing patterns and detecting potential data leakage.

### Sync vs Web Usage

`syncedFileCount` reflects desktop client usage, while `viewedOrEditedFileCount` includes both web and client interactions.
