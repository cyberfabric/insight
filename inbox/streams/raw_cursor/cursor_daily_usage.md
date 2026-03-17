# Table: `cursor_daily_usage`

## Overview

**Purpose**: Store daily aggregated usage statistics per Cursor IDE user, including feature adoption metrics, code interaction stats, and subscription usage.

**Data Source**: Cursor API via Airbyte connector

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `unique` | text | PRIMARY KEY | Unique record identifier |
| `day` | text | NOT NULL | Day label |
| `date` | bigint | NOT NULL | Unix timestamp in milliseconds |
| `email` | text | NOT NULL | User email address |
| `userId` | text | NOT NULL | Cursor user ID |
| `isActive` | boolean | NOT NULL | Whether user was active on this day |
| `apiKeyReqs` | numeric | NOT NULL | API key requests count |
| `cmdkUsages` | numeric | NOT NULL | Cmd+K feature usage count |
| `bugbotUsages` | numeric | NOT NULL | Bug bot feature usage count |
| `chatRequests` | numeric | NOT NULL | Chat requests count |
| `totalAccepts` | numeric | NOT NULL | Total code accepts |
| `totalApplies` | numeric | NOT NULL | Total code applies |
| `totalRejects` | numeric | NOT NULL | Total code rejects |
| `agentRequests` | numeric | NOT NULL | Agent mode requests |
| `clientVersion` | text | NOT NULL | Cursor client version |
| `mostUsedModel` | text | NOT NULL | Most frequently used AI model |
| `totalTabsShown` | numeric | NOT NULL | Total tab completions shown |
| `usageBasedReqs` | numeric | NOT NULL | Usage-based billing requests |
| `totalLinesAdded` | numeric | NOT NULL | Total lines of code added |
| `composerRequests` | numeric | NOT NULL | Composer feature requests |
| `totalLinesDeleted` | numeric | NOT NULL | Total lines of code deleted |
| `totalTabsAccepted` | numeric | NOT NULL | Tab completions accepted |
| `acceptedLinesAdded` | numeric | NOT NULL | Lines added from accepted suggestions |
| `acceptedLinesDeleted` | numeric | NOT NULL | Lines deleted from accepted suggestions |
| `tabMostUsedExtension` | text | NOT NULL | Most used file extension for tab completions |
| `applyMostUsedExtension` | text | NOT NULL | Most used file extension for applies |
| `subscriptionIncludedReqs` | numeric | NOT NULL | Requests included in subscription |

**Indexes**:
- `idx_cursor_daily_usage_date`: `(date)`
- `idx_cursor_daily_usage_email`: `(email)`

---

## Field Semantics

### Core Identifiers

**`unique`** (text, PRIMARY KEY)
- **Purpose**: Unique record identifier
- **Format**: Opaque string from Cursor API
- **Usage**: Primary key, deduplication

**`email`** (text, NOT NULL)
- **Purpose**: User email address
- **Example**: "developer@company.com"
- **Usage**: User identification, join key

**`userId`** (text, NOT NULL)
- **Purpose**: Cursor platform user ID
- **Format**: Opaque string identifier
- **Usage**: Alternative user identification

### Time

**`day`** (text, NOT NULL)
- **Purpose**: Day label
- **Format**: Text representation of the day
- **Usage**: Display, grouping

**`date`** (bigint, NOT NULL)
- **Purpose**: Unix timestamp in milliseconds for the day
- **Format**: Milliseconds since epoch (e.g., 1740268800000)
- **Usage**: Time-series analysis, sorting, filtering

### Activity Flags

**`isActive`** (boolean, NOT NULL)
- **Purpose**: Whether the user had any IDE activity on this day
- **Values**: true/false
- **Usage**: Active user counting, engagement metrics

### Feature Usage

**`chatRequests`** (numeric, NOT NULL)
- **Purpose**: Number of chat interactions with AI
- **Usage**: Chat feature adoption

**`cmdkUsages`** (numeric, NOT NULL)
- **Purpose**: Number of Cmd+K (inline edit) usages
- **Usage**: Inline edit feature adoption

**`composerRequests`** (numeric, NOT NULL)
- **Purpose**: Number of Composer feature requests
- **Usage**: Composer feature adoption

**`agentRequests`** (numeric, NOT NULL)
- **Purpose**: Number of agent mode requests
- **Usage**: Agent feature adoption

**`bugbotUsages`** (numeric, NOT NULL)
- **Purpose**: Number of bug bot feature usages
- **Usage**: Bug bot feature adoption

### Code Interaction

**`totalTabsShown`** (numeric, NOT NULL)
- **Purpose**: Total tab completion suggestions shown
- **Usage**: Suggestion volume tracking

**`totalTabsAccepted`** (numeric, NOT NULL)
- **Purpose**: Tab completions accepted by user
- **Usage**: Acceptance rate = totalTabsAccepted / totalTabsShown

**`totalAccepts`** (numeric, NOT NULL)
- **Purpose**: Total code suggestions accepted
- **Usage**: Overall acceptance metrics

**`totalApplies`** (numeric, NOT NULL)
- **Purpose**: Total code applications (apply to file)
- **Usage**: Apply feature tracking

**`totalRejects`** (numeric, NOT NULL)
- **Purpose**: Total code suggestions rejected
- **Usage**: Rejection analysis

**`totalLinesAdded`** (numeric, NOT NULL)
- **Purpose**: Total lines of code added during the day
- **Usage**: Productivity metrics

**`totalLinesDeleted`** (numeric, NOT NULL)
- **Purpose**: Total lines of code deleted during the day
- **Usage**: Refactoring metrics

**`acceptedLinesAdded`** (numeric, NOT NULL)
- **Purpose**: Lines added from accepted AI suggestions
- **Usage**: AI contribution metrics

**`acceptedLinesDeleted`** (numeric, NOT NULL)
- **Purpose**: Lines deleted from accepted AI suggestions
- **Usage**: AI contribution metrics

### Billing

**`apiKeyReqs`** (numeric, NOT NULL)
- **Purpose**: Requests using API key
- **Usage**: API key usage tracking

**`usageBasedReqs`** (numeric, NOT NULL)
- **Purpose**: Requests billed on usage basis
- **Usage**: Usage-based billing tracking

**`subscriptionIncludedReqs`** (numeric, NOT NULL)
- **Purpose**: Requests covered by subscription plan
- **Usage**: Subscription utilization

### Client Info

**`clientVersion`** (text, NOT NULL)
- **Purpose**: Cursor IDE version
- **Example**: "0.45.1"
- **Usage**: Version tracking, feature availability

**`mostUsedModel`** (text, NOT NULL)
- **Purpose**: AI model used most on this day
- **Examples**: "gpt-4o", "claude-3.5-sonnet"
- **Usage**: Model preference analysis

**`tabMostUsedExtension`** (text, NOT NULL)
- **Purpose**: File extension with most tab completions
- **Examples**: ".ts", ".py", ".java"
- **Usage**: Language preference for completions

**`applyMostUsedExtension`** (text, NOT NULL)
- **Purpose**: File extension with most code applies
- **Examples**: ".ts", ".py", ".java"
- **Usage**: Language preference for applies

---

## Relationships

This table is standalone — no direct foreign key relationships to other tables. User correlation is done via `email` field.

---

## Usage Examples

### Weekly active users

```sql
SELECT
    DATE_TRUNC('week', TO_TIMESTAMP(date / 1000)) as week,
    COUNT(DISTINCT email) as active_users
FROM cursor_daily_usage
WHERE isActive = true
GROUP BY week
ORDER BY week DESC;
```

### Tab completion acceptance rate by user

```sql
SELECT
    email,
    SUM(totalTabsAccepted) as accepted,
    SUM(totalTabsShown) as shown,
    ROUND(SUM(totalTabsAccepted)::numeric / NULLIF(SUM(totalTabsShown), 0) * 100, 2) as acceptance_pct
FROM cursor_daily_usage
WHERE date >= EXTRACT(EPOCH FROM '2026-01-01'::timestamp) * 1000
GROUP BY email
HAVING SUM(totalTabsShown) > 0
ORDER BY acceptance_pct DESC;
```

### Feature usage breakdown

```sql
SELECT
    email,
    SUM(chatRequests) as chat,
    SUM(cmdkUsages) as cmdk,
    SUM(composerRequests) as composer,
    SUM(agentRequests) as agent,
    SUM(bugbotUsages) as bugbot
FROM cursor_daily_usage
WHERE date >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY email
ORDER BY chat + cmdk + composer + agent DESC;
```

### AI contribution to code

```sql
SELECT
    email,
    SUM(totalLinesAdded) as total_lines_added,
    SUM(acceptedLinesAdded) as ai_lines_added,
    ROUND(SUM(acceptedLinesAdded)::numeric / NULLIF(SUM(totalLinesAdded), 0) * 100, 2) as ai_contribution_pct
FROM cursor_daily_usage
WHERE date >= EXTRACT(EPOCH FROM NOW() - INTERVAL '30 days') * 1000
GROUP BY email
HAVING SUM(totalLinesAdded) > 0
ORDER BY ai_contribution_pct DESC;
```

---

## Notes and Considerations

### Timestamp Format

The `date` field uses Unix timestamps in **milliseconds** (not seconds). Convert with `TO_TIMESTAMP(date / 1000)` in PostgreSQL.

### Acceptance Metrics

Key acceptance rate formula:
- **Tab acceptance rate**: `totalTabsAccepted / totalTabsShown`
- **AI code contribution**: `acceptedLinesAdded / totalLinesAdded`

### Client Version Tracking

The `clientVersion` field helps track IDE version rollouts and correlate feature usage with version availability.
