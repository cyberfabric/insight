{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['slack', 'silver:class_collab_chat_activity']
) }}

-- Slack chat activity aggregated per user per day.
-- Email can be NULL when Slack workspace policy hides it — we keep the row and
-- fall back to display_name for person_key (matches the git-plugin convention:
--   if(email != '', lower(email), lower(user_name))).

SELECT
    m.tenant_id,
    m.source_id AS insight_source_id,
    MD5(concat(
        m.tenant_id, '-',
        m.source_id, '-',
        coalesce(m.user, ''), '-',
        toString(toDate(toDateTime(toFloat64(m.ts))))
    )) AS unique_key,
    m.user AS user_id,
    coalesce(u.display_name, u.real_name, '') AS user_name,
    coalesce(u.email, '') AS email,
    if(coalesce(u.email, '') != '',
       lower(u.email),
       lower(coalesce(u.display_name, u.real_name, m.user))) AS person_key,
    toDate(toDateTime(toFloat64(m.ts))) AS date,
    countIf(c.is_im = true OR c.is_mpim = true) AS direct_messages,
    countIf(c.is_channel = true OR c.is_group = true) AS group_chat_messages,
    count(*) AS total_chat_messages,
    CAST(NULL AS Nullable(Int64)) AS channel_posts,
    CAST(NULL AS Nullable(Int64)) AS channel_replies,
    CAST(NULL AS Nullable(Int64)) AS urgent_messages,
    CAST(NULL AS Nullable(String)) AS report_period,
    now() AS collected_at,
    'insight_slack' AS data_source,
    toUnixTimestamp64Milli(now()) AS _version
FROM {{ source('bronze_slack', 'messages') }} m
LEFT JOIN {{ source('bronze_slack', 'channels') }} c
    ON m.channel_id = c.channel_id
    AND m.tenant_id = c.tenant_id
    AND m.source_id = c.source_id
LEFT JOIN {{ source('bronze_slack', 'users') }} u
    ON m.user = u.slack_user_id
    AND m.tenant_id = u.tenant_id
    AND m.source_id = u.source_id
WHERE m.user IS NOT NULL
  AND m.user != ''
  AND m.subtype IS NULL
{% if is_incremental() %}
  AND (
    (SELECT max(date) FROM {{ this }}) IS NULL
    OR toDate(toDateTime(toFloat64(m.ts))) > (SELECT max(date) - INTERVAL 7 DAY FROM {{ this }})
  )
{% endif %}
GROUP BY
    m.tenant_id,
    m.source_id,
    m.user,
    u.email,
    u.display_name,
    u.real_name,
    toDate(toDateTime(toFloat64(m.ts)))
