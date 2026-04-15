-- Phase 1 (Initial Seed): Claude Team users → identity.bootstrap_inputs
-- One-time seed. Writes raw alias observations from Claude Team Bronze data.
-- Raw values preserved — normalization applied at read time by BootstrapJob.
-- Idempotent: skips rows that already exist (by source + alias_type + alias_value + account).
-- Dedup: takes latest row per email by _airbyte_extracted_at.
-- Source: docs/domain/identity-resolution/specs/DECOMPOSITION.md §2.1
--
-- Run: dbt run --select seed_bootstrap_inputs_from_claude_team
--
-- Test manually: http://localhost:30123/play  (user: default, password: clickhouse_local)
--   or:          http://localhost:8123/play
--
-- NOTE: schema='staging' is intentional. Unlike persons/aliases which write
-- directly to canonical tables, bootstrap_inputs uses a multi-source union
-- pattern: each source writes to staging.*, then identity.bootstrap_inputs
-- (VIEW) aggregates them via union_by_tag. Consistent with bamboohr/zoom
-- connector models that also target staging.

{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['identity:seed', 'silver', 'silver:bootstrap_inputs']
) }}

-- Column set matches bootstrap_inputs_from_history macro output.
-- TEMPORARY: insight_tenant_id/insight_source_id derived via sipHash128 until tenants/sources tables exist (REC-IR-04).

WITH latest AS (
    SELECT id AS account_id, email, name, tenant_id, source_id
    FROM {{ source('bronze_claude_team', 'claude_team_users') }}
    WHERE email IS NOT NULL AND email != ''
    QUALIFY row_number() OVER (PARTITION BY lower(trim(email)), coalesce(tenant_id, '') ORDER BY _airbyte_extracted_at DESC) = 1
),

observations AS (
    -- email
    SELECT
        toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, ''))))        AS insight_tenant_id,
        toUUID(UUIDNumToString(sipHash128(coalesce(source_id, ''))))        AS insight_source_id,
        'claude_team'                                               AS insight_source_type,
        account_id                                                  AS source_account_id,
        'email'                                                     AS alias_type,
        email                                                       AS alias_value,
        'bronze_claude_team.claude_team_users.email'                AS alias_field_name,
        'UPSERT'                                                    AS operation_type,
        now64(3)                                                    AS _synced_at
    FROM latest

    UNION ALL

    -- platform_id (Claude Team user ID)
    SELECT
        toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, '')))),
        toUUID(UUIDNumToString(sipHash128(coalesce(source_id, '')))),
        'claude_team',
        account_id,
        'platform_id',
        account_id,
        'bronze_claude_team.claude_team_users.id',
        'UPSERT',
        now64(3)
    FROM latest
    WHERE account_id IS NOT NULL AND account_id != ''

    UNION ALL

    -- display_name
    SELECT
        toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, '')))),
        toUUID(UUIDNumToString(sipHash128(coalesce(source_id, '')))),
        'claude_team',
        account_id,
        'display_name',
        name,
        'bronze_claude_team.claude_team_users.name',
        'UPSERT',
        now64(3)
    FROM latest
    WHERE name IS NOT NULL AND name != ''
)

SELECT o.* FROM observations o
{% if is_incremental() %}
LEFT ANTI JOIN {{ this }} existing
    ON  o.alias_type          = existing.alias_type
    AND o.alias_value         = existing.alias_value
    AND o.source_account_id   = existing.source_account_id
    AND existing.insight_source_type = 'claude_team'
    AND existing.insight_tenant_id = o.insight_tenant_id
{% endif %}
