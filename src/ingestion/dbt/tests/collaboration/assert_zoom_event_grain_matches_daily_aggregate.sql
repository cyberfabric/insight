-- Cross-check: the new event-grain class_meeting_attendance and the legacy
-- daily class_collab_meeting_activity are independent dbt pipelines that
-- happen to read the same bronze (bronze_zoom.participants for the Zoom
-- portion). They MUST produce identical totals when rolled up to (person, day).
--
-- If this test fails, one of the two pipelines drifted from the other —
-- typically because someone changed a filter or a duration formula in one
-- staging model and forgot the parallel one. Either fix the divergence or,
-- if the divergence is intentional, update both feeders together.
--
-- Tolerance: zero. Both pipelines:
--   * filter participants with NULL/empty email
--   * compute duration as dateDiff('second', join_time, leave_time)
--   * date-truncate by join_time
-- so the sums must match exactly.
--
-- This is the safety net for the eventual migration of
-- class_collab_meeting_activity to a derived view over class_meeting_attendance.

WITH event_grain AS (
    SELECT
        tenant_id,
        insight_source_id,
        person_key,
        date,
        sum(duration_seconds) AS audio_seconds
    FROM {{ ref('class_meeting_attendance') }} FINAL
    WHERE data_source = 'insight_zoom'
    GROUP BY tenant_id, insight_source_id, person_key, date
),
daily AS (
    SELECT
        tenant_id,
        insight_source_id,
        person_key,
        date,
        coalesce(audio_duration_seconds, 0) AS audio_seconds
    FROM {{ ref('class_collab_meeting_activity') }} FINAL
    WHERE data_source = 'insight_zoom'
)
SELECT
    coalesce(e.tenant_id, d.tenant_id)               AS tenant_id,
    coalesce(e.insight_source_id, d.insight_source_id) AS insight_source_id,
    coalesce(e.person_key, d.person_key)             AS person_key,
    coalesce(e.date, d.date)                         AS date,
    e.audio_seconds                                   AS event_grain_seconds,
    d.audio_seconds                                   AS daily_seconds,
    e.audio_seconds - d.audio_seconds                 AS delta
FROM event_grain e
FULL OUTER JOIN daily d
    ON  e.tenant_id         = d.tenant_id
    AND e.insight_source_id = d.insight_source_id
    AND e.person_key        = d.person_key
    AND e.date              = d.date
WHERE coalesce(e.audio_seconds, 0) != coalesce(d.audio_seconds, 0)
LIMIT 100
