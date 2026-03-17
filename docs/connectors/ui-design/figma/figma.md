# Figma Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/connectors/design/README.md` (Design Tools domain)

Standalone specification for the Figma (Design Tools) connector. Expands the Design Tools domain schema with Figma-specific API details, authentication options, endpoint mapping, and known limitations.

<!-- toc -->

- [Overview](#overview)
- [Authentication](#authentication)
  - [Option 1: Personal Access Token](#option-1-personal-access-token)
  - [Option 2: OAuth 2.0 (Figma OAuth App)](#option-2-oauth-20-figma-oauth-app)
- [API Endpoints](#api-endpoints)
  - [`GET /v1/me` — Current user info](#get-v1me-current-user-info)
  - [`GET /v1/teams/{team_id}/projects` — List projects](#get-v1teamsteamidprojects-list-projects)
  - [`GET /v1/projects/{project_id}/files` — List files in project](#get-v1projectsprojectidfiles-list-files-in-project)
  - [`GET /v1/teams/{team_id}/members` — Team member directory](#get-v1teamsteamidmembers-team-member-directory)
  - [`GET /v1/files/{file_key}/versions` — Version history](#get-v1filesfilekeyversions-version-history)
  - [`GET /v1/files/{file_key}/comments` — Comments on file](#get-v1filesfilekeycomments-comments-on-file)
- [Bronze Table Mapping](#bronze-table-mapping)
- [Activity Inference Strategy](#activity-inference-strategy)
- [Rate Limiting and Pagination](#rate-limiting-and-pagination)
- [Known Limitations](#known-limitations)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Notes](#silver-gold-notes)
- [Open Questions](#open-questions)
  - [OQ-FIGMA-1: Figma Analytics API (Enterprise)](#oq-figma-1-figma-analytics-api-enterprise)
  - [OQ-FIGMA-2: Team ID configuration vs. organisation-level access](#oq-figma-2-team-id-configuration-vs-organisation-level-access)
  - [OQ-FIGMA-3: Version vs. autosave — activity undercount](#oq-figma-3-version-vs-autosave-activity-undercount)

<!-- /toc -->

---

## Overview

**API**: Figma REST API v1 — `https://api.figma.com/v1/`

**Category**: Design Tools

**`data_source`**: `insight_figma`

**Authentication**: Personal Access Token or OAuth 2.0

**Identity**: `email` from `GET /v1/teams/{team_id}/members` — resolved to canonical `person_id` via Identity Manager in Silver step 2.

**Critical limitation**: The standard Figma REST API does **not** expose per-user activity aggregates or a user activity feed. There is no `/v1/activity` endpoint equivalent to GitHub's event stream. Activity must be inferred from version history (who created versions) and comments (who posted comments). File view counts are available only on the Figma Enterprise plan via an Analytics feature that has no public REST API as of March 2026.

**Figma plan tiers relevant to this connector**:
- **Starter / Professional**: version history + comments accessible via REST API — sufficient for `versions_created` and `comments_posted`
- **Organization**: same as Professional for API access
- **Enterprise**: adds Analytics dashboard with user-level activity data — no public API available for programmatic access

---

## Authentication

### Option 1: Personal Access Token

Simpler to configure; scoped to a single Figma user account.

- Generate at: **Figma → Account Settings → Personal access tokens**
- Header: `X-Figma-Token: {token}`
- Access scope: read access to all files and teams the generating user can see
- Limitation: tied to a specific user account; if the user leaves, the token is revoked

### Option 2: OAuth 2.0 (Figma OAuth App)

Preferred for production deployments; supports org-level access.

- Authorization endpoint: `https://www.figma.com/oauth`
- Token endpoint: `https://www.figma.com/api/oauth/token`
- Required scopes: `file_read` (read files, versions, comments), `team_projects:read` (list projects)
- Flow: Authorization Code with PKCE
- Token lifetime: access token expires; refresh token must be stored securely

**Connector configuration fields**:

| Field | Required | Description |
|-------|----------|-------------|
| `team_ids` | REQUIRED | One or more Figma team IDs to collect from |
| `auth_type` | REQUIRED | `pat` (Personal Access Token) or `oauth2` |
| `access_token` | REQUIRED | PAT value or OAuth access token |
| `refresh_token` | OAuth only | OAuth refresh token for token renewal |
| `client_id` | OAuth only | OAuth app client ID |
| `client_secret` | OAuth only | OAuth app client secret (stored in secret manager) |

---

## API Endpoints

### `GET /v1/me` — Current user info

Used at connector startup to validate authentication and retrieve the authenticated user's ID.

**Response fields used**:

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Figma user ID of the authenticated user |
| `email` | String | Email address |
| `handle` | String | Display name |

---

### `GET /v1/teams/{team_id}/projects` — List projects

Enumerate all projects under a configured team. Projects are the top-level organisational units under a team.

**Path parameter**: `team_id` — from connector configuration.

**Response fields used**:

| Field | Type | Description |
|-------|------|-------------|
| `projects[].id` | String | Project ID → `design_files.project_id` |
| `projects[].name` | String | Project name → `design_files.project_name` (denormalized) |

---

### `GET /v1/projects/{project_id}/files` — List files in project

List all files within a project. Populates `design_files`.

**Response fields used**:

| Field | Type | Description |
|-------|------|-------------|
| `files[].key` | String | File key → `design_files.file_key` and `design_file_activity.file_key` |
| `files[].name` | String | File name → `design_files.file_name` |
| `files[].last_modified` | String (ISO 8601) | Last modification timestamp → `design_files.last_modified` |
| `files[].thumbnail_url` | String | Not collected — not relevant for analytics |

---

### `GET /v1/teams/{team_id}/members` — Team member directory

Retrieve team members for identity resolution. Populates `design_users`.

**Response fields used**:

| Field | Type | Description |
|-------|------|-------------|
| `members[].id` | String | Figma user ID → `design_users.user_id` |
| `members[].email` | String | User email → `design_users.email` — primary identity anchor |
| `members[].handle` | String | Display name → `design_users.display_name` |
| `members[].role` | String | Team role: `owner` / `admin` / `editor` / `viewer` → `design_users.role` |

**Note**: `email` is only returned for users within the organisation's team. Guest/external collaborators may not have their email exposed. See OQ-DESIGN-3 in domain README.

---

### `GET /v1/files/{file_key}/versions` — Version history

Retrieve the full version history for a file. The primary source for `versions_created` in `design_file_activity`.

**No date filter parameter** — the API returns the complete version history. Incremental sync must be implemented client-side by filtering on `created_at > last_sync_cursor`.

**Response fields used**:

| Field | Type | Description |
|-------|------|-------------|
| `versions[].id` | String | Version ID — used for deduplication and cursor tracking |
| `versions[].created_at` | String (ISO 8601) | Version creation timestamp — extract date for `design_file_activity.date` |
| `versions[].user.id` | String | ID of the user who created the version → maps to `design_users.user_id` |
| `versions[].user.email` | String | Email of the version creator (when available) |
| `versions[].label` | String | Optional human-readable version label — not collected |

**Aggregation**: Group by `(user.id, date(created_at))` → count → `design_file_activity.versions_created`.

---

### `GET /v1/files/{file_key}/comments` — Comments on file

Retrieve all comments on a file. The primary source for `comments_posted` in `design_file_activity`.

**No date filter parameter** — returns all comments. Incremental sync uses `created_at > last_sync_cursor` client-side.

**Response fields used**:

| Field | Type | Description |
|-------|------|-------------|
| `comments[].id` | String | Comment ID — deduplication |
| `comments[].created_at` | String (ISO 8601) | Comment creation timestamp — extract date for `design_file_activity.date` |
| `comments[].user.id` | String | ID of the user who posted the comment → maps to `design_users.user_id` |
| `comments[].user.email` | String | Email of the commenter (when available) |
| `comments[].resolved_at` | String (ISO 8601) | Null if unresolved — not collected for activity metrics |

**Aggregation**: Group by `(user.id, date(created_at))` → count → `design_file_activity.comments_posted`.

---

## Bronze Table Mapping

| Bronze table | Source endpoint(s) | Collection strategy |
|-------------|-------------------|---------------------|
| `design_files` | `GET /v1/teams/{id}/projects` + `GET /v1/projects/{id}/files` | Full refresh on each run — file directory changes rarely; overwrite on `file_key` |
| `design_users` | `GET /v1/teams/{id}/members` | Full refresh on each run — team membership changes infrequently |
| `design_file_activity` | `GET /v1/files/{key}/versions` + `GET /v1/files/{key}/comments` | Incremental — filter `created_at > last_sync_cursor`; upsert on `(user_id, file_key, date)` |
| `design_collection_runs` | Internal connector state | One row inserted per run |

---

## Activity Inference Strategy

Because Figma provides no native activity feed, `design_file_activity` is constructed as follows for each connector run:

1. **Collect file list**: iterate `team_ids` → projects → files. Upsert all files into `design_files`.
2. **Collect user list**: iterate `team_ids` → members. Upsert all members into `design_users`.
3. **For each file in `design_files`**:
   a. Fetch version history since `last_sync_cursor`. For each version where `created_at > last_sync_cursor`: record `(created_by.id, date(created_at))`.
   b. Fetch comments since `last_sync_cursor`. For each comment where `created_at > last_sync_cursor`: record `(user.id, date(created_at))`.
4. **Aggregate**: Group version records by `(user_id, file_key, date)` → `versions_created`. Group comment records by `(user_id, file_key, date)` → `comments_posted`.
5. **Merge**: For each `(user_id, file_key, date)` combination, produce one `design_file_activity` row. Upsert into Bronze.
6. **Resolve email**: For each `user_id` in the aggregated rows, look up `email` from `design_users`. If not found, emit a warning and skip (see OQ-DESIGN-3).
7. **Update cursor**: set `last_sync_cursor = max(created_at)` across all collected version and comment records.

---

## Rate Limiting and Pagination

**Rate limit**: Figma API enforces per-token rate limits. Exact limits are not publicly documented but observed to be in the range of 100–120 requests per minute per token.

**Pagination**: Most list endpoints return results in a single response (no standard pagination). Version history for files with many versions may be large — filter client-side.

**Recommended strategy**:
- Add `time.sleep(0.6)` between file-level requests (100 req/min ceiling)
- Implement exponential backoff on HTTP 429 responses
- For large teams (>500 files), spread collection across multiple runs using a round-robin file queue

---

## Known Limitations

| Limitation | Impact | Mitigation |
|-----------|--------|------------|
| No per-user activity feed endpoint | `design_file_activity` is inferred, not directly observed — activity is undercounted if a user edits without saving a named version | Document as proxy metric; recommend "Auto-save creates versions" Figma setting in team guidelines |
| `files_viewed` unavailable (non-Enterprise) | `design_file_activity.files_viewed` is NULL for all non-Enterprise tenants | Field present in schema; populate when/if Figma adds API access for Enterprise Analytics |
| Version history — no server-side date filter | Full version history fetched per file on first sync; large files with long history are slow | Store `last_version_id` as cursor; skip already-seen versions by ID rather than re-fetching |
| Guest users — email may be absent | Activity from external collaborators cannot be attributed to a `person_id` | Omit unresolvable rows; track count in `design_collection_runs.errors` as a quality signal |
| Comments — no edit/delete tracking | Deleted or edited comments are not tracked | Acceptable for activity counting — comment deletion is rare and does not affect aggregate counts significantly |
| OAuth token expiry | If the refresh token is not renewed, collection stops silently | Alert on HTTP 401 response; surface in `design_collection_runs.status = "failed"` |

---

## Identity Resolution

**Source field**: `email` from `GET /v1/teams/{team_id}/members` → `design_users.email`

**In `design_file_activity`**: `user_id` (Figma numeric ID) is the native key. At Silver step 1, join `design_file_activity.user_id` → `design_users.user_id` → `design_users.email` to resolve to email. At Silver step 2, the Identity Manager maps `email` → `person_id`.

**Email format**: Figma emails are standard corporate email addresses. In most organisations they match the email used in HR, git, and other tools — making them a reliable cross-system identity key.

---

## Silver / Gold Notes

`design_file_activity` feeds `class_design_activity` (Silver, planned). Aggregation from Bronze to Silver collapses the per-file dimension:

- `class_design_activity.files_edited` = count of distinct `file_key` values where `versions_created > 0` on a given `(person_id, date)`
- `class_design_activity.versions_created` = sum of `design_file_activity.versions_created` across all files on `(person_id, date)`
- `class_design_activity.comments_posted` = sum of `design_file_activity.comments_posted` across all files on `(person_id, date)`

**Designer↔engineer correlation (Gold)**: `class_design_activity` can be joined with `class_commits` on `(person_id, date ± N days)` and with `design_files.project_name` correlated against repository names or YouTrack/Jira project keys. High overlap between design activity and commit activity on the same project — within the same sprint window — is a signal of tight designer↔engineer collaboration.

---

## Open Questions

### OQ-FIGMA-1: Figma Analytics API (Enterprise)

Figma Enterprise plan exposes activity analytics via its admin dashboard (files viewed, time in editor, active users). There is no documented public REST API for this data as of March 2026.

**Question**: Should the connector attempt to access Figma's internal analytics endpoints (via browser session or undocumented API) for Enterprise customers, or wait for a public API release?

**Current decision**: No undocumented endpoints. `files_viewed` remains NULL until a public API is available. Revisit when Figma announces an Analytics API.

### OQ-FIGMA-2: Team ID configuration vs. organisation-level access

Figma's API is team-scoped — the connector must be configured with explicit `team_ids`. Large organisations may have many teams.

**Question**: Is there an organisation-level endpoint to enumerate all teams? Or must each team be added to `connector.settings.team_ids` manually?

**Current approach**: Manual `team_ids` configuration per connector instance. An admin-level OAuth app with `org:read` scope may provide team enumeration — verify with Figma API documentation.

### OQ-FIGMA-3: Version vs. autosave — activity undercount

Figma distinguishes between autosave events (frequent, not exposed via API) and named or auto-generated versions (exposed via `/versions`). A designer who edits a file without triggering a version save will not appear in `versions_created`.

**Question**: What is the typical version creation frequency relative to editing sessions? Is `versions_created` a reliable enough proxy for editing activity?

**Current approach**: Document as a known proxy metric. Encourage teams to enable "Autosave creates a version" in Figma Organisation settings to improve signal quality.
