-- Phase 1 (Initial Seed): Cursor members → identity.aliases
-- One-time seed. Creates alias records linking cursor identities to persons.
-- Idempotent: skips aliases that already exist (by alias_type + alias_value + source).
-- Source: docs/domain/identity-resolution/specs/DECOMPOSITION.md §2.1
--
-- Prerequisite:
--   identity.aliases table created by scripts/migrations/20260408000000_init-identity.sql
--   person.persons populated by seed_persons_from_cursor
-- Run: dbt run --select seed_aliases_from_cursor

{{ config(
    materialized='incremental',
    unique_key='id',
    schema='identity',
    tags=['identity:seed', 'aliases']
) }}

-- depends_on: {{ ref('seed_persons_from_cursor') }}
-- depends_on: {{ ref('seed_persons_from_claude_team') }}

-- Each cursor member emits up to 3 alias rows: email, platform_id, display_name.
-- Join on email to resolve person_id from the seed_persons_from_cursor output.

WITH source AS (
    SELECT
        cm.id                                                       AS source_account_id,
        cm.name,
        cm.email,
        cm.tenant_id,
        cm.source_id                                                AS bronze_source_id,
        p.id                                                        AS person_id,
        p.insight_tenant_id
    FROM {{ source('bronze_cursor', 'cursor_members') }} cm
    INNER JOIN {{ ref('seed_persons_from_cursor') }} p
        ON lower(trim(cm.email)) = lower(p.email)
        AND toUUID(UUIDNumToString(sipHash128(coalesce(cm.tenant_id, '')))) = p.insight_tenant_id  -- TEMPORARY: sipHash128 until tenants table (REC-IR-04)
    WHERE cm.email IS NOT NULL AND cm.email != ''
),

-- Unpivot: one row per alias type
aliases AS (
    -- email
    SELECT
        generateUUIDv7()                                            AS id,
        insight_tenant_id,
        person_id,
        'email'                                                     AS alias_type,
        lower(trim(email))                                          AS alias_value,
        'bronze_cursor.cursor_members.email'                        AS alias_field_name,
        toUUID(UUIDNumToString(sipHash128(coalesce(bronze_source_id, '')))) AS insight_source_id,  -- TEMPORARY: sipHash128 until sources table (REC-IR-04)
        'cursor'                                                    AS insight_source_type,
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

    -- platform_id (cursor user ID)
    SELECT
        generateUUIDv7(),
        insight_tenant_id,
        person_id,
        'platform_id',
        trim(source_account_id),
        'bronze_cursor.cursor_members.id',
        toUUID(UUIDNumToString(sipHash128(coalesce(bronze_source_id, '')))),  -- TEMPORARY: sipHash128 until sources table (REC-IR-04)
        'cursor',
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
        'bronze_cursor.cursor_members.name',
        toUUID(UUIDNumToString(sipHash128(coalesce(bronze_source_id, '')))),  -- TEMPORARY: sipHash128 until sources table (REC-IR-04)
        'cursor',
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

SELECT a.* FROM aliases a
{% if is_incremental() %}
LEFT ANTI JOIN {{ this }} existing
    ON  a.alias_type          = existing.alias_type
    AND a.alias_value         = existing.alias_value
    AND a.insight_source_type = existing.insight_source_type
    AND a.source_account_id   = existing.source_account_id
    AND existing.is_deleted   = 0
{% endif %}
