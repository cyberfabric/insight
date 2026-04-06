# Task Tracking Connector Specification (Multi-Source)

> Version 1.0 — March 2026
> Based on: YouTrack (Source 4) and Jira (Source 5)

Defines the Silver layer for task tracking connectors. The Silver layer has two steps: Step 1 unifies raw Bronze data from source-specific tables (`youtrack_*`, `jira_*`) into a common schema; Step 2 enriches with `person_id` via Identity Resolution.

**Primary analytics focus**: employee productivity metrics — cycle time, throughput, WIP, workload distribution, sprint velocity, and blocker analysis.

<!-- toc -->

- [Overview](#overview)
- [Silver Tables — Step 1: Unified Schema (pre-Identity Resolution)](#silver-tables--step-1-unified-schema-pre-identity-resolution)
  - [`task_tracker_issues` — Issue identifiers and core fields](#task_tracker_issues--issue-identifiers-and-core-fields)
  - [`task_tracker_history` — Complete field change log](#task_tracker_history--complete-field-change-log)
  - [`task_tracker_issue_ext` — Custom fields (key-value)](#task_tracker_issue_ext--custom-fields-key-value)
  - [`task_tracker_worklogs` — Logged time per issue](#task_tracker_worklogs--logged-time-per-issue)
  - [`task_tracker_comments` — Issue comments](#task_tracker_comments--issue-comments)
  - [`task_tracker_projects` — Project directory](#task_tracker_projects--project-directory)
  - [`task_tracker_issue_links` — Issue dependencies](#task_tracker_issue_links--issue-dependencies)
  - [`task_tracker_sprints` — Sprint / iteration metadata](#task_tracker_sprints--sprint--iteration-metadata)
  - [`task_tracker_users` — User directory](#task_tracker_users--user-directory)
  - [`task_tracker_collection_runs` — Connector execution log](#task_tracker_collection_runs--connector-execution-log)
- [Source Mapping](#source-mapping)
  - [YouTrack](#youtrack)
  - [Jira](#jira)
- [Identity Resolution](#identity-resolution)
- [Silver Step 2 → Gold](#silver-step-2--gold)
- [Open Questions](#open-questions)

<!-- /toc -->

---

## Overview

**Category**: Task Tracking

**Supported Sources**:
- YouTrack (`data_source = "insight_youtrack"`)
- Jira (`data_source = "insight_jira"`)

**Authentication**:
- YouTrack: Permanent token (service account)
- Jira Cloud: API token + email; Jira Server/Data Center: Basic Auth

**Identity**: `task_tracker_users.email` — internal team members resolved to canonical `person_id` via Identity Manager. All activity (history, worklogs, comments) is attributed to `person_id` in Silver.

**Design principle**: `task_tracker_issues` stores identifiers and immutable context. `task_tracker_history` is an append-only event log — the source of truth for cycle time, status periods, and assignee history. This pattern applies uniformly across YouTrack and Jira.

**`insight_source_id`**: present in all tables — required to disambiguate multiple tool instances (e.g. two YouTrack tenants or multiple Jira organizations in the same Silver Step 1 store). `(insight_source_id, issue_id)` is the composite primary key for issues.

**Terminology mapping**:

| Concept | YouTrack | Jira | Unified |
|---------|---------|------|---------|
| Internal user | User | User (Atlassian account) | `task_tracker_users` |
| Issue | Issue | Issue | `task_tracker_issues` |
| Field change log | Activities API | Changelog API | `task_tracker_history` |
| Time tracking | Work item | Worklog | `task_tracker_worklogs` |
| Iteration | Sprint (Agile board) | Sprint (Agile board) | `task_tracker_sprints` |
| Custom fields | Custom fields | Custom fields | `task_tracker_issue_ext` |

---

## Silver Tables — Step 1: Unified Schema (pre-Identity Resolution)

> **Silver Step 1**: Data from source-specific Bronze tables ([youtrack.md](youtrack.md) and [jira.md](jira.md)) is normalized and written here. No `person_id` yet — Identity Resolution runs in Step 2.

### `task_tracker_issues` — Issue identifiers and core fields

Minimal record — identifiers and immutable context fields only. All mutable state lives in `task_tracker_history`.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier, e.g. `youtrack-acme-prod`, `jira-team-alpha` |
| `issue_id` | String | REQUIRED | Source-specific internal issue ID (YouTrack `youtrack_id` / Jira `jira_id`) |
| `id_readable` | String | REQUIRED | Human-readable key, e.g. `MON-123` / `PROJ-123` — display and join key |
| `project_key` | String | REQUIRED | Project short key, e.g. `MON` / `PROJ` — joins to `task_tracker_projects.project_key` |
| `issue_type` | String | NULLABLE | Issue type: `Bug` / `Story` / `Task` / `Epic` / etc. |
| `reporter_id` | String | NULLABLE | Who created the issue — source user ID — joins to `task_tracker_users.user_id` |
| `story_points` | Float64 | NULLABLE | Story points estimate; NULL if not set |
| `due_date` | Date | NULLABLE | Due date; NULL if not set |
| `parent_id` | String | NULLABLE | Parent issue key for subtasks or Epic link; NULL for top-level issues (Jira only; NULL for YouTrack) |
| `created_at` | DateTime64(3) | REQUIRED | Issue creation timestamp |
| `updated_at` | DateTime64(3) | REQUIRED | Last update — cursor for incremental sync |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `custom_str_attrs` | Map(String, String) | DEFAULT {} | Workspace-specific string custom fields promoted from `task_tracker_issue_ext` per Custom Attributes Configuration |
| `custom_num_attrs` | Map(String, Float64) | DEFAULT {} | Workspace-specific numeric custom fields promoted from `task_tracker_issue_ext` per Custom Attributes Configuration |
| `data_source` | String | DEFAULT '' | Source discriminator: `insight_youtrack` / `insight_jira` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_tt_issue_lookup`: `(insight_source_id, issue_id, data_source)`
- `idx_tt_issue_readable`: `(insight_source_id, id_readable, data_source)`
- `idx_tt_issue_updated`: `(updated_at)`

**Note on `story_points`**: field name and ID differ per instance and project type. See OQ-TT-1.

---

### `task_tracker_history` — Complete field change log

Every state transition, reassignment, and field update is a separate row. This is the append-only event log — source of truth for cycle time, status periods, and assignee history.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier — scopes all IDs |
| `id_readable` | String | REQUIRED | Human-readable issue key — joins to `task_tracker_issues.id_readable` |
| `issue_id` | String | REQUIRED | Parent issue's internal ID |
| `author_id` | String | NULLABLE | Source user ID of who made the change — joins to `task_tracker_users.user_id` |
| `event_id` | String | REQUIRED | Source-specific event/changelog ID — groups related field changes in one operation |
| `created_at` | DateTime64(3) | REQUIRED | When the change was made |
| `field_id` | String | NULLABLE | Machine-readable field identifier |
| `field_name` | String | REQUIRED | Human-readable field name, e.g. `State`, `Assignee`, `Priority`, `Sprint` |
| `value_from` | String | NULLABLE | Previous value — raw ID or string; NULL if field was empty before |
| `value_from_display` | String | NULLABLE | Previous human-readable value (Jira `fromString`; extracted from YouTrack `removed` for enum/state fields) |
| `value_to` | String | NULLABLE | New value after the change |
| `value_to_display` | String | NULLABLE | New human-readable value (Jira `toString`; extracted from YouTrack `added` for enum/state fields) |
| `raw_value` | String | NULLABLE | Full `added`/`removed` payload as JSON for complex types (YouTrack user objects, arrays) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_history_issue`: `(insight_source_id, id_readable, data_source)`
- `idx_tt_history_author`: `(author_id, data_source)`
- `idx_tt_history_created`: `(created_at)`
- `idx_tt_history_field`: `(field_name, data_source)`

**`event_id` groups related changes**: one user action updating multiple fields produces multiple rows with the same `event_id` (YouTrack `activity_id` / Jira `changelog_id`).

**`value_from` / `value_to` normalisation**:
- Jira: `from` / `to` (raw ID or key) → `value_from` / `value_to`; `fromString` / `toString` → `value_from_display` / `value_to_display`
- YouTrack: `removed[0]` (string/object/number) → `value_from`; `added[0]` → `value_to`; complex types (user objects, arrays) stored in `raw_value`

---

### `task_tracker_issue_ext` — Custom fields (key-value)

Stores per-issue custom field values that don't fit the core schema. Follows the same key-value extension pattern as `git_repositories_ext`.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `id_readable` | String | REQUIRED | Issue key — joins to `task_tracker_issues.id_readable` |
| `field_id` | String | REQUIRED | Custom field machine ID |
| `field_name` | String | REQUIRED | Custom field display name, e.g. `Team`, `Squad`, `Customer` |
| `field_value` | String | NULLABLE | Field value as string; JSON for complex types |
| `value_type` | String | NULLABLE | Type hint: `string` / `number` / `user` / `enum` / `json` |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_ext_issue`: `(insight_source_id, id_readable, data_source)`
- `idx_tt_ext_field`: `(field_name, data_source)`

**Purpose**: captures team, squad, domain, customer, and other org-specific fields without schema changes. Promoted to Silver snapshots selectively.

---

### `task_tracker_worklogs` — Logged time per issue

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `worklog_id` | String | REQUIRED | Source-specific worklog / work item ID |
| `id_readable` | String | REQUIRED | Parent issue key — joins to `task_tracker_issues.id_readable` |
| `author_id` | String | REQUIRED | Who logged the time — source user ID — joins to `task_tracker_users.user_id` |
| `work_date` | Date | REQUIRED | Date of work (not collection date) |
| `duration_seconds` | Int64 | REQUIRED | Time logged in seconds — normalised from source units |
| `description` | String | NULLABLE | Worklog comment or description (nullable) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_worklog_issue`: `(insight_source_id, id_readable, data_source)`
- `idx_tt_worklog_author`: `(author_id, data_source)`
- `idx_tt_worklog_date`: `(work_date)`

**Duration normalisation**:
- YouTrack: `duration.minutes` × 60 → `duration_seconds`
- Jira: `timeSpentSeconds` → `duration_seconds` (no conversion)

**Purpose**: actual time invested per person per issue. Complements status history — an issue can be "In Progress" for weeks but have only 2 hours of logged work.

---

### `task_tracker_comments` — Issue comments

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `comment_id` | String | REQUIRED | Comment ID |
| `id_readable` | String | REQUIRED | Parent issue key — joins to `task_tracker_issues.id_readable` |
| `author_id` | String | REQUIRED | Comment author — source user ID — joins to `task_tracker_users.user_id` |
| `created_at` | DateTime64(3) | REQUIRED | When comment was posted |
| `updated_at` | DateTime64(3) | NULLABLE | Last edit timestamp; NULL if never edited |
| `body` | String | NULLABLE | Comment body (plain text — Markdown for YouTrack, extracted from Atlassian Document Format for Jira) |
| `is_deleted` | Int64 | DEFAULT 0 | 1 if the comment has been deleted (YouTrack only; always 0 for Jira) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_comment_issue`: `(insight_source_id, id_readable, data_source)`
- `idx_tt_comment_author`: `(author_id, data_source)`

**Purpose**: collaboration signal — comment volume per person, review participation, cross-team communication.

---

### `task_tracker_projects` — Project directory

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `project_id` | String | REQUIRED | Source-specific internal project ID |
| `project_key` | String | REQUIRED | Short key, e.g. `MON` / `PROJ` — joins to `task_tracker_issues.project_key` |
| `name` | String | REQUIRED | Full project name |
| `lead_id` | String | NULLABLE | Project lead — source user ID — joins to `task_tracker_users.user_id` |
| `project_type` | String | NULLABLE | Jira: `software` / `business` / `service_desk`; NULL for YouTrack |
| `project_style` | String | NULLABLE | Jira: `classic` / `next-gen` — affects custom field IDs; NULL for YouTrack |
| `archived` | Int64 | DEFAULT 0 | 1 if the project is archived |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_project_lookup`: `(insight_source_id, project_key, data_source)`

**Purpose**: maps issues to teams/departments. `project_style` (Jira) is important — Next-gen and Classic projects use different custom field IDs for story points and sprint assignment.

---

### `task_tracker_issue_links` — Issue dependencies

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `source_issue` | String | REQUIRED | Source issue key (`id_readable`) |
| `target_issue` | String | REQUIRED | Target issue key (`id_readable`) |
| `link_type` | String | REQUIRED | Link type name, e.g. `blocks` / `is blocked by` / `duplicates` / `relates to` / `subtask of` |
| `direction` | String | NULLABLE | `outward` / `inward` — perspective from source issue (YouTrack only; NULL for Jira) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_link_source`: `(insight_source_id, source_issue, data_source)`
- `idx_tt_link_target`: `(insight_source_id, target_issue, data_source)`

**Purpose**: dependency and blocker analysis. Required for fair productivity measurement — blocked issues should not penalise the assignee's throughput metrics.

---

### `task_tracker_sprints` — Sprint / iteration metadata

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `sprint_id` | String | REQUIRED | Source-specific sprint ID (YouTrack text ID / Jira numeric ID as string) |
| `board_id` | String | REQUIRED | Agile board ID (text for YouTrack, numeric as string for Jira) |
| `board_name` | String | NULLABLE | Agile board name |
| `sprint_name` | String | REQUIRED | Sprint name |
| `project_key` | String | NULLABLE | Associated project — joins to `task_tracker_projects.project_key` |
| `state` | String | REQUIRED | Normalised state: `active` / `closed` / `future` |
| `start_date` | Date | NULLABLE | Sprint start date |
| `end_date` | Date | NULLABLE | Sprint end date (planned) |
| `complete_date` | Date | NULLABLE | Actual completion date; NULL if not closed |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_sprint_lookup`: `(insight_source_id, sprint_id, data_source)`
- `idx_tt_sprint_project`: `(insight_source_id, project_key, data_source)`

**`state` normalisation**:
- YouTrack: `is_completed = true` → `closed`; active board sprint → `active`; future sprint → `future`
- Jira: native `state` field (`active` / `closed` / `future`) — mapped directly

**Note**: issue-to-sprint membership is tracked via `task_tracker_history` (field_name = `Sprint` for both YouTrack and Jira). Sprint changes appear as history events, enabling carry-over analysis.

---

### `task_tracker_users` — User directory

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `insight_source_id` | String | REQUIRED | Connector instance identifier |
| `user_id` | String | REQUIRED | Source-specific user ID (YouTrack `youtrack_id` / Jira Atlassian `account_id`) |
| `email` | String | NULLABLE | Email — primary key for identity resolution; **nullable** — may be suppressed by Atlassian privacy controls (Jira Cloud) |
| `display_name` | String | NULLABLE | Display name (`full_name` in YouTrack, `displayName` in Jira) |
| `username` | String | NULLABLE | Login username (YouTrack only; NULL for Jira Cloud) |
| `account_type` | String | NULLABLE | Jira: `atlassian` / `app` / `customer`; NULL for YouTrack |
| `is_active` | Int64 | DEFAULT 1 | 1 if account is active; 0 if banned (YouTrack) or deactivated (Jira) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_tt_user_lookup`: `(insight_source_id, user_id, data_source)`
- `idx_tt_user_email`: `(email)`

**Identity note**: `user_id` is scoped to the source system (YouTrack IDs look like `1-234`; Jira Cloud uses Atlassian alphanumeric `account_id`). Email is the cross-system resolution key. For Jira, when email is suppressed, `account_id` may serve as a fallback within the Atlassian ecosystem — see OQ-TT-2.

---

### `task_tracker_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `issues_collected` | Int64 | NULLABLE | Rows collected for `task_tracker_issues` |
| `history_records_collected` | Int64 | NULLABLE | Rows collected for `task_tracker_history` |
| `worklogs_collected` | Int64 | NULLABLE | Rows collected for `task_tracker_worklogs` |
| `comments_collected` | Int64 | NULLABLE | Rows collected for `task_tracker_comments` |
| `users_collected` | Int64 | NULLABLE | Rows collected for `task_tracker_users` |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Number of errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (instance URL, project filter, lookback) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

---

## Source Mapping

> Per-source Bronze schemas (raw connector output) are defined in [youtrack.md](youtrack.md) and [jira.md](jira.md). The tables below describe how those Bronze records are normalized into Silver Step 1 unified tables.

### YouTrack

| Unified table | YouTrack source | Key mapping notes |
|---------------|----------------|-------------------|
| `task_tracker_issues` | `GET /api/issues` | `id` → `issue_id`; `idReadable` → `id_readable`; Unix ms timestamps → DateTime64(3) |
| `task_tracker_history` | `GET /api/issues/{id}/activities` | `author.id` → `author_id`; `id` (activity batch) → `event_id`; `removed[0]` → `value_from`; `added[0]` → `value_to`; complex types → `raw_value` |
| `task_tracker_issue_ext` | Custom fields from issue response | All non-core custom fields as key-value rows |
| `task_tracker_worklogs` | `GET /api/issues/{id}/timeTracking/workItems` | `duration.minutes` × 60 → `duration_seconds`; `date` (Unix ms) → `work_date` |
| `task_tracker_comments` | `GET /api/issues/{id}/comments` | `author.id` → `author_id`; `deleted` → `is_deleted` |
| `task_tracker_projects` | `GET /api/admin/projects` | `leader.id` → `lead_id`; `shortName` → `project_key` |
| `task_tracker_issue_links` | `GET /api/issues/{id}/links` | `direction` preserved; `linkType.name` → `link_type` |
| `task_tracker_sprints` | `GET /api/agiles/{boardId}/sprints` | `isCompleted` → `state = "closed"` or `"active"`; `start`/`finish` (Unix ms) → dates |
| `task_tracker_users` | `GET /api/admin/users` | `id` → `user_id`; `banned` → `is_active = 0`; `login` → `username` |

### Jira

| Unified table | Jira source | Key mapping notes |
|---------------|------------|-------------------|
| `task_tracker_issues` | `GET /rest/api/3/search` (JQL) | `id` → `issue_id`; `key` → `id_readable`; `fields.parent.key` → `parent_id` (subtasks / Epics) |
| `task_tracker_history` | `GET /rest/api/3/issue/{key}/changelog` | `accountId` → `author_id`; `id` (changelog batch) → `event_id`; `from` → `value_from`; `fromString` → `value_from_display`; `to` → `value_to`; `toString` → `value_to_display` |
| `task_tracker_issue_ext` | `fields.customfield_*` from issue response | Custom fields discovered via `GET /rest/api/3/field` |
| `task_tracker_worklogs` | `GET /rest/api/3/issue/{key}/worklog` | `timeSpentSeconds` → `duration_seconds`; `started` → `work_date` |
| `task_tracker_comments` | `GET /rest/api/3/issue/{key}/comment` | `author.accountId` → `author_id`; ADF body extracted to plain text → `body`; `is_deleted` = 0 always |
| `task_tracker_projects` | `GET /rest/api/3/project` | `lead.accountId` → `lead_id`; `style` → `project_style` (`classic` / `next-gen`) |
| `task_tracker_issue_links` | `fields.issuelinks` in issue response | `direction` = NULL; `type.outward` / `type.inward` → `link_type` |
| `task_tracker_sprints` | `GET /rest/agile/1.0/board/{boardId}/sprint` | `state` mapped directly; `completeDate` → `complete_date` |
| `task_tracker_users` | `GET /rest/api/3/users/search` | `accountId` → `user_id`; `emailAddress` → `email` (nullable); `displayName` → `display_name`; `active` → `is_active` |

---

## Identity Resolution

**Identity anchor**: `task_tracker_users` — all team members who interact with issues.

**Resolution process**:
1. Extract `email` from `task_tracker_users`
2. Normalize (lowercase, trim)
3. Map to canonical `person_id` via Identity Manager in Silver step 2
4. Propagate `person_id` to `task_tracker_history`, `task_tracker_worklogs`, and `task_tracker_comments` via `author_id` join

**Resolution chain**:
```
task_tracker_history.author_id
  → task_tracker_users.user_id
  → task_tracker_users.email
  → person_id
```
Same chain applies to `task_tracker_worklogs.author_id`, `task_tracker_comments.author_id`, and `task_tracker_projects.lead_id`.

**`insight_source_id` is required in all joins** — `id_readable` values like `PROJ-123` can collide across instances.

**Jira email suppression**: Atlassian privacy controls may suppress `emailAddress` for some users. When email is NULL, `user_id` (Atlassian `account_id`) may be used as a fallback within the Atlassian ecosystem (Jira + Confluence + Bitbucket on the same tenant). See OQ-TT-2.

---

## Silver Step 2 → Gold

Silver Step 1 (`task_tracker_*`) feeds into Silver Step 2 (`class_*`) after Identity Resolution adds `person_id`.

| Silver Step 1 table | Silver Step 2 target | Notes |
|---------------------|----------------------|-------|
| `task_tracker_issues` + `task_tracker_history` | `class_task_tracker_activities` | Append-only event stream — state transitions with resolved `person_id` |
| `task_tracker_issues` + `task_tracker_history` | `class_task_tracker_snapshot` | Current state per issue (upsert) — latest assignee, status, priority |
| `task_tracker_worklogs` | `class_task_tracker_worklogs` | Planned — actual time logged per person per issue |
| `task_tracker_comments` | `class_task_tracker_comments` | Planned — collaboration signal per person |
| `task_tracker_sprints` | `class_task_tracker_sprints` | Planned — sprint metadata for velocity metrics |
| `task_tracker_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `task_tracker_projects` | Reference — team/project mapping | No unified stream; used for grouping and filtering |
| `task_tracker_issue_links` | Reference — blocker analysis | Used to flag blocked issues in Gold |
| `task_tracker_issue_ext` | Merged into Silver Step 2 snapshots | Custom fields promoted selectively by configuration |

**Silver Step 2**: `class_task_tracker_activities` (event log) + `class_task_tracker_snapshot` (current state) — identity resolution adds `author_id` → `person_id` via Identity Manager

**Gold metrics**:
- **Cycle time**: time from first `In Progress` to first `Done` transition in `task_tracker_history`
- **Throughput**: issues resolved per person per sprint/week
- **WIP**: count of issues in active states at a point in time
- **Status periods**: time spent in each state per issue
- **Sprint velocity**: story points completed per sprint from `class_task_tracker_sprints`
- **Worklog hours**: actual time invested per person per project from `class_task_tracker_worklogs`
- **Blocker rate**: fraction of issues blocked at any point — from `task_tracker_issue_links`

---

## Open Questions

### OQ-TT-1: `story_points` field detection

Story points field ID and name differ across systems and instances:
- YouTrack: custom field name varies per instance (`Story Points`, `Estimation`, `SP`) — configured as minutes in Scrum template
- Jira Classic: `story_points` standard field
- Jira Next-gen: `customfield_10016`
- Some instances use other custom field IDs entirely

**Question**: Should the connector auto-detect the story points field by scanning field metadata, or require explicit per-instance configuration? Should YouTrack Scrum estimation (minutes) be converted to story points or stored as-is?

### OQ-TT-2: Jira email suppression — fallback identity strategy

Jira Cloud may suppress `emailAddress` for some users via Atlassian privacy controls. When `email` is NULL:
- Option A: use `account_id` as a fallback within the Atlassian ecosystem (valid if Jira + Bitbucket share the same tenant)
- Option B: exclude users without email from `person_id`-level analytics and report the gap
- Option C: support `account_id` as an alternative resolution path in Identity Manager

**Current approach**: store `account_id` as `user_id` in Bronze; attempt email-based resolution in Silver; fall back to `account_id` for within-Atlassian joins only.

### OQ-TT-3: Sprint-issue membership — historical vs current

Issue-sprint assignment can change (carry-over, re-planning):
- YouTrack: sprint field changes appear in `task_tracker_history` as `field_name = "Sprint"`; current sprint from Agile board API
- Jira Classic: `fields.sprint` (current) + changelog entries for `Sprint` field changes
- Jira Next-gen: `customfield_10020` (current) + changelog

**Question**: Does the connector capture all historical sprint assignments (full changelog for sprint field) or only the current assignment? How is carry-over (issue moved to next sprint without completion) tracked for velocity calculations?

### OQ-TT-4: `task_tracker_history` normalisation for YouTrack complex types

YouTrack `added`/`removed` arrays contain typed objects for user fields (`{name, id}`) and arrays for tags. The unified `value_from`/`value_to` columns store simple strings.

**Question**: For user-type field changes in YouTrack (e.g. Assignee change), should `value_to` contain the user ID or display name? Should `value_to_display` be populated from the user object's `name` field? The current approach stores the scalar ID in `value_to` and the name in `value_to_display`, with the full object in `raw_value`.
