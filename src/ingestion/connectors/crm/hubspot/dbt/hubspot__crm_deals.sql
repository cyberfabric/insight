{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(unique_key)',
    settings={'allow_nullable_key': 1},
    tags=['hubspot', 'silver:class_crm_deals']
) }}

SELECT * FROM (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS deal_id,
        properties_dealname                             AS name,
        -- HubSpot has its own forecast category on hs_forecast_category —
        -- mirrors the Salesforce Opportunity.ForecastCategory column.
        properties_hs_forecast_category                 AS forecast_category,
        properties_dealstage                            AS stage,
        toFloat64OrNull(properties_amount)              AS amount,
        toDateOrNull(properties_closedate)              AS close_date,
        properties_hubspot_owner_id                     AS owner_id,
        arrayElement(
            coalesce(associations_companies, []), 1
        )                                               AS account_id,
        toInt64(coalesce(properties_hs_is_closed, 'false') = 'true')     AS is_closed,
        toInt64(coalesce(properties_hs_is_closed_won, 'false') = 'true') AS is_won,
        properties_hs_analytics_source                  AS lead_source,
        toFloat64OrNull(properties_hs_deal_stage_probability) AS probability,
        toJSONString(map(
            'pipeline',       coalesce(toString(properties_pipeline), ''),
            'deal_type',      coalesce(toString(properties_dealtype), ''),
            'archived',       toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        parseDateTime64BestEffortOrNull(updatedAt, 3)   AS updated_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        )                                               AS _version
    FROM {{ source('bronze_hubspot', 'deals') }}
)
{% if is_incremental() %}
WHERE _version > coalesce((SELECT max(_version) FROM {{ this }}), 0)
{% endif %}
