{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['slack', 'silver:class_comms_events']
) }}

SELECT
    m.tenant_id,
    m.source_id,
    m.unique_key,
    m.user AS slack_user_id,
    m.channel_id,
    c.channel_type,
    toDateTime(toFloat64(m.ts)) AS activity_date,
    m.type AS event_type,
    m.subtype,
    m.thread_ts IS NOT NULL AS is_thread_reply,
    COALESCE(m.reply_count, 0) AS reply_count,
    'slack' AS source
FROM {{ source('bronze_slack', 'messages') }} m
LEFT JOIN {{ source('bronze_slack', 'channels') }} c
    ON m.channel_id = c.channel_id
    AND m.tenant_id = c.tenant_id
    AND m.source_id = c.source_id
WHERE m.user IS NOT NULL
  AND m.subtype IS NULL
{% if is_incremental() %}
  AND toDateTime(toFloat64(m.ts)) > (SELECT max(activity_date) - INTERVAL 7 DAY FROM {{ this }})
{% endif %}
