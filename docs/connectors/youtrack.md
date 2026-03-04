# YouTrack Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 4 (YouTrack), OQ-5, OQ-6

Standalone specification for the YouTrack (Task Tracking) connector. Expands Source 4 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`youtrack_issue` — Issue identifiers and timestamps](#youtrackissue-issue-identifiers-and-timestamps)
  - [`youtrack_issue_history` — Complete field change log](#youtrackissuehistory-complete-field-change-log)
  - [`youtrack_user` — User directory](#youtrackuser-user-directory)
  - [`youtrack_collection_runs` — Connector execution log](#youtrackcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-YT-1: `source_instance_id` presence in `youtrack_issue`](#oq-yt-1-sourceinstanceid-presence-in-youtrackissue)
  - [OQ-YT-2: `author_youtrack_id` type in Silver — text vs numeric](#oq-yt-2-authoryoutrackid-type-in-silver-text-vs-numeric)

<!-- /toc -->

---

## Overview

**API**: YouTrack REST API (Hub API + Issues API)

**Category**: Task Tracking

**Authentication**: Permanent token (YouTrack service account)

**Identity**: `youtrack_user.email` — resolved to canonical `person_id` via Identity Manager. `youtrack_id` (internal numeric ID like `2-12345`) and `username` are YouTrack-internal; email is the cross-system key.

**Field naming**: snake_case — preserved as-is at Bronze level.

**Why multiple tables**: Issue and history are a genuine 1:N relationship — one issue has many field-change events over its lifetime. Merging would require either denormalizing issue metadata onto every history row or losing the event model. `youtrack_user` is a separate identity anchor (1 row per user, many issues per user).

**Design principle**: `youtrack_issue` is intentionally minimal — only identifiers and timestamps. All state (status, assignee, type, priority) lives in `youtrack_issue_history`. This avoids maintaining a separate "current state" snapshot at Bronze level — the history is the source of truth.

---

## Bronze Tables

### `youtrack_issue` — Issue identifiers and timestamps

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier, e.g. `youtrack-acme-prod` — distinguishes multiple YouTrack instances |
| `youtrack_id` | text | YouTrack internal ID, e.g. `2-12345` |
| `id_readable` | text | Human-readable ID, e.g. `MON-123` — joins to `youtrack_issue_history.id_readable` |
| `created` | timestamp | Issue creation timestamp |
| `updated` | timestamp | Last update — cursor for incremental sync |

Intentionally minimal. All state lives in `youtrack_issue_history`.

---

### `youtrack_issue_history` — Complete field change log

Every state transition, reassignment, and field update is a separate row.

| Field | Type | Description |
|-------|------|-------------|
| `id_readable` | varchar | Human-readable issue ID — joins to `youtrack_issue.id_readable` |
| `issue_youtrack_id` | varchar | Parent issue's internal ID |
| `author_youtrack_id` | varchar | Who made the change — joins to `youtrack_user.youtrack_id` |
| `activity_id` | varchar | Batch ID — multiple changes in one operation share this |
| `created_at` | timestamptz | When the change was made |
| `field_id` | varchar | Machine-readable field identifier |
| `field_name` | varchar | Human-readable field name, e.g. `State`, `Assignee` |
| `value` | jsonb | New field value after the change — varies by field type (see note) |
| `value_id` | varchar | Unique value change ID — for deduplication |

**`value` field variation by type:**
- State / Priority fields: plain string, e.g. `"In Progress"`
- User fields (Assignee): object `{"name": "Jane Smith", "id": "1-234"}`
- Tags: array of strings

---

### `youtrack_user` — User directory

| Field | Type | Description |
|-------|------|-------------|
| `youtrack_id` | varchar | YouTrack internal user ID — joins to `youtrack_issue_history.author_youtrack_id` |
| `email` | varchar | Email — primary key for cross-system identity resolution |
| `full_name` | varchar | Display name |
| `username` | varchar | Login username |

---

### `youtrack_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `issues_collected` | numeric | Rows collected for `youtrack_issue` |
| `history_records_collected` | numeric | Rows collected for `youtrack_issue_history` |
| `users_collected` | numeric | Rows collected for `youtrack_user` |
| `api_calls` | numeric | API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (instance URL, project filter, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`youtrack_user.email` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

`youtrack_issue_history.author_youtrack_id` joins to `youtrack_user.youtrack_id` to resolve the author's email, which is then resolved to `person_id` in Silver step 2.

`youtrack_id` (e.g. `2-12345`) and `username` are YouTrack-internal — not used for cross-system resolution.

`source_instance_id` scopes all IDs to their YouTrack instance. If two instances use overlapping `youtrack_id` values, `source_instance_id` differentiates them.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `youtrack_issue` + `youtrack_issue_history` | `class_task_tracker_activities` | ✓ Feeds Silver step 1 |
| `youtrack_issue` + `youtrack_issue_history` | `class_task_tracker_snapshot` | ✓ Feeds Silver step 1 (parallel) |
| `youtrack_user` | Identity Manager (email → `person_id`) | ✓ Used for identity resolution |

**Silver step 1** (written by the connector simultaneously):
- `class_task_tracker_activities` — append-only event stream; one row per field-change event in `youtrack_issue_history`
- `class_task_tracker_snapshot` — current state per issue (upsert by `source_instance_id` + `issue_ref`)

**Silver step 2**: `class_task_tracker` — `author_youtrack_id` resolved to `person_id` via Identity Manager.

**Gold**: `status_periods`, `lifecycle_summary`, `throughput`, `wip_snapshots` — derived from `class_task_tracker`. Requires per-`source_instance_id` status category configuration (which status names map to `in_progress`, `done`, etc.).

---

## Open Questions

### OQ-YT-1: `source_instance_id` presence in `youtrack_issue`

`youtrack_issue.source_instance_id` is present in the Connector Reference spec but may not appear in some stream spec definitions (PR #3). Clarification needed:

- Is `source_instance_id` currently produced by the YouTrack connector?
- Should it be added to `youtrack_issue_history` as well, or is it only needed in the issue table?

See also: `CONNECTORS_REFERENCE.md` OQ-5.

### OQ-YT-2: `author_youtrack_id` type in Silver — text vs numeric

`youtrack_issue_history.author_youtrack_id` is `varchar` at Bronze level but Silver's `class_task_tracker_activities` uses `UInt64` for `event_author_raw`.

- Does the Silver pipeline parse `author_youtrack_id` as a numeric value? YouTrack IDs like `2-12345` are not pure integers.
- Should the Silver layer store the raw string identifier instead of a numeric type?

See also: `CONNECTORS_REFERENCE.md` OQ-6.
