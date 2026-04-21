{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['m365', 'silver:class_collab_meeting_activity']
) }}

SELECT
    tenant_id,
    source_id AS insight_source_id,
    MD5(concat(tenant_id, '-', source_id, '-', coalesce(userPrincipalName, ''), '-', toString(reportRefreshDate))) AS unique_key,
    userPrincipalName AS user_id,
    userPrincipalName AS user_name,
    userPrincipalName AS email,
    if(userPrincipalName IS NOT NULL AND userPrincipalName != '',
       lower(userPrincipalName),
       '') AS person_key,
    toDate(reportRefreshDate) AS date,
    callCount AS calls_count,
    meetingsOrganizedCount AS meetings_organized,
    meetingsAttendedCount AS meetings_attended,
    adHocMeetingsOrganizedCount AS adhoc_meetings_organized,
    adHocMeetingsAttendedCount AS adhoc_meetings_attended,
    COALESCE(scheduledOneTimeMeetingsOrganizedCount, 0)
        + COALESCE(scheduledRecurringMeetingsOrganizedCount, 0) AS scheduled_meetings_organized,
    COALESCE(scheduledOneTimeMeetingsAttendedCount, 0)
        + COALESCE(scheduledRecurringMeetingsAttendedCount, 0) AS scheduled_meetings_attended,
    toInt64(toSeconds(parseTimeDelta(ifNull(audioDuration, 'PT0S')))) AS audio_duration_seconds,
    toInt64(toSeconds(parseTimeDelta(ifNull(videoDuration, 'PT0S')))) AS video_duration_seconds,
    toInt64(toSeconds(parseTimeDelta(ifNull(screenShareDuration, 'PT0S')))) AS screen_share_duration_seconds,
    reportPeriod AS report_period,
    now() AS collected_at,
    'insight_m365' AS data_source,
    toUnixTimestamp64Milli(now()) AS _version
FROM {{ source('bronze_m365', 'teams_activity') }}
WHERE userPrincipalName IS NOT NULL
  AND userPrincipalName != ''
{% if is_incremental() %}
  AND (
    (SELECT max(date) FROM {{ this }}) IS NULL
    OR toDate(reportRefreshDate) > (SELECT max(date) - INTERVAL 3 DAY FROM {{ this }})
  )
{% endif %}
