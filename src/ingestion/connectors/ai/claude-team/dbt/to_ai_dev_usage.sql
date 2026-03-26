-- Bronze → Silver step 1: Claude Team code usage → class_ai_dev_usage
-- Filters to actor_type = 'user' and maps actor_identifier (email) as identity key.
-- This model handles Claude Code sessions — developer AI tool usage alongside Cursor/Windsurf.
{{ config(materialized='incremental', unique_key='unique_id') }}

SELECT
    tenant_id,
    source_instance_id,
    concat(date, '|', actor_identifier, '|', terminal_type)
                                                    AS unique_id,
    date                                            AS report_date,
    actor_identifier                                AS email,
    terminal_type,
    input_tokens,
    output_tokens,
    cache_read_tokens,
    cache_creation_tokens,
    input_tokens + output_tokens
        + cache_read_tokens
        + cache_creation_tokens                     AS total_tokens,
    tool_use_count,
    session_count,
    lines_generated,
    -- person_id resolved in Silver step 2 via Identity Manager
    NULL                                            AS person_id,
    'anthropic'                                     AS provider,
    'claude_code'                                   AS client,
    'insight_claude_team'                           AS data_source,
    collected_at
FROM {{ source('bronze', 'claude_team_code_usage') }}
WHERE actor_type = 'user'
{% if is_incremental() %}
  AND date > (SELECT max(report_date) FROM {{ this }})
{% endif %}
