# Table: `ms365_sharepoint_activity`

## Overview

**Purpose**: Store Microsoft SharePoint activity reports per user, including file interactions, page visits, and sharing metrics.

**Data Source**: Microsoft Graph API — SharePoint Activity Reports via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `unique` | text | PRIMARY KEY | Unique record identifier |
| `isDeleted` | boolean | NOT NULL | Whether user account is deleted |
| `reportPeriod` | text | NOT NULL | Report period duration |
| `syncedFileCount` | numeric | NOT NULL | Files synced |
| `assignedProducts` | jsonb | NOT NULL | M365 products assigned |
| `lastActivityDate` | date | NOT NULL | Last SharePoint activity date |
| `visitedPageCount` | numeric | NOT NULL | SharePoint pages visited |
| `reportRefreshDate` | date | NOT NULL | Report refresh date |
| `userPrincipalName` | text | NOT NULL | User principal name (email) |
| `viewedOrEditedFileCount` | numeric | NOT NULL | Files viewed or edited |
| `sharedExternallyFileCount` | numeric | NOT NULL | Files shared externally |
| `sharedInternallyFileCount` | numeric | NOT NULL | Files shared internally |

**Indexes**:
- `idx_ms365_sharepoint_activity_report_refresh_date`: `(reportRefreshDate)`
- `idx_ms365_sharepoint_activity_user_principal_name`: `(userPrincipalName)`

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
- **Purpose**: Number of SharePoint files viewed or edited
- **Usage**: Document interaction metrics

**`visitedPageCount`** (numeric, NOT NULL)
- **Purpose**: Number of SharePoint pages visited
- **Usage**: Intranet/portal engagement, page activity

**`syncedFileCount`** (numeric, NOT NULL)
- **Purpose**: Number of files synced from SharePoint
- **Usage**: Sync client adoption

**`sharedInternallyFileCount`** (numeric, NOT NULL)
- **Purpose**: Files shared with internal users
- **Usage**: Internal collaboration metrics

**`sharedExternallyFileCount`** (numeric, NOT NULL)
- **Purpose**: Files shared with external users
- **Usage**: External collaboration tracking, security monitoring

### Report Metadata

**`reportPeriod`** (text, NOT NULL)
- **Purpose**: Report period duration in days

**`reportRefreshDate`** (date, NOT NULL)
- **Purpose**: Date of report data refresh

**`lastActivityDate`** (date, NOT NULL)
- **Purpose**: Date of last SharePoint activity

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

### Top SharePoint users

```sql
SELECT
    userPrincipalName,
    viewedOrEditedFileCount,
    visitedPageCount,
    syncedFileCount
FROM ms365_sharepoint_activity
WHERE reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_sharepoint_activity)
  AND isDeleted = false
ORDER BY viewedOrEditedFileCount + visitedPageCount DESC
LIMIT 20;
```

### SharePoint vs OneDrive file activity

```sql
SELECT
    sp.userPrincipalName,
    sp.viewedOrEditedFileCount as sp_files,
    od.viewedOrEditedFileCount as od_files
FROM ms365_sharepoint_activity sp
JOIN ms365_onedrive_activity od ON sp.userPrincipalName = od.userPrincipalName
  AND sp.reportRefreshDate = od.reportRefreshDate
WHERE sp.reportRefreshDate = (SELECT MAX(reportRefreshDate) FROM ms365_sharepoint_activity)
  AND sp.isDeleted = false
ORDER BY sp_files + od_files DESC
LIMIT 20;
```

### Page visit trends

```sql
SELECT
    reportRefreshDate,
    SUM(visitedPageCount) as total_page_visits,
    COUNT(DISTINCT CASE WHEN visitedPageCount > 0 THEN userPrincipalName END) as active_users
FROM ms365_sharepoint_activity
WHERE isDeleted = false
GROUP BY reportRefreshDate
ORDER BY reportRefreshDate DESC;
```

---

## Notes and Considerations

### SharePoint vs OneDrive

SharePoint and OneDrive share similar metrics (file views, sync, sharing) but track different scopes. SharePoint covers team sites and document libraries, while OneDrive tracks personal file storage. The `visitedPageCount` metric is unique to SharePoint.

### Page Visits

The `visitedPageCount` metric tracks SharePoint site page visits, useful for measuring intranet engagement and content consumption.
