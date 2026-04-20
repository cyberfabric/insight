-- Bronze → Silver step 1: Salesforce Accounts → crm_accounts
-- Reference data — used for grouping deals and activities by company.
{{ config(
    materialized='view',
    schema='salesforce',
    tags=['silver:class_crm_accounts']
) }}

SELECT
    Id                                              AS account_id,
    Name                                            AS name,
    Website                                         AS domain,
    Industry                                        AS industry,
    OwnerId                                         AS owner_id,
    ParentId                                        AS parent_account_id,
    toJSONString(map(
        'Type',              coalesce(toString(Type), ''),
        'BillingCity',       coalesce(toString(BillingCity), ''),
        'BillingState',      coalesce(toString(BillingState), ''),
        'BillingCountry',    coalesce(toString(BillingCountry), ''),
        'NumberOfEmployees', coalesce(toString(NumberOfEmployees), ''),
        'AnnualRevenue',     coalesce(toString(AnnualRevenue), ''),
        'IsDeleted',         toString(coalesce(IsDeleted, false))
    ))                                              AS metadata,
    parseDateTimeBestEffort(CreatedDate)             AS created_at,
    parseDateTimeBestEffort(LastModifiedDate)        AS updated_at,
    data_source,
    toUnixTimestamp64Milli(
        parseDateTimeBestEffort(SystemModstamp)
    )                                               AS _version
FROM {{ source('salesforce', 'accounts') }}
