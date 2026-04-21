{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['m365', 'silver:class_comms_events']
) }}

SELECT
    tenant_id,
    source_id,
    unique_key,
    userPrincipalName                    AS user_email,
    CAST(NULL AS Nullable(String))       AS user_name,
    sendCount                            AS emails_sent,
    reportRefreshDate                    AS activity_date,
    CAST(NULL AS Nullable(String))       AS event_type,
    CAST(NULL AS Nullable(Int64))        AS duration_seconds,
    'm365'                               AS source
FROM {{ source('bronze_m365', 'email_activity') }}
{% if is_incremental() %}
WHERE reportRefreshDate > (SELECT max(activity_date) FROM {{ this }})
{% endif %}
