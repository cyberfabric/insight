-- Bronze → Silver step 1: Salesforce Contacts → crm_contacts
-- Reference data only — external customers, not resolved to person_id.
{{ config(
    materialized='view',
    schema='salesforce',
    tags=['silver:class_crm_contacts']
) }}

SELECT
    Id                                              AS contact_id,
    Email                                           AS email,
    FirstName                                       AS first_name,
    LastName                                        AS last_name,
    OwnerId                                         AS owner_id,
    AccountId                                       AS account_id,
    NULL                                            AS lifecycle_stage,
    toJSONString(map(
        'Title',      coalesce(toString(Title), ''),
        'Phone',      coalesce(toString(Phone), ''),
        'LeadSource', coalesce(toString(LeadSource), ''),
        'IsDeleted',  toString(coalesce(IsDeleted, false))
    ))                                              AS metadata,
    CAST(map() AS Map(String, String))              AS custom_str_attrs,
    CAST(map() AS Map(String, Float64))             AS custom_num_attrs,
    parseDateTimeBestEffort(CreatedDate)             AS created_at,
    parseDateTimeBestEffort(LastModifiedDate)        AS updated_at,
    data_source,
    toUnixTimestamp64Milli(
        parseDateTimeBestEffort(SystemModstamp)
    )                                               AS _version
FROM {{ source('salesforce', 'contacts') }}
