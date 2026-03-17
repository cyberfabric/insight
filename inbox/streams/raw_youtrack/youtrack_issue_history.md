# Table: `youtrack_issue_history`

## Overview

**Purpose**: Store detailed field change history for YouTrack issues, capturing every state transition including who made the change, when, and what the new value is.

**Data Source**: YouTrack REST API — Activities endpoint

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | int | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `id_readable` | varchar | NOT NULL | Human-readable issue ID |
| `issue_youtrack_id` | varchar | NOT NULL | YouTrack internal issue ID |
| `author_youtrack_id` | varchar | NOT NULL | Author's YouTrack user ID |
| `index` | int | NOT NULL | Activity index within batch |
| `activity_id` | varchar | NOT NULL | YouTrack activity ID |
| `created_at` | timestamptz | NOT NULL | When the change was made |
| `field_id` | varchar | NOT NULL | Field identifier |
| `field_name` | varchar | NOT NULL | Field display name |
| `value` | jsonb | NULLABLE | New field value |
| `value_id` | varchar | NOT NULL, UNIQUE | Unique value identifier |

**Indexes**:
- `idx_youtrack_issue_history_activity_id`: `(activity_id)`
- `idx_youtrack_issue_history_created_at`: `(created_at)`
- `idx_youtrack_issue_history_field_name`: `(field_name)`
- `idx_youtrack_issue_history_id_readable`: `(id_readable)`
- `idx_youtrack_issue_history_issue_field`: `(issue_youtrack_id, field_name)`
- `idx_youtrack_issue_history_issue_field_created`: `(issue_youtrack_id, field_name, created_at)`
- `idx_youtrack_issue_history_issue_youtrack_id`: `(issue_youtrack_id)`

---

## Field Semantics

### Core Identifiers

**`id`** (int, PRIMARY KEY)
- **Purpose**: Internal auto-increment key

**`id_readable`** (varchar, NOT NULL)
- **Purpose**: Human-readable issue ID for the parent issue
- **Format**: "PROJECT-NUMBER" (e.g., "MON-123")
- **Usage**: Display, filtering

**`issue_youtrack_id`** (varchar, NOT NULL)
- **Purpose**: Parent issue's YouTrack internal ID
- **Usage**: Join key to `youtrack_issue` table

**`activity_id`** (varchar, NOT NULL)
- **Purpose**: YouTrack activity batch identifier
- **Note**: Multiple field changes in one operation share the same activity_id
- **Usage**: Grouping related changes

**`value_id`** (varchar, UNIQUE, NOT NULL)
- **Purpose**: Unique identifier for this specific value change
- **Usage**: Deduplication

### Change Details

**`author_youtrack_id`** (varchar, NOT NULL)
- **Purpose**: Who made the change
- **Usage**: Join key to `youtrack_user` table, attribution

**`field_id`** (varchar, NOT NULL)
- **Purpose**: Machine-readable field identifier
- **Examples**: "State", "Assignee", "Priority", "Type"
- **Usage**: Programmatic field identification

**`field_name`** (varchar, NOT NULL)
- **Purpose**: Human-readable field display name
- **Examples**: "State", "Assignee", "Priority", "Type"
- **Usage**: Display, field-based filtering

**`value`** (jsonb, NULLABLE)
- **Purpose**: The new value of the field after the change
- **Format**: JSON — can be string, object, array depending on field type
- **Examples**: `"In Progress"`, `{"name": "John Smith"}`, `["tag1", "tag2"]`
- **Usage**: State tracking, workflow analysis

**`index`** (int, NOT NULL)
- **Purpose**: Order index within an activity batch
- **Usage**: Ordering changes within the same activity

### Timestamps

**`created_at`** (timestamptz, NOT NULL)
- **Purpose**: When the change was made
- **Format**: Timestamp with timezone
- **Usage**: Time-series analysis, workflow timing

---

## Relationships

### Parent

**`youtrack_issue`**
- **Join**: `issue_youtrack_id` ← `youtrack_id`
- **Cardinality**: Many history records to one issue
- **Description**: All field changes belong to an issue

### Related

**`youtrack_user`**
- **Join**: `author_youtrack_id` ← `youtrack_id`
- **Cardinality**: Many history records to one author
- **Description**: Each change has an author

---

## Usage Examples

### State transitions for an issue

```sql
SELECT
    created_at,
    field_name,
    value,
    author_youtrack_id
FROM youtrack_issue_history
WHERE id_readable = 'MON-123'
  AND field_name = 'State'
ORDER BY created_at;
```

### Time in each state

```sql
WITH state_changes AS (
    SELECT
        id_readable,
        value::text as state,
        created_at,
        LEAD(created_at) OVER (PARTITION BY id_readable ORDER BY created_at) as next_change
    FROM youtrack_issue_history
    WHERE field_name = 'State'
)
SELECT
    id_readable,
    state,
    EXTRACT(EPOCH FROM (next_change - created_at)) / 3600 as hours_in_state
FROM state_changes
WHERE next_change IS NOT NULL
ORDER BY id_readable, created_at;
```

### Most active issue updaters

```sql
SELECT
    h.author_youtrack_id,
    u.full_name,
    COUNT(*) as change_count
FROM youtrack_issue_history h
LEFT JOIN youtrack_user u ON h.author_youtrack_id = u.youtrack_id
WHERE h.created_at >= '2026-01-01'
GROUP BY h.author_youtrack_id, u.full_name
ORDER BY change_count DESC
LIMIT 20;
```

### Recent priority changes

```sql
SELECT
    h.id_readable,
    h.value,
    h.created_at,
    u.full_name as changed_by
FROM youtrack_issue_history h
LEFT JOIN youtrack_user u ON h.author_youtrack_id = u.youtrack_id
WHERE h.field_name = 'Priority'
  AND h.created_at >= NOW() - INTERVAL '7 days'
ORDER BY h.created_at DESC;
```

---

## Notes and Considerations

### Value Format

The `value` field is JSONB and its structure depends on the field type:
- **Simple fields** (State, Priority): String value like `"In Progress"`
- **User fields** (Assignee): Object like `{"name": "John", "id": "1-5"}`
- **Multi-value fields** (Tags): Array like `["tag1", "tag2"]`

Always handle the varying JSON structure when extracting values.

### Activity Batching

Multiple field changes made in a single operation share the same `activity_id`. Use the `index` field to order changes within a batch.

### Comprehensive Indexing

The table is heavily indexed for common query patterns (by issue, by field, by time). Composite indexes like `(issue_youtrack_id, field_name, created_at)` are optimized for workflow analysis queries.
