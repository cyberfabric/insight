//! Initial schema for identity-resolution `MariaDB` tables:
//!
//! 1. `persons` -- identity-attribute history (SCD-style append-only).
//! 2. `account_person_map` -- stable mapping of source-accounts to
//!    `person_id`s. Primary source of truth for "which person does this
//!    source-account belong to"; seed reads/writes this to make re-runs
//!    idempotent without deriving identifiers from mutable fields
//!    (email). See ADR-0002.
//!
//! Column types mirror `analytics-api` conventions: `BINARY(16)` for
//! UUIDs (`SeaORM`'s `.uuid()` default on `MariaDB`), `TIMESTAMP` for
//! wall-clock columns (stored internally as UTC by `MariaDB`). The one
//! non-standard choice is `alias_value VARCHAR(512) COLLATE utf8mb4_bin`:
//! identity observations are compared byte-wise for uniqueness, so
//! "Foo@x.com" and "foo@x.com" are two distinct observations rather
//! than colliding through case-insensitive collation.
//!
//! The schema is applied via raw DDL rather than the `SeaORM` DSL because
//! per-column `COLLATE utf8mb4_bin` on `alias_value` is not cleanly
//! expressible through the DSL.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const CREATE_PERSONS: &str = r"
CREATE TABLE IF NOT EXISTS persons (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    alias_type          VARCHAR(50)  NOT NULL
                        COMMENT 'Field kind: email, display_name, platform_id, employee_id, etc.',
    insight_source_type VARCHAR(100) NOT NULL
                        COMMENT 'Source system: bamboohr, zoom, cursor, claude_admin, etc.',
    insight_source_id   BINARY(16)   NOT NULL
                        COMMENT 'Connector instance UUID (sipHash from bronze source_id)',
    insight_tenant_id   BINARY(16)   NOT NULL
                        COMMENT 'Tenant UUID (sipHash from bronze tenant_id)',
    alias_value         VARCHAR(512) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL
                        COMMENT 'Field value (email address, display name, platform ID, etc.)',
    person_id           BINARY(16)   NOT NULL
                        COMMENT 'Person UUID -- stable, looked up via account_person_map, never re-derived',
    author_person_id    BINARY(16)   NOT NULL
                        COMMENT 'Person UUID of who/what made this change',
    reason              TEXT         NOT NULL DEFAULT ''
                        COMMENT 'Optional change reason / comment',
    created_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                        COMMENT 'When this record was created (stored internally in UTC)',

    UNIQUE KEY uq_person_observation (
        insight_tenant_id, person_id, insight_source_type, insight_source_id,
        alias_type, alias_value
    ),
    INDEX idx_person_id (person_id),
    INDEX idx_tenant_person (insight_tenant_id, person_id),
    INDEX idx_alias_lookup (insight_tenant_id, alias_type, alias_value),
    INDEX idx_source (insight_source_type, insight_source_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
";

/// `account_person_map` -- stable (tenant, source-instance, account) ->
/// `person_id` mapping. Written once per account at first observation;
/// never updated, never re-derived. Guarantees `person_id` stability
/// across re-seeds even when mutable attributes (email, name) change
/// at the source.
const CREATE_ACCOUNT_PERSON_MAP: &str = r"
CREATE TABLE IF NOT EXISTS account_person_map (
    insight_tenant_id   BINARY(16)   NOT NULL
                        COMMENT 'Tenant UUID (sipHash from bronze tenant_id)',
    insight_source_type VARCHAR(100) NOT NULL
                        COMMENT 'Source system: bamboohr, zoom, cursor, claude_admin, etc.',
    insight_source_id   BINARY(16)   NOT NULL
                        COMMENT 'Connector instance UUID (sipHash from bronze source_id)',
    source_account_id   VARCHAR(255) NOT NULL
                        COMMENT 'Source-native account identifier (email-external-system ID, employee ID, user ID, etc.)',
    person_id           BINARY(16)   NOT NULL
                        COMMENT 'Person UUID (random UUIDv7, minted at first observation)',
    created_reason      VARCHAR(50)  NOT NULL
                        COMMENT 'Why this mapping was created: initial-bootstrap | new-account | operator-merge',
    created_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                        COMMENT 'When the mapping was created (UTC)',

    PRIMARY KEY (insight_tenant_id, insight_source_type, insight_source_id, source_account_id),
    INDEX idx_person_id (person_id),
    INDEX idx_tenant_person (insight_tenant_id, person_id)
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
