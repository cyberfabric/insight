# Table: `cursor_events_token_usage`

## Overview

**Purpose**: Store detailed token consumption metrics for each Cursor IDE event, including input/output tokens, cache usage, and costs.

**Data Source**: Cursor API via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `event_unique` | text | PRIMARY KEY | Reference to cursor_events.unique |
| `totalCents` | numeric | NULLABLE | Total cost in cents |
| `inputTokens` | numeric | NULLABLE | Number of input tokens consumed |
| `outputTokens` | numeric | NULLABLE | Number of output tokens generated |
| `cacheReadTokens` | numeric | NULLABLE | Tokens read from cache |
| `cacheWriteTokens` | numeric | NULLABLE | Tokens written to cache |
| `discountPercentOff` | numeric | NULLABLE | Discount percentage applied |

---

## Field Semantics

### Core Identifier

**`event_unique`** (text, PRIMARY KEY)
- **Purpose**: Foreign key linking to the parent event
- **References**: `cursor_events.unique`
- **Usage**: Join key to event details

### Token Metrics

**`inputTokens`** (numeric, NULLABLE)
- **Purpose**: Number of tokens in the prompt/input
- **Format**: Integer count
- **Usage**: Understanding prompt complexity, cost attribution

**`outputTokens`** (numeric, NULLABLE)
- **Purpose**: Number of tokens in the model response
- **Format**: Integer count
- **Usage**: Response length analysis, cost attribution

**`cacheReadTokens`** (numeric, NULLABLE)
- **Purpose**: Tokens served from prompt cache
- **Format**: Integer count
- **Usage**: Cache efficiency analysis, cost savings tracking

**`cacheWriteTokens`** (numeric, NULLABLE)
- **Purpose**: Tokens written to prompt cache
- **Format**: Integer count
- **Usage**: Cache utilization tracking

### Cost

**`totalCents`** (numeric, NULLABLE)
- **Purpose**: Total cost for this event in cents
- **Format**: Decimal value
- **Usage**: Cost tracking, budget analysis

**`discountPercentOff`** (numeric, NULLABLE)
- **Purpose**: Discount percentage applied to this event
- **Format**: Percentage (0-100)
- **Usage**: Discount tracking, effective cost calculation

---

## Relationships

### Parent

**`cursor_events`**
- **Join**: `event_unique` ← `unique`
- **Cardinality**: One token usage record to one event
- **Description**: Each token usage record belongs to exactly one event

---

## Usage Examples

### Average token usage by model

```sql
SELECT
    e.model,
    AVG(t.inputTokens) as avg_input,
    AVG(t.outputTokens) as avg_output,
    AVG(t.totalCents) as avg_cost_cents
FROM cursor_events e
JOIN cursor_events_token_usage t ON e.unique = t.event_unique
WHERE e.timestamp >= '2026-01-01'
GROUP BY e.model
ORDER BY avg_cost_cents DESC;
```

### Cache efficiency

```sql
SELECT
    DATE(e.timestamp) as day,
    SUM(t.cacheReadTokens) as cached_tokens,
    SUM(t.inputTokens) as total_input_tokens,
    ROUND(SUM(t.cacheReadTokens)::numeric / NULLIF(SUM(t.inputTokens), 0) * 100, 2) as cache_hit_pct
FROM cursor_events e
JOIN cursor_events_token_usage t ON e.unique = t.event_unique
WHERE e.timestamp >= NOW() - INTERVAL '30 days'
GROUP BY DATE(e.timestamp)
ORDER BY day DESC;
```

### Total spending per user

```sql
SELECT
    e.userEmail,
    SUM(t.totalCents) / 100.0 as total_dollars,
    SUM(t.inputTokens + t.outputTokens) as total_tokens
FROM cursor_events e
JOIN cursor_events_token_usage t ON e.unique = t.event_unique
WHERE e.timestamp >= '2026-01-01'
GROUP BY e.userEmail
ORDER BY total_dollars DESC;
```

---

## Notes and Considerations

### Nullable Fields

All token and cost fields are nullable — not all events have detailed token tracking. Events without token-based billing may have null values.

### Cache Tokens

The `cacheReadTokens` and `cacheWriteTokens` fields track Cursor's prompt caching mechanism. High cache read rates indicate effective prompt reuse and cost savings.

### Cost Calculation

The effective cost after discount can be calculated as:
```
effective_cost = totalCents * (1 - discountPercentOff / 100)
```
