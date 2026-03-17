# Table: `git.loc`

## Overview

**Purpose**: Store daily lines-of-code (LOC) snapshots for files in tracked repositories, enabling LOC trend analysis over time.

**Data Source**: Computed from repository file contents at default branch HEAD

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | integer | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `repo_id` | integer | NOT NULL | References repo.gitlab_repo_id |
| `file_id` | integer | NOT NULL | References file.id |
| `loc` | integer | NOT NULL | Lines of code count (0 for deleted/binary files) |
| `snapshot_date` | date | NOT NULL | UTC date for daily LOC snapshot |
| `commit_id` | integer | NOT NULL | Default branch HEAD commit at snapshot time |
| `created_at` | timestamp | NOT NULL, DEFAULT CURRENT_TIMESTAMP | Snapshot timestamp |

**Indexes**:
- `(repo_id, file_id, snapshot_date)` — UNIQUE, one LOC row per file per day
- `repo_id` — repository filtering
- `file_id` — file filtering
- `snapshot_date` — date-based queries
- `(repo_id, snapshot_date)` — daily snapshot queries by repo
- `created_at` — chronological ordering
- `(file_id, created_at)` — latest LOC per file queries
- `(repo_id, created_at)` — LOC history per repo

---

## Field Semantics

### Core Identifiers

**`id`** (integer, PRIMARY KEY)
- **Purpose**: Internal auto-increment key

**`repo_id`** (integer, NOT NULL)
- **Purpose**: Reference to the parent repository
- **References**: `git.repo.gitlab_repo_id`
- **Usage**: Join key to repository

**`file_id`** (integer, NOT NULL)
- **Purpose**: Reference to the file
- **References**: `git.file.id`
- **Usage**: Join key to file path

**`commit_id`** (integer, NOT NULL)
- **Purpose**: The default branch HEAD commit at the time of snapshot
- **References**: `git.commit.id`
- **Usage**: Tracking which code version was measured

### Metrics

**`loc`** (integer, NOT NULL)
- **Purpose**: Lines of code in the file
- **Format**: Non-negative integer
- **Values**: 0 for deleted or binary files, positive for text files
- **Usage**: Codebase size tracking, growth analysis

### Time

**`snapshot_date`** (date, NOT NULL)
- **Purpose**: The date this LOC snapshot was taken
- **Format**: UTC date (YYYY-MM-DD)
- **Usage**: Time-series analysis, daily snapshots

**`created_at`** (timestamp, NOT NULL)
- **Purpose**: Exact time the snapshot was created
- **Usage**: Ordering, freshness tracking

---

## Relationships

### Parents

**`git.repo`**
- **Join**: `repo_id` ← `gitlab_repo_id`
- **On Delete**: CASCADE

**`git.file`**
- **Join**: `file_id` ← `id`
- **On Delete**: CASCADE

**`git.commit`**
- **Join**: `commit_id` ← `id`
- **On Delete**: CASCADE

---

## Usage Examples

### Total LOC per repository over time

```sql
SELECT
    r.path,
    l.snapshot_date,
    SUM(l.loc) as total_loc
FROM git.loc l
JOIN git.repo r ON l.repo_id = r.gitlab_repo_id
GROUP BY r.path, l.snapshot_date
ORDER BY r.path, l.snapshot_date;
```

### LOC by file extension

```sql
SELECT
    SUBSTRING(f.path FROM '\.([^.]+)$') as extension,
    SUM(l.loc) as total_loc,
    COUNT(DISTINCT f.id) as file_count
FROM git.loc l
JOIN git.file f ON l.file_id = f.id
WHERE l.snapshot_date = CURRENT_DATE
GROUP BY extension
ORDER BY total_loc DESC;
```

### LOC growth trend (last 30 days)

```sql
SELECT
    l.snapshot_date,
    SUM(l.loc) as total_loc
FROM git.loc l
WHERE l.repo_id = 42
  AND l.snapshot_date >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY l.snapshot_date
ORDER BY l.snapshot_date;
```

### Largest files in repository

```sql
SELECT
    f.path,
    l.loc
FROM git.loc l
JOIN git.file f ON l.file_id = f.id
WHERE l.repo_id = 42
  AND l.snapshot_date = (SELECT MAX(snapshot_date) FROM git.loc WHERE repo_id = 42)
  AND l.loc > 0
ORDER BY l.loc DESC
LIMIT 20;
```

---

## Notes and Considerations

### Daily Snapshots

LOC is captured once per day per file. The unique constraint `(repo_id, file_id, snapshot_date)` ensures exactly one measurement per file per day.

### Zero LOC

A LOC value of 0 indicates either a deleted file or a binary file. To get accurate codebase size, filter where `loc > 0`.

### Snapshot Consistency

Each snapshot references the `commit_id` (HEAD of default branch at snapshot time), ensuring the LOC measurement can be correlated with a specific code version.
