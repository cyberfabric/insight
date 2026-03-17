# Table: `youtrack_user`

## Overview

**Purpose**: Store YouTrack user profiles including identifiers, contact information, and display names.

**Data Source**: YouTrack REST API — Users endpoint

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | int | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `youtrack_id` | varchar | NOT NULL, UNIQUE | YouTrack internal user ID |
| `email` | varchar | UNIQUE, NULLABLE | User email address |
| `full_name` | varchar | NOT NULL | User full name |
| `username` | varchar | NOT NULL, UNIQUE | YouTrack username |

---

## Field Semantics

### Core Identifiers

**`id`** (int, PRIMARY KEY)
- **Purpose**: Internal auto-increment key
- **Usage**: Internal references

**`youtrack_id`** (varchar, UNIQUE, NOT NULL)
- **Purpose**: YouTrack internal user identifier
- **Format**: Alphanumeric string (e.g., "1-5", "2-123")
- **Usage**: Join key for issue history, API operations

**`username`** (varchar, UNIQUE, NOT NULL)
- **Purpose**: YouTrack login username
- **Examples**: "john.smith", "admin"
- **Usage**: User identification, display

### Contact Information

**`email`** (varchar, UNIQUE, NULLABLE)
- **Purpose**: User email address
- **Format**: Standard email format
- **Note**: Can be NULL if not set or not visible
- **Usage**: Cross-system user correlation (with git authors, MS365 users, etc.)

**`full_name`** (varchar, NOT NULL)
- **Purpose**: User's full display name
- **Examples**: "John Smith", "Jane Doe"
- **Usage**: Display, reporting

---

## Relationships

### Parent Of

**`youtrack_issue_history`** (via author_youtrack_id)
- **Join**: `youtrack_id` → `author_youtrack_id`
- **Cardinality**: One user to many history records
- **Description**: User as the author of issue changes

---

## Usage Examples

### Find user by email

```sql
SELECT youtrack_id, full_name, username
FROM youtrack_user
WHERE email = 'john.smith@company.com';
```

### All users with their activity count

```sql
SELECT
    u.full_name,
    u.email,
    COUNT(h.id) as changes_made
FROM youtrack_user u
LEFT JOIN youtrack_issue_history h ON u.youtrack_id = h.author_youtrack_id
GROUP BY u.id, u.full_name, u.email
ORDER BY changes_made DESC;
```

### Cross-system user correlation

```sql
SELECT
    u.full_name,
    u.email,
    a.name as git_name,
    a.email as git_email
FROM youtrack_user u
LEFT JOIN git.author a ON LOWER(u.email) = a.email_lower
WHERE u.email IS NOT NULL;
```

---

## Notes and Considerations

### Email Availability

The `email` field may be NULL for users who haven't set their email or where it's not visible via the API. Use `username` or `youtrack_id` as fallback identifiers.

### Cross-System Identity

The `email` field is the primary key for correlating YouTrack users with identities in other systems (git authors, MS365 users, Zulip users). Identity resolution across systems should use case-insensitive email matching.
