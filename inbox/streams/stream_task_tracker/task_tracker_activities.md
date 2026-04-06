# Table: `task_tracker_activities`

## Overview

**Purpose**: Store issue activity history from task trackers as an append-only event stream. Each row represents a field change event — when a whitelisted field is modified, a new record is created containing the updated field value along with all other currently populated whitelisted fields for that issue type.

**Data Sources**:
- YouTrack: `source = "youtrack"`
- Jira: `source = "jira"`
- GitHub Issues: `source = "github"`

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | UInt64 | PRIMARY KEY | Auto-generated unique identifier |
| `source` | String | REQUIRED | Task tracker type: `youtrack`, `jira`, `github` |
| `insight_source_id` | String | REQUIRED | Unique identifier of the task tracker instance (e.g. `youtrack-acme-prod`, `jira-team-alpha`) |
| `event_date` | Date | REQUIRED | Date when the activity occurred |
| `event_author` | String | REQUIRED | Person who performed the activity |
| `activity_ref` | String | REQUIRED | Internal activity ID within the task tracker |
| `task_id` | String | REQUIRED | Human-readable issue key (e.g. `TASK-1`, `PROJ-42`) |
| `issue_ref` | String | REQUIRED | Internal issue ID within the task tracker |
| `type` | String | REQUIRED | Issue type (e.g. `User Story`, `Task`, `Bug`, `Epic`) |
| `created_date` | Date | REQUIRED | Date when the issue was originally created |
| `done_date` | Date | NULLABLE | Date when the issue transitioned to a terminal state |
| `state` | String | REQUIRED | Current issue state (e.g. `new`, `in progress`, `to verify`, `done`) |
| `parent_issue_ref` | String | NULLABLE | Internal ID of the parent issue (for hierarchy traversal) |
| `assignee` | String | NULLABLE | Person currently assigned to the issue |
| `title_version` | UInt32 | REQUIRED | Incremental version counter for title changes |
| `description_version` | UInt32 | REQUIRED | Incremental version counter for description changes |
| `fields_map` | Map(String, String) | REQUIRED | Key-value map of whitelisted custom fields and their current values |
| `collected_at` | DateTime64(3) | REQUIRED | Timestamp when the record was collected |
| `_version` | UInt64 | REQUIRED | Deduplication version for ReplacingMergeTree |

**Indexes**:
- `idx_issue_lookup`: `(source, insight_source_id, issue_ref)`
- `idx_event_date`: `(event_date)`
- `idx_task_id`: `(task_id)`
- `idx_parent`: `(parent_issue_ref)`

---

## Field Semantics

### Source Identification

**`source`** (String, REQUIRED)
- **Purpose**: Identifies the type of task tracker
- **Values**: `youtrack`, `jira`, `github`
- **Usage**: Filtering and source-specific logic

**`insight_source_id`** (String, REQUIRED)
- **Purpose**: Identifies the specific task tracker instance. A company may operate multiple instances of the same tracker type (e.g. several YouTrack installations).
- **Format**: Free-form string, recommended pattern: `{source}-{org}-{env}` (e.g. `youtrack-acme-prod`, `jira-team-alpha`)
- **Usage**: Multi-tenant queries, instance-level aggregation

### Event Context

**`event_date`** (Date, REQUIRED)
- **Purpose**: Date when the activity happened
- **Format**: `2026-01-02`
- **Usage**: Time-range filtering, timeline reconstruction

**`event_author`** (String, REQUIRED)
- **Purpose**: Person who triggered the activity (may differ from assignee)
- **Example**: `"PM 1"`, `"Dev 1"`, `"QA 1"`
- **Usage**: Tracking who makes changes, audit trail

**`activity_ref`** (String, REQUIRED)
- **Purpose**: Unique activity identifier within the task tracker
- **Format**: Tracker-specific (e.g. `"2-5"` in YouTrack)
- **Usage**: Deduplication, ordering events within a single issue

### Issue Identification

**`task_id`** (String, REQUIRED)
- **Purpose**: Human-readable issue key
- **Examples**: `"TASK-1"`, `"PROJ-42"`, `"BUG-100"`
- **Usage**: Display, cross-referencing with commit messages

**`issue_ref`** (String, REQUIRED)
- **Purpose**: Internal issue identifier within the task tracker
- **Format**: Tracker-specific (e.g. `"1-1"` in YouTrack)
- **Usage**: Stable reference for joins and hierarchy traversal

**`type`** (String, REQUIRED)
- **Purpose**: Issue type classification
- **Values**: `User Story`, `Task`, `Bug`, `Epic`, etc. (tracker-specific)
- **Usage**: Filtering by work type, metrics segmentation

### Issue State

**`created_date`** (Date, REQUIRED)
- **Purpose**: When the issue was originally created (immutable across events)
- **Usage**: Lead time calculations, issue age analysis

**`done_date`** (Date, NULLABLE)
- **Purpose**: When the issue reached a terminal/done state
- **Note**: NULL if issue is not yet completed
- **Usage**: Cycle time calculations, completion tracking

**`state`** (String, REQUIRED)
- **Purpose**: Issue state at the time of this event
- **Values**: `new`, `in progress`, `to verify`, `done` (tracker-specific)
- **Usage**: State transition analysis, workflow metrics

**`parent_issue_ref`** (String, NULLABLE)
- **Purpose**: Reference to the parent issue (using `issue_ref` format)
- **Note**: NULL for top-level issues (e.g. User Stories without a parent Epic)
- **Usage**: Hierarchy traversal, parent-child aggregation

**`assignee`** (String, NULLABLE)
- **Purpose**: Currently assigned person at the time of this event
- **Usage**: Workload analysis, assignment tracking

### Content Versioning

**`title_version`** (UInt32, REQUIRED)
- **Purpose**: Incremental counter tracking title changes
- **Behavior**: Starts at 0 on creation, increments by 1 on each title edit
- **Usage**: Detecting title churn, requirement volatility

**`description_version`** (UInt32, REQUIRED)
- **Purpose**: Incremental counter tracking description changes
- **Behavior**: Starts at 0 on creation, increments by 1 on each description edit
- **Usage**: Detecting scope creep, specification changes

### Custom Fields

**`fields_map`** (Map(String, String), REQUIRED)
- **Purpose**: Key-value store for whitelisted custom fields. Each issue type can have its own set of tracked fields. Only fields that are part of the whitelist for the given issue type are stored.
- **Format**: ClickHouse `Map(String, String)` — e.g. `{'sprints': '1', 'confidence in requirements': 'high', 'tags': 'ready for dev'}`
- **Behavior**: On each activity, the map contains the **full snapshot** of all populated whitelisted fields (not just the changed one)
- **Usage**: Custom field analysis, filtering by field values

### System Fields

**`collected_at`** (DateTime64(3), REQUIRED)
- **Purpose**: When the record was ingested into the system
- **Usage**: Data freshness tracking, debugging

**`_version`** (UInt64, REQUIRED)
- **Purpose**: Deduplication version for ReplacingMergeTree
- **Format**: Millisecond timestamp
- **Usage**: Ensures idempotent re-ingestion

---

## Relationships

### Parent (self-referencing)

**`task_tracker_activities`** (parent issue)
- **Join**: `parent_issue_ref` → `issue_ref` (within the same `source` and `insight_source_id`)
- **Cardinality**: Many child issues to one parent issue
- **Description**: Links child tasks/bugs to their parent User Story or Epic

---

## Data Model Concepts

### Event Stream Model

This table follows an **append-only event stream** pattern:

1. When an issue is created, the first record is inserted with all initial field values.
2. Each subsequent activity that modifies a whitelisted field produces a new row.
3. The new row contains the updated field **plus all other current whitelisted field values** — forming a complete snapshot at that point in time.
4. To get the current state of an issue, query the latest record by `activity_ref` or `event_date`.

### Whitelisted Fields

Not all fields are tracked. Only fields on a per-issue-type whitelist generate new activity records. Common whitelisted fields:

| Issue Type | Typical Whitelisted Fields |
|------------|---------------------------|
| User Story | `sprints`, `confidence in requirements`, `tags` |
| Task | `confidence in implementation` |
| Bug | `severity`, `root cause` |

### Hierarchy

Issues form a tree via `parent_issue_ref`:
```
Epic
  └── User Story
        ├── Task
        ├── Task
        └── Bug
```

---

## Usage Examples

### 1. All issues created by a specific person within a time range

```sql
SELECT
    task_id,
    type,
    state,
    created_date,
    fields_map
FROM task_tracker_activities
WHERE source = 'youtrack'
  AND insight_source_id = 'youtrack-acme-prod'
  AND event_author = 'Dev 1'
  AND created_date >= '2026-01-01'
  AND created_date < '2026-02-01'
  -- first activity per issue = creation event
  AND title_version = 0
  AND description_version = 0
ORDER BY created_date;
```

### 2. All tasks belonging to a specific User Story

```sql
-- Step 1: find the issue_ref of the target User Story
-- Step 2: query all children

SELECT
    task_id,
    type,
    state,
    assignee,
    event_date,
    fields_map
FROM task_tracker_activities
WHERE source = 'youtrack'
  AND insight_source_id = 'youtrack-acme-prod'
  AND parent_issue_ref = '1-1'  -- issue_ref of the target User Story
ORDER BY task_id, event_date;
```

To get only the **latest state** of each child issue:

```sql
SELECT
    task_id,
    type,
    state,
    assignee,
    done_date,
    fields_map
FROM task_tracker_activities
WHERE source = 'youtrack'
  AND insight_source_id = 'youtrack-acme-prod'
  AND parent_issue_ref = '1-1'
ORDER BY task_id, event_date DESC
LIMIT 1 BY task_id;
```

### 3. User Stories that have child issues of type Bug

```sql
-- Find User Stories whose children include at least one Bug
SELECT DISTINCT
    parent.task_id AS user_story_id,
    parent.state AS user_story_state,
    parent.assignee AS user_story_assignee
FROM task_tracker_activities AS child
INNER JOIN (
    SELECT
        task_id,
        issue_ref,
        state,
        assignee
    FROM task_tracker_activities
    WHERE source = 'youtrack'
      AND insight_source_id = 'youtrack-acme-prod'
      AND type = 'User Story'
    ORDER BY issue_ref, event_date DESC
    LIMIT 1 BY issue_ref
) AS parent
    ON child.parent_issue_ref = parent.issue_ref
WHERE child.source = 'youtrack'
  AND child.insight_source_id = 'youtrack-acme-prod'
  AND child.type = 'Bug';
```

### 4. User Stories with children NOT in a terminal state (not `done` and not `new`)

```sql
-- User Stories that have at least one child in an active (non-terminal) state
SELECT DISTINCT
    parent.task_id AS user_story_id,
    parent.state AS user_story_state
FROM (
    -- latest state of each child issue
    SELECT
        issue_ref,
        parent_issue_ref,
        state,
        source,
        insight_source_id
    FROM task_tracker_activities
    WHERE source = 'youtrack'
      AND insight_source_id = 'youtrack-acme-prod'
      AND parent_issue_ref != ''
    ORDER BY issue_ref, event_date DESC
    LIMIT 1 BY issue_ref
) AS child
INNER JOIN (
    -- latest state of each User Story
    SELECT
        task_id,
        issue_ref,
        state
    FROM task_tracker_activities
    WHERE source = 'youtrack'
      AND insight_source_id = 'youtrack-acme-prod'
      AND type = 'User Story'
    ORDER BY issue_ref, event_date DESC
    LIMIT 1 BY issue_ref
) AS parent
    ON child.parent_issue_ref = parent.issue_ref
WHERE child.state NOT IN ('done', 'new');
```

---

## Notes and Considerations

### fields_map Usage

Access individual fields from the map using ClickHouse map syntax:

```sql
-- Filter by a custom field value
SELECT task_id, fields_map['confidence in requirements'] AS confidence
FROM task_tracker_activities
WHERE fields_map['confidence in requirements'] = 'high';

-- Check if a field exists
SELECT task_id
FROM task_tracker_activities
WHERE mapContains(fields_map, 'sprints');
```

### Getting Current Issue State

Since this is an event stream, always use `LIMIT 1 BY` or a subquery to get the latest record:

```sql
SELECT *
FROM task_tracker_activities
WHERE source = 'youtrack'
  AND insight_source_id = 'youtrack-acme-prod'
ORDER BY issue_ref, event_date DESC
LIMIT 1 BY issue_ref;
```

### Multi-Instance Queries

When querying across multiple tracker instances, always include `source` and `insight_source_id` in filters and joins to avoid cross-contamination:

```sql
SELECT source, insight_source_id, COUNT(DISTINCT issue_ref) AS issue_count
FROM task_tracker_activities
GROUP BY source, insight_source_id;
```

### Performance Considerations

- Use `(source, insight_source_id, issue_ref)` index for issue lookups
- Use `(event_date)` index for time-range scans
- `LIMIT 1 BY` is efficient in ClickHouse for "latest per group" queries
- The `_version` field with `ReplacingMergeTree` ensures idempotent re-ingestion; use `FINAL` for guaranteed deduplication
