# Table: `zulip_users`

## Overview

**Purpose**: Store Zulip chat user profiles including roles, activity status, and contact information.

**Data Source**: Zulip API via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigint | PRIMARY KEY | Zulip user ID |
| `role` | numeric | NOT NULL | User role level |
| `uuid` | text | NOT NULL | User UUID |
| `email` | text | NOT NULL | User email address |
| `full_name` | text | NOT NULL | User full name |
| `is_active` | boolean | NOT NULL | Whether user is active |
| `recipient_id` | bigint | NOT NULL | Recipient ID for direct messages |

**Indexes**:
- `idx_zulip_users_email`: `(email)`
- `idx_zulip_users_uuid`: `(uuid)`

---

## Field Semantics

### Core Identifiers

**`id`** (bigint, PRIMARY KEY)
- **Purpose**: Zulip user ID
- **Format**: Integer
- **Usage**: Primary key, join key for messages

**`uuid`** (text, NOT NULL)
- **Purpose**: Universally unique identifier for the user
- **Format**: UUID string
- **Usage**: Alternative unique identifier

**`recipient_id`** (bigint, NOT NULL)
- **Purpose**: Recipient ID used in Zulip's messaging system
- **Usage**: Direct message targeting

### User Information

**`email`** (text, NOT NULL)
- **Purpose**: User email address
- **Format**: Standard email format
- **Example**: "john.smith@company.com"
- **Usage**: User identification, cross-system correlation

**`full_name`** (text, NOT NULL)
- **Purpose**: User's display name
- **Example**: "John Smith"
- **Usage**: Display, reporting

**`role`** (numeric, NOT NULL)
- **Purpose**: User role level in Zulip
- **Values**: Numeric role codes (e.g., 100 = owner, 200 = admin, 400 = member, 600 = guest)
- **Usage**: Permission analysis, user categorization

**`is_active`** (boolean, NOT NULL)
- **Purpose**: Whether the user account is currently active
- **Values**: true (active), false (deactivated)
- **Usage**: Filtering active users

---

## Relationships

### Parent Of

**`zulip_messages`**
- **Join**: `id` → `sender_id`
- **Cardinality**: One user to many messages
- **Description**: Messages sent by this user

---

## Usage Examples

### Active users list

```sql
SELECT id, full_name, email, role
FROM zulip_users
WHERE is_active = true
ORDER BY full_name;
```

### Admin users

```sql
SELECT full_name, email, role
FROM zulip_users
WHERE role <= 200
  AND is_active = true
ORDER BY role, full_name;
```

### Cross-system user correlation

```sql
SELECT
    z.full_name,
    z.email,
    a.name as git_name,
    a.email as git_email
FROM zulip_users z
LEFT JOIN git.author a ON LOWER(z.email) = a.email_lower
WHERE z.is_active = true;
```

---

## Notes and Considerations

### Role Hierarchy

Zulip roles are numeric with lower values indicating higher permissions. Common values: 100 (owner), 200 (admin), 400 (member), 600 (guest).

### Cross-System Identity

The `email` field is the primary key for correlating Zulip users with identities in other systems. Use case-insensitive matching for reliable cross-system correlation.
