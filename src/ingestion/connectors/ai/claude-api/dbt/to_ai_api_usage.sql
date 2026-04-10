-- Bronze → Silver step 1: Claude API messages usage → class_ai_api_usage
-- Joins with keys and workspaces for dimension name enrichment.
{{ config(materialized='incremental', unique_key='unique_id') }}

WITH usage AS (
    SELECT
        tenant_id AS insight_tenant_id,
        source_id AS insight_source_id,
        'claude-api' AS insight_source_type,
        date                                        AS report_date,
        model,
        api_key_id,
        workspace_id,
        service_tier,
        context_window,
        uncached_input_tokens,
        cache_read_tokens,
        cache_creation_5m_tokens,
        cache_creation_1h_tokens,
        output_tokens,
        web_search_requests,
        -- derived: total input = uncached + cache reads + cache creation
        uncached_input_tokens
            + cache_read_tokens
            + cache_creation_5m_tokens
            + cache_creation_1h_tokens              AS total_input_tokens,
        -- derived: total tokens
        uncached_input_tokens
            + cache_read_tokens
            + cache_creation_5m_tokens
            + cache_creation_1h_tokens
            + output_tokens                         AS total_tokens,
        collected_at,
        'insight_claude_api'                        AS data_source
    FROM {{ source('bronze', 'claude_api_messages_usage') }}
    {% if is_incremental() %}
    WHERE date > (SELECT max(report_date) FROM {{ this }})
    {% endif %}
),

keys AS (
    SELECT DISTINCT tenant_id, id, name AS key_name
    FROM {{ source('bronze', 'claude_api_keys') }}
),

workspaces AS (
    SELECT DISTINCT tenant_id, id, display_name AS workspace_name
    FROM {{ source('bronze', 'claude_api_workspaces') }}
)

SELECT
    u.insight_tenant_id,
    u.insight_source_id,
    u.insight_source_type,
    -- composite unique id for incremental
    concat(u.insight_tenant_id, '-', u.insight_source_id, '-',
           u.report_date, '|', u.model, '|', u.api_key_id, '|',
           u.workspace_id, '|', u.service_tier, '|',
           u.context_window)                        AS unique_id,
    u.report_date,
    u.model,
    u.api_key_id,
    k.key_name,
    u.workspace_id,
    w.workspace_name,
    u.service_tier,
    u.context_window,
    u.uncached_input_tokens,
    u.cache_read_tokens,
    u.cache_creation_5m_tokens,
    u.cache_creation_1h_tokens,
    u.cache_creation_5m_tokens
        + u.cache_creation_1h_tokens                AS cache_creation_tokens,
    u.output_tokens,
    u.total_input_tokens,
    u.total_tokens,
    u.web_search_requests,
    -- person_id is NULL at this stage — API usage has no direct user attribution
    NULL                                            AS person_id,
    'anthropic'                                     AS provider,
    u.data_source,
    u.collected_at
FROM usage u
LEFT JOIN keys k ON u.insight_tenant_id = k.tenant_id AND u.api_key_id = k.id
LEFT JOIN workspaces w ON u.insight_tenant_id = w.tenant_id AND u.workspace_id = w.id
