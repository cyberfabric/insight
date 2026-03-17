# Table: `git.num_stat`

## Overview

**Purpose**: Store per-file line change statistics for each commit, representing the output of `git numstat` — lines added and removed per file per commit.

**Data Source**: Git numstat output collected via GitLab API

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | integer | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `commit_id` | bigint | NOT NULL | References commit.id |
| `file_id` | integer | NOT NULL | References file.id |
| `added` | integer | DEFAULT 0 | Lines added |
| `removed` | integer | DEFAULT 0 | Lines removed |

**Indexes**:
- `(commit_id, file_id)` — UNIQUE, one record per file per commit
- `commit_id` — commit-based lookup
- `file_id` — file-based lookup
- `(file_id, added)` — file change statistics

---

## Field Semantics

### Core Identifiers

**`id`** (integer, PRIMARY KEY)
- **Purpose**: Internal auto-increment key
- **Usage**: Internal references

**`commit_id`** (bigint, NOT NULL)
- **Purpose**: Reference to the parent commit
- **References**: `git.commit.id`
- **Usage**: Join key to commit details

**`file_id`** (integer, NOT NULL)
- **Purpose**: Reference to the file
- **References**: `git.file.id`
- **Usage**: Join key to file path

### Change Statistics

**`added`** (integer, DEFAULT 0)
- **Purpose**: Number of lines added to the file in this commit
- **Format**: Non-negative integer
- **Examples**: 0, 15, 200
- **Usage**: Code churn metrics, developer productivity

**`removed`** (integer, DEFAULT 0)
- **Purpose**: Number of lines removed from the file in this commit
- **Format**: Non-negative integer
- **Examples**: 0, 5, 100
- **Usage**: Code churn metrics, refactoring detection

---

## Relationships

### Parents

**`git.commit`**
- **Join**: `commit_id` ← `id`
- **Cardinality**: Many numstat records to one commit
- **On Delete**: CASCADE

**`git.file`**
- **Join**: `file_id` ← `id`
- **Cardinality**: Many numstat records to one file
- **On Delete**: CASCADE

---

## Usage Examples

### File changes in a specific commit

```sql
SELECT
    f.path,
    ns.added,
    ns.removed
FROM git.num_stat ns
JOIN git.file f ON ns.file_id = f.id
JOIN git.commit c ON ns.commit_id = c.id
WHERE c.hash = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'
ORDER BY ns.added + ns.removed DESC;
```

### Most changed files in a repository

```sql
SELECT
    f.path,
    COUNT(*) as change_count,
    SUM(ns.added) as total_added,
    SUM(ns.removed) as total_removed
FROM git.num_stat ns
JOIN git.file f ON ns.file_id = f.id
WHERE f.repo_id = 42
GROUP BY f.path
ORDER BY change_count DESC
LIMIT 20;
```

### Developer churn by file type

```sql
SELECT
    SUBSTRING(f.path FROM '\.([^.]+)$') as extension,
    SUM(ns.added) as lines_added,
    SUM(ns.removed) as lines_removed,
    COUNT(DISTINCT ns.commit_id) as commits
FROM git.num_stat ns
JOIN git.file f ON ns.file_id = f.id
JOIN git.commit c ON ns.commit_id = c.id
WHERE c.created_at >= '2026-01-01'
GROUP BY extension
ORDER BY lines_added + lines_removed DESC;
```

### Daily code churn

```sql
SELECT
    DATE(c.created_at) as day,
    SUM(ns.added) as added,
    SUM(ns.removed) as removed,
    COUNT(DISTINCT c.id) as commits
FROM git.num_stat ns
JOIN git.commit c ON ns.commit_id = c.id
WHERE c.created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE(c.created_at)
ORDER BY day DESC;
```

---

## Notes and Considerations

### Git Numstat

This table mirrors `git diff --numstat` output. Binary files may show 0 for both added and removed. Renamed files appear as a remove from the old path and add to the new path.

### Granularity

Each row represents one file's changes in one commit. To get total commit statistics, aggregate across all files for a given `commit_id`.

### CASCADE Deletes

Records are automatically removed when the parent commit or file is deleted, maintaining referential integrity.
