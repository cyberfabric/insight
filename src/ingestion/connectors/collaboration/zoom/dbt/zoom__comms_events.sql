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
    p.user_name,
    COALESCE(p.email, '') AS user_email,
    p.join_time AS activity_date,
    'meeting_participation' AS event_type,
    p.duration AS duration_seconds,
    'zoom' AS source
FROM {{ source('bronze_zoom', 'participants') }} p
{% if is_incremental() %}
WHERE p.join_time > (SELECT max(activity_date) FROM {{ this }})
{% endif %}
