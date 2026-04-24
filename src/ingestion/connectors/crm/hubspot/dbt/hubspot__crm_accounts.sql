{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(unique_key)',
    settings={'allow_nullable_key': 1},
    tags=['hubspot', 'silver:class_crm_accounts']
) }}

SELECT * FROM (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS account_id,
        properties_name                                 AS name,
        properties_domain                               AS domain,
        properties_industry                             AS industry,
        properties_hubspot_owner_id                     AS owner_id,
        -- HubSpot has no native parent-account hierarchy in v3;
        -- parent_account_id stays NULL so Silver schema fit matches Salesforce.
        CAST(NULL AS Nullable(String))                  AS parent_account_id,
        toJSONString(map(
            'city',              coalesce(toString(properties_city), ''),
            'state',             coalesce(toString(properties_state), ''),
            'country',           coalesce(toString(properties_country), ''),
            'numberofemployees', coalesce(toString(properties_numberofemployees), ''),
            'annualrevenue',     coalesce(toString(properties_annualrevenue), ''),
            'archived',          toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        parseDateTime64BestEffortOrNull(updatedAt, 3)   AS updated_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        )                                               AS _version
    FROM {{ source('bronze_hubspot', 'companies') }}
)
{% if is_incremental() %}
WHERE _version > coalesce((SELECT max(_version) FROM {{ this }}), 0)
{% endif %}
