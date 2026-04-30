-- Bronze → Silver: Claude Enterprise per-user per-day Code activity.
--
-- Source: bronze_claude_enterprise.claude_enterprise_users — daily per-user
-- snapshot of Claude Enterprise usage including code_* fields.
--
-- Strategy: Enterprise is the canonical source for Claude Code activity
-- (lines_added, sessions, tool_accepted/rejected) for orgs on the Enterprise
-- subscription. Claude Admin's claude_admin_code_usage is no longer tagged
-- for silver:class_ai_dev_usage — Enterprise covers the same activity at
-- the user-day grain plus additional dimensions (chat, cowork, office) that
-- Admin doesn't expose. Admin remains tagged for silver:class_ai_api_usage
-- (token-level metrics that Enterprise doesn't publish).
--
-- Fundamental gap: Enterprise reports `code_lines_added` (AI-accepted lines)
-- but does not expose `total_lines_added` (every keystroke including manual
-- edits). This is the same limitation every assistant-mode AI coder has —
-- Cursor exposes both because it sees keystrokes; Claude Code only sees its
-- own suggestions. Downstream metrics that need a denominator (e.g.,
-- `ai_loc_share_pct = accepted/total`) emit NULL for Enterprise rows; that
-- metric is Cursor-only by design.
--
-- Ingestion shape:
--   • One row per (user_id, date). claude_enterprise_users is a daily
--     snapshot, so we treat it as already aggregated at the (email, day)
--     grain. No SUM/argMax wrapping needed.
--   • Filter: code_session_count > 0 OR code_lines_added > 0
--                                       OR code_tool_accepted_count > 0
--     drop rows where the user had Enterprise activity but no Code activity
--     that day (avoids polluting class_ai_dev_usage with empty Code rows).
--     The third condition catches tool-only days where the user accepted
--     Edit/Write/MultiEdit/NotebookEdit tool calls without a session/lines
--     event being attributed.

{{ config(
    materialized='incremental',
    incremental_strategy='append',
    unique_key='unique_key',
    engine='ReplacingMergeTree(_version)',
    order_by=['unique_key'],
    settings={'allow_nullable_key': 1},
    schema='staging',
    tags=['claude-enterprise', 'silver:class_ai_dev_usage']
) }}

SELECT
    tenant_id                                                          AS insight_tenant_id,
    source_id,
    CAST(concat(coalesce(tenant_id, ''), '-', coalesce(source_id, ''), '-', coalesce(user_id, ''), '-', coalesce(date, '')) AS String)
                                                                       AS unique_key,
    lower(trim(user_email))                                            AS email,
    CAST(NULL AS Nullable(String))                                     AS api_key_id,
    toDate(parseDateTimeBestEffortOrNull(date))                        AS day,
    'claude_code'                                                      AS tool,
    toUInt32(coalesce(code_session_count, 0))                          AS session_count,
    toUInt32(coalesce(code_lines_added, 0))                            AS lines_added,
    toUInt32(coalesce(code_lines_removed, 0))                          AS lines_removed,
    -- Enterprise reports AI-accepted lines only — no view of total user keystrokes.
    -- ai_loc_share_pct downstream filters to tool='cursor' precisely because of this gap.
    CAST(NULL AS Nullable(UInt32))                                     AS total_lines_added,
    CAST(NULL AS Nullable(UInt32))                                     AS total_lines_removed,
    toUInt32(coalesce(code_tool_accepted_count, 0)
           + coalesce(code_tool_rejected_count, 0))                    AS tool_use_offered,
    toUInt32(coalesce(code_tool_accepted_count, 0))                    AS tool_use_accepted,
    -- completions_count := accepted Code tool invocations (Edit/Write/MultiEdit/NotebookEdit)
    toUInt32(coalesce(code_tool_accepted_count, 0))                    AS completions_count,
    -- agent_sessions := no direct Enterprise equivalent. Enterprise's cowork_dispatch_turn_count
    -- represents agentic turns in Cowork (different product surface), not Code agent runs.
    -- Leave NULL until Anthropic exposes a Code-specific agent counter.
    CAST(NULL AS Nullable(UInt32))                                     AS agent_sessions,
    -- chat_requests: Enterprise has no Code-specific chat counter. Its chat_message_count
    -- covers Claude.ai chat turns (a different product surface than Code chat in IDEs/CLI),
    -- so attributing it here would mix surfaces. Leave NULL until Anthropic exposes a
    -- Code-scoped chat counter.
    CAST(NULL AS Nullable(UInt32))                                     AS chat_requests,
    -- Cost is not surfaced per-user in Enterprise; tied to org subscription, not consumption.
    CAST(NULL AS Nullable(UInt32))                                     AS cost_cents,
    'claude_enterprise'                                                AS source,
    'insight_claude_enterprise'                                        AS data_source,
    parseDateTime64BestEffortOrNull(coalesce(collected_at, ''), 3)     AS collected_at,
    toUnixTimestamp64Milli(_airbyte_extracted_at)                       AS _version
FROM {{ source('bronze_claude_enterprise', 'claude_enterprise_users') }}
WHERE user_email IS NOT NULL
  AND trim(user_email) != ''
  AND date IS NOT NULL
  AND (coalesce(code_session_count, 0) > 0
       OR coalesce(code_lines_added, 0) > 0
       OR coalesce(code_tool_accepted_count, 0) > 0)
{% if is_incremental() %}
  AND toDate(parseDateTimeBestEffortOrNull(date)) > (
      SELECT coalesce(max(day), toDate('1970-01-01')) - INTERVAL 3 DAY
      FROM {{ this }}
  )
{% endif %}
