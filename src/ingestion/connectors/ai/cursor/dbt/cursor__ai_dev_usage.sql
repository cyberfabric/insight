-- Bronze → Silver step 1: Cursor per-user per-day usage → class_ai_dev_usage
--
-- Source: bronze_cursor.cursor_daily_usage — daily aggregate stream from
-- POST /teams/daily-usage-data. One row per (userId, date) when the user was
-- active that day (isActive=true).
--
-- Filter: isActive=true AND email IS NOT NULL AND trim(email)!=''.
--
-- session_count semantics: Cursor does not expose a per-day "session count" —
-- it exposes chat/composer/agent request counters instead. For class_ai_dev_usage
-- we set session_count=1 per active day, which matches the concept of
-- "a day the user used the tool". Alternative counters (chatRequests,
-- agentRequests, totalTabsAccepted) are carried through as dedicated columns.
--
-- Note: the previous implementation of this model read cursor_usage_events* and
-- produced per-event rows with token granularity. It was replaced with a per-day
-- aggregation because class_ai_dev_usage consumers expect (tenant, email, day,
-- tool) granularity. Per-event / token-level data remains in Bronze and can be
-- tapped by a separate staging model if ever needed.
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    order_by=['unique_key'],
    schema='staging',
    tags=['cursor', 'silver:class_ai_dev_usage']
) }}

SELECT
    tenant_id                                       AS insight_tenant_id,
    source_id,
    CAST(concat(coalesce(tenant_id, ''), '-', coalesce(source_id, ''), '-', coalesce(userId, ''), '-', toString(toDate(fromUnixTimestamp64Milli(CAST(date AS Int64))))) AS String)
                                                    AS unique_key,
    lower(trim(email))                              AS email,
    CAST(NULL AS Nullable(String))                  AS api_key_id,
    toDate(fromUnixTimestamp64Milli(CAST(date AS Int64))) AS day,
    'cursor'                                        AS tool,
    toUInt32(1)                                     AS session_count,
    toUInt32(coalesce(acceptedLinesAdded, 0))       AS lines_added,
    toUInt32(coalesce(acceptedLinesDeleted, 0))     AS lines_removed,
    toUInt32OrNull(toString(totalTabsShown))        AS tool_use_offered,
    toUInt32OrNull(toString(totalTabsAccepted))     AS tool_use_accepted,
    toUInt32OrNull(toString(totalTabsAccepted))     AS completions_count,
    toUInt32OrNull(toString(agentRequests))         AS agent_sessions,
    toUInt32(coalesce(chatRequests, 0) + coalesce(composerRequests, 0))
                                                    AS chat_requests,
    CAST(NULL AS Nullable(UInt32))                  AS cost_cents,
    'cursor'                                        AS source,
    'insight_cursor'                                AS data_source,
    CAST(_airbyte_extracted_at AS Nullable(DateTime64(3))) AS collected_at
FROM {{ source('bronze_cursor', 'cursor_daily_usage') }}
WHERE isActive = true
  AND email IS NOT NULL
  AND trim(email) != ''
{% if is_incremental() %}
  AND toDate(fromUnixTimestamp64Milli(CAST(date AS Int64))) > (
      SELECT coalesce(max(day), toDate('1970-01-01')) - INTERVAL 3 DAY
      FROM {{ this }}
  )
{% endif %}
