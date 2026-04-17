-- Identity proposals: generate matching suggestions for operator.
-- Incremental: processes only new identity_input rows since last run.
--
-- Proposal types:
--   'new_profile'    — profile not currently linked to any person
--   'email_match'    — two profiles share the same current email across sources
--   'deactivation'   — DELETE operation received, suggest deactivating aliases
--
-- Run: dbt run --select identity_proposals

{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='identity',
    tags=['identity']
) }}

WITH new_inputs AS (
    SELECT *
    FROM {{ ref('identity_input') }}
    {% if is_incremental() %}
    WHERE _synced_at > (SELECT max(_synced_at) FROM {{ this }})
    {% endif %}
),

-- All distinct profiles seen in new inputs
new_profiles AS (
    SELECT DISTINCT
        insight_tenant_id,
        source_type,
        profile_id
    FROM new_inputs
    WHERE operation = 'UPSERT'
),

-- Current link state: latest action per (tenant, source_type, profile_id)
current_link_state AS (
    SELECT
        insight_tenant_id,
        source_type,
        profile_id,
        action
    FROM (
        SELECT *,
            row_number() OVER (
                PARTITION BY insight_tenant_id, source_type, profile_id
                ORDER BY created_at DESC
            ) AS rn
        FROM identity.links
    )
    WHERE rn = 1
),

-- Profiles not currently linked (never linked, or last action = unlink)
unlinked AS (
    SELECT
        np.insight_tenant_id,
        np.source_type,
        np.profile_id
    FROM new_profiles np
    LEFT JOIN current_link_state cls
        ON np.insight_tenant_id = cls.insight_tenant_id
        AND np.source_type = cls.source_type
        AND np.profile_id = cls.profile_id
    WHERE cls.action IS NULL                -- never linked
       OR cls.action = ''                   -- ClickHouse default for empty LEFT JOIN
       OR cls.action = 'unlink'             -- was unlinked
),

-- Proposal: new unlinked profile
unlinked_proposals AS (
    SELECT
        generateUUIDv7() AS id,
        u.insight_tenant_id,
        'new_profile' AS proposal_type,
        'pending' AS status,
        u.source_type,
        u.profile_id,
        '' AS field_type,
        '' AS field_value,
        '' AS matched_source_type,
        '' AS matched_profile_id,
        '' AS match_reason,
        toFloat32(1.0) AS confidence,
        now64(3) AS _synced_at
    FROM unlinked u
),

-- Latest email per profile (not historical, only current)
current_emails AS (
    SELECT
        insight_tenant_id,
        source_type,
        profile_id,
        lower(trim(argMax(field_value, observed_at))) AS email
    FROM {{ ref('identity_input') }}
    WHERE field_type = 'email'
      AND operation = 'UPSERT'
      AND field_value != ''
    GROUP BY insight_tenant_id, source_type, profile_id
    HAVING email != ''
),

-- Cross-source email matches (only different source_types)
email_matches AS (
    SELECT DISTINCT
        a.insight_tenant_id AS insight_tenant_id,
        a.source_type AS source_type_a,
        a.profile_id AS profile_id_a,
        b.source_type AS source_type_b,
        b.profile_id AS profile_id_b,
        a.email AS email
    FROM current_emails a
    JOIN current_emails b
        ON a.insight_tenant_id = b.insight_tenant_id
        AND a.email = b.email
        AND a.source_type != b.source_type  -- cross-source only
        AND a.source_type < b.source_type   -- avoid (A,B) and (B,A) duplicates
    -- Only include matches involving new inputs
    JOIN new_profiles np
        ON np.insight_tenant_id = a.insight_tenant_id
        AND ((np.source_type = a.source_type AND np.profile_id = a.profile_id)
          OR (np.source_type = b.source_type AND np.profile_id = b.profile_id))
),

-- Proposal: email match between profiles
email_match_proposals AS (
    SELECT
        generateUUIDv7() AS id,
        em.insight_tenant_id,
        'email_match' AS proposal_type,
        'pending' AS status,
        em.source_type_a AS source_type,
        em.profile_id_a AS profile_id,
        'email' AS field_type,
        em.email AS field_value,
        em.source_type_b AS matched_source_type,
        em.profile_id_b AS matched_profile_id,
        'same_email' AS match_reason,
        toFloat32(1.0) AS confidence,
        now64(3) AS _synced_at
    FROM email_matches em
),

-- Proposal: deactivation (DELETE from connector)
deactivation_proposals AS (
    SELECT
        generateUUIDv7() AS id,
        ni.insight_tenant_id,
        'deactivation' AS proposal_type,
        'pending' AS status,
        ni.source_type,
        ni.profile_id,
        ni.field_type,
        '' AS field_value,
        '' AS matched_source_type,
        '' AS matched_profile_id,
        'connector_delete' AS match_reason,
        toFloat32(1.0) AS confidence,
        now64(3) AS _synced_at
    FROM new_inputs ni
    WHERE ni.operation = 'DELETE'
),

all_proposals AS (
    SELECT * FROM unlinked_proposals
    UNION ALL
    SELECT * FROM email_match_proposals
    UNION ALL
    SELECT * FROM deactivation_proposals
)

-- Deduplicate: don't create proposals that already exist
SELECT ap.*
FROM all_proposals ap
{% if is_incremental() %}
LEFT ANTI JOIN {{ this }} existing
    ON ap.insight_tenant_id = existing.insight_tenant_id
    AND ap.proposal_type = existing.proposal_type
    AND ap.source_type = existing.source_type
    AND ap.profile_id = existing.profile_id
    AND ap.field_type = existing.field_type
    AND ap.field_value = existing.field_value
    AND ap.matched_source_type = existing.matched_source_type
    AND ap.matched_profile_id = existing.matched_profile_id
{% endif %}
