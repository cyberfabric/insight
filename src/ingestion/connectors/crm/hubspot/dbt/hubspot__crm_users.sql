{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(unique_key)',
    settings={'allow_nullable_key': 1},
    tags=['hubspot', 'silver:class_crm_users']
) }}

SELECT * FROM (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS user_id,
        email                                           AS email,
        firstName                                       AS first_name,
        lastName                                        AS last_name,
        -- HubSpot Owners API exposes no title/department. Matching the
        -- Salesforce silver schema requires these columns to exist with
        -- compatible types, so emit explicit NULLs.
        CAST(NULL AS Nullable(String))                  AS title,
        CAST(NULL AS Nullable(String))                  AS department,
        toInt64(NOT coalesce(archived, false))          AS is_active,
        toJSONString(map(
            'userId',   coalesce(toString(userId), ''),
            'archived', toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        collected_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        )                                               AS _version
    FROM {{ source('bronze_hubspot', 'owners') }}
    -- Silver class_crm_users requires email NOT NULL for identity resolution.
    -- HubSpot Owners for deactivated internal users can lack an email.
    WHERE email IS NOT NULL AND email != ''
)
{% if is_incremental() %}
WHERE _version > coalesce((SELECT max(_version) FROM {{ this }}), 0)
{% endif %}
