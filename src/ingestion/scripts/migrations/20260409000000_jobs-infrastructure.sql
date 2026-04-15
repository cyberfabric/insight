-- Job infrastructure: job registry and run history.
-- Used by BootstrapJob and future scheduled jobs.
-- Source: docs/domain/identity-resolution/specs/DESIGN.md (BootstrapJob)

-- ============================================================
-- identity.jobs — registered job definitions
-- ============================================================

CREATE TABLE IF NOT EXISTS identity.jobs
(
    id          UUID DEFAULT generateUUIDv7(),
    name        String,
    job_type    LowCardinality(String) DEFAULT 'manual',
    description String DEFAULT '',
    created_at  DateTime64(3, 'UTC') DEFAULT now64(3),
    updated_at  DateTime64(3, 'UTC') DEFAULT now64(3),
    is_deleted  UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (name);

-- ============================================================
-- identity.job_runs — execution history with watermarks
-- ============================================================

CREATE TABLE IF NOT EXISTS identity.job_runs
(
    id                      UUID DEFAULT generateUUIDv7(),
    job_name                String,
    insight_tenant_id       UUID,
    state                   LowCardinality(String) DEFAULT 'running',
    started_at              DateTime64(3, 'UTC') DEFAULT now64(3),
    finished_at             DateTime64(3, 'UTC') DEFAULT toDateTime64('1970-01-01 00:00:00.000', 3, 'UTC'),
    watermark               DateTime64(3, 'UTC') DEFAULT toDateTime64('1970-01-01 00:00:00.000', 3, 'UTC'),
    rows_processed          UInt64 DEFAULT 0,
    rows_aliases_created    UInt64 DEFAULT 0,
    rows_aliases_updated    UInt64 DEFAULT 0,
    rows_persons_created    UInt64 DEFAULT 0,
    error_message           String DEFAULT '',
    created_at              DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree
ORDER BY (job_name, insight_tenant_id, started_at);

-- ============================================================
-- Seed: register bootstrap_job
-- ============================================================

INSERT INTO identity.jobs (name, job_type, description)
VALUES ('bootstrap_job', 'manual', 'Processes bootstrap_inputs into aliases and persons');
