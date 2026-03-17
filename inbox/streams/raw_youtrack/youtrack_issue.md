# Table: `youtrack_issue`

## Overview

**Purpose**: Store YouTrack issue metadata including identifiers and timestamps for all tracked issues.

**Data Source**: YouTrack REST API

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | int | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `youtrack_id` | text | NOT NULL, UNIQUE | YouTrack internal issue ID |
| `id_readable` | text | NOT NULL, UNIQUE | Human-readable issue ID |
| `created` | timestamp | NOT NULL | Issue creation timestamp |
| `updated` | timestamp | NOT NULL | Last update timestamp |

**Indexes**:
- `youtrack_issue_idx_id_readable`: `(id_readable)`
- `youtrack_issue_idx_youtrack_id`: `(youtrack_id)`

---

## Field Semantics

### Core Identifiers

**`id`** (int, PRIMARY KEY)
- **Purpose**: Internal auto-increment key
- **Usage**: Internal references

**`youtrack_id`** (text, UNIQUE, NOT NULL)
- **Purpose**: YouTrack internal issue ID
- **Format**: Alphanumeric string (e.g., "2-12345")
- **Usage**: API references, deduplication

**`id_readable`** (text, UNIQUE, NOT NULL)
- **Purpose**: Human-readable issue identifier
- **Format**: "PROJECT-NUMBER" (e.g., "MON-123", "PLAT-456")
- **Usage**: Display, cross-referencing with commit messages, user-facing identification

### Timestamps

**`created`** (timestamp, NOT NULL)
- **Purpose**: When the issue was created in YouTrack
- **Usage**: Issue age analysis, creation metrics

**`updated`** (timestamp, NOT NULL)
- **Purpose**: When the issue was last modified
- **Usage**: Activity tracking, incremental sync

---

## Relationships

### Children

**`youtrack_issue_history`**
- **Join**: `youtrack_id` → `issue_youtrack_id`
- **Cardinality**: One issue to many history records
- **Description**: All field change history for this issue

---

## Usage Examples

### Recently updated issues

```sql
SELECT id_readable, created, updated
FROM youtrack_issue
WHERE updated > NOW() - INTERVAL '7 days'
ORDER BY updated DESC;
```

### Issue creation rate by month

```sql
SELECT
    DATE_TRUNC('month', created) as month,
    COUNT(*) as issues_created
FROM youtrack_issue
GROUP BY month
ORDER BY month DESC;
```

### Find issue by readable ID

```sql
SELECT youtrack_id, id_readable, created, updated
FROM youtrack_issue
WHERE id_readable = 'MON-123';
```

---

## Notes and Considerations

### Dual Identifiers

Issues have two unique identifiers: `youtrack_id` (internal) and `id_readable` (human-readable). Use `id_readable` for display and cross-referencing with commit messages, use `youtrack_id` for API operations.

### Incremental Sync

The `updated` timestamp enables incremental synchronization — only fetch issues modified since the last sync.
