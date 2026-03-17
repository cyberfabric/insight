# Outline Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/connectors/wiki/README.md` unified schema, Outline REST API

Standalone specification for the Outline connector. Maps Outline (Knowledge Base) API data to the unified Bronze wiki schema (`wiki_*` tables) defined in [`README.md`](README.md).

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`wiki_spaces` — Collection directory (Outline mapping)](#wikispaces-collection-directory-outline-mapping)
  - [`wiki_pages` — Document metadata (Outline mapping)](#wikipages-document-metadata-outline-mapping)
  - [`wiki_page_activity` — Views and edits (Outline mapping)](#wikipageactivity-views-and-edits-outline-mapping)
  - [`wiki_users` — User directory (Outline mapping)](#wikiusers-user-directory-outline-mapping)
  - [`outline_collection_runs` — Connector execution log](#outlinecollectionruns-connector-execution-log)
- [API Reference](#api-reference)
- [Source Mapping](#source-mapping)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-OTL-1: Aggregate-only view data — no per-user attribution](#oq-otl-1-aggregate-only-view-data-no-per-user-attribution)
  - [OQ-OTL-2: Self-hosted Outline URL configuration](#oq-otl-2-self-hosted-outline-url-configuration)
  - [OQ-OTL-3: Deleted document recovery and `deletedAt` handling](#oq-otl-3-deleted-document-recovery-and-deletedat-handling)

<!-- /toc -->

---

## Overview

**API**: Outline REST API — `https://app.getoutline.com/api/` (Cloud) or `https://{self-hosted-domain}/api/` (self-hosted)

**Category**: Wiki / Knowledge Management

**data_source**: `insight_outline`

**Authentication**: Bearer token — API key generated from Outline workspace settings (`Settings → API`). All requests use `Authorization: Bearer {api_key}` header.

**Identity**: `email` from `users.list` — available directly without a separate enrichment step. `email` is the cross-system identity key.

**API style**: All Outline API endpoints use `POST` with a JSON body, even for read (list) operations. This is a Outline-specific convention — not REST standard.

**Document states**: Outline documents have four lifecycle states tracked by timestamp fields:
- `draft` — `publishedAt = null` and `archivedAt = null` and `deletedAt = null`
- `current` (published) — `publishedAt IS NOT NULL` and `archivedAt = null` and `deletedAt = null`
- `archived` — `archivedAt IS NOT NULL` and `deletedAt = null`
- `deleted` — `deletedAt IS NOT NULL`

**Views limitation**: `views.list` returns aggregate view counts per document (total `count` + `lastViewedAt`), NOT per-user per-day data. This is a fundamental difference from Confluence Analytics. See OQ-OTL-1.

**Terminology**: Outline uses "document" and "collection" where the unified schema uses "page" and "space". Field mapping follows the terminology table in [`README.md`](README.md).

---

## Bronze Tables

> All Outline data is inserted into the shared `wiki_*` tables with `data_source = 'insight_outline'`. The schema is defined in [`README.md`](README.md). This section documents field-level mapping from Outline API response to Bronze columns.

### `wiki_spaces` — Collection directory (Outline mapping)

Populated from `POST /collections.list`.

| Field | Type | Outline API field | Notes |
|-------|------|------------------|-------|
| `source_instance_id` | String | connector config | e.g. `outline-main` |
| `space_id` | String | `data[].id` | Outline collection UUID |
| `name` | String | `data[].name` | Collection name |
| `description` | String | `data[].description` | Optional description |
| `space_type` | String | `data[].private` | `private` (true) / `public` (false) |
| `status` | String | derived | `active` if `deletedAt IS NULL`; `archived` if `deletedAt IS NOT NULL` |
| `created_at` | DateTime64(3) | `data[].createdAt` | ISO 8601 → DateTime64 |
| `url` | String | `data[].url` | URL to collection in Outline UI |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_outline` | |
| `_version` | UInt64 | ms timestamp | |

---

### `wiki_pages` — Document metadata (Outline mapping)

Populated from `POST /documents.list` (paginated). Upserted on each run.

| Field | Type | Outline API field | Notes |
|-------|------|------------------|-------|
| `source_instance_id` | String | connector config | |
| `page_id` | String | `data[].id` | Outline document UUID |
| `space_id` | String | `data[].collectionId` | Parent collection UUID |
| `title` | String | `data[].title` | Document title |
| `status` | String | derived from timestamps | See document states above |
| `author_id` | String | `data[].createdById` | Outline user UUID of creator |
| `author_email` | String | joined from `wiki_users` | `createdById` → `wiki_users.user_id` → `email` |
| `last_editor_id` | String | `data[].updatedBy.id` | User UUID of last editor (if available) |
| `last_editor_email` | String | joined from `wiki_users` | |
| `created_at` | DateTime64(3) | `data[].createdAt` | |
| `updated_at` | DateTime64(3) | `data[].updatedAt` | |
| `published_at` | DateTime64(3) | `data[].publishedAt` | NULL for drafts |
| `archived_at` | DateTime64(3) | `data[].archivedAt` | NULL if not archived |
| `version_number` | Int64 | `data[].revision` | Outline revision number |
| `parent_page_id` | String | `data[].parentDocumentId` | NULL for top-level documents |
| `view_count` | Int64 | from `views.list` | Aggregate total views; joined by `page_id` |
| `distinct_viewers` | Int64 | NULL | Not available from Outline API |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_outline` | |
| `_version` | UInt64 | ms timestamp | |

**Document list parameters** (`POST /documents.list` body):
```json
{
  "collectionId": "{optional: filter by collection}",
  "includeArchived": true,
  "offset": 0,
  "limit": 100
}
```

Deleted documents: `POST /documents.list` does not return deleted documents by default. To collect deleted documents (for `status = deleted`), use `POST /documents.list` with `{ "deletedAt": { "gt": null } }` — or accept that deleted documents are not tracked until a separate deletion sweep is implemented.

---

### `wiki_page_activity` — Views and edits (Outline mapping)

Two activity sub-types collected separately:

**Edits** — derived from revision history (`POST /revisions.list`):

| Field | Type | Outline API field | Notes |
|-------|------|------------------|-------|
| `source_instance_id` | String | connector config | |
| `page_id` | String | `data[].documentId` | |
| `user_id` | String | `data[].createdBy.id` | Outline user UUID of revision author |
| `user_email` | String | `data[].createdBy.email` | Available directly in revision response |
| `date` | Date | `data[].createdAt` (date part) | UTC date of revision |
| `view_count` | Int64 | NULL | Not applicable for edit rows |
| `edit_count` | Int64 | 1 per revision | One revision = one edit event |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_outline` | |
| `_version` | UInt64 | ms timestamp | |

**Views** — from `POST /views.list` (aggregate, NOT per-user):

| Field | Type | Outline API field | Notes |
|-------|------|------------------|-------|
| `source_instance_id` | String | connector config | |
| `page_id` | String | `data[].documentId` | |
| `user_id` | String | NULL | `views.list` returns aggregate only — no per-user breakdown |
| `user_email` | String | NULL | Not available |
| `date` | Date | `data[].lastViewedAt` (date part) | Date of last recorded view (aggregate) |
| `view_count` | Int64 | `data[].count` | Total aggregate view count for this document |
| `edit_count` | Int64 | NULL | Not applicable for view rows |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_outline` | |
| `_version` | UInt64 | ms timestamp | |

> **Critical limitation**: Outline `views.list` returns a single aggregate row per document with `count` (total views) and `lastViewedAt`. Individual user viewing events are not exposed by the API. `user_id` and `user_email` are always NULL for view rows from `insight_outline`. See OQ-OTL-1.

---

### `wiki_users` — User directory (Outline mapping)

Populated from `POST /users.list`.

| Field | Type | Outline API field | Notes |
|-------|------|------------------|-------|
| `source_instance_id` | String | connector config | |
| `user_id` | String | `data[].id` | Outline user UUID |
| `email` | String | `data[].email` | Available directly — no enrichment step needed |
| `display_name` | String | `data[].name` | |
| `is_active` | Int64 | `!data[].isSuspended` | 1 = active; 0 = suspended |
| `collected_at` | DateTime64(3) | collection time | |
| `data_source` | String | `insight_outline` | |
| `_version` | UInt64 | ms timestamp | |

**`POST /users.list` body**:
```json
{
  "offset": 0,
  "limit": 100,
  "filter": "all"
}
```

`filter: "all"` includes suspended users (needed to avoid gaps in identity resolution for historical data).

---

### `outline_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp |
| `status` | String | REQUIRED | `running` / `completed` / `failed` |
| `collections_collected` | Int64 | NULLABLE | Rows written to `wiki_spaces` for `insight_outline` |
| `documents_collected` | Int64 | NULLABLE | Rows written to `wiki_pages` for `insight_outline` |
| `revisions_collected` | Int64 | NULLABLE | Revision records processed (edit activity rows) |
| `view_records_collected` | Int64 | NULLABLE | Aggregate view records from `views.list` |
| `users_collected` | Int64 | NULLABLE | Rows written to `wiki_users` for `insight_outline` |
| `api_calls` | Int64 | NULLABLE | Total Outline API calls made |
| `errors` | Int64 | NULLABLE | Errors encountered |
| `settings` | String | NULLABLE | Collection config as JSON (API URL, collection filter, include_archived flag) |
| `data_source` | String | DEFAULT 'insight_outline' | Always `insight_outline` |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

Monitoring table — not an analytics source.

---

## API Reference

All Outline API endpoints use `POST` method with JSON body.

| Endpoint | Purpose | Pagination |
|----------|---------|------------|
| `POST /collections.list` | List all collections | `offset` + `limit` |
| `POST /documents.list` | List documents (filterable by collection) | `offset` + `limit` |
| `POST /documents.info` | Single document metadata | N/A |
| `POST /revisions.list` | List revisions for a document | `offset` + `limit` |
| `POST /views.list` | Aggregate view counts per document | `offset` + `limit` |
| `POST /users.list` | List workspace users | `offset` + `limit` |

**Base URL** (Cloud): `https://app.getoutline.com/api/`
**Base URL** (self-hosted): `https://{hostname}/api/` — configurable per connector instance (see OQ-OTL-2).

**Authentication**: `Authorization: Bearer {api_key}` on all requests.

**Rate limits**: Outline does not publish explicit rate limits. The connector should implement conservative request pacing (e.g. 10 req/s) and retry on HTTP 429 with exponential backoff.

---

## Source Mapping

| Unified table | Outline endpoint | Mapping notes |
|---------------|-----------------|---------------|
| `wiki_spaces` | `POST /collections.list` | `id` → `space_id`; `private` → `space_type`; `deletedAt` determines `status` |
| `wiki_pages` | `POST /documents.list` | `id` → `page_id`; `collectionId` → `space_id`; `createdById` → `author_id`; `revision` → `version_number`; lifecycle timestamps mapped directly |
| `wiki_page_activity` (edits) | `POST /revisions.list` per document | `documentId` → `page_id`; `createdBy.id` → `user_id`; `createdBy.email` → `user_email`; `createdAt` date → `date`; `edit_count = 1` per revision |
| `wiki_page_activity` (views) | `POST /views.list` per document | `documentId` → `page_id`; `user_id = NULL` (aggregate); `count` → `view_count`; `lastViewedAt` → `date` |
| `wiki_users` | `POST /users.list` | `id` → `user_id`; `email` → `email`; `name` → `display_name`; `isSuspended` inverted → `is_active` |

---

## Identity Resolution

**Identity anchor**: `email` from `wiki_users` (sourced directly from `POST /users.list`).

**Resolution process**:
1. Collect `wiki_users` with `email` for all users (including suspended, `filter: "all"`).
2. Backfill `author_email` in `wiki_pages` by joining `author_id` → `wiki_users.user_id`.
3. Revision rows have `createdBy.email` available inline — no separate join needed.
4. Normalize email (lowercase, trim).
5. Map to canonical `person_id` via Identity Manager in Silver step 2.

**Advantage over Confluence**: Outline embeds `email` directly in revision responses (`createdBy.email`), eliminating the need for a separate user enrichment step for edit activity. Only `wiki_pages.author_email` requires the `wiki_users` join.

**View rows**: No identity resolution possible for view rows — `user_id` and `user_email` are NULL (aggregate data only).

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `wiki_pages` (insight_outline) | `class_wiki_pages` | Draft — SCD2 page metadata |
| `wiki_page_activity` — edits (insight_outline) | `class_wiki_activity` | Draft — per-user per-day edits |
| `wiki_page_activity` — views (insight_outline) | `class_wiki_activity` | Draft — aggregate views (user_id = NULL) |
| `wiki_spaces` | Reference dimension | Planned |
| `wiki_users` | Identity Manager (`email` → `person_id`) | Used for identity resolution |

**`class_wiki_pages`** key fields from Outline source:
- `person_id` — resolved from `author_id` via email
- `data_source = 'insight_outline'`
- `version_number` — Outline `revision` field
- `status` — derived from `publishedAt`, `archivedAt`, `deletedAt`

**`class_wiki_activity`** key fields from Outline source:
- Edit rows: `person_id`, `page_id`, `date`, `edit_count = 1` per revision
- View rows: `person_id = NULL`, `page_id`, `date`, `view_count` (aggregate total)

**Silver handling of aggregate view rows**: When `person_id = NULL` (Outline view rows), Silver ETL should preserve these rows as document-level view totals rather than person-level activity. These rows contribute to page-level Gold metrics (total views per page) but cannot contribute to per-person metrics.

---

## Open Questions

### OQ-OTL-1: Aggregate-only view data — no per-user attribution

Outline's `views.list` endpoint returns `{ documentId, count, lastViewedAt }` — one row per document with a total view count. Individual user viewing events are not exposed.

**Consequence**: For `insight_outline`, it is not possible to answer "how many times did person X view document Y?" View-based Silver metrics cannot be attributed to individuals. Only document-level view totals are available.

**Question**: Is this acceptable for the current analytics use cases? If per-user view data is required for Outline, the only alternative is self-hosted Outline with direct database access — which is out of scope for the API-based connector approach.

### OQ-OTL-2: Self-hosted Outline URL configuration

Outline supports self-hosted deployments at arbitrary domain names. The connector must support a configurable API base URL.

**Question**: Define the connector configuration schema for self-hosted Outline. Should the URL be stored in `settings` of `outline_collection_runs`? Confirm whether the self-hosted API is identical to the Cloud API (same endpoints, same response schemas) or whether version differences need to be handled.

### OQ-OTL-3: Deleted document recovery and `deletedAt` handling

`POST /documents.list` by default excludes deleted documents. Deleted documents may still have analytics value (edit history before deletion).

**Question**: Should the connector attempt to collect deleted documents using `POST /documents.list` with deletion filter, or should deletion be handled by detecting gaps in subsequent runs? If deleted documents should be included, define the lookback window for deletion sweeps.
