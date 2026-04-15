-- Phase 1 (Initial Seed): Cursor members → identity.bootstrap_inputs
-- One-time seed. Writes raw alias observations from Cursor Bronze data.
-- Raw values preserved — normalization applied at read time by BootstrapJob.
-- Idempotent: skips rows that already exist (by source + alias_type + alias_value + account).
-- Source: docs/domain/identity-resolution/specs/DECOMPOSITION.md §2.1
--
-- Run: dbt run --select seed_bootstrap_inputs_from_cursor
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

-- Each cursor member emits up to 3 observation rows: email, platform_id, display_name.
-- Column set matches bootstrap_inputs_from_history macro output.
-- TEMPORARY: insight_tenant_id/insight_source_id derived via sipHash128 until tenants/sources tables exist (REC-IR-04).

WITH source AS (
    SELECT
        cm.id                                                       AS source_account_id,
        cm.name,
        cm.email,
        cm.tenant_id,
        cm.source_id
    FROM {{ source('bronze_cursor', 'cursor_members') }} cm
),

observations AS (
    -- email
    SELECT
        toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, ''))))        AS insight_tenant_id,
        toUUID(UUIDNumToString(sipHash128(coalesce(source_id, ''))))        AS insight_source_id,
        'cursor'                                                    AS insight_source_type,
        source_account_id,
        'email'                                                     AS alias_type,
        email                                                       AS alias_value,
        'bronze_cursor.cursor_members.email'                        AS alias_field_name,
        'UPSERT'                                                    AS operation_type,
        now64(3)                                                    AS _synced_at
    FROM source
    WHERE email IS NOT NULL AND email != ''

    UNION ALL

    -- platform_id (cursor user ID)
    SELECT
        toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, '')))),
        toUUID(UUIDNumToString(sipHash128(coalesce(source_id, '')))),
        'cursor',
        source_account_id,
        'platform_id',
        source_account_id,
        'bronze_cursor.cursor_members.id',
        'UPSERT',
        now64(3)
    FROM source
    WHERE source_account_id IS NOT NULL AND source_account_id != ''

    UNION ALL

    -- display_name
    SELECT
        toUUID(UUIDNumToString(sipHash128(coalesce(tenant_id, '')))),
        toUUID(UUIDNumToString(sipHash128(coalesce(source_id, '')))),
        'cursor',
        source_account_id,
        'display_name',
        name,
        'bronze_cursor.cursor_members.name',
        'UPSERT',
        now64(3)
    FROM source
    WHERE name IS NOT NULL AND name != ''
)

SELECT o.* FROM observations o
{% if is_incremental() %}
LEFT ANTI JOIN {{ this }} existing
    ON  o.alias_type          = existing.alias_type
    AND o.alias_value         = existing.alias_value
    AND o.source_account_id   = existing.source_account_id
    AND existing.insight_source_type = 'cursor'
    AND existing.insight_tenant_id = o.insight_tenant_id
{% endif %}
