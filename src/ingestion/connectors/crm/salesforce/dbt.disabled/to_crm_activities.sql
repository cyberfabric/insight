-- Bronze → Silver step 1: Salesforce Tasks + Events → crm_activities
-- UNION ALL with activity_type discriminator.
-- WhatId polymorphic resolution: 006=Opportunity→deal_id, 001=Account→account_id.
-- Duration: CallDurationInSeconds (tasks), DurationInMinutes*60 (events).
{{ config(materialized='incremental', unique_key='activity_id', schema='salesforce', tags=['silver:class_crm_activities']) }}

WITH tasks AS (
    SELECT
        Id                                          AS activity_id,
        CASE
            WHEN CallType IS NOT NULL THEN 'call'
            WHEN TaskSubtype = 'Email' THEN 'email'
            ELSE 'task'
        END                                         AS activity_type,
        OwnerId                                     AS owner_id,
        WhoId                                       AS contact_id,
        CASE WHEN startsWith(coalesce(WhatId, ''), '006') THEN WhatId
             ELSE NULL END                          AS deal_id,
        CASE WHEN startsWith(coalesce(WhatId, ''), '001') THEN WhatId
             ELSE NULL END                          AS account_id,
        parseDateTimeBestEffort(
            coalesce(ActivityDate, toString(CreatedDate))
        )                                           AS timestamp,
        CASE WHEN CallType IS NOT NULL
             THEN toInt64(CallDurationInSeconds)
             ELSE NULL END                          AS duration_seconds,
        Status                                      AS outcome,
        toJSONString(map(
            'Subject',     coalesce(toString(Subject), ''),
            'Priority',    coalesce(toString(Priority), ''),
            'TaskSubtype', coalesce(toString(TaskSubtype), ''),
            'CallType',    coalesce(toString(CallType), ''),
            'IsDeleted',   toString(coalesce(IsDeleted, false))
        ))                                          AS metadata,
        parseDateTimeBestEffort(CreatedDate)         AS created_at,
        data_source,
        toUnixTimestamp64Milli(
            parseDateTimeBestEffort(SystemModstamp)
        )                                           AS _version
    FROM {{ source('salesforce', 'tasks') }}
    {% if is_incremental() %}
    WHERE toUnixTimestamp64Milli(parseDateTimeBestEffort(SystemModstamp))
          > (SELECT coalesce(max(_version), 0) FROM {{ this }})
    {% endif %}
),

events AS (
    SELECT
        Id                                          AS activity_id,
        CASE
            WHEN EventSubtype IS NULL OR EventSubtype = 'Event' THEN 'event'
            ELSE 'meeting'
        END                                         AS activity_type,
        OwnerId                                     AS owner_id,
        WhoId                                       AS contact_id,
        CASE WHEN startsWith(coalesce(WhatId, ''), '006') THEN WhatId
             ELSE NULL END                          AS deal_id,
        CASE WHEN startsWith(coalesce(WhatId, ''), '001') THEN WhatId
             ELSE NULL END                          AS account_id,
        parseDateTimeBestEffort(StartDateTime)       AS timestamp,
        toInt64(DurationInMinutes) * 60             AS duration_seconds,
        NULL                                        AS outcome,
        toJSONString(map(
            'Subject',      coalesce(toString(Subject), ''),
            'Location',     coalesce(toString(Location), ''),
            'EndDateTime',  coalesce(toString(EndDateTime), ''),
            'EventSubtype', coalesce(toString(EventSubtype), ''),
            'IsDeleted',    toString(coalesce(IsDeleted, false))
        ))                                          AS metadata,
        parseDateTimeBestEffort(CreatedDate)         AS created_at,
        data_source,
        toUnixTimestamp64Milli(
            parseDateTimeBestEffort(SystemModstamp)
        )                                           AS _version
    FROM {{ source('salesforce', 'events') }}
    {% if is_incremental() %}
    WHERE toUnixTimestamp64Milli(parseDateTimeBestEffort(SystemModstamp))
          > (SELECT coalesce(max(_version), 0) FROM {{ this }})
    {% endif %}
)

SELECT
    activity_id,
    activity_type,
    owner_id,
    contact_id,
    deal_id,
    account_id,
    timestamp,
    duration_seconds,
    outcome,
    metadata,
    created_at,
    data_source,
    _version
FROM tasks

UNION ALL

SELECT
    activity_id,
    activity_type,
    owner_id,
    contact_id,
    deal_id,
    account_id,
    timestamp,
    duration_seconds,
    outcome,
    metadata,
    created_at,
    data_source,
    _version
FROM events
