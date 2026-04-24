//! Initial schema for identity-resolution `MariaDB` tables:
//!
//! 1. `persons` -- identity-attribute history (SCD-style append-only).
//!    Every row is one observation of one attribute value of one person
//!    at one source-account at one moment in time. The `persons` table is
//!    the authoritative source of truth for the identity domain.
//! 2. `account_person_map` -- SCD-2 materialized view of the stable
//!    source-account -> `person_id` binding, rebuilt deterministically
//!    from `persons` rows where `value_type = 'id'`. The binding history
//!    lives in `persons` observations; the map is a derived fast-lookup
//!    cache that also answers "state as of date T" questions without
//!    window functions.
//!
//! # Column split on `persons`
//!
//! The identity observation "value" is split into three nullable columns
//! with hardcoded routing by `value_type`:
//!
//! - `value_id VARCHAR(320) COLLATE utf8mb4_bin` -- for `value_type` in
//!   (`id`, `email`). Strict byte comparison; hot-path index target.
//!   Size 320 covers RFC 5321/5322 maximum email length (64 local +
//!   `@` + 255 domain).
//! - `value_full_text VARCHAR(512) COLLATE utf8mb4_unicode_ci` -- for
//!   `value_type = 'display_name'`. Case- and accent-insensitive for
//!   operator search; leaves room for a future FULLTEXT index.
//! - `value TEXT` -- catch-all for any other `value_type` (e.g.,
//!   `employee_id`, `functional_team`, future custom attributes).
//!   Not indexed.
//!
//! Exactly one of the three columns is non-null in each normal row.
//! All-three-null is reserved for "attribute unset at source" events
//! (future feature; not emitted by the initial seed).
//!
//! Uniqueness is enforced via a generated `value_effective` column
//! that coalesces the three value columns, because `MariaDB` treats
//! `NULL` as distinct in `UNIQUE` keys.
//!
//! # Why `VARCHAR` vs `TEXT` / declared max doesn't affect speed
//!
//! `InnoDB` stores variable-length columns by actual value size (not
//! declared max); B-tree fanout, index seeks, and disk footprint for
//! the same content are identical across `VARCHAR(255)` / `VARCHAR(512)`
//! / `VARCHAR(320)`. The declared max matters for temp-table sort-buffer
//! sizing in older engines (not modern `MariaDB` 10.5+ `TempTable`) and
//! the `UNIQUE` key length budget (3072 bytes with `innodb_large_prefix`
//! on DYNAMIC row format). Our widest column (512 chars `utf8mb4` =
//! 2048 bytes) is well under that budget.
//!
//! See ADR-0002 (stable `person_id` + observation schema) and ADR-0006
//! (service-owned migrations).

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const CREATE_PERSONS: &str = r"
CREATE TABLE IF NOT EXISTS persons (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    value_type          VARCHAR(50)  NOT NULL
                        COMMENT 'Attribute kind: id, email, display_name, employee_id, platform_id, ...',
    insight_source_type VARCHAR(100) NOT NULL
                        COMMENT 'Source system: bamboohr, zoom, cursor, claude_admin, etc.',
    insight_source_id   BINARY(16)   NOT NULL
                        COMMENT 'Connector instance UUID (sipHash from bronze source_id)',
    insight_tenant_id   BINARY(16)   NOT NULL
                        COMMENT 'Tenant UUID (sipHash from bronze tenant_id)',

    value_id            VARCHAR(320) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL
                        COMMENT 'For value_type IN (id, email); strict byte comparison; hot-path index target',
    value_full_text     VARCHAR(512) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL
                        COMMENT 'For value_type = display_name; case/accent-insensitive',
    value               TEXT NULL
                        COMMENT 'Catch-all for any other value_type (employee_id, functional_team, custom fields)',

    value_effective     VARCHAR(512) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin
                        GENERATED ALWAYS AS (COALESCE(value_id, value_full_text, LEFT(value, 512))) STORED
                        COMMENT 'Generated coalesce of the three value columns; enables NULL-safe UNIQUE',

    person_id           BINARY(16)   NOT NULL
                        COMMENT 'Person UUID (random UUIDv7, minted at first observation)',
    author_person_id    BINARY(16)   NOT NULL
                        COMMENT 'Person UUID of who/what made this change; system sentinel 00..0 for automatic seed',
    reason              TEXT         NOT NULL DEFAULT ''
                        COMMENT 'Optional change reason / comment',
    created_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                        COMMENT 'When this record was created (stored internally in UTC)',

    UNIQUE KEY uq_person_observation (
        insight_tenant_id, person_id, insight_source_type, insight_source_id,
        value_type, value_effective
    ),
    INDEX idx_value_id        (insight_tenant_id, value_type, value_id),
    INDEX idx_value_full_text (insight_tenant_id, value_type, value_full_text),
    INDEX idx_person_id       (person_id),
    INDEX idx_tenant_person   (insight_tenant_id, person_id),
    INDEX idx_source          (insight_source_type, insight_source_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
";

/// `account_person_map` -- SCD-2 materialized view of (tenant,
/// source-instance, `source_account`) -> `person_id` binding. Rebuilt
/// deterministically from `persons` rows where `value_type = 'id'`.
/// Never the source of truth; drift is impossible by construction
/// because rebuild re-derives every row from `persons` observations.
///
/// Each account gets one row per historical binding period:
/// `valid_from = created_at` of the `persons` observation that opened
/// the period, `valid_to = created_at` of the next observation (or
/// `NULL` for the currently-active binding). Queries "state as of
/// date T" become a trivial range scan; "current binding" is
/// `WHERE valid_to IS NULL`.
///
/// `author_person_id` carries forward from the `persons` observation;
/// the zero-UUID sentinel `00000000-0000-0000-0000-000000000000`
/// marks auto-minted bindings from the seed. Operator-driven future
/// flows will populate real `person_id`s.
const CREATE_ACCOUNT_PERSON_MAP: &str = r"
CREATE TABLE IF NOT EXISTS account_person_map (
    insight_tenant_id   BINARY(16)   NOT NULL
                        COMMENT 'Tenant UUID (sipHash from bronze tenant_id)',
    insight_source_type VARCHAR(100) NOT NULL
                        COMMENT 'Source system: bamboohr, zoom, cursor, claude_admin, etc.',
    insight_source_id   BINARY(16)   NOT NULL
                        COMMENT 'Connector instance UUID (sipHash from bronze source_id)',
    source_account_id   VARCHAR(320) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL
                        COMMENT 'Source-native account identifier (same domain + size as persons.value_id)',
    person_id           BINARY(16)   NOT NULL
                        COMMENT 'Person UUID (random UUIDv7); derived from persons.person_id at rebuild time',
    author_person_id    BINARY(16)   NOT NULL
                        COMMENT 'Forwarded from the persons observation; 00..0 sentinel = auto-minted by seed',
    reason              VARCHAR(50)  NOT NULL
                        COMMENT 'Why this binding was created: initial-bootstrap | new-account | operator-merge | ...',
    valid_from          TIMESTAMP    NOT NULL
                        COMMENT 'When this binding became current (= created_at of the persons observation)',
    valid_to            TIMESTAMP    NULL
                        COMMENT 'When this binding ended (= next observation created_at); NULL = current',

    PRIMARY KEY (insight_tenant_id, insight_source_type, insight_source_id, source_account_id, valid_from),
    INDEX idx_current         (insight_tenant_id, insight_source_type, insight_source_id, source_account_id, valid_to),
    INDEX idx_person_id       (person_id),
    INDEX idx_tenant_person   (insight_tenant_id, person_id),
    INDEX idx_valid_from      (insight_tenant_id, valid_from)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
";

const DROP_PERSONS: &str = "DROP TABLE IF EXISTS persons";
const DROP_ACCOUNT_PERSON_MAP: &str = "DROP TABLE IF EXISTS account_person_map";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared(CREATE_PERSONS).await?;
        db.execute_unprepared(CREATE_ACCOUNT_PERSON_MAP).await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared(DROP_ACCOUNT_PERSON_MAP).await?;
        db.execute_unprepared(DROP_PERSONS).await?;
        Ok(())
    }
}
