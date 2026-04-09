-- Bronze → Silver step 1: Claude Team web/mobile usage → class_ai_tool_usage
--
-- PLACEHOLDER MODEL — The Anthropic Admin API does not currently expose a dedicated
-- endpoint for web/mobile (claude.ai) activity at per-user daily granularity.
--
-- The available endpoints are:
--   /v1/organizations/usage_report/messages   — API-level token usage (no user attribution)
--   /v1/organizations/usage_report/claude_code — Claude Code usage only
--
-- Web/mobile activity (message_count, conversation_count per user per day per client)
-- was defined in the original Claude Team PRD (from CONNECTORS_REFERENCE Source 14)
-- but is not available through the current Admin API.
--
-- When Anthropic adds a per-user activity endpoint for web/mobile usage, this model
-- should be implemented to:
--   1. Read from the new Bronze table (e.g. claude_team_web_activity)
--   2. Filter to client IN ('web', 'mobile')
--   3. Map to class_ai_tool_usage Silver schema
--   4. Use email as identity key → person_id via Identity Manager
--   5. Set data_source = 'insight_claude_team'
--
-- Expected Silver schema (class_ai_tool_usage):
--   tenant_id, source_id, unique_id, report_date, email,
--   client (web/mobile), model, message_count, conversation_count,
--   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
--   person_id (NULL until Silver step 2), provider, data_source, collected_at

{{ config(enabled=false) }}

SELECT 1 AS placeholder
