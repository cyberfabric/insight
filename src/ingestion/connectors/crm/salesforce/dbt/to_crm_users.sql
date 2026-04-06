-- Bronze → Silver step 1: Salesforce Users → crm_users
-- Full-refresh source (small table). Identity key: email → person_id in step 2.
{{ config(
    materialized='view',
    schema='salesforce',
    tags=['silver:class_crm_users']
) }}

SELECT
    Id                                              AS user_id,
    Email                                           AS email,
    FirstName                                       AS first_name,
    LastName                                        AS last_name,
    Title                                           AS title,
    Department                                      AS department,
    toInt64(IsActive = true)                        AS is_active,
    toJSONString(map(
        'Username',   coalesce(toString(Username), ''),
        'ProfileId',  coalesce(toString(ProfileId), ''),
        'UserRoleId', coalesce(toString(UserRoleId), ''),
        'IsDeleted',  toString(coalesce(IsDeleted, false))
    ))                                              AS metadata,
    collected_at,
    data_source,
    toUnixTimestamp64Milli(
        parseDateTimeBestEffort(SystemModstamp)
    )                                               AS _version
FROM {{ source('salesforce', 'users') }}
