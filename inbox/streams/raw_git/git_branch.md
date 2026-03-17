# Table: `git.branch`

## Overview

**Purpose**: Track git branches in repositories, including default branch identification and sync status for incremental collection.

**Data Source**: GitLab API via custom git service

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | integer | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `repo_id` | integer | NOT NULL | References repo.gitlab_repo_id |
| `name` | varchar(500) | NOT NULL | Branch name |
| `is_default` | boolean | DEFAULT false | True if this is the default branch |
| `last_commit_hash` | varchar(40) | NULLABLE | Last known commit hash on this branch |
| `last_synced_at` | timestamp | NULLABLE | When this branch was last synced |
| `created_at` | timestamp | DEFAULT CURRENT_TIMESTAMP | Record creation timestamp |

**Indexes**:
- `(repo_id, name)` — UNIQUE, branch lookup within repo
- `repo_id` — repository-based filtering
- `is_default` — default branch queries

---

## Field Semantics

### Core Identifiers

**`id`** (integer, PRIMARY KEY)
- **Purpose**: Internal auto-increment key
- **Usage**: Internal references

**`repo_id`** (integer, NOT NULL)
- **Purpose**: Reference to the parent repository
- **References**: `git.repo.gitlab_repo_id`
- **Usage**: Join key to repository

**`name`** (varchar(500), NOT NULL)
- **Purpose**: Branch name
- **Examples**: "main", "develop", "feature/auth-v2", "release/1.5"
- **Usage**: Branch identification, filtering

### Branch Status

**`is_default`** (boolean, DEFAULT false)
- **Purpose**: Whether this is the repository's default branch
- **Values**: true (default branch, typically "main" or "master"), false
- **Usage**: Filtering for default branch commits, identifying primary development line

**`last_commit_hash`** (varchar(40), NULLABLE)
- **Purpose**: Last known commit SHA on this branch
- **Format**: 40-character git SHA-1 hash
- **Usage**: Incremental sync — detect new commits since last sync

**`last_synced_at`** (timestamp, NULLABLE)
- **Purpose**: When this branch was last synchronized
- **Usage**: Incremental collection scheduling, staleness detection

### System Fields

**`created_at`** (timestamp, DEFAULT CURRENT_TIMESTAMP)
- **Purpose**: Record creation timestamp
- **Usage**: Audit trail

---

## Relationships

### Parent

**`git.repo`**
- **Join**: `repo_id` ← `gitlab_repo_id`
- **Cardinality**: Many branches to one repository
- **On Delete**: CASCADE

---

## Usage Examples

### List default branches

```sql
SELECT r.path, b.name, b.last_synced_at
FROM git.branch b
JOIN git.repo r ON b.repo_id = r.gitlab_repo_id
WHERE b.is_default = true
ORDER BY b.last_synced_at DESC;
```

### Find stale branches (not synced recently)

```sql
SELECT r.path, b.name, b.last_synced_at
FROM git.branch b
JOIN git.repo r ON b.repo_id = r.gitlab_repo_id
WHERE b.last_synced_at < NOW() - INTERVAL '7 days'
   OR b.last_synced_at IS NULL
ORDER BY b.last_synced_at ASC NULLS FIRST;
```

### Branch count per repository

```sql
SELECT
    r.path,
    COUNT(*) as branch_count
FROM git.branch b
JOIN git.repo r ON b.repo_id = r.gitlab_repo_id
GROUP BY r.path
ORDER BY branch_count DESC;
```

---

## Notes and Considerations

### Incremental Sync

The `last_commit_hash` and `last_synced_at` fields enable efficient incremental collection. On each sync, only commits after `last_commit_hash` are fetched, avoiding re-processing of already collected data.

### CASCADE Delete

Branches are deleted when their parent repository is removed, ensuring referential integrity.
