{{ config(
    materialized='incremental',
    unique_key='unique_key',
    order_by=['unique_key'],
    settings={'allow_nullable_key': 1},
    schema='staging',
    tags=['zoom', 'silver:class_meeting']
) }}

-- One row per Zoom meeting (event grain).
-- Source: bronze_zoom.meetings — Zoom Dashboard API only returns meetings
-- hosted by users in the connected Zoom tenant. Externally hosted meetings
-- (where someone joins a customer's Zoom) are NOT present here.
-- That's a known data gap — see class_meeting_invite for the upper bound
-- derived from M365 calendar.

SELECT
    tenant_id,
    source_id AS insight_source_id,
    MD5(concat(tenant_id, '-', source_id, '-', uuid)) AS unique_key,
    uuid AS meeting_uid,
    coalesce(topic, '') AS topic,
    email AS host_email,
    if(email IS NOT NULL AND email != '', lower(email), '') AS host_person_key,
    parseDateTimeBestEffortOrNull(start_time) AS start_time,
    parseDateTimeBestEffortOrNull(end_time) AS end_time,
    if(start_time IS NOT NULL AND end_time IS NOT NULL,
       toInt64(dateDiff('second', parseDateTimeBestEffort(start_time), parseDateTimeBestEffort(end_time))),
       toInt64(0)) AS duration_seconds,
    toDate(parseDateTimeBestEffortOrNull(start_time)) AS date,
    toInt64(coalesce(toFloat64OrZero(toString(participants)), 0)) AS participant_count,
    has_video,
    has_screen_share,
    has_recording,
    -- bronze_zoom.meetings only contains meetings hosted by the connected
    -- Zoom tenant, so is_external_host is always false here. Field exists
    -- so other sources (future Teams callRecords, future external Zoom feeds)
    -- can populate it.
    toUInt8(0) AS is_external_host,
    now() AS collected_at,
    'insight_zoom' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version
FROM {{ source('bronze_zoom', 'meetings') }}
WHERE uuid IS NOT NULL
  AND uuid != ''
{% if is_incremental() %}
  AND (
    (SELECT max(date) FROM {{ this }}) IS NULL
    OR toDate(parseDateTimeBestEffortOrNull(start_time)) > (SELECT max(date) - INTERVAL 3 DAY FROM {{ this }})
  )
{% endif %}
