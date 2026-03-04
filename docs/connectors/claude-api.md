# Claude API Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 13 (Claude API), OQ-3

Standalone specification for the Claude API (AI Tool) connector. Expands Source 13 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`claude_api_daily_usage` — Daily token usage per API key per model](#claudeapidailyusage-daily-token-usage-per-api-key-per-model)
  - [`claude_api_requests` — Individual API request events](#claudeapirequests-individual-api-request-events)
  - [`claude_api_collection_runs` — Connector execution log](#claudeapicollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-CAPI-1: Per-key user attribution — `X-Anthropic-User-Id` coverage](#oq-capi-1-per-key-user-attribution-x-anthropic-user-id-coverage)
  - [OQ-CAPI-2: `class_ai_api_usage` Silver design — nullable `person_id`](#oq-capi-2-classaiapiusage-silver-design-nullable-personid)

<!-- /toc -->

---

## Overview

**API**: Anthropic Admin API (`/v1/usage`)

**Category**: AI Tool

**Authentication**: Admin API key (Anthropic Console)

**Identity**: `user_id` in `claude_api_requests` — the value of the `X-Anthropic-User-Id` request header set by the caller. This is nullable — attribution is only possible when the calling application includes this header. `claude_api_daily_usage` has no user-level attribution.

**Field naming**: snake_case — preserved as-is at Bronze level.

**Why two tables**: Daily aggregates (from the usage API) and per-request events (requires per-request instrumentation with user context) have different granularity and availability. Not all clients instrument per-request headers, so the events table may be sparse.

**Key difference from Cursor/Windsurf**: There is no IDE context, no completions model, no per-session analytics. The unit of analysis is an API request — typically from internal tooling, automations, or AI-powered product features, not individual developer sessions.

---

## Bronze Tables

### `claude_api_daily_usage` — Daily token usage per API key per model

| Field | Type | Description |
|-------|------|-------------|
| `date` | date | Usage date |
| `api_key_id` | text | API key identifier (name or last-4 alias from Anthropic Console) |
| `model` | text | Model ID, e.g. `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5` |
| `request_count` | numeric | Number of API requests |
| `input_tokens` | numeric | Input tokens consumed |
| `output_tokens` | numeric | Output tokens generated |
| `cache_read_tokens` | numeric | Tokens served from prompt cache |
| `cache_write_tokens` | numeric | Tokens written to prompt cache |
| `total_cost_cents` | numeric | Total cost in cents |

Granularity: one row per `(date, api_key_id, model)`. No user attribution at this level — user breakdown requires the requests table.

---

### `claude_api_requests` — Individual API request events

Available only when the caller passes `X-Anthropic-User-Id` in the request header. Without this header, requests are not recorded at this level — only in daily aggregates.

| Field | Type | Description |
|-------|------|-------------|
| `request_id` | text | Unique request ID from Anthropic response headers |
| `timestamp` | timestamptz | Request timestamp |
| `api_key_id` | text | API key used |
| `user_id` | text | Value of `X-Anthropic-User-Id` header — caller-defined identifier (nullable) |
| `model` | text | Model ID |
| `input_tokens` | numeric | Input tokens |
| `output_tokens` | numeric | Output tokens |
| `cache_read_tokens` | numeric | Cache read tokens |
| `cache_write_tokens` | numeric | Cache write tokens |
| `cost_cents` | numeric | Request cost in cents |
| `stop_reason` | text | Why generation stopped: `end_turn` / `max_tokens` / `stop_sequence` / `tool_use` |
| `application` | text | Internal application tag — identifies which product or service made the call (caller-set convention, not an Anthropic API field) |

`application` is a caller convention — callers must set it themselves. Absent without explicit instrumentation.

---

### `claude_api_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `daily_usage_records_collected` | numeric | Rows collected for `claude_api_daily_usage` |
| `request_records_collected` | numeric | Rows collected for `claude_api_requests` |
| `api_calls` | numeric | Admin API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (workspace, lookback period, key filter) |

Monitoring table — not an analytics source.

---

## Identity Resolution

Identity resolution is partial and conditional for Claude API:

- `claude_api_daily_usage`: **no user attribution** — usage is attributable only to `api_key_id`, not to a person.
- `claude_api_requests.user_id`: nullable — present only when the calling application includes `X-Anthropic-User-Id`. When present, `user_id` is a caller-defined identifier (typically an internal user ID or email) that must be mapped to `person_id` by the Identity Manager.

The mapping from `user_id` (arbitrary caller string) to `person_id` requires a client-specific configuration — the Identity Manager must know the convention used by each application (e.g. is `user_id` an email? an employee ID? a GitHub login?).

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `claude_api_daily_usage` | `class_ai_api_usage` | Planned — stream not yet defined |
| `claude_api_requests` | `class_ai_api_usage` | Planned — with nullable `person_id` |

**Gold**: AI API cost analytics (spend per API key, per model, per application), usage trends by team once `person_id` is resolved. The `application` field enables attribution to specific product features or internal tools.

---

## Open Questions

### OQ-CAPI-1: Per-key user attribution — `X-Anthropic-User-Id` coverage

`claude_api_requests` requires the calling application to pass `X-Anthropic-User-Id`. This is a caller convention, not enforced by Anthropic:

- How much of the client's API traffic is instrumented with this header?
- Should the connector emit a warning when the daily_usage request count significantly exceeds the request records count (indicating uninstrumented traffic)?

See also: `CONNECTORS_REFERENCE.md` OQ-3.

### OQ-CAPI-2: `class_ai_api_usage` Silver design — nullable `person_id`

When `user_id` is NULL (uninstrumented requests), the Silver row has no person attribution. Options:

- Store rows with `person_id = NULL` (partial attribution Silver table)
- Separate `class_ai_api_usage` (per-key, no person) from `class_ai_usage` (per-person, when available)
- Track per-key usage in Gold without a Silver unification step

See also: `CONNECTORS_REFERENCE.md` OQ-3.
