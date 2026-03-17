# Table: `git.repo`

## Overview

**Purpose**: Store GitLab repository metadata including project IDs, paths, namespace information, and activity timestamps.

**Data Source**: GitLab API via custom git service

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | integer | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `gitlab_repo_id` | integer | UNIQUE, NOT NULL | GitLab project ID |
| `path` | varchar(500) | NOT NULL | Repository path (e.g., group/project) |
| `kind` | varchar(20) | NULLABLE | GitLab namespace kind: "user" or "group" |
| `last_activity_at` | timestamp | NULLABLE | Last activity from GitLab API |
| `created_at` | timestamp | DEFAULT CURRENT_TIMESTAMP | Record creation timestamp |

**Indexes**:
- `gitlab_repo_id` — unique repository lookup
- `path` — path-based search
- `last_activity_at` — activity-based filtering
- `kind` — namespace type filtering

---

## Field Semantics

### Core Identifiers

**`id`** (integer, PRIMARY KEY)
- **Purpose**: Internal auto-increment primary key
- **Usage**: Internal references, not exposed externally

**`gitlab_repo_id`** (integer, UNIQUE, NOT NULL)
- **Purpose**: GitLab project ID from the API
- **Format**: Integer (e.g., 42, 1567)
- **Usage**: Primary business key, foreign key reference for other tables

**`path`** (varchar(500), NOT NULL)
- **Purpose**: Full repository path in GitLab
- **Format**: "namespace/project" or "group/subgroup/project"
- **Examples**: "platform/backend", "tools/ci-scripts"
- **Usage**: Repository identification, display

### Metadata

**`kind`** (varchar(20), NULLABLE)
- **Purpose**: GitLab namespace kind
- **Values**: "user" (personal projects), "group" (organization projects)
- **Note**: Only group repos have commits synced
- **Usage**: Filtering personal vs organizational repositories

**`last_activity_at`** (timestamp, NULLABLE)
- **Purpose**: Last activity timestamp from GitLab API
- **Format**: PostgreSQL timestamp
- **Usage**: Activity tracking, incremental sync optimization

### System Fields

**`created_at`** (timestamp, DEFAULT CURRENT_TIMESTAMP)
- **Purpose**: When this record was created in our system
- **Usage**: Audit trail

---

## Relationships

### Parent Of

**`git.commit`**
- **Join**: `gitlab_repo_id` → `repo_id`
- **Cardinality**: One repository to many commits
- **Description**: All commits belong to a repository

**`git.branch`**
- **Join**: `gitlab_repo_id` → `repo_id`
- **Cardinality**: One repository to many branches
- **On Delete**: CASCADE

**`git.file`**
- **Join**: `gitlab_repo_id` → `repo_id`
- **Cardinality**: One repository to many files
- **On Delete**: CASCADE

**`git.loc`**
- **Join**: `gitlab_repo_id` → `repo_id`
- **Cardinality**: One repository to many LOC snapshots
- **On Delete**: CASCADE

---

## Usage Examples

### List all group repositories

```sql
SELECT gitlab_repo_id, path, last_activity_at
FROM git.repo
WHERE kind = 'group'
ORDER BY last_activity_at DESC;
```

### Find recently active repositories

```sql
SELECT path, last_activity_at
FROM git.repo
WHERE last_activity_at > NOW() - INTERVAL '30 days'
ORDER BY last_activity_at DESC;
```

### Repository count by namespace kind

```sql
SELECT
    kind,
    COUNT(*) as repo_count
FROM git.repo
GROUP BY kind;
```

---

## Notes and Considerations

### Personal vs Group Repositories

The `kind` field distinguishes between personal ("user") and organizational ("group") repositories. **Only group repositories have commits synced** — personal projects are tracked but not actively collected.

### GitLab Repo ID as Business Key

Other tables reference repositories via `gitlab_repo_id` (not the internal `id`), making it the primary business key for cross-table joins.
