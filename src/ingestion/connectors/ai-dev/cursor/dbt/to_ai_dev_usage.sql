-- Bronze → Silver step 1: Cursor usage events → class_ai_dev_usage
-- Deduplication rule:
--   Yesterday and earlier: cursor_usage_events_daily_resync (authoritative, finalized costs)
--   Today only: cursor_usage_events (near-real-time, costs may change)
{{ config(materialized='view') }}

WITH resync AS (
    -- Authoritative data for completed days (yesterday and earlier)
    SELECT
        tenant_id,
        userEmail                   AS user_email,
        timestamp                   AS event_timestamp,
        kind                        AS event_kind,
        model,
        requestsCosts               AS request_cost,
        cursorTokenFee              AS platform_fee,
        isTokenBasedCall            AS is_token_based,
        isFreeBugbot                AS is_free_bugbot,
        maxMode                     AS max_mode,
        JSONExtractFloat(tokenUsage, 'inputTokens')      AS input_tokens,
        JSONExtractFloat(tokenUsage, 'outputTokens')     AS output_tokens,
        JSONExtractFloat(tokenUsage, 'cacheReadTokens')  AS cache_read_tokens,
        JSONExtractFloat(tokenUsage, 'cacheWriteTokens') AS cache_write_tokens,
        JSONExtractFloat(tokenUsage, 'totalCents')       AS total_cents,
        'insight_cursor'            AS data_source
    FROM {{ source('bronze', 'cursor_usage_events_daily_resync') }}
    WHERE toDate(fromUnixTimestamp64Milli(CAST(timestamp AS Int64))) < today()
),

realtime AS (
    -- Near-real-time data for today only
    SELECT
        tenant_id,
        userEmail                   AS user_email,
        timestamp                   AS event_timestamp,
        kind                        AS event_kind,
        model,
        requestsCosts               AS request_cost,
        cursorTokenFee              AS platform_fee,
        isTokenBasedCall            AS is_token_based,
        isFreeBugbot                AS is_free_bugbot,
        maxMode                     AS max_mode,
        JSONExtractFloat(tokenUsage, 'inputTokens')      AS input_tokens,
        JSONExtractFloat(tokenUsage, 'outputTokens')     AS output_tokens,
        JSONExtractFloat(tokenUsage, 'cacheReadTokens')  AS cache_read_tokens,
        JSONExtractFloat(tokenUsage, 'cacheWriteTokens') AS cache_write_tokens,
        JSONExtractFloat(tokenUsage, 'totalCents')       AS total_cents,
        'insight_cursor'            AS data_source
    FROM {{ source('bronze', 'cursor_usage_events') }}
    WHERE toDate(fromUnixTimestamp64Milli(CAST(timestamp AS Int64))) = today()
)

SELECT * FROM resync
UNION ALL
SELECT * FROM realtime
