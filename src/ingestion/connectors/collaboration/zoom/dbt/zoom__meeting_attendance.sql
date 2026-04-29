{{ config(
    materialized='incremental',
    unique_key='unique_key',
    order_by=['unique_key'],
    settings={'allow_nullable_key': 1},
    schema='staging',
    tags=['zoom', 'silver:class_meeting_attendance']
) }}

-- One row per (meeting × participant × join session). A user who drops and
-- rejoins shows up as multiple rows; downstream aggregates should sum
-- duration_seconds.
--
-- See zoom__collab_meeting_activity for the rationale on filtering out
-- participants without an email.

SELECT
    p.tenant_id,
    p.source_id AS insight_source_id,
    MD5(concat(
        p.tenant_id, '-',
        p.source_id, '-',
        coalesce(p.meeting_uuid, ''), '-',
        coalesce(p.participant_uuid, p.id, ''), '-',
        coalesce(p.join_time, '')
    )) AS unique_key,
    p.meeting_uuid AS meeting_uid,
    p.email AS email,
    if(p.email IS NOT NULL AND p.email != '', lower(p.email), '') AS person_key,
    coalesce(p.user_name, '') AS user_name,
    coalesce(p.role, 'participant') AS role,
    parseDateTimeBestEffortOrNull(p.join_time) AS join_time,
    parseDateTimeBestEffortOrNull(p.leave_time) AS leave_time,
    if(p.join_time IS NOT NULL AND p.leave_time IS NOT NULL,
       toInt64(dateDiff('second', parseDateTimeBestEffort(p.join_time), parseDateTimeBestEffort(p.leave_time))),
       toInt64(0)) AS duration_seconds,
    toDate(parseDateTimeBestEffortOrNull(p.join_time)) AS date,
    coalesce(p.client, '') AS client,
    coalesce(p.device, '') AS device,
    coalesce(p.os, '') AS os,
    -- Per-session video flag is not exposed by Zoom; fall back to the
    -- meeting-level flag.
    m.has_video AS has_video,
    now() AS collected_at,
    'insight_zoom' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version
FROM {{ source('bronze_zoom', 'participants') }} p
LEFT JOIN {{ source('bronze_zoom', 'meetings') }} m
    ON p.meeting_uuid = m.uuid
    AND p.tenant_id = m.tenant_id
    AND p.source_id = m.source_id
WHERE p.join_time IS NOT NULL
  AND p.email IS NOT NULL
  AND p.email != ''
  AND p.meeting_uuid IS NOT NULL
{% if is_incremental() %}
  AND (
    (SELECT max(date) FROM {{ this }}) IS NULL
    OR toDate(parseDateTimeBestEffortOrNull(p.join_time)) > (SELECT max(date) - INTERVAL 3 DAY FROM {{ this }})
  )
{% endif %}
