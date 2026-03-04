# GitHub Copilot Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 15 (GitHub Copilot)

Standalone specification for the GitHub Copilot (AI Dev Tool) connector. Expands Source 15 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`copilot_seats` — Seat assignment and last activity](#copilotseats-seat-assignment-and-last-activity)
  - [`copilot_usage` — Org-level daily usage totals](#copilotusage-org-level-daily-usage-totals)
  - [`copilot_usage_breakdown` — Daily breakdown by language and editor](#copilotusagebreakdown-daily-breakdown-by-language-and-editor)
  - [`copilot_collection_runs` — Connector execution log](#copilotcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-COP-1: No per-user daily metrics — impact on Silver unification](#oq-cop-1-no-per-user-daily-metrics-impact-on-silver-unification)
  - [OQ-COP-2: `last_activity_at` as a proxy for active usage](#oq-cop-2-lastactivityat-as-a-proxy-for-active-usage)

<!-- /toc -->

---

## Overview

**API**: GitHub REST API — `/orgs/{org}/copilot/*` endpoints

**Category**: AI Dev Tool

**Authentication**: GitHub App installation token or PAT with `manage_billing:copilot` scope

**Identity**: `user_email` in `copilot_seats` — resolved to canonical `person_id` via Identity Manager. `copilot_usage` and `copilot_usage_breakdown` are org-level and have no user attribution.

**Field naming**: snake_case — GitHub API uses snake_case; preserved as-is at Bronze level.

**Why three tables**: Seats (per-user roster), org-level daily totals, and per-language/editor breakdown are three distinct entities that cannot be merged. `copilot_usage` and `copilot_usage_breakdown` have no user-level data.

**Key structural difference from Cursor/Windsurf**: The GitHub Copilot API does not expose per-user daily usage. It provides:
- Per-seat last-activity timestamps (`copilot_seats`)
- Org-level daily aggregates (`copilot_usage`)
- Language × editor breakdown without per-user data (`copilot_usage_breakdown`)

No per-user token counts or per-user daily metrics exist in the standard API.

---

## Bronze Tables

### `copilot_seats` — Seat assignment and last activity

| Field | Type | Description |
|-------|------|-------------|
| `user_login` | text | GitHub login of the seat holder |
| `user_email` | text | Email (from linked GitHub account) — identity resolution key |
| `plan_type` | text | `business` / `enterprise` |
| `pending_cancellation_date` | date | If seat is scheduled for cancellation (NULL otherwise) |
| `last_activity_at` | timestamptz | Last recorded Copilot activity across all editors |
| `last_activity_editor` | text | Editor used in last activity, e.g. `vscode`, `jetbrains` |
| `created_at` | timestamptz | When the seat was assigned |
| `updated_at` | timestamptz | Last seat record update |

One row per user. `last_activity_at` is the only per-user usage signal available in the Copilot API.

---

### `copilot_usage` — Org-level daily usage totals

| Field | Type | Description |
|-------|------|-------------|
| `date` | date | Usage date — primary key |
| `total_suggestions_count` | numeric | Code completion suggestions shown |
| `total_acceptances_count` | numeric | Suggestions accepted (tab) |
| `total_lines_suggested` | numeric | Lines of code suggested |
| `total_lines_accepted` | numeric | Lines of code accepted |
| `total_active_users` | numeric | Users with at least one completion interaction |
| `total_chat_turns` | numeric | Copilot Chat interactions (IDE + github.com) |
| `total_chat_acceptances` | numeric | Code blocks accepted from chat |
| `total_active_chat_users` | numeric | Users who used Copilot Chat |

Org-level only — no per-user breakdown. Enables trend analysis of overall adoption without individual attribution.

---

### `copilot_usage_breakdown` — Daily breakdown by language and editor

| Field | Type | Description |
|-------|------|-------------|
| `date` | date | Usage date |
| `language` | text | Programming language, e.g. `python`, `typescript`, `go` |
| `editor` | text | Editor, e.g. `vscode`, `jetbrains`, `neovim`, `vim`, `xcode` |
| `suggestions_count` | numeric | Suggestions shown for this language × editor |
| `acceptances_count` | numeric | Suggestions accepted |
| `lines_suggested` | numeric | Lines suggested |
| `lines_accepted` | numeric | Lines accepted |
| `active_users` | numeric | Active users for this language × editor combination |

One row per `(date, language, editor)`. Enables analysis of adoption by editor and language without per-user resolution.

---

### `copilot_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `seats_collected` | numeric | Rows collected for `copilot_seats` |
| `usage_records_collected` | numeric | Rows collected for `copilot_usage` |
| `breakdown_records_collected` | numeric | Rows collected for `copilot_usage_breakdown` |
| `api_calls` | numeric | API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (org, lookback period) |

Monitoring table — not an analytics source.

---

## Identity Resolution

Only `copilot_seats` has user-level data. `user_email` is the primary identity key — resolved to canonical `person_id` via Identity Manager.

`user_login` (GitHub username) is a secondary identifier — useful for cross-referencing with `github_commits.author_login` but not used as the primary identity key.

`copilot_usage` and `copilot_usage_breakdown` have no user attribution — org-level aggregate data only.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `copilot_seats` | *(seat roster — activity signal only)* | Available — `last_activity_at` is the only per-user metric |
| `copilot_usage` | `class_ai_dev_usage` (org-level rows) | Planned — org-level aggregate, no `person_id` |
| `copilot_usage_breakdown` | *(org analytics)* | Available — language/editor adoption, no Silver target yet |

**Gold**: GitHub Copilot adoption metrics (active users trend, acceptance rate, lines accepted per day, editor/language distribution). Per-user Gold metrics are not possible from Copilot API data alone — only the seat roster's `last_activity_at` provides any per-user signal.

---

## Open Questions

### OQ-COP-1: No per-user daily metrics — impact on Silver unification

GitHub Copilot does not expose per-user daily usage. When building `class_ai_dev_usage`:

- Cursor and Windsurf contribute per-user daily rows with acceptance rates, lines added, etc.
- Copilot can only contribute org-level aggregate rows and seat-level last-activity timestamps.

- Should `class_ai_dev_usage` allow org-level rows (with `person_id = NULL`)?
- Or should Copilot aggregate data go into a separate `class_ai_org_usage` stream?
- Is `copilot_seats.last_activity_at` sufficient as a "user was active" signal for per-user Gold metrics?

### OQ-COP-2: `last_activity_at` as a proxy for active usage

`copilot_seats.last_activity_at` is the only per-user usage timestamp. It is:
- Updated on any Copilot interaction (completion or chat)
- Not granular — no count of interactions, no token usage

- Is `last_activity_at` sufficient to classify a user as "active" for a given period?
- Should the connector be run daily and snapshot `last_activity_at` changes to reconstruct a daily activity binary signal?
