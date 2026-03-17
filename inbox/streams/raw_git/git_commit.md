# Table: `git.commit`

## Overview

**Purpose**: Store git commit history from all branches in monitored GitLab repositories, including commit metadata, author references, and task ID extraction.

**Data Source**: GitLab API via custom git service

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigint | PRIMARY KEY, AUTO INCREMENT | Auto-increment primary key |
| `hash` | varchar(40) | NOT NULL | Git commit SHA |
| `repo_id` | integer | NOT NULL | References repo.gitlab_repo_id |
| `author_id` | integer | NOT NULL | References author.id |
| `parents` | text[] | NULLABLE | Parent commit hashes |
| `message` | text | NULLABLE | Full multi-line commit message |
| `task_id` | varchar(50) | NULLABLE | Extracted task ID (e.g., MON-123) |
| `default_branch` | boolean | DEFAULT false | True if commit exists in default branch |
| `created_at` | timestamp | NOT NULL | Commit timestamp |

**Indexes**:
- `(repo_id, hash)` — UNIQUE, commit lookup within repo
- `hash` — cross-repo commit search
- `repo_id` — repository-based filtering
- `author_id` — author-based filtering
- `task_id` — task reference lookup
- `default_branch` — default branch filtering
- `created_at` — time-range queries
- `(repo_id, created_at)` — date-range queries within repo
- `(author_id, created_at)` — author activity over time

---

## Field Semantics

### Core Identifiers

**`id`** (bigint, PRIMARY KEY)
- **Purpose**: Auto-increment primary key
- **Usage**: Foreign key reference in `git.num_stat`

**`hash`** (varchar(40), NOT NULL)
- **Purpose**: Git commit SHA-1 hash
- **Format**: 40-character hexadecimal string
- **Example**: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
- **Usage**: Commit identification, cross-repo duplicate detection

**`repo_id`** (integer, NOT NULL)
- **Purpose**: Reference to the parent repository
- **References**: `git.repo.gitlab_repo_id`
- **Usage**: Join key to repository

**`author_id`** (integer, NOT NULL)
- **Purpose**: Reference to the commit author
- **References**: `git.author.id`
- **Usage**: Join key to author

### Commit Content

**`message`** (text, NULLABLE)
- **Purpose**: Full commit message text
- **Format**: Multi-line text
- **Examples**: "MON-123 fix user authentication", "Merge branch 'feature/auth'"
- **Usage**: Search, task extraction, commit analysis

**`task_id`** (varchar(50), NULLABLE)
- **Purpose**: Task/issue ID extracted from commit message
- **Format**: Typically "PROJECT-123" pattern
- **Examples**: "MON-123", "PLAT-456"
- **Usage**: Linking commits to task tracker issues

**`parents`** (text[], NULLABLE)
- **Purpose**: Array of parent commit hashes
- **Format**: PostgreSQL text array
- **Examples**: `{"a1b2c3..."}` (regular commit), `{"a1b2c3...", "d4e5f6..."}` (merge commit)
- **Usage**: Commit graph traversal, merge detection

### Branch Info

**`default_branch`** (boolean, DEFAULT false)
- **Purpose**: Whether this commit exists in the default branch
- **Values**: true (on default branch), false (other branches only)
- **Usage**: Filtering for main development line, excluding feature branch noise

### Timestamps

**`created_at`** (timestamp, NOT NULL)
- **Purpose**: Commit timestamp (author date)
- **Format**: PostgreSQL timestamp
- **Usage**: Time-series analysis, ordering, filtering

---

## Relationships

### Parents

**`git.repo`**
- **Join**: `repo_id` ← `gitlab_repo_id`
- **Cardinality**: Many commits to one repository
- **On Delete**: CASCADE

**`git.author`**
- **Join**: `author_id` ← `id`
- **Cardinality**: Many commits to one author

### Children

**`git.num_stat`**
- **Join**: `id` → `commit_id`
- **Cardinality**: One commit to many numstat records
- **Description**: Per-file line changes for this commit

---

## Usage Examples

### Recent commits on default branch

```sql
SELECT
    c.hash,
    a.name as author,
    c.message,
    c.created_at
FROM git.commit c
JOIN git.author a ON c.author_id = a.id
WHERE c.default_branch = true
  AND c.created_at > NOW() - INTERVAL '7 days'
ORDER BY c.created_at DESC
LIMIT 50;
```

### Commits by task ID

```sql
SELECT
    c.hash,
    a.name as author,
    c.message,
    r.path as repo,
    c.created_at
FROM git.commit c
JOIN git.author a ON c.author_id = a.id
JOIN git.repo r ON c.repo_id = r.gitlab_repo_id
WHERE c.task_id = 'MON-123'
ORDER BY c.created_at;
```

### Developer commit statistics

```sql
SELECT
    a.name,
    a.email,
    COUNT(*) as commit_count,
    MIN(c.created_at) as first_commit,
    MAX(c.created_at) as last_commit
FROM git.commit c
JOIN git.author a ON c.author_id = a.id
WHERE c.created_at >= '2026-01-01'
  AND c.default_branch = true
GROUP BY a.id, a.name, a.email
ORDER BY commit_count DESC
LIMIT 20;
```

### Find merge commits

```sql
SELECT
    c.hash,
    a.name as author,
    c.message,
    c.created_at
FROM git.commit c
JOIN git.author a ON c.author_id = a.id
WHERE array_length(c.parents, 1) > 1
  AND c.default_branch = true
ORDER BY c.created_at DESC;
```

---

## Notes and Considerations

### Task ID Extraction

The `task_id` field is automatically extracted from commit messages using pattern matching (e.g., "MON-123" from "MON-123 fix bug"). This enables linking commits to YouTrack/Jira issues without manual tagging.

### Default Branch Flag

The `default_branch` flag helps focus analytics on the main development line. Commits from feature branches that haven't been merged may represent work-in-progress and are typically excluded from productivity metrics.

### Cross-Repository Commits

The same commit hash can appear in different repositories (forks). The `hash` index enables finding the same commit across repos, while `(repo_id, hash)` uniquely identifies a commit within a specific repository.
