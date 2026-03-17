# Table: `git.author`

## Overview

**Purpose**: Store unique commit authors identified by normalized name and email combinations. Supports case-insensitive deduplication via generated columns.

**Data Source**: Extracted from git commit metadata via GitLab API

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | integer | PRIMARY KEY, AUTO INCREMENT | Auto-increment primary key |
| `name` | varchar(255) | NULLABLE | Original author name (preserves case) |
| `email` | varchar(255) | NULLABLE | Original author email (preserves case) |
| `name_lower` | varchar(255) | GENERATED | COALESCE(LOWER(name), '') |
| `email_lower` | varchar(255) | GENERATED | COALESCE(LOWER(email), '') |
| `created_at` | timestamp | DEFAULT CURRENT_TIMESTAMP | Record creation timestamp |

**Indexes**:
- `(name_lower, email_lower)` — UNIQUE, normalized author lookup
- `email_lower` — fast email-based lookup

---

## Field Semantics

### Core Identifiers

**`id`** (integer, PRIMARY KEY)
- **Purpose**: Auto-increment primary key
- **Usage**: Foreign key in `git.commit` table

**`name`** (varchar(255), NULLABLE)
- **Purpose**: Original author name as it appears in git commits
- **Format**: Free-text, preserves original case
- **Examples**: "John Smith", "john.smith", "J. Smith"
- **Note**: Can be NULL for commits with missing author info

**`email`** (varchar(255), NULLABLE)
- **Purpose**: Original author email from git commits
- **Format**: Email address, preserves original case
- **Examples**: "john.smith@company.com", "John.Smith@Company.COM"
- **Note**: Can be NULL for commits with missing email

### Generated Columns

**`name_lower`** (varchar(255), GENERATED)
- **Purpose**: Lowercase normalized name for deduplication
- **Formula**: `COALESCE(LOWER(name), '')`
- **Usage**: Part of unique constraint to prevent case-variant duplicates

**`email_lower`** (varchar(255), GENERATED)
- **Purpose**: Lowercase normalized email for deduplication
- **Formula**: `COALESCE(LOWER(email), '')`
- **Usage**: Part of unique constraint, fast email lookups

### System Fields

**`created_at`** (timestamp, DEFAULT CURRENT_TIMESTAMP)
- **Purpose**: When the author record was first created
- **Usage**: Audit trail

---

## Relationships

### Parent Of

**`git.commit`**
- **Join**: `id` → `author_id`
- **Cardinality**: One author to many commits
- **Description**: Each commit has exactly one author

---

## Usage Examples

### Find author by email

```sql
SELECT id, name, email
FROM git.author
WHERE email_lower = 'john.smith@company.com';
```

### Most active authors by commit count

```sql
SELECT
    a.name,
    a.email,
    COUNT(c.id) as commit_count
FROM git.author a
JOIN git.commit c ON a.id = c.author_id
GROUP BY a.id, a.name, a.email
ORDER BY commit_count DESC
LIMIT 20;
```

### Find duplicate authors (same email, different names)

```sql
SELECT
    email_lower,
    ARRAY_AGG(DISTINCT name) as names,
    COUNT(DISTINCT name) as name_variants
FROM git.author
WHERE email_lower != ''
GROUP BY email_lower
HAVING COUNT(DISTINCT name) > 1;
```

---

## Notes and Considerations

### Case-Insensitive Deduplication

The unique constraint on `(name_lower, email_lower)` ensures that "John.Smith" with "john@co.com" and "john.smith" with "John@CO.com" are treated as the same author. Original case is preserved in `name` and `email` fields.

### NULL Handling

Both `name` and `email` can be NULL. The `COALESCE` in generated columns converts NULL to empty string for the unique constraint, ensuring that authors with NULL name or email are still properly deduplicated.
