# Confluence Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/connectors/wiki/README.md` unified schema, Atlassian Confluence REST API v2

Standalone specification for the Confluence connector. Maps Atlassian Confluence Cloud API data to the unified Bronze wiki schema (`wiki_*` tables) defined in [`README.md`](README.md).

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`wiki_spaces` — Space directory (Confluence mapping)](#wikispaces-space-directory-confluence-mapping)
  - [`wiki_pages` — Page metadata (Confluence mapping)](#wikipages-page-metadata-confluence-mapping)
  - [`wiki_page_activity` — Views and edits per user per day (Confluence mapping)](#wikipageactivity-views-and-edits-per-user-per-day-confluence-mapping)
  - [`wiki_users` — User directory (Confluence mapping)](#wikiusers-user-directory-confluence-mapping)
  - [`confluence_collection_runs` — Connector execution log](#confluencecollectionruns-connector-execution-log)
- [API Reference](#api-reference)
- [Source Mapping](#source-mapping)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-CONF-1: Email resolution from `accountId`](#oq-conf-1-email-resolution-from-accountid)
  - [OQ-CONF-2: Analytics endpoint tier and rate limiting](#oq-conf-2-analytics-endpoint-tier-and-rate-limiting)
  - [OQ-CONF-3: Incremental page sync strategy](#oq-conf-3-incremental-page-sync-strategy)

<!-- /toc -->

---

## Overview

**API**: Atlassian Confluence REST API v2 (Cloud) — `https://{domain}.atlassian.net/wiki/api/v2/`

**Category**: Wiki / Knowledge Management

**data_source**: `insight_confluence`

**Authentication**:
- Basic Auth: email address + Atlassian API token (generated at `id.atlassian.com`)
- OAuth 2.0: 3-legged OAuth flow via Atlassian developer console (for user-context requests)

**Required scopes** (OAuth 2.0):
- `read:confluence-space.summary` — list spaces
- `read:confluence-content.all` — read pages and page history
- `read:confluence-content.summary` — read page metadata
- `read:confluence-user` — read user profiles (for email resolution)
- `read:confluence-analytics` — read analytics data (Premium tier only)

**Identity**: `accountId` (Atlassian account ID) is the source-native user identifier. Email is resolved via the Atlassian User API. `email` is the cross-system identity key.

**Why four entity tables**: Spaces, pages, page activity (views + edits), and users are distinct entities with different cardinalities and collection frequencies. Pages are collected on every run (full or incremental); activity data is collected daily.

> **Note**: Confluence REST API v1 (`/rest/api/`) and v2 (`/wiki/api/v2/`) coexist. This specification uses v2 exclusively. Some endpoints (e.g. footer comments) may still require v1 — documented per endpoint.

---

## Bronze Tables

> All Confluence data is inserted into the shared `wiki_*` tables with `data_source = 'insight_confluence'`. The schema is defined in [`README.md`](README.md). This section documents field-level mapping from Confluence API response to Bronze columns.

### `wiki_spaces` — Space directory (Confluence mapping)

Populated from `GET /spaces` (paginated).

| Field | Type | Confluence API field | Notes |
|-------|------|---------------------|-------|
| `insight_source_id` | String | connector config | e.g. `confluence-acme` |
| `space_id` | String | `spaces[].id` | Confluence space ID |
| `name` | String | `spaces[].name` | Space display name |
| `description` | String | `spaces[].description.plain.value` | Plain text description |
| `space_type` | String | `spaces[].type` | `global` / `personal` |
| `status` | String | `spaces[].status` | `current` (→ `active`) / `archived` |
| `created_at` | DateTime64(3) | Not available in v2 | NULL — v2 `/spaces` does not return `createdAt` |
| `url` | String | `spaces[]._links.webui` | Web URL of space |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_confluence` | |
| `_version` | UInt64 | ms timestamp | |

---

### `wiki_pages` — Page metadata (Confluence mapping)

Populated from `GET /pages` (paginated, filtered by space). Upserted on each run.

| Field | Type | Confluence API field | Notes |
|-------|------|---------------------|-------|
| `insight_source_id` | String | connector config | |
| `page_id` | String | `pages[].id` | Confluence page ID |
| `space_id` | String | `pages[].spaceId` | Parent space ID |
| `title` | String | `pages[].title` | Page title |
| `status` | String | `pages[].status` | `current` / `archived` / `trashed` / `draft` |
| `author_id` | String | `pages[].authorId` | Atlassian `accountId` of creator |
| `author_email` | String | resolved via User API | Enriched in post-processing step; see Identity Resolution |
| `last_editor_id` | String | `pages[].version.authorId` | `accountId` of last version author |
| `last_editor_email` | String | resolved via User API | Enriched in post-processing step |
| `created_at` | DateTime64(3) | `pages[].createdAt` | ISO 8601 string → DateTime64 |
| `updated_at` | DateTime64(3) | `pages[].version.createdAt` | Timestamp of latest version |
| `published_at` | DateTime64(3) | NULL | No Confluence equivalent — always NULL |
| `archived_at` | DateTime64(3) | NULL | Not exposed via v2 pages endpoint |
| `version_number` | Int64 | `pages[].version.number` | Current version number |
| `parent_page_id` | String | `pages[].parentId` | NULL for top-level pages |
| `view_count` | Int64 | from analytics endpoint | Requires Premium; see `wiki_page_activity` |
| `distinct_viewers` | Int64 | from analytics endpoint | Requires Premium |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_confluence` | |
| `_version` | UInt64 | ms timestamp | |

**Page query parameters**:
- `GET /pages?spaceId={id}&status=current,archived&limit=250` — paginated by cursor
- `sort=modified-date` + `lastModifiedAfter` for incremental sync (see OQ-CONF-3)

---

### `wiki_page_activity` — Views and edits per user per day (Confluence mapping)

Two activity sub-types collected separately and merged into the unified table:

**Edits** — derived from version history (`GET /pages/{id}/versions`):

| Field | Type | Confluence API field | Notes |
|-------|------|---------------------|-------|
| `insight_source_id` | String | connector config | |
| `page_id` | String | `versions[].pageId` | |
| `user_id` | String | `versions[].authorId` | `accountId` of version author |
| `user_email` | String | resolved via User API | |
| `date` | Date | `versions[].createdAt` (date part) | UTC date of version creation |
| `view_count` | Int64 | NULL | Not applicable for edit rows |
| `edit_count` | Int64 | 1 per version | One version = one edit |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_confluence` | |
| `_version` | UInt64 | ms timestamp | |

**Views** — from Confluence Analytics (`GET /analytics/content/{id}/viewers`, Premium only):

| Field | Type | Confluence API field | Notes |
|-------|------|---------------------|-------|
| `page_id` | String | path parameter | |
| `user_id` | String | `viewers[].user.accountId` | |
| `user_email` | String | `viewers[].user.email` | Available directly in analytics response |
| `date` | Date | `viewers[].viewedAt` (date part) | UTC date of last view (not per-view granularity) |
| `view_count` | Int64 | 1 per analytics row | Analytics returns one row per viewer, not per view event |
| `edit_count` | Int64 | NULL | Not applicable for view rows |

**Note**: The analytics endpoint reports that a user has viewed a page, not a count of times they viewed it. `view_count = 1` per row represents at least one view by that user on that date. Total views per page are available on `wiki_pages.view_count` (aggregate).

---

### `wiki_users` — User directory (Confluence mapping)

Populated by enriching `accountId` values encountered in page and version responses via the Atlassian User API.

| Field | Type | Confluence API field | Notes |
|-------|------|---------------------|-------|
| `insight_source_id` | String | connector config | |
| `user_id` | String | `accountId` | Atlassian account ID |
| `email` | String | `email` | From User API; requires `read:confluence-user` scope |
| `display_name` | String | `displayName` | |
| `is_active` | Int64 | `accountStatus == "active"` | 1 = active; 0 = inactive / closed |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_confluence` | |
| `_version` | UInt64 | ms timestamp | |

**User API endpoint**: `GET /wiki/rest/api/user?accountId={accountId}` (v1 API — no v2 equivalent for single-user lookup). Batch: `GET /wiki/rest/api/user/bulk?accountId={id1}&accountId={id2}` (up to 200 IDs per request).

---

### `confluence_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `spaces_collected` | Int64 | NULLABLE | Rows written to `wiki_spaces` for `insight_confluence` |
| `pages_collected` | Int64 | NULLABLE | Rows written to `wiki_pages` for `insight_confluence` |
| `versions_collected` | Int64 | NULLABLE | Versions processed (edit activity rows) |
| `analytics_records_collected` | Int64 | NULLABLE | Viewer records collected from analytics endpoint |
| `users_collected` | Int64 | NULLABLE | Rows written to `wiki_users` for `insight_confluence` |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Errors encountered |
| `settings` | String | NULLABLE | Collection config as JSON (domain, space filter, analytics enabled, incremental cursor) |
| `data_source` | String | DEFAULT 'insight_confluence' | Always `insight_confluence` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

Monitoring table — not an analytics source.

---

## API Reference

| Endpoint | Method | Purpose | Tier |
|----------|--------|---------|------|
| `/spaces` | GET | List all spaces | All |
| `/pages` | GET | List pages (paginated, filterable by space) | All |
| `/pages/{id}` | GET | Single page metadata | All |
| `/pages/{id}/versions` | GET | Version history (edit log) | All |
| `/pages/{id}/footer-comments` | GET | Page footer comments | All |
| `/analytics/content/{id}/viewers` | GET | Per-user view data | **Premium only** |
| `/rest/api/user` | GET | Single user profile (v1 API) | All |
| `/rest/api/user/bulk` | GET | Batch user profile lookup (v1 API) | All |

**Base URL**: `https://{domain}.atlassian.net/wiki/api/v2/` (v2 endpoints)
**Legacy base**: `https://{domain}.atlassian.net/wiki/rest/api/` (v1 endpoints, for user lookup)

**Rate limits**: Atlassian enforces per-user rate limits (typically 10 requests/second per token for Cloud). The connector must implement exponential backoff on HTTP 429 responses.

**Pagination**: All list endpoints use `cursor`-based pagination. Follow `_links.next` until absent.

---

## Source Mapping

| Unified table | Confluence endpoint | Mapping notes |
|---------------|--------------------|-----------------------|
| `wiki_spaces` | `GET /spaces` | `id` → `space_id`; `type` → `space_type`; `status: current` → `active` |
| `wiki_pages` | `GET /pages?spaceId=...` | `id` → `page_id`; `spaceId` → `space_id`; `authorId` → `author_id`; `version.number` → `version_number` |
| `wiki_page_activity` (edits) | `GET /pages/{id}/versions` | One row per version; `authorId` → `user_id`; `createdAt` date → `date`; `edit_count = 1` |
| `wiki_page_activity` (views) | `GET /analytics/content/{id}/viewers` | `user.accountId` → `user_id`; `user.email` → `user_email`; `viewedAt` date → `date`; Premium only |
| `wiki_users` | `GET /rest/api/user/bulk` | `accountId` → `user_id`; `email` → `email`; `displayName` → `display_name` |

---

## Identity Resolution

**Identity anchor**: `email` resolved from Atlassian `accountId` via the User API.

**Resolution process**:
1. Collect all unique `accountId` values from `pages[].authorId`, `versions[].authorId`, and analytics viewer records.
2. Batch-resolve to email via `GET /rest/api/user/bulk?accountId=...` (up to 200 IDs per call).
3. Populate `wiki_users` and backfill `author_email`, `last_editor_email`, `user_email` in page and activity tables.
4. Normalize email (lowercase, trim).
5. Map to canonical `person_id` via Identity Manager in Silver step 2.

**Atlassian `accountId`** is an opaque string (e.g. `5b10ac8d82e05b22cc7d4ef5`) — not used for cross-system identity resolution. `email` is the only reliable cross-system key.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `wiki_pages` (insight_confluence) | `class_wiki_pages` | Draft — SCD2 page metadata |
| `wiki_page_activity` (insight_confluence) | `class_wiki_activity` | Draft — per-user per-day activity |
| `wiki_spaces` | Reference dimension | Planned |
| `wiki_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |

**`class_wiki_pages`** key fields from Confluence source:
- `person_id` — resolved from `author_id` via email
- `data_source = 'insight_confluence'`
- `version_number` — tracks page evolution
- `status` — `current` / `archived` / `trashed` / `draft`

**`class_wiki_activity`** key fields from Confluence source:
- Per-user edit rows: `person_id`, `page_id`, `date`, `edit_count`
- Per-user view rows (Premium): `person_id`, `page_id`, `date`, `view_count = 1`

---

## Open Questions

### OQ-CONF-1: Email resolution from `accountId`

Confluence REST API v2 page and version responses return `authorId` (Atlassian `accountId`) but not email. Email resolution requires a separate call to the Atlassian User API (`/rest/api/user/bulk`).

**Question**: Does the API token (Basic Auth) have access to `/rest/api/user/bulk` for all account IDs in the tenant, including deactivated accounts? Confirm whether deactivated user emails are returned or whether `email` is redacted for inactive accounts.

### OQ-CONF-2: Analytics endpoint tier and rate limiting

`GET /analytics/content/{id}/viewers` is a Premium-only endpoint. On Standard tier it returns 403 or 404. The endpoint also requires iterating over every page individually — potentially thousands of API calls per run.

**Question**: Define the graceful degradation strategy when analytics is unavailable (Standard tier): should the connector skip analytics collection entirely and set view fields to NULL, or should it attempt collection and catch errors per-page? Also define the rate limit budget for analytics calls relative to the overall API quota.

### OQ-CONF-3: Incremental page sync strategy

Full space scans on large Confluence instances (10,000+ pages) are expensive. The v2 `/pages` endpoint supports `lastModifiedAfter` for incremental sync.

**Question**: Define the incremental sync cursor strategy. Should the connector store `max(version.createdAt)` per space and use it as the `lastModifiedAfter` parameter on subsequent runs? Confirm whether new pages (never modified since creation) appear in incremental results.
