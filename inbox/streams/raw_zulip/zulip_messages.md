# Table: `zulip_messages`

## Overview

**Purpose**: Store aggregated Zulip message counts per user per time period, tracking messaging activity over time.

**Data Source**: Zulip API via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `uniq` | text | PRIMARY KEY | Unique record identifier |
| `count` | numeric | NOT NULL | Message count |
| `sender_id` | bigint | NOT NULL | Sender's Zulip user ID |
| `created_at` | timestamptz | NOT NULL | Message timestamp |

**Indexes**:
- `idx_zulip_messages_created_at`: `(created_at)`
- `idx_zulip_messages_sender_id`: `(sender_id)`

---

## Field Semantics

### Core Identifiers

**`uniq`** (text, PRIMARY KEY)
- **Purpose**: Unique record identifier
- **Usage**: Primary key, deduplication

**`sender_id`** (bigint, NOT NULL)
- **Purpose**: Zulip user ID of the message sender
- **References**: `zulip_users.id`
- **Usage**: Join key to user details

### Metrics

**`count`** (numeric, NOT NULL)
- **Purpose**: Number of messages in this record
- **Format**: Positive integer
- **Usage**: Messaging activity metrics

### Timestamps

**`created_at`** (timestamptz, NOT NULL)
- **Purpose**: Timestamp for the message or aggregation period
- **Format**: Timestamp with timezone
- **Usage**: Time-series analysis, activity tracking

---

## Relationships

### Parent

**`zulip_users`**
- **Join**: `sender_id` ← `id`
- **Cardinality**: Many message records to one user
- **Description**: Each message record belongs to a sender

---

## Usage Examples

### Most active Zulip users

```sql
SELECT
    u.full_name,
    u.email,
    SUM(m.count) as total_messages
FROM zulip_messages m
JOIN zulip_users u ON m.sender_id = u.id
WHERE m.created_at >= NOW() - INTERVAL '30 days'
GROUP BY u.id, u.full_name, u.email
ORDER BY total_messages DESC
LIMIT 20;
```

### Daily message volume

```sql
SELECT
    DATE(created_at) as day,
    SUM(count) as messages,
    COUNT(DISTINCT sender_id) as active_senders
FROM zulip_messages
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY DATE(created_at)
ORDER BY day DESC;
```

### User messaging trend

```sql
SELECT
    DATE_TRUNC('week', m.created_at) as week,
    u.full_name,
    SUM(m.count) as messages
FROM zulip_messages m
JOIN zulip_users u ON m.sender_id = u.id
WHERE m.created_at >= NOW() - INTERVAL '90 days'
  AND u.email = 'john.smith@company.com'
GROUP BY week, u.full_name
ORDER BY week DESC;
```

---

## Notes and Considerations

### Aggregated Data

This table stores aggregated message counts rather than individual messages. Each record represents a count of messages for a user at a given timestamp.

### Sender-Only Tracking

Only the sender is tracked — there is no recipient information in this table. For analyzing communication patterns between specific users, additional data would be needed.
