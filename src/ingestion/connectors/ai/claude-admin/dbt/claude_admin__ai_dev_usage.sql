-- Bronze → Silver step 1: Claude Admin Claude Code usage → class_ai_dev_usage
--
-- Source: bronze_claude_admin.claude_admin_code_usage — daily Claude Code
-- activity from /v1/organizations/usage_report/claude_code. Filtered to
-- actor_type='user' so actor_identifier carries the user email.
--
-- Note: Claude Code usage is also present in Enterprise data (claude_enterprise_users.code_*)
-- but we deliberately take it from claude-admin only, per the lead's rule: data
-- available in the common Admin API is always sourced from there to avoid double
-- counting in class_ai_dev_usage aggregates.
--
-- Aggregation: claude_admin_code_usage has one row per
-- (date, actor_identifier, terminal_type) — we aggregate across terminal_type
-- to match class_ai_dev_usage granularity (tenant, email, day, tool).
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['claude-admin', 'silver:class_ai_dev_usage']
) }}

WITH agg AS (
    SELECT
        tenant_id,
        insight_source_id                                   AS source_id,
        lower(actor_identifier)                             AS email_lc,
        toDate(date)                                        AS day,
        sum(coalesce(session_count, 0))                     AS sessions_sum,
        sum(coalesce(lines_added, 0))                       AS lines_added_sum,
        sum(coalesce(lines_removed, 0))                     AS lines_removed_sum,
        sum(coalesce(tool_use_accepted, 0))                 AS tool_accepted_sum,
        sum(coalesce(tool_use_rejected, 0))                 AS tool_rejected_sum,
        max(parseDateTime64BestEffortOrNull(coalesce(collected_at, ''), 3)) AS collected_at_max
    FROM {{ source('bronze_claude_admin', 'claude_admin_code_usage') }}
    WHERE actor_type = 'user'
      AND actor_identifier IS NOT NULL
      AND trim(actor_identifier) != ''
    {% if is_incremental() %}
      AND toDate(date) > (
          SELECT coalesce(max(day), toDate('1970-01-01')) - INTERVAL 3 DAY
          FROM {{ this }}
      )
    {% endif %}
    GROUP BY tenant_id, insight_source_id, lower(actor_identifier), toDate(date)
)

SELECT
    tenant_id                                       AS insight_tenant_id,
    source_id,
    concat(tenant_id, '-', source_id, '-', email_lc, '-', toString(day))
                                                    AS unique_key,
    email_lc                                        AS email,
    CAST(NULL AS Nullable(UUID))                    AS person_id,
    day,
    'claude_code'                                   AS tool,
    toUInt32(sessions_sum)                          AS session_count,
    toUInt32(lines_added_sum)                       AS lines_added,
    toUInt32(lines_removed_sum)                     AS lines_removed,
    toUInt32(tool_accepted_sum + tool_rejected_sum) AS tool_use_offered,
    toUInt32(tool_accepted_sum)                     AS tool_use_accepted,
    CAST(NULL AS Nullable(UInt32))                  AS completions_count,
    CAST(NULL AS Nullable(UInt32))                  AS agent_sessions,
    CAST(NULL AS Nullable(UInt32))                  AS chat_requests,
    CAST(NULL AS Nullable(UInt32))                  AS cost_cents,
    'claude_admin'                                  AS source,
    'insight_claude_admin'                          AS data_source,
    CAST(collected_at_max AS Nullable(DateTime64(3))) AS collected_at
FROM agg
