{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['zoom', 'silver:class_comms_events']
) }}

SELECT
    p.tenant_id,
    p.source_id,
    p.unique_key,
    COALESCE(p.email, '')                AS user_email,
    p.user_name,
    CAST(NULL AS Nullable(Decimal(38,9))) AS emails_sent,
    p.join_time                          AS activity_date,
    'meeting_participation'              AS event_type,
    if(p.join_time IS NOT NULL AND p.leave_time IS NOT NULL,
       dateDiff('second', parseDateTimeBestEffort(p.join_time), parseDateTimeBestEffort(p.leave_time)),
       0)                                AS duration_seconds,
    'zoom'                               AS source
FROM (
    SELECT *
    FROM {{ source('bronze_zoom', 'participants') }}
    ORDER BY _airbyte_extracted_at DESC
    LIMIT 1 BY unique_key
) p
{% if is_incremental() %}
WHERE p.join_time > (SELECT max(activity_date) FROM {{ this }})
{% endif %}
