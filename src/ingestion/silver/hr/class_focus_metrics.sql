{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

SELECT
    ce.tenant_id                                                    AS insight_tenant_id,
    ce.source_id,
    lower(ce.user_email)                                            AS email,
    toDate(parseDateTimeBestEffortOrNull(ce.activity_date))         AS day,
    concat(
        ce.tenant_id, '-',
        lower(ce.user_email), '-',
        toString(toDate(parseDateTimeBestEffortOrNull(ce.activity_date)))
    )                                                               AS unique_key,
    countIf(ce.event_type = 'meeting_participation')                AS meetings_count,
    ROUND(
        sumIf(ce.duration_seconds, ce.event_type = 'meeting_participation') / 3600.0,
        4
    )                                                               AS meeting_hours,
    wh.working_hours_per_day,
    ROUND(
        GREATEST(toFloat64(0), 100.0 - (
            sumIf(ce.duration_seconds, ce.event_type = 'meeting_participation')
            / 3600.0
            / wh.working_hours_per_day
        ) * 100.0),
        2
    )                                                               AS focus_time_pct,
    ROUND(
        GREATEST(toFloat64(0),
            wh.working_hours_per_day -
            sumIf(ce.duration_seconds, ce.event_type = 'meeting_participation') / 3600.0
        ),
        4
    )                                                               AS dev_time_h
FROM {{ ref('class_comms_events') }} ce
JOIN {{ ref('class_hr_working_hours') }} wh
    ON lower(ce.user_email) = lower(wh.email)
WHERE ce.user_email != ''
  AND toDate(parseDateTimeBestEffortOrNull(ce.activity_date)) IS NOT NULL
{% if is_incremental() %}
  AND toDate(parseDateTimeBestEffortOrNull(ce.activity_date))
      > (SELECT max(day) FROM {{ this }})
{% endif %}
GROUP BY
    ce.tenant_id,
    ce.source_id,
    lower(ce.user_email),
    toDate(parseDateTimeBestEffortOrNull(ce.activity_date)),
    wh.working_hours_per_day
