-- Bronze → Silver step 1: Claude Team code usage → class_ai_dev_usage
-- Filters to actor_type = 'user' and maps actor_identifier (email) as identity key.
-- Per-model token data is in model_breakdown_json (Bronze); token extraction deferred to Silver step 2 or Gold.
-- This model handles Claude Code sessions — developer AI tool usage alongside Cursor/Windsurf.
{{ config(materialized='incremental', unique_key='unique_id') }}

SELECT
    tenant_id,
    source_instance_id,
    -- actor_type omitted from key: model filters to actor_type='user' so it's
    -- always constant; Bronze unique key includes it (see connector.yaml)
    concat(date, '|', actor_identifier, '|', terminal_type)
                                                    AS unique_id,
    date                                            AS report_date,
    actor_identifier                                AS email,
    terminal_type,
    session_count,
    lines_added,
    lines_removed,
    tool_use_accepted,
    tool_use_rejected,
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
