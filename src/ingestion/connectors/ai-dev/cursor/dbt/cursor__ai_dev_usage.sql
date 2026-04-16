-- Bronze -> Staging: Cursor usage events -> staging.cursor__ai_dev_usage
-- Deduplication rule:
--   Yesterday and earlier: cursor_usage_events_daily_resync (authoritative, finalized costs)
--   Today only: cursor_usage_events (near-real-time, costs may change)
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['cursor', 'silver:class_ai_dev_usage']
) }}

WITH resync AS (
    -- Authoritative data for completed days (yesterday and earlier)
    SELECT
        tenant_id,
        source_id,
        unique_key,
        userEmail                   AS user_email,
        timestamp                   AS event_timestamp,
        kind                        AS event_kind,
        model,
        requestsCosts               AS request_cost,
        cursorTokenFee              AS platform_fee,
        isTokenBasedCall            AS is_token_based,
        isFreeBugbot                AS is_free_bugbot,
        maxMode                     AS max_mode,
        JSONExtractFloat(toString(tokenUsage), 'inputTokens')      AS input_tokens,
        JSONExtractFloat(toString(tokenUsage), 'outputTokens')     AS output_tokens,
        JSONExtractFloat(toString(tokenUsage), 'cacheReadTokens')  AS cache_read_tokens,
        JSONExtractFloat(toString(tokenUsage), 'cacheWriteTokens') AS cache_write_tokens,
        JSONExtractFloat(toString(tokenUsage), 'totalCents')       AS total_cents,
        'cursor'                    AS source
    FROM {{ source('bronze_cursor', 'cursor_usage_events_daily_resync') }}
    WHERE toDate(fromUnixTimestamp64Milli(CAST(timestamp AS Int64))) < today()
    {% if is_incremental() %}
      AND timestamp >= (SELECT coalesce(max(event_timestamp), '0') FROM {{ this }})
    {% endif %}
),

realtime AS (
    -- Near-real-time data for today only
    SELECT
        tenant_id,
        source_id,
        unique_key,
        userEmail                   AS user_email,
        timestamp                   AS event_timestamp,
        kind                        AS event_kind,
        model,
        requestsCosts               AS request_cost,
        cursorTokenFee              AS platform_fee,
        isTokenBasedCall            AS is_token_based,
        isFreeBugbot                AS is_free_bugbot,
        maxMode                     AS max_mode,
        JSONExtractFloat(toString(tokenUsage), 'inputTokens')      AS input_tokens,
        JSONExtractFloat(toString(tokenUsage), 'outputTokens')     AS output_tokens,
        JSONExtractFloat(toString(tokenUsage), 'cacheReadTokens')  AS cache_read_tokens,
        JSONExtractFloat(toString(tokenUsage), 'cacheWriteTokens') AS cache_write_tokens,
        JSONExtractFloat(toString(tokenUsage), 'totalCents')       AS total_cents,
        'cursor'                    AS source
    FROM {{ source('bronze_cursor', 'cursor_usage_events') }}
    WHERE toDate(fromUnixTimestamp64Milli(CAST(timestamp AS Int64))) = today()
    {% if is_incremental() %}
      AND timestamp >= (SELECT coalesce(max(event_timestamp), '0') FROM {{ this }})
    {% endif %}
)

SELECT * FROM resync
UNION ALL
SELECT * FROM realtime
