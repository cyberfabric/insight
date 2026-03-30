{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['zoom', 'silver:class_comms_events']
) }}

WITH meeting_participation AS (
    SELECT
        p.tenant_id,
        p.source_id,
        p.unique_key,
        p.display_name AS user_name,
        COALESCE(p.email, '') AS user_email,
        p.join_at AS activity_date,
        'meeting_participation' AS event_type,
        p.attendance_duration_seconds AS duration_seconds,
        'zoom' AS source
    FROM {{ source('bronze_zoom', 'participants') }} p
    {% if is_incremental() %}
    WHERE p.join_at > (SELECT max(activity_date) FROM {{ this }})
    {% endif %}
),

messages AS (
    SELECT
        m.tenant_id,
        m.source_id,
        m.unique_key,
        '' AS user_name,
        '' AS user_email,
        m.activity_date,
        'chat_message' AS event_type,
        CAST(m.message_count AS Nullable(Int64)) AS duration_seconds,
        'zoom' AS source
    FROM {{ source('bronze_zoom', 'message_activities') }} m
)

SELECT * FROM meeting_participation
UNION ALL
SELECT * FROM messages
