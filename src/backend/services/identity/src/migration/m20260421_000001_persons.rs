//! Initial schema: the `persons` identity-attribute history table.
//!
//! Each row is one observed field value for a person from one source at a
//! point in time (SCD-style append-only log). The `uq_person_observation`
//! UNIQUE key makes `INSERT IGNORE` safe for idempotent re-runs of the
//! one-shot seed (see ADR-0002 in the identity-resolution specs).
//!
//! The schema is applied via raw DDL rather than the SeaORM DSL because
//! it relies on per-column `CHARACTER SET` and `COLLATE` clauses (ASCII
//! for UUID / enum-like columns, `utf8mb4_bin` for `alias_value`) that
//! the DSL does not expose cleanly. Raw DDL keeps the declaration exactly
//! faithful to the design intent.

use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const CREATE_PERSONS: &str = r"
CREATE TABLE IF NOT EXISTS persons (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    alias_type          VARCHAR(50)   CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL
                        COMMENT 'Field kind: email, display_name, platform_id, employee_id, etc.',
    insight_source_type VARCHAR(100)  CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL
                        COMMENT 'Source system: bamboohr, zoom, cursor, claude_admin, etc.',
    insight_source_id   CHAR(36)      CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL
                        COMMENT 'Connector instance UUID (sipHash from bronze source_id)',
    insight_tenant_id   CHAR(36)      CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL
                        COMMENT 'Tenant UUID (sipHash from bronze tenant_id)',
    alias_value         VARCHAR(512)  CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL
                        COMMENT 'Field value (email address, display name, platform ID, etc.)',
    person_id           CHAR(36)      CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL
                        COMMENT 'Person UUID -- deterministic UUIDv5 from (insight_tenant_id, lower(trim(email)))',
    author_person_id    CHAR(36)      CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL
                        COMMENT 'Person UUID of who/what made this change',
    reason              TEXT          NOT NULL DEFAULT ''
                        COMMENT 'Optional change reason / comment',
    created_at          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                        COMMENT 'When this record was created',

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

const DROP_PERSONS: &str = "DROP TABLE IF EXISTS persons";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared(CREATE_PERSONS).await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared(DROP_PERSONS).await?;
        Ok(())
    }
}
