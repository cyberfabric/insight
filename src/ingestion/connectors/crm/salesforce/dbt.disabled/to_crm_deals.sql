-- Bronze → Silver step 1: Salesforce Opportunities → crm_deals
-- Incremental via SystemModstamp. IsClosed/IsWon are native Salesforce fields.
{{ config(materialized='incremental', unique_key='deal_id', schema='salesforce', tags=['silver:class_crm_deals']) }}

SELECT
    Id                                              AS deal_id,
    Name                                            AS name,
    ForecastCategory                                AS pipeline,
    StageName                                       AS stage,
    Amount                                          AS amount,
    toDateOrNull(CloseDate)                         AS close_date,
    OwnerId                                         AS owner_id,
    AccountId                                       AS account_id,
    toInt64(IsClosed = true)                        AS is_closed,
    toInt64(IsWon = true)                           AS is_won,
    LeadSource                                      AS lead_source,
    Probability                                     AS probability,
    toJSONString(map(
        'Type',            coalesce(toString(Type), ''),
        'CurrencyIsoCode', coalesce(toString(CurrencyIsoCode), ''),
        'IsDeleted',       toString(coalesce(IsDeleted, false))
    ))                                              AS metadata,
    CAST(map() AS Map(String, String))              AS custom_str_attrs,
    CAST(map() AS Map(String, Float64))             AS custom_num_attrs,
    parseDateTimeBestEffort(CreatedDate)             AS created_at,
    parseDateTimeBestEffort(LastModifiedDate)        AS updated_at,
    data_source,
    toUnixTimestamp64Milli(
        parseDateTimeBestEffort(SystemModstamp)
    )                                               AS _version
FROM {{ source('salesforce', 'opportunities') }}
{% if is_incremental() %}
WHERE toUnixTimestamp64Milli(parseDateTimeBestEffort(SystemModstamp))
      > (SELECT coalesce(max(_version), 0) FROM {{ this }})
{% endif %}
