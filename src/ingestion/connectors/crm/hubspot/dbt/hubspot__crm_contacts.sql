{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(unique_key)',
    settings={'allow_nullable_key': 1},
    tags=['hubspot', 'silver:class_crm_contacts']
) }}

SELECT * FROM (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS contact_id,
        properties_email                                AS email,
        properties_firstname                            AS first_name,
        properties_lastname                             AS last_name,
        properties_hubspot_owner_id                     AS owner_id,
        -- HubSpot allows multiple companies per contact; Silver keeps primary.
        arrayElement(
            coalesce(associations_companies, []), 1
        )                                               AS account_id,
        properties_lifecyclestage                       AS lifecycle_stage,
        toJSONString(map(
            'hs_lead_status',     coalesce(toString(properties_hs_lead_status), ''),
            'hs_analytics_source',coalesce(toString(properties_hs_analytics_source), ''),
            'phone',              coalesce(toString(properties_phone), ''),
            'archived',           toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        parseDateTime64BestEffortOrNull(updatedAt, 3)   AS updated_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        )                                               AS _version
    FROM {{ source('bronze_hubspot', 'contacts') }}
)
{% if is_incremental() %}
WHERE _version > coalesce((SELECT max(_version) FROM {{ this }}), 0)
{% endif %}
