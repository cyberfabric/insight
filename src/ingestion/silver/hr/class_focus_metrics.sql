{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

SELECT
    ce.tenant_id                                                    AS insight_tenant_id,
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
    COALESCE(wh.working_hours_per_day, 8.0)                        AS working_hours_per_day,
    ROUND(
        GREATEST(toFloat64(0), 100.0 - (
            sumIf(ce.duration_seconds, ce.event_type = 'meeting_participation')
            / 3600.0
            / nullIf(COALESCE(wh.working_hours_per_day, 8.0), 0)
        ) * 100.0),
        2
    )                                                               AS focus_time_pct,
    ROUND(
        GREATEST(toFloat64(0),
            COALESCE(wh.working_hours_per_day, 8.0) -
            sumIf(ce.duration_seconds, ce.event_type = 'meeting_participation') / 3600.0
        ),
        4
    )                                                               AS dev_time_h
FROM {{ ref('class_comms_events') }} ce
LEFT JOIN {{ ref('class_hr_working_hours') }} wh
    ON lower(ce.user_email) = lower(wh.email)
   AND ce.tenant_id = wh.insight_tenant_id
WHERE ce.user_email != ''
  AND toDate(parseDateTimeBestEffortOrNull(ce.activity_date)) IS NOT NULL
{% if is_incremental() %}
  AND toDate(parseDateTimeBestEffortOrNull(ce.activity_date))
      > (SELECT max(day) - INTERVAL 3 DAY FROM {{ this }})
{% endif %}
GROUP BY
    ce.tenant_id,
    lower(ce.user_email),
    toDate(parseDateTimeBestEffortOrNull(ce.activity_date)),
    COALESCE(wh.working_hours_per_day, 8.0)
