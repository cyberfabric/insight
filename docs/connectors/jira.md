# Jira Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 5 (Jira)

Standalone specification for the Jira (Task Tracking) connector. Expands Source 5 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`jira_issue` — Issue identifiers and timestamps](#jiraissue-issue-identifiers-and-timestamps)
  - [`jira_issue_history` — Complete changelog (field change log)](#jiraissuehistory-complete-changelog-field-change-log)
  - [`jira_user` — User directory](#jirauser-user-directory)
  - [`jira_collection_runs` — Connector execution log](#jiracollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-JIRA-1: `account_id` vs email as the primary identity key](#oq-jira-1-accountid-vs-email-as-the-primary-identity-key)
  - [OQ-JIRA-2: Multi-instance Jira deployments](#oq-jira-2-multi-instance-jira-deployments)

<!-- /toc -->

---

## Overview

**API**: Jira REST API v3 (Atlassian Cloud) or v2 (Jira Server/Data Center)

**Category**: Task Tracking

**Authentication**: API token (Cloud) or Basic Auth (Server)

**Identity**: `jira_user.email` — resolved to canonical `person_id` via Identity Manager. Jira Cloud uses Atlassian `account_id` as the internal user identifier; email is the cross-system key.

**Field naming**: snake_case — Jira API uses camelCase but fields are renamed to snake_case at Bronze level for consistency.

**Why multiple tables**: Same 1:N structure as YouTrack — one issue has many changelog entries. `jira_user` is a separate identity anchor.

**Key differences from YouTrack:**

| Aspect | YouTrack | Jira |
|--------|----------|------|
| User ID type | Internal numeric string, e.g. `2-12345` | Atlassian `account_id` (alphanumeric) |
| Changelog values | New value only (`value`) | Both old (`value_from`) and new (`value_to`) |
| Human-readable values | Embedded in `value` jsonb | Separate `*_string` fields |
| Project scoping | Via `id_readable` prefix | Explicit `project_key` column |

---

## Bronze Tables

### `jira_issue` — Issue identifiers and timestamps

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier, e.g. `jira-team-alpha` |
| `jira_id` | text | Jira internal numeric ID, e.g. `10001` |
| `id_readable` | text | Human-readable key, e.g. `PROJ-123` |
| `project_key` | text | Project key, e.g. `PROJ` |
| `created` | timestamp | Issue creation timestamp |
| `updated` | timestamp | Last update — cursor for incremental sync |

Intentionally minimal. All state lives in `jira_issue_history`.

---

### `jira_issue_history` — Complete changelog (field change log)

Every state transition, reassignment, and field update is a separate row. Jira's changelog API returns one entry per operation; each entry may contain multiple field changes — each stored as a separate row.

| Field | Type | Description |
|-------|------|-------------|
| `id_readable` | varchar | Human-readable issue key, e.g. `PROJ-123` — joins to `jira_issue.id_readable` |
| `issue_jira_id` | varchar | Parent issue's internal numeric ID |
| `author_account_id` | varchar | Atlassian account ID of who made the change — joins to `jira_user.account_id` |
| `changelog_id` | varchar | Changelog entry ID — multiple field changes in one operation share this |
| `created_at` | timestamptz | When the change was made |
| `field_id` | varchar | Machine-readable field identifier |
| `field_name` | varchar | Human-readable field name, e.g. `status`, `assignee` |
| `value_from` | varchar | Previous raw value (ID or key) |
| `value_from_string` | varchar | Previous human-readable value, e.g. `In Progress` |
| `value_to` | varchar | New raw value after the change |
| `value_to_string` | varchar | New human-readable value, e.g. `Done` |

**`changelog_id` groups related changes:** when a user performs one action that updates multiple fields simultaneously, all resulting rows share the same `changelog_id`.

---

### `jira_user` — User directory

| Field | Type | Description |
|-------|------|-------------|
| `account_id` | varchar | Atlassian account ID — primary key; joins to `jira_issue_history.author_account_id` |
| `email` | varchar | Email — primary key for cross-system identity resolution |
| `display_name` | varchar | Display name |
| `account_type` | varchar | `atlassian` / `app` / `customer` |
| `active` | boolean | Whether the account is active |

---

### `jira_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `issues_collected` | numeric | Rows collected for `jira_issue` |
| `history_records_collected` | numeric | Rows collected for `jira_issue_history` |
| `users_collected` | numeric | Rows collected for `jira_user` |
| `api_calls` | numeric | API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (instance URL, project filter, lookback) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`jira_user.email` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

`jira_issue_history.author_account_id` joins to `jira_user.account_id` to resolve the author's email, which is then resolved to `person_id`.

`account_id` is Atlassian-platform-specific — it is shared across Jira, Confluence, and Bitbucket on the same Atlassian tenant, which makes it more useful for cross-tool resolution within the Atlassian ecosystem. However, email remains the canonical cross-system key for Insight's Identity Manager.

`source_instance_id` scopes all IDs to their Jira instance, preventing collisions across multiple Jira deployments.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `jira_issue` + `jira_issue_history` | `class_task_tracker_activities` | ✓ Feeds Silver step 1 |
| `jira_issue` + `jira_issue_history` | `class_task_tracker_snapshot` | ✓ Feeds Silver step 1 (parallel) |
| `jira_user` | Identity Manager (email → `person_id`) | ✓ Used for identity resolution |

**Silver step 1** (written by the connector simultaneously):
- `class_task_tracker_activities` — append-only event stream; `value_to` maps to `changed_to`, `value_from` maps to `changed_from`
- `class_task_tracker_snapshot` — current state per issue (upsert by `source_instance_id` + `issue_ref`)

**Silver step 2**: `class_task_tracker` — `author_account_id` resolved to `person_id` via Identity Manager.

**Gold**: Same as YouTrack — `status_periods`, `lifecycle_summary`, `throughput`, `wip_snapshots`. Jira and YouTrack produce identical Gold outputs from the same `class_task_tracker` Silver stream.

---

## Open Questions

### OQ-JIRA-1: `account_id` vs email as the primary identity key

Jira Cloud may not expose email addresses for all users (Atlassian privacy controls can hide emails). In this case:

- Can `account_id` be used as a fallback identity key within the Atlassian ecosystem (Jira + Bitbucket share the same account)?
- Should the Identity Manager support Atlassian `account_id` as an alternative resolution path?

### OQ-JIRA-2: Multi-instance Jira deployments

`source_instance_id` disambiguates multiple Jira instances. When the same `project_key` (e.g. `PROJ`) exists in two instances:

- Is `(source_instance_id, id_readable)` the unique composite key for issues in Silver?
- How does `task_id` in `class_task_tracker` disambiguate — does it include the instance prefix?
