-- Bronze → Silver step 1: Claude Enterprise engagement → class_ai_api_usage
--
-- Source: bronze_claude_enterprise.claude_enterprise_users — per-user per-day
-- engagement metrics from /v1/organizations/analytics/users. Each Bronze row
-- carries metrics for four surfaces: chat (web), claude_code, office, cowork.
--
-- Surface split:
--   • channel='web'     ← chat_* fields (chat_conversation_count, chat_message_count)
--   • channel='office'  ← office_* fields (excel + powerpoint sessions/messages)
--   • channel='cowork'  ← cowork_* fields (cowork sessions/messages)
--   • code_* fields     ← NOT emitted. Claude Code usage comes from claude-admin
--                         only (lead's rule: shared capability, single source).
--
-- Each Bronze row can produce up to 3 staging rows (one per non-empty channel).
-- A channel is "non-empty" if its primary counter (conversations for web,
-- sessions for office/cowork) is > 0.
--
-- email is sourced from user_email (lowercased, trimmed). Enterprise Analytics
-- API always provides user_email for this stream (unlike the Admin API's
-- messages_usage, which is attributable only to api_key_id / workspace_id).
--
-- Note: this model has never been run end-to-end against live Enterprise data
-- (as of 2026-04). It is written against the spec; real-data validation will
-- happen once the tenant onboards an Enterprise Analytics API key. Column
-- extraction logic mirrors the transformations in claude-enterprise/connector.yaml.
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    order_by=['unique_key'],
    schema='staging',
    tags=['claude-enterprise', 'silver:class_ai_api_usage']
) }}

WITH base AS (
    SELECT
        tenant_id,
        source_id,
        toDate(date)                                AS day,
        lower(trim(user_email))                     AS email,
        chat_conversation_count,
        chat_message_count,
        excel_session_count,
        excel_message_count,
        powerpoint_session_count,
        powerpoint_message_count,
        cowork_session_count,
        cowork_message_count,
        CAST(parseDateTime64BestEffortOrNull(coalesce(collected_at, ''), 3) AS Nullable(DateTime64(3))) AS collected_at
    FROM {{ source('bronze_claude_enterprise', 'claude_enterprise_users') }}
    WHERE user_email IS NOT NULL
      AND trim(user_email) != ''
    {% if is_incremental() %}
      AND toDate(date) > (
          SELECT coalesce(max(day), toDate('1970-01-01')) - INTERVAL 3 DAY
          FROM {{ this }}
      )
    {% endif %}
),

-- ── channel = 'web' ────────────────────────────────────────────────────────
web AS (
    SELECT
        tenant_id                                   AS insight_tenant_id,
        source_id,
        CAST(concat(coalesce(tenant_id, ''), '-', coalesce(source_id, ''), '-', coalesce(email, ''), '-', toString(day), '-web') AS String)
                                                    AS unique_key,
        email,
        CAST(NULL AS Nullable(String))              AS api_key_id,
        CAST(NULL AS Nullable(String))              AS workspace_id,
        day,
        'anthropic'                                 AS provider,
        'web'                                       AS channel,
        toUInt32OrNull(toString(chat_conversation_count)) AS conversation_count,
        toUInt32OrNull(toString(chat_message_count))      AS message_count,
        CAST(NULL AS Nullable(UInt64))              AS input_tokens,
        CAST(NULL AS Nullable(UInt64))              AS output_tokens,
        CAST(NULL AS Nullable(UInt64))              AS cache_read_tokens,
        CAST(NULL AS Nullable(UInt64))              AS cache_creation_tokens,
        CAST(NULL AS Nullable(Decimal(18, 4)))      AS cost_amount,
        CAST(NULL AS Nullable(String))              AS cost_currency,
        'claude_enterprise'                         AS source,
        'insight_claude_enterprise'                 AS data_source,
        collected_at
    FROM base
    WHERE coalesce(chat_conversation_count, 0) > 0
       OR coalesce(chat_message_count, 0) > 0
),

-- ── channel = 'office' ─────────────────────────────────────────────────────
office AS (
    SELECT
        tenant_id                                   AS insight_tenant_id,
        source_id,
        CAST(concat(coalesce(tenant_id, ''), '-', coalesce(source_id, ''), '-', coalesce(email, ''), '-', toString(day), '-office') AS String)
                                                    AS unique_key,
        email,
        CAST(NULL AS Nullable(String))              AS api_key_id,
        CAST(NULL AS Nullable(String))              AS workspace_id,
        day,
        'anthropic'                                 AS provider,
        'office'                                    AS channel,
        CAST(NULL AS Nullable(UInt32))              AS conversation_count,
        -- Nullable(UInt32) to match web / cowork branches — ClickHouse
        -- UNION ALL type promotion across a non-nullable office column
        -- is order-dependent and fragile.
        CAST(coalesce(excel_message_count, 0)
           + coalesce(powerpoint_message_count, 0) AS Nullable(UInt32)) AS message_count,
        CAST(NULL AS Nullable(UInt64))              AS input_tokens,
        CAST(NULL AS Nullable(UInt64))              AS output_tokens,
        CAST(NULL AS Nullable(UInt64))              AS cache_read_tokens,
        CAST(NULL AS Nullable(UInt64))              AS cache_creation_tokens,
        CAST(NULL AS Nullable(Decimal(18, 4)))      AS cost_amount,
        CAST(NULL AS Nullable(String))              AS cost_currency,
        'claude_enterprise'                         AS source,
        'insight_claude_enterprise'                 AS data_source,
        collected_at
    FROM base
    WHERE coalesce(excel_session_count, 0) > 0
       OR coalesce(powerpoint_session_count, 0) > 0
),

-- ── channel = 'cowork' ─────────────────────────────────────────────────────
cowork AS (
    SELECT
        tenant_id                                   AS insight_tenant_id,
        source_id,
        CAST(concat(coalesce(tenant_id, ''), '-', coalesce(source_id, ''), '-', coalesce(email, ''), '-', toString(day), '-cowork') AS String)
                                                    AS unique_key,
        email,
        CAST(NULL AS Nullable(String))              AS api_key_id,
        CAST(NULL AS Nullable(String))              AS workspace_id,
        day,
        'anthropic'                                 AS provider,
        'cowork'                                    AS channel,
        toUInt32OrNull(toString(cowork_session_count)) AS conversation_count,
        toUInt32OrNull(toString(cowork_message_count)) AS message_count,
        CAST(NULL AS Nullable(UInt64))              AS input_tokens,
        CAST(NULL AS Nullable(UInt64))              AS output_tokens,
        CAST(NULL AS Nullable(UInt64))              AS cache_read_tokens,
        CAST(NULL AS Nullable(UInt64))              AS cache_creation_tokens,
        CAST(NULL AS Nullable(Decimal(18, 4)))      AS cost_amount,
        CAST(NULL AS Nullable(String))              AS cost_currency,
        'claude_enterprise'                         AS source,
        'insight_claude_enterprise'                 AS data_source,
        collected_at
    FROM base
    WHERE coalesce(cowork_session_count, 0) > 0
)

SELECT * FROM web
UNION ALL
SELECT * FROM office
UNION ALL
SELECT * FROM cowork
