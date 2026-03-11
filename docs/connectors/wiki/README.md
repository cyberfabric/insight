# Wiki Connector Specification (Multi-Source)

> Version 1.0 — March 2026
> Based on: Confluence (Atlassian REST API v2) and Outline (REST API)

Data-source agnostic specification for wiki connectors. Defines unified Bronze schemas that work across Confluence and Outline using a `data_source` discriminator column.

**Primary analytics focus**: knowledge creation and consumption patterns — page authorship, editorial activity, space structure, and documentation health.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`wiki_pages` — Page metadata and current state](#wikipages-page-metadata-and-current-state)
  - [`wiki_page_activity` — Views and edits per user per day](#wikipageactivity-views-and-edits-per-user-per-day)
  - [`wiki_spaces` — Space / collection directory](#wikispaces-space-collection-directory)
  - [`wiki_users` — User directory](#wikiusers-user-directory)
  - [`wiki_collection_runs` — Connector execution log](#wikicollectionruns-connector-execution-log)
- [Terminology Mapping](#terminology-mapping)
- [Source Mapping](#source-mapping)
  - [Confluence](#confluence)
  - [Outline](#outline)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-WIKI-1: Outline views are aggregate, not per-user per-day](#oq-wiki-1-outline-views-are-aggregate-not-per-user-per-day)
  - [OQ-WIKI-2: Confluence Analytics availability (Premium tier)](#oq-wiki-2-confluence-analytics-availability-premium-tier)
  - [OQ-WIKI-3: Page hierarchy and space navigation depth](#oq-wiki-3-page-hierarchy-and-space-navigation-depth)

<!-- /toc -->

---

## Overview

**Category**: Wiki / Knowledge Management

**Supported Sources**:
- Confluence (`data_source = "insight_confluence"`) — Atlassian Confluence Cloud
- Outline (`data_source = "insight_outline"`) — Outline Cloud or self-hosted

**Authentication**:
- Confluence: Basic Auth (email + API token) or OAuth 2.0
- Outline: Bearer token (API key from workspace settings)

**Data model note**: Wiki data is **document-centric** rather than event-centric. Bronze tables store current page state (`wiki_pages`) and aggregated activity metrics (`wiki_page_activity`). The Silver layer applies SCD2 (Slowly Changing Dimension Type 2) to track page evolution over time.

**Identity key**: `email` is available in both systems and is the primary cross-system identity key for the Identity Manager.

**Why four analytics tables**:
- `wiki_pages` — one row per page (current state, updated on each collection run)
- `wiki_page_activity` — one row per user per page per day (views and edits)
- `wiki_spaces` — one row per space/collection (organizational structure)
- `wiki_users` — one row per user (identity anchor)

---

## Bronze Tables

### `wiki_pages` — Page metadata and current state

One row per page. Updated (upserted) on each collection run. Tracks current state; Silver SCD2 tracks history.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier, e.g. `confluence-acme`, `outline-main` |
| `page_id` | String | REQUIRED | Source-native page identifier |
| `space_id` | String | REQUIRED | Space / collection identifier (source-native) |
| `title` | String | REQUIRED | Page title |
| `status` | String | REQUIRED | `current` / `archived` / `draft` / `deleted` (normalised from source-specific values) |
| `author_id` | String | REQUIRED | Source-native user ID of page creator |
| `author_email` | String | NULLABLE | Author email — identity key → `person_id` |
| `last_editor_id` | String | NULLABLE | Source-native user ID of last editor |
| `last_editor_email` | String | NULLABLE | Last editor email — identity key |
| `created_at` | DateTime64(3) | REQUIRED | Page creation timestamp |
| `updated_at` | DateTime64(3) | REQUIRED | Last edit timestamp |
| `published_at` | DateTime64(3) | NULLABLE | Publication timestamp (Outline only) |
| `archived_at` | DateTime64(3) | NULLABLE | Archival timestamp (Outline only) |
| `version_number` | Int64 | REQUIRED | Current version number |
| `parent_page_id` | String | NULLABLE | Parent page identifier (for nested page hierarchies) |
| `view_count` | Int64 | NULLABLE | Total view count (Confluence Analytics Premium; Outline aggregate) |
| `distinct_viewers` | Int64 | NULLABLE | Distinct viewer count (Confluence Analytics Premium only) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator: `insight_confluence` / `insight_outline` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_wiki_pages_lookup`: `(source_instance_id, page_id, data_source)`
- `idx_wiki_pages_space`: `(space_id, status)`
- `idx_wiki_pages_author`: `(author_email)`

---

### `wiki_page_activity` — Views and edits per user per day

Per-user per-page per-day activity. Populated from Confluence Analytics (Premium) and Outline views endpoint.

> **Important**: Outline's `views.list` endpoint returns aggregate view counts per document (total `count`), NOT per-user per-day data. For Outline, `wiki_page_activity` rows have `user_id = NULL` and `user_email = NULL`. See OQ-WIKI-1.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `page_id` | String | REQUIRED | Source-native page identifier |
| `user_id` | String | NULLABLE | Source-native user identifier (NULL for Outline aggregate rows) |
| `user_email` | String | NULLABLE | User email — identity key (NULL for Outline aggregate rows) |
| `date` | Date | REQUIRED | Activity date (Confluence: view date; Outline: `lastViewedAt` date for aggregate rows) |
| `view_count` | Int64 | NULLABLE | Views of this page by this user on this date (Confluence per-user; Outline: total aggregate) |
| `edit_count` | Int64 | NULLABLE | Edits made by this user on this date (derived from version history) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_wiki_activity_user`: `(source_instance_id, user_email, date)`
- `idx_wiki_activity_page`: `(page_id, date)`

---

### `wiki_spaces` — Space / collection directory

One row per space (Confluence) or collection (Outline). Organisational container for pages.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `space_id` | String | REQUIRED | Source-native space / collection identifier |
| `name` | String | REQUIRED | Space / collection display name |
| `description` | String | NULLABLE | Space description |
| `space_type` | String | NULLABLE | `global` / `personal` (Confluence); `public` / `private` (Outline) |
| `status` | String | REQUIRED | `active` / `archived` |
| `created_at` | DateTime64(3) | NULLABLE | Space creation timestamp |
| `url` | String | NULLABLE | Direct URL to space / collection |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

---

### `wiki_users` — User directory

User identity anchor for wiki analytics.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `source_instance_id` | String | REQUIRED | Connector instance identifier |
| `user_id` | String | REQUIRED | Source-native user identifier (Confluence `accountId` / Outline user UUID) |
| `email` | String | REQUIRED | Email — primary identity key → `person_id` |
| `display_name` | String | NULLABLE | Display name |
| `is_active` | Int64 | DEFAULT 1 | 1 = active; 0 = deactivated |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_wiki_users_email`: `(email)`
- `idx_wiki_users_lookup`: `(source_instance_id, user_id, data_source)`

---

### `wiki_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `pages_collected` | Int64 | NULLABLE | Rows collected for `wiki_pages` |
| `activity_records_collected` | Int64 | NULLABLE | Rows collected for `wiki_page_activity` |
| `spaces_collected` | Int64 | NULLABLE | Rows collected for `wiki_spaces` |
| `users_collected` | Int64 | NULLABLE | Rows collected for `wiki_users` |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (domain, space filter, analytics enabled, lookback) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

Monitoring table — not an analytics source.

---

## Terminology Mapping

| Concept | Confluence | Outline | Unified Bronze |
|---------|-----------|---------|----------------|
| Organisational container | Space | Collection | `wiki_spaces` (`space_id`) |
| Document | Page | Document | `wiki_pages` (`page_id`) |
| Document version | Version (integer) | Revision | `wiki_pages.version_number` |
| Author | `authorId` (accountId) | `createdById` (user UUID) | `wiki_pages.author_id` + `author_email` |
| Viewer data | Analytics API (Premium) | `views.list` (aggregate only) | `wiki_page_activity` |
| User directory | `/users` (accountId + email) | `/users.list` (UUID + email) | `wiki_users` |
| URL base | `https://{domain}.atlassian.net/wiki/api/v2/` | `https://app.getoutline.com/api/` | — |

---

## Source Mapping

### Confluence

All data collected via Atlassian Confluence REST API v2 (`https://{domain}.atlassian.net/wiki/api/v2/`).

| Unified table | Confluence endpoint | Key mapping notes |
|---------------|--------------------|--------------------|
| `wiki_spaces` | `GET /spaces` | `id` → `space_id`; `name` → `name`; `type` → `space_type`; `status` → `status` |
| `wiki_pages` | `GET /pages` (paginated) | `id` → `page_id`; `spaceId` → `space_id`; `authorId` → `author_id`; `version.number` → `version_number`; `version.createdAt` → `updated_at` |
| `wiki_pages` (view counts) | `GET /analytics/content/{id}/viewers` | `viewCount` → `view_count`; `distinctViewers` → `distinct_viewers` — requires Confluence Analytics (Premium tier) |
| `wiki_page_activity` (edits) | `GET /pages/{id}/versions` | One activity row per version per day; `createdBy` → `user_id`; date from version `createdAt` |
| `wiki_page_activity` (views) | `GET /analytics/content/{id}/viewers` | Per-user view counts — Premium only; see OQ-WIKI-2 |
| `wiki_users` | Derived from `authorId` fields in page responses | Enrich with Atlassian User API to resolve email from `accountId` |

**Pagination**: Uses cursor-based pagination (`cursor` parameter in response `_links.next`).

**Analytics tier**: `GET /analytics/content/{id}/viewers` requires Confluence Premium. On Standard tier, `view_count` and `distinct_viewers` are NULL.

### Outline

All data collected via Outline REST API (`https://app.getoutline.com/api/` or self-hosted URL).

| Unified table | Outline endpoint | Key mapping notes |
|---------------|-----------------|-------------------|
| `wiki_spaces` | `POST /collections.list` | `id` → `space_id`; `name` → `name`; `private` → `space_type`; `deletedAt IS NULL` → `status = active` |
| `wiki_pages` | `POST /documents.list` | `id` → `page_id`; `collectionId` → `space_id`; `createdById` → `author_id`; `revision` → `version_number`; `updatedAt` → `updated_at`; `publishedAt`, `archivedAt` mapped directly |
| `wiki_page_activity` (views) | `POST /views.list` | `documentId` → `page_id`; `count` → `view_count`; `user_id = NULL` (aggregate); `lastViewedAt` → `date` — aggregate only, not per-user per-day |
| `wiki_page_activity` (edits) | `POST /revisions.list` | One row per revision per day per user; `createdById` → `user_id`; `createdAt` → `date`; `edit_count = 1` per revision |
| `wiki_users` | `POST /users.list` | `id` → `user_id`; `email` → `email`; `name` → `display_name`; `isSuspended` → `is_active` |

**Authentication**: All Outline API calls use `Authorization: Bearer {api_key}` header.

**Document states**: Outline documents have `publishedAt`, `archivedAt`, `deletedAt` timestamps. Status is derived:
- `deletedAt IS NOT NULL` → `deleted`
- `archivedAt IS NOT NULL` → `archived`
- `publishedAt IS NOT NULL` → `current`
- otherwise → `draft`

---

## Identity Resolution

**Identity anchor**: `email` in `wiki_users` (available in both Confluence and Outline).

**Resolution process**:
1. Collect `wiki_users` with `email` for all active users.
2. Enrich `wiki_pages.author_email` and `wiki_page_activity.user_email` by joining on `user_id` → `wiki_users`.
3. Normalize email (lowercase, trim).
4. Map to canonical `person_id` via Identity Manager in Silver step 2.
5. Propagate `person_id` to Silver activity rows.

**Confluence**: `authorId` is an Atlassian `accountId` (opaque string). Email is resolved via a separate Atlassian User API call or from Confluence user profile endpoint. Confluence does not embed email in page API responses by default — requires enrichment step.

**Outline**: `createdById` is an Outline user UUID. Email is available directly from `users.list`.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `wiki_pages` | `class_wiki_pages` | Draft — SCD2 page metadata |
| `wiki_page_activity` | `class_wiki_activity` | Draft — per-user per-day activity |
| `wiki_spaces` | Reference dimension | Planned |
| `wiki_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |

**`class_wiki_pages`** — Silver SCD2 table tracking page state over time:

| Field | Description |
|-------|-------------|
| `person_id` | Canonical author identifier (post-identity-resolution) |
| `page_id` | Source-native page ID |
| `data_source` | `insight_confluence` / `insight_outline` |
| `title` | Page title |
| `status` | Normalised status |
| `space_id` | Space / collection identifier |
| `version_number` | Current version |
| `created_at` / `updated_at` | Page timestamps |
| `valid_from` / `valid_to` | SCD2 effective date range |

**`class_wiki_activity`** — Silver per-user per-day activity:

| Field | Description |
|-------|-------------|
| `person_id` | Canonical user identifier |
| `page_id` | Page identifier |
| `date` | Activity date |
| `view_count` | Views (NULL for Outline aggregate rows without user_id) |
| `edit_count` | Edits (from revision history) |
| `data_source` | Source discriminator |

**Gold metrics** (planned):
- Documentation velocity: new pages + edits per person per week
- Knowledge consumption: views per page per week
- Space health: pages created vs. archived ratio
- Contributor breadth: distinct authors per space

---

## Open Questions

### OQ-WIKI-1: Outline views are aggregate, not per-user per-day

Outline's `views.list` endpoint returns `{ documentId, count, lastViewedAt }` — a single aggregate count per document, not a per-user breakdown. This is fundamentally different from Confluence Analytics, which provides per-user view data.

**Consequence**: For `insight_outline`, `wiki_page_activity` rows for views have `user_id = NULL` and `user_email = NULL`. View-based Silver analytics (`class_wiki_activity.view_count`) cannot be attributed to individual users for Outline.

**Question**: Is aggregate view count (without user attribution) sufficient for Outline, or should we investigate whether self-hosted Outline has a more granular views API?

### OQ-WIKI-2: Confluence Analytics availability (Premium tier)

`GET /analytics/content/{id}/viewers` requires Confluence Premium. On Standard tier, per-user view data is unavailable.

**Question**: Should the connector gracefully degrade on Standard tier (skip analytics collection, set view fields to NULL) or should analytics collection be a hard requirement? Define the behaviour when the endpoint returns 403 / 404.

### OQ-WIKI-3: Page hierarchy and space navigation depth

Confluence and Outline both support nested page hierarchies (`parent_page_id`). The current schema stores only one level of parent reference.

**Question**: Is shallow parent reference (one level) sufficient for Gold metrics, or do we need to materialise the full ancestor path for space-level aggregations? If full path is needed, a separate `wiki_page_ancestors` Bronze table may be required.
