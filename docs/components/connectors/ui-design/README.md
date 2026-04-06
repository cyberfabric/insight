# Design Tools Connector Specification (Multi-Source)

> Version 1.0 — March 2026
> Based on: Figma (Source TBD — to be assigned in CONNECTORS_REFERENCE.md)

Data-source agnostic specification for design tool connectors. Defines unified Bronze schemas that work across Figma (and future sources: Sketch, Adobe XD) using a `data_source` discriminator column.

**Primary analytics focus**: design team activity — file editing frequency, comment collaboration, version creation rate, and cross-team design file sharing patterns. Can be correlated with git commits to surface designer↔engineer collaboration signals.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`design_file_activity` — Per-user per-file per-day activity](#designfileactivity-per-user-per-file-per-day-activity)
  - [`design_files` — File and project directory](#designfiles-file-and-project-directory)
  - [`design_users` — User directory](#designusers-user-directory)
  - [`design_collection_runs` — Connector execution log](#designcollectionruns-connector-execution-log)
- [Source Mapping](#source-mapping)
  - [Figma](#figma)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-DESIGN-1: Figma Analytics API availability](#oq-design-1-figma-analytics-api-availability)
  - [OQ-DESIGN-2: Version history depth and incremental sync](#oq-design-2-version-history-depth-and-incremental-sync)
  - [OQ-DESIGN-3: Guest and external collaborator identity](#oq-design-3-guest-and-external-collaborator-identity)
  - [OQ-DESIGN-4: Sketch and Adobe XD source viability](#oq-design-4-sketch-and-adobe-xd-source-viability)

<!-- /toc -->

---

## Overview

**Category**: Design Tools

**Supported Sources**:
- Figma (`data_source = "insight_figma"`)
- Sketch (`data_source = "insight_sketch"`) — planned
- Adobe XD (`data_source = "insight_adobexd"`) — planned

**Authentication**:
- Figma: Personal Access Token or OAuth 2.0 (Figma OAuth app)

**Data model note**: Standard design tool APIs do not expose a real-time activity feed per user. Activity must be **inferred** from available signals:
- **Version creation** — who created a version of a file, and when (proxy for active editing)
- **Comments** — who posted a comment on a file, and when (proxy for async design review/collaboration)

Figma's Analytics API (Enterprise plan only) provides user-level activity summaries via an admin dashboard, but this is not available through a public REST API for non-Enterprise plans. `design_file_activity` is therefore a **derived table** populated at collection time by aggregating version and comment records per user per file per day.

**Why four tables**: Design tool data naturally separates into: (1) per-user activity aggregates (the primary metric table), (2) a file/project directory (the dimension table for file metadata), (3) a user directory (identity anchor), and (4) the standard collection run log. Keeping them separate avoids wide denormalized rows and allows each table to evolve independently.

**Terminology mapping**:

| Concept | Figma | Sketch (planned) | Unified |
|---------|-------|------------------|---------|
| File edit / version | `POST /v1/files/{key}/versions` (version created) | — | `design_file_activity.versions_created` |
| Comment posted | `GET /v1/files/{key}/comments` | — | `design_file_activity.comments_posted` |
| File viewed | Figma Analytics (Enterprise only) | — | `design_file_activity.files_viewed` |
| File | `GET /v1/projects/{id}/files` | — | `design_files` |
| Project | `GET /v1/teams/{id}/projects` | — | `design_files.project_name` (denormalized) |
| User | `GET /v1/teams/{id}/members` | — | `design_users` |

---

## Bronze Tables

### `design_file_activity` — Per-user per-file per-day activity

Derived daily aggregates of design activity per user per file. Populated at collection time by aggregating version history and comment records. This is the primary analytics table for design team productivity.

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier, e.g. `figma-acme` |
| `data_source` | String | Source discriminator: `insight_figma` |
| `user_id` | String | Source-native user identifier (Figma: numeric user ID) |
| `email` | String | User email — primary identity key → `person_id` |
| `file_key` | String | Source-native file identifier (Figma: file key string) |
| `date` | Date | Activity date (UTC) — day on which the versions/comments occurred |
| `versions_created` | Int64 | Number of new file versions created by this user on this date (proxy for active editing) |
| `comments_posted` | Int64 | Number of comments posted by this user on this file on this date |
| `files_viewed` | Int64 | Number of file view events (Figma Enterprise Analytics only; NULL otherwise) |
| `collected_at` | DateTime64(3) | Collection timestamp |
| `_version` | UInt64 | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_design_activity_user`: `(insight_source_id, email, date)`
- `idx_design_activity_file`: `(file_key, date, data_source)`

**Derivation note**: One `design_file_activity` row per `(user_id, file_key, date)`. At collection time:
- `versions_created` = count of version records where `created_by.id = user_id` on `date`
- `comments_posted` = count of comment records where `user.id = user_id` on `date`
- `files_viewed` = populated only when Figma Analytics API is available (Enterprise plan); NULL otherwise

**`files_viewed` limitation**: The standard Figma REST API has no endpoint for view counts per user. File view data is available only through Figma's Enterprise Analytics feature, which has no public API at this time. See OQ-DESIGN-1.

---

### `design_files` — File and project directory

Directory of all design files and the projects they belong to. Used as a dimension table to enrich `design_file_activity` with file metadata (project, name, last modified time).

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier |
| `data_source` | String | Source discriminator: `insight_figma` |
| `file_key` | String | Source-native file identifier — primary key for joins with `design_file_activity` |
| `file_name` | String | Human-readable file name |
| `project_id` | String | Source-native project identifier |
| `project_name` | String | Project name (denormalized from project directory) |
| `team_id` | String | Team identifier — top-level organisational unit in Figma |
| `last_modified` | DateTime64(3) | Last modification timestamp reported by the source API |
| `collected_at` | DateTime64(3) | Collection timestamp |
| `_version` | UInt64 | Deduplication version |

**Indexes**:
- `idx_design_files_key`: `(file_key, data_source)`
- `idx_design_files_project`: `(project_id, team_id)`

---

### `design_users` — User directory

Identity anchor for design tool analytics. Populated from the team members endpoint. Used to resolve source-native `user_id` to `email` and thence to canonical `person_id` in Silver.

| Field | Type | Description |
|-------|------|-------------|
| `insight_source_id` | String | Connector instance identifier |
| `data_source` | String | Source discriminator: `insight_figma` |
| `user_id` | String | Source-native user identifier (Figma: numeric user ID string) |
| `email` | String | User email — primary identity key → `person_id` |
| `display_name` | String | Display name as reported by the source API |
| `role` | String | User role in team: `owner` / `admin` / `editor` / `viewer` (source-specific values) |
| `is_active` | Int64 | `1` if account is active; `0` if deactivated |
| `collected_at` | DateTime64(3) | Collection timestamp |
| `_version` | UInt64 | Deduplication version |

**Indexes**:
- `idx_design_users_email`: `(email)`
- `idx_design_users_lookup`: `(insight_source_id, user_id, data_source)`

---

### `design_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | Run start timestamp |
| `completed_at` | DateTime64(3) | Run end timestamp |
| `status` | String | `running` / `completed` / `failed` |
| `file_activity_records_collected` | Int64 | Rows collected for `design_file_activity` |
| `files_collected` | Int64 | Rows collected for `design_files` |
| `users_collected` | Int64 | Rows collected for `design_users` |
| `api_calls` | Int64 | Total API calls made |
| `errors` | Int64 | Errors encountered |
| `settings` | String (JSON) | Collection configuration as JSON (team IDs, enabled endpoints, plan tier) |
| `data_source` | String | Source discriminator |
| `_version` | UInt64 | Deduplication version |

Monitoring table — not an analytics source.

---

## Source Mapping

### Figma

**API**: Figma REST API v1 (`https://api.figma.com/v1/`)

**Authentication**: `X-Figma-Token` header (Personal Access Token) or `Authorization: Bearer {token}` (OAuth 2.0)

| Unified table | Figma endpoint | Key mapping notes |
|---------------|----------------|-------------------|
| `design_files` | `GET /v1/teams/{team_id}/projects` → `GET /v1/projects/{project_id}/files` | `key` → `file_key`; `name` → `file_name`; `last_modified` → `last_modified` |
| `design_users` | `GET /v1/teams/{team_id}/members` | `id` → `user_id`; `email` → `email`; `handle` → `display_name`; `role` → `role` |
| `design_file_activity` (versions) | `GET /v1/files/{file_key}/versions` | Aggregate by `(created_by.id, date(created_at))` → `versions_created` |
| `design_file_activity` (comments) | `GET /v1/files/{file_key}/comments` | Aggregate by `(user.id, date(created_at))` → `comments_posted` |
| `design_file_activity` (views) | Figma Analytics API (Enterprise only) | `files_viewed` — NULL for non-Enterprise plans |

**`design_file_activity` construction**: The connector iterates over all files in all projects for all configured teams. For each file:
1. Fetch version history (`/v1/files/{key}/versions`) — extract all versions created since last sync, group by `(created_by.id, date)`, count → `versions_created`
2. Fetch comments (`/v1/files/{key}/comments`) — extract all comments posted since last sync, group by `(user.id, date)`, count → `comments_posted`
3. Merge version and comment aggregates into `design_file_activity` rows; upsert on `(user_id, file_key, date)`

**Rate limiting**: Figma REST API is rate-limited per token. Large teams with many files will require cursor-based pagination and rate-limit backoff.

---

## Identity Resolution

**Identity anchor**: `design_users` table (`email` field from team members endpoint).

**Resolution process**:
1. Collect `email` from `design_users` (populated from `GET /v1/teams/{team_id}/members`)
2. In `design_file_activity`, `user_id` is the Figma numeric ID — resolve to `email` via `design_users` join at Silver step 1
3. Normalize email (lowercase, trim)
4. Map to canonical `person_id` via Identity Manager in Silver step 2

**`email` availability**: Figma team members endpoint exposes email only for users within the organisation's team. Guest users and external collaborators may have email withheld.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `design_file_activity` | `class_design_activity` | Planned — schema defined below |
| `design_files` | Dimension / lookup (no separate Silver stream) | Used for enrichment at Silver step 1 |
| `design_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |

**`class_design_activity`** — planned Silver stream, per-user per-day design activity aggregated across all files:

| Field | Type | Description |
|-------|------|-------------|
| `person_id` | String | Canonical person identifier (from Identity Manager, Silver step 2) |
| `date` | Date | Activity date |
| `data_source` | String | Source discriminator: `insight_figma` |
| `files_edited` | Int64 | Count of distinct files where `versions_created > 0` on this date |
| `versions_created` | Int64 | Total new versions created across all files on this date |
| `comments_posted` | Int64 | Total comments posted across all files on this date |
| `files_viewed` | Int64 | Total file view events (Enterprise only; NULL otherwise) |
| `files_with_activity` | Int64 | Count of distinct files touched (versions or comments) on this date |

**Gold metrics**:
- **Design team activity**: versions created + comments posted per person per week — headline design productivity metric
- **File collaboration**: comments per file — high comment count signals active review cycle
- **Cross-team file sharing**: files where `collab_document_activity.shared_internally_count > 0` correlated with `design_files` — identifies design assets shared across teams
- **Designer↔engineer collaboration**: `class_design_activity` joined with `class_commits` on `(person_id, date ± N days)` — surfaces concurrent design and engineering activity on related projects

---

## Open Questions

### OQ-DESIGN-1: Figma Analytics API availability

Figma's Enterprise plan includes an Analytics feature that provides per-user activity summaries (files opened, time in editor, etc.). There is no documented public REST API endpoint for this data as of March 2026. The data is surfaced via an admin dashboard only.

**Question**: Will Figma expose an Analytics API for Enterprise plans? Is there an undocumented endpoint or export mechanism usable by the connector?

**Impact**: `design_file_activity.files_viewed` will remain NULL for all non-Enterprise customers until this is resolved. The remaining fields (`versions_created`, `comments_posted`) are available to all plans.

### OQ-DESIGN-2: Version history depth and incremental sync

Figma's `GET /v1/files/{key}/versions` returns the full version history for a file with no date filter parameter. For files with long histories, this can be large.

**Question**: What is the optimal incremental sync strategy? Options: (a) store `last_synced_version_id` per file and skip already-seen versions; (b) filter by `created_at` client-side; (c) use `GET /v1/files/{key}?version={id}` for point-in-time fetches.

**Current approach**: Client-side filter on `created_at > last_sync_cursor` stored in `design_collection_runs.settings`.

### OQ-DESIGN-3: Guest and external collaborator identity

Figma files can be shared with users outside the team (guests). These users may appear in version history and comments but will not be present in `design_users` (which is scoped to team members). Their `email` may be unavailable.

**Question**: Should the connector attempt to collect guest user metadata? Or silently omit activity rows where `user_id` cannot be resolved to an email?

**Current approach**: Omit rows where `user_id` is not found in `design_users`. Activity from guest contributors is not counted.

### OQ-DESIGN-4: Sketch and Adobe XD source viability

Sketch and Adobe XD are listed as planned sources. Both products have APIs with limited activity tracking capability.

**Question**: Confirm whether Sketch and Adobe XD are in scope for a future connector iteration, or whether Figma is the only design tool to support.
