# Zulip Connector Specification

> Version 1.0 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 7 (Zulip), OQ-4

Standalone specification for the Zulip (Chat) connector. Expands Source 7 in the main Connector Reference with full table schemas, proposed OQ-4 field additions, identity mapping, Silver pipeline notes, and open questions.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`zulip_users` — User directory](#zulipusers-user-directory)
  - [`zulip_messages` — Aggregated message counts per sender](#zulipmessages-aggregated-message-counts-per-sender)
  - [`zulip_collection_runs` — Connector execution log](#zulipcollectionruns-connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver-gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-ZUL-1: Extra fields in stream spec vs. Connector Reference](#oq-zul-1-extra-fields-in-stream-spec-vs-connector-reference)
  - [OQ-ZUL-2: `zulip_messages` aggregation granularity](#oq-zul-2-zulipmessages-aggregation-granularity)

<!-- /toc -->

---

## Overview

**API**: Zulip REST API v1 — `https://{realm}.zulipchat.com/api/v1/`

**Category**: Chat

**Authentication**: HTTP Basic Auth — bot email + API key per realm

**Identity**: `email` (from `zulip_users`) — resolved to canonical `person_id` via Identity Manager

**Field naming**: snake_case — Zulip API uses Python-style field names; preserved as-is at Bronze level.

**Why two tables**: `zulip_users` is the identity anchor (1 row per user); `zulip_messages` holds aggregated message counts (N rows per user over time). Merging would repeat all user metadata on every message record.

> **Note**: Individual message content is not collected — only aggregated counts per sender per period. This is a deliberate design choice to avoid storing message text.

---

## Bronze Tables

### `zulip_users` — User directory

| Field | Type | Description |
|-------|------|-------------|
| `id` | Int64 | Zulip user ID — primary key |
| `email` | String | Email — identity key for cross-system resolution |
| `full_name` | String | Display name |
| `role` | Float64 | 100 owner / 200 admin / 400 member / 600 guest |
| `is_active` | Bool | Whether account is active |
| `uuid` | String | Universally unique identifier |
| `recipient_id` | Int64 | Internal Zulip recipient ID — present in stream spec (`streams/raw_zulip/zulip_users.md`) but absent from main Reference; see OQ-ZUL-1 |

---

### `zulip_messages` — Aggregated message counts per sender

| Field | Type | Description |
|-------|------|-------------|
| `uniq` | String | Primary key — present in stream spec (`streams/raw_zulip/zulip_messages.md`) but absent from main Reference; see OQ-ZUL-1 |
| `sender_id` | Int64 | Sender's Zulip user ID — joins to `zulip_users.id` |
| `count` | Float64 | Number of messages in this record |
| `created_at` | DateTime64(3) | Message timestamp / aggregation period |

Aggregated counts — individual message content is not collected.

---

### `zulip_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | String | Unique run identifier |
| `started_at` / `completed_at` | DateTime64(3) | Run timing |
| `status` | String | `running` / `completed` / `failed` |
| `users_collected` | Float64 | Rows collected for `zulip_users` |
| `messages_collected` | Float64 | Rows collected for `zulip_messages` |
| `api_calls` | Float64 | API calls made |
| `errors` | Float64 | Errors encountered |
| `settings` | String | Collection configuration (realm URL, lookback period) |

Monitoring table — not an analytics source.

---

## Identity Resolution

`email` in `zulip_users` is the primary identity key. The Identity Manager maps it to canonical `person_id` in Silver step 2.

`id` (numeric Zulip user ID) and `uuid` are Zulip-internal identifiers — not used for cross-system resolution. `email` takes precedence.

`zulip_messages.sender_id` joins to `zulip_users.id` to resolve the sender's email, which is then resolved to `person_id` in Silver step 2.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Status |
|-------------|--------------|--------|
| `zulip_messages` | `class_communication_metrics` | ✓ Mapped |
| `zulip_users` | Identity Manager (email → `person_id`) | ✓ Used for identity resolution |

**Channel mapping** into `class_communication_metrics`:

| source | channel | direction | Source table | Source field |
|--------|---------|-----------|--------------|--------------|
| `zulip` | `chat` | outbound | `zulip_messages` | `count` |

**Silver step 1** uses `zulip_users.email` as the identity key (`user_email`). Each `zulip_messages` record maps to one row in `class_communication_metrics` — there is no channel subdivision (one Zulip record = one channel entry, unlike M365 Teams which produces multiple rows per day).

**Gold**: No Gold tables are defined specifically for Zulip. Communication-level Gold metrics derive from the unified `class_communication_metrics` stream across all sources.

---

## Open Questions

### OQ-ZUL-1: Extra fields in stream spec vs. Connector Reference

`streams/raw_zulip/zulip_users.md` (PR #3) contains a `recipient_id` (bigint) field not present in the main Connector Reference. `streams/raw_zulip/zulip_messages.md` contains a `uniq` (text, PRIMARY KEY) field also absent from the Reference.

Both fields are included in this spec as proposed additions. Decision required:

- Are `recipient_id` and `uniq` produced by the current connector and should be added to `CONNECTORS_REFERENCE.md`?
- Or are they implementation artifacts in the stream spec that should be removed?

### OQ-ZUL-2: `zulip_messages` aggregation granularity

`zulip_messages` currently stores one row per `(sender_id, created_at)`. The aggregation period is unclear — is `created_at` a daily bucket, an hourly bucket, or the raw message timestamp rounded to some unit?

Clarifying the granularity affects how `count` is interpreted in Silver and whether it can be compared directly to M365 daily message counts.
