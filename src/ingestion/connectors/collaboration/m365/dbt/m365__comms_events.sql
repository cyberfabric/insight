{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['m365', 'silver:class_comms_events']
) }}

SELECT
    tenant_id AS insight_tenant_id,
    source_id AS insight_source_id,
    'm365' AS insight_source_type,
    unique_key,
    userPrincipalName AS user_email,
    sendCount AS emails_sent,
    reportRefreshDate AS activity_date,
    'm365' AS source
FROM {{ source('bronze_m365', 'email_activity') }}
{% if is_incremental() %}
WHERE reportRefreshDate > (SELECT max(activity_date) FROM {{ this }})
{% endif %}
