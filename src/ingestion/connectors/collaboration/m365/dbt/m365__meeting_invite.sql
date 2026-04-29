{{ config(
    materialized='incremental',
    unique_key='unique_key',
    order_by=['unique_key'],
    settings={'allow_nullable_key': 1},
    schema='staging',
    tags=['m365', 'silver:class_meeting_invite']
) }}

-- One row per calendar event (meeting invite, planned grain).
-- Source: bronze_m365.calendar_events from Microsoft Graph /users/{id}/calendarView.
--
-- This is the "intent" layer: what was scheduled, not what actually happened.
-- Pair with class_meeting_attendance to detect gaps — e.g. invites with a
-- Zoom join_url that have no matching Zoom attendance row likely represent
-- meetings hosted on an external Zoom tenant (which Zoom Reports API does
-- not expose).
--
-- online_provider derivation:
--   * Microsoft populates onlineMeetingProvider for Teams/Skype natively.
--   * Zoom invites come through with onlineMeetingProvider='unknown' (or null)
--     and a zoom.us/zoomgov.com URL in the body. We pattern-match on the URL.

WITH base AS (
    SELECT
        tenant_id,
        source_id,
        id AS invite_uid,
        coalesce(subject, '') AS subject,
        user_id AS organizer_user_graph_id,
        JSONExtractString(toString(organizer), 'emailAddress', 'address') AS organizer_email_raw,
        parseDateTimeBestEffortOrNull(JSONExtractString(toString(start), 'dateTime')) AS start_time,
        parseDateTimeBestEffortOrNull(JSONExtractString(toString(end), 'dateTime')) AS end_time,
        coalesce(isOnlineMeeting, false) AS is_online,
        coalesce(onlineMeetingProvider, '') AS provider_raw,
        coalesce(JSONExtractString(toString(onlineMeeting), 'joinUrl'), '') AS online_join_url,
        coalesce(bodyPreview, '') AS body_preview,
        coalesce(webLink, '') AS web_link,
        coalesce(isCancelled, false) AS is_cancelled,
        coalesce(showAs, '') AS show_as,
        coalesce(sensitivity, '') AS sensitivity,
        coalesce(seriesMasterId, '') AS series_master_id,
        coalesce(type, '') AS event_type,
        toString(attendees) AS attendees_json,
        unique_key AS bronze_unique_key
    FROM {{ source('bronze_m365', 'calendar_events') }}
    WHERE id IS NOT NULL
      AND id != ''
)
SELECT
    tenant_id,
    source_id AS insight_source_id,
    MD5(concat(tenant_id, '-', source_id, '-', invite_uid)) AS unique_key,
    invite_uid,
    subject,
    organizer_email_raw AS organizer_email,
    if(organizer_email_raw != '', lower(organizer_email_raw), '') AS organizer_person_key,
    start_time,
    end_time,
    if(start_time IS NOT NULL AND end_time IS NOT NULL,
       toInt64(dateDiff('second', start_time, end_time)),
       toInt64(0)) AS duration_seconds,
    toDate(start_time) AS date,
    multiIf(
        lower(provider_raw) IN ('teamsforbusiness', 'teamsforconsumer', 'skypeforbusiness', 'skypeforconsumer'),
            'teams',
        match(online_join_url, '(?i)zoom\\.(us|gov)') OR match(body_preview, '(?i)zoom\\.(us|gov)/j/'),
            'zoom',
        match(body_preview, '(?i)meet\\.google\\.com'),
            'google',
        match(body_preview, '(?i)webex\\.com'),
            'webex',
        is_online,
            'other',
        ''
    ) AS online_provider,
    multiIf(
        online_join_url != '', online_join_url,
        match(body_preview, '(?i)https://[a-z0-9.-]*zoom\\.(us|gov)/j/[0-9]+[^\\s]*'),
            extract(body_preview, '(?i)https://[a-z0-9.-]*zoom\\.(us|gov)/j/[0-9]+[^\\s]*'),
        ''
    ) AS join_url,
    toInt64(JSONLength(attendees_json)) AS attendee_count,
    arrayMap(
        x -> lower(JSONExtractString(x, 'emailAddress', 'address')),
        JSONExtractArrayRaw(attendees_json)
    ) AS attendee_person_keys,
    is_cancelled,
    show_as,
    sensitivity,
    series_master_id,
    event_type,
    web_link,
    now() AS collected_at,
    'insight_m365_calendar' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version
FROM base
{% if is_incremental() %}
WHERE (
    (SELECT max(date) FROM {{ this }}) IS NULL
    OR toDate(start_time) > (SELECT max(date) - INTERVAL 3 DAY FROM {{ this }})
)
{% endif %}
