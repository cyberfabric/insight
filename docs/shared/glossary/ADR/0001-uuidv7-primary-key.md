---
status: proposed
date: 2026-04-03
---

# ADR-0001: UUIDv7 as Universal Primary Key Strategy

- [ ] `p1` - **ID**: `cpt-insightspec-adr-db-uuidv7-primary-key`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [UUID-only PK (UUIDv7)](#uuid-only-pk-uuidv7)
  - [INT Surrogate PK + Separate UUID Column](#int-surrogate-pk--separate-uuid-column)
  - [INT Auto-Increment PK Only](#int-auto-increment-pk-only)
  - [Composite Natural Keys](#composite-natural-keys)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

Insight is a multi-service platform (8 Rust microservices) where entities are referenced across services via HTTP SDK clients, Redpanda events, REST APIs, logs, and audit trails. The primary key strategy must work consistently across MariaDB (OLTP metadata), ClickHouse (OLAP analytics/audit), and the JSON API surface. Which primary key type and pattern should all internal MariaDB tables use?

## Decision Drivers

* Cross-service identity -- the same entity ID appears in API responses, Redpanda events, audit logs, inter-service SDK calls, and database rows; mapping between internal and external IDs adds complexity
* API Guideline alignment -- the project [API Guideline](../../api-guideline/README.md) already mandates `uuidv7` for all resource identifiers in JSON responses
* InnoDB clustered index performance -- MariaDB/InnoDB clusters rows by PK; random UUIDs cause page splits; time-ordered UUIDs (v7) mitigate this
* Schema simplicity -- fewer columns and indexes reduce cognitive load and migration complexity across 8 services
* Metadata workload scale -- Insight MariaDB tables hold configuration, org trees, roles, alerts, and templates (thousands to low millions of rows per tenant), not high-volume transactional data

## Considered Options

* UUID-only PK (UUIDv7)
* INT Surrogate PK + Separate UUID Column
* INT Auto-Increment PK Only
* Composite Natural Keys

## Decision Outcome

Chosen option: "UUID-only PK (UUIDv7)", because it provides the simplest schema while satisfying cross-service identity requirements, aligns with the existing API Guideline, and has negligible performance trade-offs at Insight's metadata workload scale.

### Consequences

* Good, because one identifier per entity works everywhere -- API, DB, events, logs, inter-service calls
* Good, because aligns with existing API Guideline (`uuidv7` already mandated for JSON responses)
* Good, because no mapping layer between internal INT and external UUID
* Good, because UUIDv7 is time-ordered, achieving ~90% InnoDB page fill (vs ~94% for sequential INT)
* Good, because globally unique without coordination -- safe for future distributed scenarios
* Bad, because 16-byte PK bloats secondary indexes (4x vs INT) -- acceptable for metadata tables with few indexes
* Bad, because JOINs on 16-byte UUID are marginally slower than 4-byte INT -- not measurable at Insight scale

### Confirmation

* All MariaDB `CREATE TABLE` statements in DESIGN documents use `id UUID NOT NULL DEFAULT uuid_v7() PRIMARY KEY`
* No `AUTO_INCREMENT` PKs in any service schema
* API responses use the same UUID value as the database PK -- no ID translation layer exists
* Code review: verify no service stores two ID columns for the same entity

## Pros and Cons of the Options

### UUID-only PK (UUIDv7)

Single `id UUID DEFAULT uuid_v7()` column serves as both PK and external identifier. UUIDv7 (RFC 9562) embeds a Unix millisecond timestamp in the high bits, producing time-ordered values.

* Good, because single identifier everywhere -- zero mapping complexity
* Good, because UUIDv7 is time-ordered -- near-sequential inserts, ~90% InnoDB page fill
* Good, because MariaDB 10.7+ native `UUID` type stores 16 bytes internally (not 36-byte CHAR)
* Good, because `uuid_v7()` built into MariaDB 11.4+ (or application-generated for earlier versions)
* Good, because globally unique without central authority -- safe for cross-service, cross-tenant references
* Neutral, because 16-byte PK is larger than 4-byte INT but smaller than 36-byte CHAR(36)
* Bad, because secondary indexes carry 16-byte PK values (4x larger than INT per index entry)
* Bad, because within-millisecond ordering has random lower bits (minor, only affects bulk inserts of identical entities)

### INT Surrogate PK + Separate UUID Column

`id INT AUTO_INCREMENT PRIMARY KEY` for internal use, plus `external_id UUID UNIQUE` for API/event exposure. Used in the Identity Resolution DESIGN (PR #54) for SCD Type 2 tables.

* Good, because smallest possible PK (4 bytes) -- optimal InnoDB page fill (~94%) and secondary index size
* Good, because JOINs on INT are marginally faster (smaller comparisons, better cache utilization)
* Good, because well-established pattern in high-write OLTP systems
* Bad, because two ID columns per table -- which one to use in events? In logs? In SDK calls?
* Bad, because requires additional UNIQUE index on UUID column (storage overhead partially negates INT savings)
* Bad, because application must generate UUID on insert (additional logic)
* Bad, because cross-service references must always use UUID but internal FKs might use INT -- inconsistency risk
* Bad, because the performance benefit is negligible for Insight's metadata workload (not a high-write OLTP system)

### INT Auto-Increment PK Only

`id INT AUTO_INCREMENT PRIMARY KEY` with no UUID column. Internal-only identifiers.

* Good, because simplest schema, smallest storage, fastest JOINs
* Bad, because sequential INTs are guessable -- information disclosure risk (entity count enumeration)
* Bad, because not globally unique -- collisions when merging data from multiple services or tenants
* Bad, because API Guideline mandates UUIDv7 for JSON responses -- would need a separate ID for the API layer anyway
* Bad, because Redpanda events and audit logs would use different identifiers than the database

### Composite Natural Keys

Primary key composed of business-meaningful columns (e.g., `(tenant_id, email, source_system)`).

* Good, because no surrogate IDs needed -- data is self-describing
* Good, because enforces uniqueness at the business level
* Bad, because natural keys change (email changes, username changes) -- cascading FK updates
* Bad, because composite keys complicate JOINs and API references
* Bad, because not compatible with API Guideline's `id` field convention
* Bad, because ClickHouse uses composite ORDER BY keys for analytics -- conflating OLTP PKs with OLAP ordering

## More Information

**SCD Type 2 exception**: For versioned/historical tables (e.g., person version history, org unit history), each row still has `id UUID` as PK, plus a logical entity reference (`person_id UUID` FK to the entity table). This is not the INT+UUID anti-pattern -- both columns are UUIDs, and they serve different purposes (row identity vs entity identity). See [README.md section 2.2](../README.md#22-scd-type-2--versioned-tables).

**ClickHouse tables** do not use UUID as PK in the RDBMS sense. ClickHouse uses composite `ORDER BY` keys optimised for analytical queries. UUID columns exist for filtering and joining but are placed last in ORDER BY (if at all).

**MariaDB version**: native `UUID` type requires MariaDB 10.7+. `uuid_v7()` function requires MariaDB 11.4+ (or application-side generation with the `uuid` Rust crate).

**References**:
- [RFC 9562 -- UUIDs](https://www.rfc-editor.org/rfc/rfc9562) -- UUIDv7 specification
- [MariaDB UUID Data Type](https://mariadb.com/docs/server/reference/data-types/string-data-types/uuid-data-type/)
- [PlanetScale: The Problem with UUID PKs in MySQL](https://planetscale.com/blog/the-problem-with-using-a-uuid-primary-key-in-mysql) -- UUIDv7 mitigates most issues
- [Bytebase: UUID vs Auto-Increment](https://www.bytebase.com/blog/choose-primary-key-uuid-or-auto-increment/)

## Traceability

This decision directly addresses the following requirements or design elements:

* `cpt-insightspec-nfr-be-tenant-isolation` -- UUID tenant_id is part of the universal UUID convention; consistent type across all tables and services
* `cpt-insightspec-nfr-be-query-safety` -- Parameterized UUID bind parameters eliminate injection vectors in ID-based queries
* `cpt-insightspec-principle-be-service-owns-data` -- UUID PKs are globally unique, enabling safe cross-service references without coordination
* `cpt-insightspec-principle-be-api-versioned` -- API Guideline mandates UUIDv7; using the same value as PK ensures zero-translation API versioning
* `cpt-insightspec-fr-be-audit-trail` -- Audit events reference entity UUIDs; same value in DB and audit log simplifies correlation
