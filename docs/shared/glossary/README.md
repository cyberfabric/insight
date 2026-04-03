# Database Field Naming & Type Conventions

> Applies to all **internal Insight tables** (MariaDB metadata, ClickHouse analytics/audit).
> Does NOT apply to Bronze tables ingested from external sources via Airbyte connectors — those preserve source-native schemas.

This document defines mandatory naming patterns and data types for columns that appear across multiple services and layers. The goal is consistency: any engineer reading any table in any service should immediately recognise the role of a column by its name.

## Architecture Decision Records

| ADR | Decision | Status |
|-----|----------|--------|
| [ADR-0001](ADR/0001-uuidv7-primary-key.md) | UUIDv7 as universal primary key -- single UUID PK per table, no INT surrogates | proposed |
| [ADR-0002](ADR/0002-database-field-conventions.md) | Database field naming and type conventions -- temporal naming, tenant_id type, actor attribution, DATETIME(3), ClickHouse patterns | proposed |

---

<!-- toc -->

- [Architecture Decision Records](#architecture-decision-records)
- [1. General Rules](#1-general-rules)
- [2. Identifiers & Primary Keys](#2-identifiers--primary-keys)
  - [2.1 Standard Tables (No Versioning)](#21-standard-tables-no-versioning)
  - [2.2 SCD Type 2 / Versioned Tables](#22-scd-type-2--versioned-tables)
  - [2.3 Why UUID-Only, Not INT Surrogate + UUID](#23-why-uuid-only-not-int-surrogate--uuid)
- [3. Tenant Isolation](#3-tenant-isolation)
- [4. Timestamp Fields](#4-timestamp-fields)
  - [4.1 Record Lifecycle Timestamps](#41-record-lifecycle-timestamps)
  - [4.2 Temporal Validity (Effective Ranges)](#42-temporal-validity-effective-ranges)
  - [4.3 Job / Processing Timestamps](#43-job--processing-timestamps)
  - [4.4 Event Timestamps](#44-event-timestamps)
- [5. Foreign Key References](#5-foreign-key-references)
- [6. Status & Enum Fields](#6-status--enum-fields)
- [7. Actor / Audit Attribution](#7-actor--audit-attribution)
- [8. Confidence & Scoring Fields](#8-confidence--scoring-fields)
- [9. Hash & Change Detection](#9-hash--change-detection)
- [10. JSON / Flexible Storage](#10-json--flexible-storage)
- [11. ClickHouse-Specific Conventions](#11-clickhouse-specific-conventions)
  - [ORDER BY Key Design](#order-by-key-design)
  - [Nullable](#nullable)
  - [LowCardinality](#lowcardinality)
  - [Partitioning](#partitioning)
  - [TTL](#ttl)
- [12. MariaDB-Specific Conventions](#12-mariadb-specific-conventions)
  - [UUID Type](#uuid-type)
  - [DATETIME Precision](#datetime-precision)
  - [Character Sets](#character-sets)
- [13. Anti-Patterns](#13-anti-patterns)

<!-- /toc -->

---

## 1. General Rules

| Rule | Convention | Source |
|------|-----------|--------|
| Column naming | `snake_case`, lowercase | [API Guideline](../api-guideline/API.md) §4 |
| Table naming | `snake_case`, lowercase, singular (`person`, `alert_rule`) | Project convention |
| ID format | UUIDv7 (time-ordered) | [API Guideline](../api-guideline/README.md) §3 |
| Timestamp format | ISO-8601 UTC with milliseconds in JSON; DB-native types in storage | [API Guideline](../api-guideline/API.md) §3 |
| Nullability | Avoid unless null carries distinct semantic meaning | ClickHouse best practice; MariaDB convention |

---

## 2. Identifiers & Primary Keys

### 2.1 Standard Tables (No Versioning)

Every table has a single `id` column as primary key:

**MariaDB:**

```sql
id UUID NOT NULL DEFAULT uuid_v7() PRIMARY KEY
```

> MariaDB 10.7+ native `UUID` type stores 16 bytes internally. Always use `uuid_v7()` (time-ordered) to preserve insert ordering and minimise InnoDB page splits.

**ClickHouse:**

```sql
id UUID DEFAULT generateUUIDv7()
```

> In ClickHouse `id` is a column, not a PK in the RDBMS sense. It should appear **last** in the `ORDER BY` key (if at all) — never first. See [section 11](#11-clickhouse-specific-conventions).

**Foreign key references** use the pattern `{entity}_id`:

```
person_id       UUID    -- FK to person.id
org_unit_id     UUID    -- FK to org_unit.id
metric_id       UUID    -- FK to metric.id
tenant_id       UUID    -- FK to tenant.id (see section 3)
```

### 2.2 SCD Type 2 / Versioned Tables

For tables that track historical versions of the same logical entity (e.g., person transfers, org restructures), use a **composite primary key**:

```sql
-- Row-level identity
id          UUID NOT NULL DEFAULT uuid_v7(),
-- Logical entity identity (same across all versions)
person_id   UUID NOT NULL,
-- Version tracking
version     INT  NOT NULL DEFAULT 1,

PRIMARY KEY (id),
UNIQUE (person_id, version)
```

- `id` — unique row identifier (UUIDv7), serves as PK
- `person_id` — logical entity FK, remains constant across versions
- `version` — monotonically incrementing per logical entity

Current version is identified by:

```sql
-- Option A: partial unique index (preferred)
CREATE UNIQUE INDEX idx_person_current ON person (person_id) WHERE valid_to IS NULL;

-- Option B: query filter
WHERE valid_to IS NULL
```

### 2.3 Why UUID-Only, Not INT Surrogate + UUID

The identity-resolution DESIGN (PR #54) proposed `id INT AUTO_INCREMENT` as PK with a separate `person_id UUID` column. We standardise on **UUID-only** for the following reasons:

| Factor | INT surrogate + UUID | UUID-only (UUIDv7) |
|--------|---------------------|---------------------|
| Schema complexity | Two ID columns to manage, two indexes | One column, one index |
| Cross-service references | Services must know both IDs or always join | Single ID works everywhere (API, DB, events, logs) |
| InnoDB page fill (UUIDv7) | ~94% (sequential INT) | ~90% (time-ordered, minor random suffix) |
| Secondary index overhead | 4 bytes per entry | 16 bytes per entry |
| Practical impact at Insight scale | Negligible — metadata tables, not billions of rows | Negligible |
| API consistency | API exposes UUID, DB uses INT — mapping layer needed | API and DB use the same value |

**Decision**: the marginal InnoDB performance benefit of INT surrogates does not justify the complexity for Insight's metadata workloads (thousands to low millions of rows per tenant). UUIDv7 provides near-sequential ordering. All services, events, logs, and APIs use one identifier per entity.

**Exception**: ClickHouse Bronze/Silver tables do NOT use UUID PKs — they use composite `ORDER BY` keys optimised for analytical queries. See [section 11](#11-clickhouse-specific-conventions).

---

## 3. Tenant Isolation

Every table in every storage system includes `tenant_id`:

| Storage | Column | Type | Enforcement |
|---------|--------|------|-------------|
| MariaDB | `tenant_id` | `UUID NOT NULL` | `SecureConn` + `AccessScope` (modkit-db) |
| ClickHouse | `tenant_id` | `UUID` | Row-level filter on all queries |
| Redis | key prefix | `{tenant_id}:` | Application convention |
| Redpanda | message field | UUID (JSON) | Consumer-side filter |
| S3 / MinIO | object prefix | `{tenant_id}/` | Application convention |

`tenant_id` is always `UUID`, consistent with the project-wide ID convention. Never `VARCHAR` or `String`.

---

## 4. Timestamp Fields

### 4.1 Record Lifecycle Timestamps

Present on virtually every MariaDB table:

| Column | Type (MariaDB) | Nullable | Default | Description |
|--------|----------------|----------|---------|-------------|
| `created_at` | `DATETIME(3) NOT NULL` | No | `CURRENT_TIMESTAMP(3)` | When the record was first inserted |
| `updated_at` | `DATETIME(3) NOT NULL` | No | `CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)` | When the record was last modified |

- Always `DATETIME(3)` (millisecond precision) to match the API's ISO-8601 `.SSS` format.
- `DATETIME` over `TIMESTAMP` — wider range (no 2038 problem), no implicit timezone conversion, predictable behaviour.
- `created_at` is immutable after insert.

### 4.2 Temporal Validity (Effective Ranges)

For records with a period of validity (org memberships, SCD2 versions, alias ownership):

| Column | Type (MariaDB) | Nullable | Description |
|--------|----------------|----------|-------------|
| `effective_from` | `DATE NOT NULL` | No | Start of validity (inclusive) |
| `effective_to` | `DATE NULL` | Yes | End of validity (exclusive); `NULL` = currently active |

**Rules:**
- All temporal ranges use **half-open intervals**: `[effective_from, effective_to)`
- `NULL` in `effective_to` means "currently active / no known end"
- Never use `BETWEEN` for temporal queries — use `effective_from <= @date AND (effective_to IS NULL OR effective_to > @date)`
- Use `DATE` (not `DATETIME`) when the business granularity is days (org memberships, role assignments)
- Use `DATETIME(3)` when sub-day precision matters (SCD2 version ranges in identity resolution)

**Naming convention**: always `effective_from` / `effective_to`. Not `valid_from/valid_to`, not `owned_from/owned_until` — one consistent pair across all services.

### 4.3 Job / Processing Timestamps

For records that are periodically re-evaluated by background jobs:

| Column | Type (MariaDB) | Nullable | Description |
|--------|----------------|----------|-------------|
| `last_analyzed_at` | `DATETIME(3) NULL` | Yes | When a job last processed this record (e.g., bootstrap, identity resolution) |
| `resolved_at` | `DATETIME(3) NULL` | Yes | When a conflict / unmapped alias was resolved |

`NULL` means "never processed" or "never resolved".

### 4.4 Event Timestamps

For ClickHouse event tables (audit log, analytics):

| Column | Type (ClickHouse) | Description |
|--------|-------------------|-------------|
| `timestamp` | `DateTime64(3, 'UTC')` | When the event occurred |

- Use `DateTime64(3, 'UTC')` (millisecond precision) for event tables where sub-second ordering matters.
- Use `DateTime` (second precision) for analytical aggregates where milliseconds add no value.
- Always specify `'UTC'` timezone explicitly.

---

## 5. Foreign Key References

Pattern: `{referenced_entity}_id`

```
person_id           UUID        -- FK to person.id
org_unit_id         UUID        -- FK to org_unit.id
tenant_id           UUID        -- FK to tenant.id
metric_id           UUID        -- FK to metric.id
connector_id        UUID        -- FK to connector_config.id
granted_by          UUID        -- FK to person.id (actor who granted)
manager_person_id   UUID        -- FK to person.id (with role qualifier)
```

When the same entity is referenced twice in one table, prefix with role: `source_person_id`, `target_person_id`, `manager_person_id`.

---

## 6. Status & Enum Fields

Use MariaDB `ENUM` for fixed, small value sets. Name the column by what it represents:

| Column | Typical values | Notes |
|--------|---------------|-------|
| `status` | `active`, `inactive`, `deleted` | Generic record lifecycle |
| `role` | `member`, `manager` | Role within a relationship |
| `outcome` | `success`, `failure`, `denied` | Result of an operation |
| `priority` | `p1`, `p2`, `p3` | Requirement priority |

**Rules:**
- Values are `snake_case`, lowercase
- Prefer short, unambiguous strings
- ClickHouse equivalent: `LowCardinality(String)` — never ClickHouse `Enum8/Enum16` (hard to evolve)
- Do NOT encode business logic in enum names (no `auto_approved_by_admin`)

---

## 7. Actor / Audit Attribution

For tracking who performed an action:

| Column | Type (MariaDB) | Description |
|--------|----------------|-------------|
| `actor_person_id` | `UUID NOT NULL` | FK to person.id — who performed the action |
| `actor_ip` | `VARCHAR(45)` | Client IP (IPv4 or IPv6) |
| `actor_user_agent` | `VARCHAR(500)` | Client User-Agent |

**Rules:**
- Always reference persons by `UUID` FK, never by username or email string.
- For grant/revoke patterns: `granted_by UUID` / `revoked_by UUID`.
- For resolution patterns: `resolved_by UUID` (FK to person.id).
- The `performed_by VARCHAR` anti-pattern (storing a username string instead of person FK) should not be used — it breaks when usernames change and cannot be joined.

---

## 8. Confidence & Scoring Fields

For match quality and completeness:

| Column | Type | Description |
|--------|------|-------------|
| `confidence` | `DECIMAL(3,2)` | Score 0.00–1.00 |
| `completeness_score` | `FLOAT` | Fraction of non-null attributes (0.0–1.0) |

---

## 9. Hash & Change Detection

| Column | Type | Description |
|--------|------|-------------|
| `record_hash` | `VARCHAR(64)` | SHA-256 hex of canonical attribute set for change detection |
| `version` | `INT NOT NULL DEFAULT 1` | Monotonic counter for SCD2 / optimistic locking |

---

## 10. JSON / Flexible Storage

Use JSON columns sparingly for genuinely dynamic data:

| Column | Type (MariaDB) | Description |
|--------|----------------|-------------|
| `config` | `JSON` | Rule-specific parameters, plugin configs |
| `parameters` | `JSON` | Connector-specific parameters |
| `snapshot_before` | `JSON` | Full state snapshot for audit rollback |
| `snapshot_after` | `JSON` | State after change |

**Rules:**
- JSON field names inside the value also follow `snake_case`
- Do NOT store data in JSON that is queried with `WHERE` — extract it into a proper column
- ClickHouse equivalent: `String` (store JSON string, parse with JSON functions)

---

## 11. ClickHouse-Specific Conventions

### ORDER BY Key Design

```sql
ORDER BY (tenant_id, event_date, entity_type, id)
```

- **First**: `tenant_id` — always filtered, lowest cardinality
- **Middle**: date/category columns — filtered frequently, medium cardinality
- **Last** (if needed): UUID — highest cardinality, only for deduplication

Never place UUID first — it destroys granule-level data skipping and compression.

### Nullable

Avoid `Nullable` unless null is semantically meaningful. Prefer:
- Empty string `''` for text
- `0` for counts
- Sentinel `'1970-01-01'` for dates
- `toUUID('00000000-0000-0000-0000-000000000000')` for UUIDs

Each `Nullable` column adds a UInt8 null-mask column (storage + processing overhead).

### LowCardinality

Use `LowCardinality(String)` for string columns with fewer than ~10,000 distinct values:

```sql
service         LowCardinality(String),    -- ~8 services
action          LowCardinality(String),    -- ~50 actions
category        LowCardinality(String),    -- ~6 categories
outcome         LowCardinality(String),    -- success/failure/denied
```

### Partitioning

```sql
PARTITION BY toYYYYMM(timestamp)
```

Use month-based partitioning for time-series data. Ensures efficient TTL expiry and partition pruning.

### TTL

```sql
TTL timestamp + INTERVAL 1 YEAR
```

Always define TTL on event tables. Configurable per tenant via application logic.

---

## 12. MariaDB-Specific Conventions

### UUID Type

Use the native `UUID` type (MariaDB 10.7+). It stores 16 bytes internally and displays as `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`. Always generate with `uuid_v7()`.

### DATETIME Precision

Use `DATETIME(3)` (millisecond precision) for all timestamp columns to match the API's ISO-8601 `.SSS` format:

```sql
created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
```

### Character Sets

Use `utf8mb4` character set and `utf8mb4_unicode_ci` collation for all string columns.

---

## 13. Anti-Patterns

| Anti-pattern | Why | Do instead |
|-------------|-----|-----------|
| `INT AUTO_INCREMENT` PK + separate UUID column | Unnecessary complexity at Insight scale; two IDs to manage | `id UUID DEFAULT uuid_v7() PRIMARY KEY` |
| `tenant_id VARCHAR(100)` | Inconsistent with project UUID convention; larger storage | `tenant_id UUID NOT NULL` |
| `performed_by VARCHAR(100)` (username string) | Breaks on rename; cannot join to person table | `actor_person_id UUID` (FK to person.id) |
| `valid_from` / `valid_to` or `owned_from` / `owned_until` | Multiple naming conventions for the same concept | `effective_from` / `effective_to` everywhere |
| `TIMESTAMP` for MariaDB columns | Implicit timezone conversion; 2038 limit | `DATETIME(3)` |
| UUID first in ClickHouse `ORDER BY` | Destroys data skipping and compression | `tenant_id` first, UUID last |
| `Nullable(String)` in ClickHouse | Storage overhead from null-mask column | Empty string `''` as default |
| `Enum8`/`Enum16` in ClickHouse | Hard to evolve (adding values requires ALTER) | `LowCardinality(String)` |
