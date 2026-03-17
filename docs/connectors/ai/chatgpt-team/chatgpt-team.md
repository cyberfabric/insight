# ChatGPT Team Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 19 (ChatGPT Team)

Standalone specification for the ChatGPT Team (AI Tool) connector. Expands Source 19 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`chatgpt_team_seats` — Seat assignment and status](#chatgptteamseats-seat-assignment-and-status)
  - [`chatgpt_team_activity` — Daily usage per user per model](#chatgptteamactivity-daily-usage-per-user-per-model)
  - [`chatgpt_team_collection_runs` — Connector execution log](#chatgptteamcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-CGT-1: ChatGPT Team vs OpenAI API for the same user](#oq-cgt-1-chatgpt-team-vs-openai-api-for-the-same-user)
  - [OQ-CGT-2: Parallel to Claude Team — unified Silver stream](#oq-cgt-2-parallel-to-claude-team-unified-silver-stream)

<!-- /toc -->

---

## Overview

**API**: OpenAI Admin API — workspace user management and usage reports for Team/Enterprise accounts

**Category**: AI Tool

**Authentication**: Admin API key (OpenAI Platform — Team/Enterprise plan)

**Identity**: `email` in both `chatgpt_team_seats` and `chatgpt_team_activity` — resolved to canonical `person_id` via Identity Manager.

**Field naming**: snake_case — preserved as-is at Bronze level.

**Why two tables**: Seat assignment (one row per user) and daily activity (many rows per user over time) are different entities — same pattern as Claude Team Plan (Source 14).

**Parallel to Claude Team Plan**: Same two-table model — seats + daily activity. ChatGPT Team covers `chatgpt.com` web interface, desktop app, and mobile. The billing model is flat per-seat (no per-request cost). Reasoning tokens appear in the activity table for o1/o3 model usage.

| Aspect | OpenAI API (Source 18) | ChatGPT Team (Source 19) |
|--------|------------------------|--------------------------|
| Billing | Pay-per-token | Fixed per-seat/month |
| Access | `api.openai.com` | `chatgpt.com` + desktop app |
| Clients | Programmatic only | `web`, `desktop`, `mobile` |

---

## Bronze Tables

### `chatgpt_team_seats` — Seat assignment and status

| Field | Type | Description |
|-------|------|-------------|
| `user_id` | String | OpenAI platform user ID |
| `email` | String | User email — primary key for cross-system identity resolution |
| `role` | String | `owner` / `admin` / `member` |
| `status` | String | `active` / `inactive` / `pending` |
| `added_at` | DateTime64(3) | When the seat was assigned |
| `last_active_at` | DateTime64(3) | Last recorded activity |

One row per user. Current-state only — no versioning.

---

### `chatgpt_team_activity` — Daily usage per user per model

| Field | Type | Description |
|-------|------|-------------|
| `user_id` | String | OpenAI platform user ID |
| `email` | String | User email — identity key |
| `date` | Date | Activity date |
| `client` | String | `web` / `desktop` / `mobile` |
| `model` | String | Model used, e.g. `gpt-4o`, `o1`, `o3-mini` |
| `conversation_count` | Float64 | Number of distinct conversations |
| `message_count` | Float64 | Messages sent |
| `input_tokens` | Float64 | Input tokens consumed |
| `output_tokens` | Float64 | Output tokens generated |
| `reasoning_tokens` | Float64 | Reasoning tokens (o1/o3 models only; billed but not in output) |

No `cost_cents` — flat subscription.

`reasoning_tokens` is present for o1/o3 model usage — ChatGPT Team exposes this to workspace admins even though it is not billed separately under the flat subscription.

---

### `chatgpt_team_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` | DateTime64(3) | Run start time |
| `completed_at` | DateTime64(3) | Run end time |
| `status` | String | `running` / `completed` / `failed` |
| `seats_collected` | Float64 | Rows collected for `chatgpt_team_seats` |
| `activity_records_collected` | Float64 | Rows collected for `chatgpt_team_activity` |
| `api_calls` | Float64 | Admin API calls made |
| `errors` | Float64 | Errors encountered |
| `settings` | String | Collection configuration (workspace, lookback period) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`email` in both `chatgpt_team_seats` and `chatgpt_team_activity` is the primary identity key — resolved to canonical `person_id` via Identity Manager in Silver step 2.

`user_id` (OpenAI platform user ID) is OpenAI-internal — not used for cross-system resolution.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `chatgpt_team_seats` | *(seat roster)* | Available — no unified stream defined yet |
| `chatgpt_team_activity` | `class_ai_tool_usage` | Planned — alongside Claude Team web/mobile |

**Gold**: General AI tool adoption metrics (active users, conversation volume, model distribution, client breakdown). Alongside Claude Team Plan web/mobile activity, enables cross-provider AI tool adoption analytics.

---

## Open Questions

### OQ-CGT-1: ChatGPT Team vs OpenAI API for the same user

A developer may use both ChatGPT Team (via web/desktop) and the OpenAI API (programmatic calls). The same person generates usage in both.

**CLOSED.** `class_ai_tool_usage` (conversational) and `class_ai_api_usage` (programmatic) are kept as separate Silver streams. They serve different analytics purposes: `class_ai_tool_usage` measures AI assistant adoption (chat interactions, seat utilization), while `class_ai_api_usage` measures programmatic API spend and throughput. A unified `class_ai_usage` stream will NOT be created — three separate streams are maintained: `class_ai_dev_usage` (IDE/coding tools), `class_ai_api_usage` (programmatic API), and `class_ai_tool_usage` (chat/assistant tools). Cross-stream analysis by `person_id` can be performed at Gold level without collapsing the Silver schemas.

### OQ-CGT-2: Parallel to Claude Team — unified Silver stream

ChatGPT Team and Claude Team Plan have nearly identical Bronze schemas (seats + daily activity by client). A unified Silver `class_ai_tool_usage` would cover both:

- `source`: `claude_team` / `chatgpt_team`
- Shared fields: `date`, `email`, `client`, `model`, token counts, `message_count`, `conversation_count`
- Claude-specific: `tool_use_count`, `cache_write_tokens`, `cache_read_tokens`
- OpenAI-specific: `reasoning_tokens`

Should the Silver schema use explicit nullable columns for source-specific fields, or a jsonb `extras`?
