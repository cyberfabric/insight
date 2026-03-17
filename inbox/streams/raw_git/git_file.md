# Table: `git.file`

## Overview

**Purpose**: Store all file paths that have ever existed in tracked repositories, serving as a normalized lookup table for file-level metrics.

**Data Source**: Extracted from git commit diffs via GitLab API

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | integer | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `repo_id` | integer | NOT NULL | References repo.gitlab_repo_id |
| `path` | text | NOT NULL | File path within repository |
| `created_at` | timestamp | DEFAULT CURRENT_TIMESTAMP | Record creation timestamp |

**Indexes**:
- `(repo_id, path)` — UNIQUE, file lookup within repo
- `repo_id` — repository-based filtering

---

## Field Semantics

### Core Identifiers

**`id`** (integer, PRIMARY KEY)
- **Purpose**: Internal auto-increment key
- **Usage**: Foreign key reference in `git.num_stat` and `git.loc` tables

**`repo_id`** (integer, NOT NULL)
- **Purpose**: Reference to the parent repository
- **References**: `git.repo.gitlab_repo_id`
- **Usage**: Join key to repository

**`path`** (text, NOT NULL)
- **Purpose**: Full file path within the repository
- **Examples**: "src/main.ts", "README.md", "packages/core/lib/utils.js"
- **Usage**: File identification, path-based filtering and grouping

### System Fields

**`created_at`** (timestamp, DEFAULT CURRENT_TIMESTAMP)
- **Purpose**: When the file was first seen
- **Usage**: Tracking when files were introduced

---

## Relationships

### Parent

**`git.repo`**
- **Join**: `repo_id` ← `gitlab_repo_id`
- **Cardinality**: Many files to one repository
- **On Delete**: CASCADE

### Children

**`git.num_stat`**
- **Join**: `id` → `file_id`
- **Cardinality**: One file to many numstat records
- **Description**: Per-commit line changes for this file

**`git.loc`**
- **Join**: `id` → `file_id`
- **Cardinality**: One file to many LOC snapshots
- **Description**: Daily lines-of-code snapshots for this file

---

## Usage Examples

### List all files in a repository

```sql
SELECT path
FROM git.file
WHERE repo_id = 42
ORDER BY path;
```

### Find files by extension

```sql
SELECT f.path, r.path as repo_path
FROM git.file f
JOIN git.repo r ON f.repo_id = r.gitlab_repo_id
WHERE f.path LIKE '%.ts'
ORDER BY f.path;
```

### Count files per repository

```sql
SELECT
    r.path as repo_path,
    COUNT(*) as file_count
FROM git.file f
JOIN git.repo r ON f.repo_id = r.gitlab_repo_id
GROUP BY r.path
ORDER BY file_count DESC;
```

---

## Notes and Considerations

### Historical File Tracking

This table contains **all files that have ever existed** in a repository, including deleted files. A file being present in this table does not mean it currently exists in the repository.

### Normalized Design

File paths are normalized into this lookup table to avoid storing full paths repeatedly in `git.num_stat` and `git.loc` tables, reducing storage and enabling efficient file-based queries.
