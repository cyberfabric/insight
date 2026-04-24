{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(unique_key)',
    settings={'allow_nullable_key': 1},
    tags=['hubspot', 'silver:class_crm_activities']
) }}

WITH calls AS (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS activity_id,
        'call'                                          AS activity_type,
        properties_hubspot_owner_id                     AS owner_id,
        arrayElement(coalesce(associations_contacts, []), 1)  AS contact_id,
        arrayElement(coalesce(associations_deals, []), 1)     AS deal_id,
        arrayElement(coalesce(associations_companies, []), 1) AS account_id,
        -- Deterministic fallback so timestamp never NULLs: try hs_timestamp,
        -- then createdAt, finally epoch 0 so Silver schema `not_null` holds.
        coalesce(
            parseDateTime64BestEffortOrNull(toString(properties_hs_timestamp), 3),
            parseDateTime64BestEffortOrNull(toString(createdAt), 3),
            toDateTime64(0, 3)
        )                                               AS timestamp,
        -- hs_call_duration is in milliseconds. Preserve NULLs so Silver can
        -- distinguish "unknown duration" from a real zero-duration call.
        CASE
            WHEN properties_hs_call_duration IS NULL THEN NULL
            ELSE intDiv(toInt64OrNull(properties_hs_call_duration), 1000)
        END                                             AS duration_seconds,
        properties_hs_call_disposition                  AS outcome,
        toJSONString(map(
            'title',          coalesce(toString(properties_hs_call_title), ''),
            'direction',      coalesce(toString(properties_hs_call_direction), ''),
            'archived',       toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        ) AS _version
    FROM {{ source('bronze_hubspot', 'engagements_calls') }}
),
emails AS (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS activity_id,
        'email'                                         AS activity_type,
        properties_hubspot_owner_id                     AS owner_id,
        arrayElement(coalesce(associations_contacts, []), 1)  AS contact_id,
        arrayElement(coalesce(associations_deals, []), 1)     AS deal_id,
        arrayElement(coalesce(associations_companies, []), 1) AS account_id,
        -- Deterministic fallback so timestamp never NULLs: try hs_timestamp,
        -- then createdAt, finally epoch 0 so Silver schema `not_null` holds.
        coalesce(
            parseDateTime64BestEffortOrNull(toString(properties_hs_timestamp), 3),
            parseDateTime64BestEffortOrNull(toString(createdAt), 3),
            toDateTime64(0, 3)
        )                                               AS timestamp,
        CAST(NULL AS Nullable(Int64))                   AS duration_seconds,
        properties_hs_email_status                      AS outcome,
        toJSONString(map(
            'subject',        coalesce(toString(properties_hs_email_subject), ''),
            'direction',      coalesce(toString(properties_hs_email_direction), ''),
            'archived',       toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        ) AS _version
    FROM {{ source('bronze_hubspot', 'engagements_emails') }}
),
meetings AS (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS activity_id,
        'meeting'                                       AS activity_type,
        properties_hubspot_owner_id                     AS owner_id,
        arrayElement(coalesce(associations_contacts, []), 1)  AS contact_id,
        arrayElement(coalesce(associations_deals, []), 1)     AS deal_id,
        arrayElement(coalesce(associations_companies, []), 1) AS account_id,
        -- Deterministic fallback: meeting_start → hs_timestamp → createdAt → epoch 0.
        coalesce(
            parseDateTime64BestEffortOrNull(toString(properties_hs_meeting_start_time), 3),
            parseDateTime64BestEffortOrNull(toString(properties_hs_timestamp), 3),
            parseDateTime64BestEffortOrNull(toString(createdAt), 3),
            toDateTime64(0, 3)
        )                                               AS timestamp,
        -- Meeting duration: start/end are ms-since-epoch strings. Preserve
        -- NULLs so "unknown duration" is distinguishable from zero-length.
        CASE
            WHEN toInt64OrNull(properties_hs_meeting_end_time) IS NOT NULL
             AND toInt64OrNull(properties_hs_meeting_start_time) IS NOT NULL
            THEN intDiv(
                toInt64OrNull(properties_hs_meeting_end_time) - toInt64OrNull(properties_hs_meeting_start_time),
                1000
            )
            ELSE NULL
        END                                             AS duration_seconds,
        properties_hs_meeting_outcome                   AS outcome,
        toJSONString(map(
            'title',          coalesce(toString(properties_hs_meeting_title), ''),
            'location',       coalesce(toString(properties_hs_meeting_location), ''),
            'archived',       toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        ) AS _version
    FROM {{ source('bronze_hubspot', 'engagements_meetings') }}
),
tasks AS (
    SELECT
        tenant_id,
        source_id,
        unique_key,
        id                                              AS activity_id,
        'task'                                          AS activity_type,
        properties_hubspot_owner_id                     AS owner_id,
        arrayElement(coalesce(associations_contacts, []), 1)  AS contact_id,
        arrayElement(coalesce(associations_deals, []), 1)     AS deal_id,
        arrayElement(coalesce(associations_companies, []), 1) AS account_id,
        -- Deterministic fallback so timestamp never NULLs: try hs_timestamp,
        -- then createdAt, finally epoch 0 so Silver schema `not_null` holds.
        coalesce(
            parseDateTime64BestEffortOrNull(toString(properties_hs_timestamp), 3),
            parseDateTime64BestEffortOrNull(toString(createdAt), 3),
            toDateTime64(0, 3)
        )                                               AS timestamp,
        CAST(NULL AS Nullable(Int64))                   AS duration_seconds,
        properties_hs_task_status                       AS outcome,
        toJSONString(map(
            'subject',        coalesce(toString(properties_hs_task_subject), ''),
            'priority',       coalesce(toString(properties_hs_task_priority), ''),
            'type',           coalesce(toString(properties_hs_task_type), ''),
            'archived',       toString(coalesce(archived, false))
        ))                                              AS metadata,
        custom_fields,
        parseDateTime64BestEffortOrNull(createdAt, 3)   AS created_at,
        data_source,
        coalesce(
            toUnixTimestamp64Milli(parseDateTime64BestEffortOrNull(updatedAt, 3)),
            0
        ) AS _version
    FROM {{ source('bronze_hubspot', 'engagements_tasks') }}
),
combined AS (
    SELECT * FROM calls
    UNION ALL SELECT * FROM emails
    UNION ALL SELECT * FROM meetings
    UNION ALL SELECT * FROM tasks
)
SELECT * FROM combined
{% if is_incremental() %}
WHERE _version > coalesce((SELECT max(_version) FROM {{ this }}), 0)
{% endif %}
