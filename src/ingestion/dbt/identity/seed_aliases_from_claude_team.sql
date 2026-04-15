-- Phase 1 (Initial Seed): Claude Team users → identity.aliases
-- Idempotent: skips aliases that already exist (by alias_type + alias_value + source).
-- Dedup: takes latest row per email by _airbyte_extracted_at.
-- Each user produces up to 3 aliases: email, platform_id, display_name.
-- Source: docs/domain/identity-resolution/specs/DECOMPOSITION.md §2.1
--
-- Prerequisite:
--   identity.aliases table created by scripts/migrations/20260408000000_init-identity.sql
--   person.persons populated (by seed_persons_from_cursor or seed_persons_from_claude_team)
-- Run: dbt run --select seed_aliases_from_claude_team
--
-- Test manually: http://localhost:30123/play  (user: default, password: clickhouse_local)
--   or:          http://localhost:8123/play

{{ config(
    materialized='incremental',
    unique_key='id',
    schema='identity',
    tags=['identity:seed', 'aliases']
) }}

-- depends_on: {{ ref('seed_persons_from_claude_team') }}
-- depends_on: {{ ref('seed_persons_from_cursor') }}

WITH latest AS (
    SELECT id AS account_id, email, name, tenant_id, source_id
    FROM {{ source('bronze_claude_team', 'claude_team_users') }}
    WHERE email IS NOT NULL AND email != ''
    QUALIFY row_number() OVER (PARTITION BY lower(trim(email)), coalesce(tenant_id, '') ORDER BY _airbyte_extracted_at DESC) = 1
),

source AS (
    SELECT
        l.account_id                                                AS source_account_id,
        l.name,
        l.email,
        l.source_id                                                 AS bronze_source_id,
        p.id                                                        AS person_id,
        p.insight_tenant_id
    FROM latest l
    INNER JOIN person.persons p ON lower(trim(l.email)) = lower(p.email)
        AND toUUID(UUIDNumToString(sipHash128(coalesce(l.tenant_id, '')))) = p.insight_tenant_id  -- TEMPORARY: sipHash128 until tenants table (REC-IR-04)
),

new_aliases AS (
    -- email
    SELECT
        generateUUIDv7()                                            AS id,
        insight_tenant_id,
        person_id,
        'email'                                                     AS alias_type,
        lower(trim(email))                                          AS alias_value,
        'bronze_claude_team.claude_team_users.email'                AS alias_field_name,
        toUUID(UUIDNumToString(sipHash128(coalesce(bronze_source_id, '')))) AS insight_source_id,  -- TEMPORARY: sipHash128 until sources table (REC-IR-04)
        'claude_team'                                               AS insight_source_type,
        source_account_id,
        toFloat32(1.0)                                              AS confidence,
        toUInt8(1)                                                  AS is_active,
        now64(3)                                                    AS effective_from,
        toDateTime64('1970-01-01 00:00:00.000', 3, 'UTC')          AS effective_to,
        now64(3)                                                    AS first_observed_at,
        now64(3)                                                    AS last_observed_at,
        now64(3)                                                    AS created_at,
        now64(3)                                                    AS updated_at,
        toUInt8(0)                                                  AS is_deleted
    FROM source
    WHERE email IS NOT NULL AND email != ''

    UNION ALL

    -- platform_id (Claude Team user ID)
    SELECT
        generateUUIDv7(),
        insight_tenant_id,
        person_id,
        'platform_id',
        trim(source_account_id),
        'bronze_claude_team.claude_team_users.id',
        toUUID(UUIDNumToString(sipHash128(coalesce(bronze_source_id, '')))),  -- TEMPORARY: sipHash128 until sources table (REC-IR-04)
        'claude_team',
        source_account_id,
        toFloat32(1.0),
        toUInt8(1),
        now64(3),
        toDateTime64('1970-01-01 00:00:00.000', 3, 'UTC'),
        now64(3),
        now64(3),
        now64(3),
        now64(3),
        toUInt8(0)
    FROM source
    WHERE source_account_id IS NOT NULL AND source_account_id != ''

    UNION ALL

    -- display_name
    SELECT
        generateUUIDv7(),
        insight_tenant_id,
        person_id,
        'display_name',
        trim(name),
        'bronze_claude_team.claude_team_users.name',
        toUUID(UUIDNumToString(sipHash128(coalesce(bronze_source_id, '')))),  -- TEMPORARY: sipHash128 until sources table (REC-IR-04)
        'claude_team',
        source_account_id,
        toFloat32(1.0),
        toUInt8(1),
        now64(3),
        toDateTime64('1970-01-01 00:00:00.000', 3, 'UTC'),
        now64(3),
        now64(3),
        now64(3),
        now64(3),
        toUInt8(0)
    FROM source
    WHERE name IS NOT NULL AND name != ''
)

SELECT na.* FROM new_aliases na
{% if is_incremental() %}
LEFT ANTI JOIN {{ this }} existing
    ON  na.alias_type          = existing.alias_type
    AND na.alias_value         = existing.alias_value
    AND na.source_account_id   = existing.source_account_id
    AND existing.insight_source_type = 'claude_team'
    AND existing.is_deleted    = 0
{% endif %}
