---
status: accepted
date: 2026-03-31
---

# ADR-002: API Response Structure — Nested Records and Field Mapping

**ID**: `cpt-insightspec-adr-claude-api-002`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Option 1: DpathExtractor with P1D step and AddFields mapping](#option-1-dpathextractor-with-p1d-step-and-addfields-mapping)
  - [Option 2: P31D step with wildcard flattening](#option-2-p31d-step-with-wildcard-flattening)
  - [Option 3: Store date buckets as JSON blobs](#option-3-store-date-buckets-as-json-blobs)
  - [Option 4: Switch to Python CDK connector](#option-4-switch-to-python-cdk-connector)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

---

## Context and Problem Statement

During implementation, the actual Anthropic Admin API response structure was found to differ significantly from what was assumed in the PRD. This required decisions about extraction patterns, field mapping, and schema expansion for both the `messages_usage` and `cost_report` streams.

**Nested response structure (messages_usage and cost_report).**
The `usage_report` endpoints return a nested response where individual usage records are inside `data[].results[]`, not at the top level of `data[]`. The `date` field does not exist in individual records -- it is derived from the parent bucket's `starting_at`.

```json
{
  "data": [
    {
      "starting_at": "2025-12-27T00:00:00Z",
      "ending_at": "2025-12-28T00:00:00Z",
      "results": [
        { "model": "claude-haiku-4-5", "api_key_id": "...", "uncached_input_tokens": 67047, ... }
      ]
    }
  ]
}
```

**Field name differences (messages_usage).**
Several fields in the actual API response use different names or are nested inside sub-objects compared to what the PRD specified:

| PRD expected | API actual | Notes |
|---|---|---|
| `cache_read_tokens` | `cache_read_input_tokens` | Different name |
| `cache_creation_5m_tokens` | `cache_creation.ephemeral_5m_input_tokens` | Nested object |
| `cache_creation_1h_tokens` | `cache_creation.ephemeral_1h_input_tokens` | Nested object |
| `web_search_requests` | `server_tool_use.web_search_requests` | Nested object |
| `date` | *(not present in results)* | Derived from bucket `starting_at` |

**Cost report has richer structure than PRD specified.**
The PRD specified four fields (`date`, `workspace_id`, `description`, `amount_cents`), but the API returns per cost line: `workspace_id`, `description`, `amount` (string, USD), `currency`, `cost_type`, `model`, `service_tier`, `context_window`, `token_type`, `inference_geo`. The reference implementation (`additional-claude-platform/apps/claude-platform/src/cost-report-sync.ts`) already stores the additional fields: `model`, `cost_type`, `token_type`, `service_tier`, `context_window`, `inference_geo`.

---

## Decision Drivers

- The Airbyte declarative (no-code) approach must be preserved per project conventions -- custom Python is a last resort.
- The `DpathExtractor` in Airbyte CDK uses `dpath.util.get`, not `dpath.util.values`, so wildcard `*` on array indices is not supported.
- The Bronze schema must capture all available API fields for forward compatibility, not just the subset the PRD initially listed.
- The `date` field must be injected from the request interval because it is absent from the nested result records.
- Field names in the Bronze schema should match the PRD naming conventions for downstream dbt compatibility and alignment with `class_ai_api_usage`.
- The composite unique key must be stable and consistent with the PRD specification for idempotent upserts.

---

## Considered Options

1. **DpathExtractor with P1D step and AddFields mapping** -- Use one-day step to guarantee a single date bucket, extract from `data[0].results[]`, and use `AddFields` to rename/flatten nested fields.
2. **P31D step with wildcard flattening** -- Use a 31-day step and attempt `data[*].results[*]` extraction.
3. **Store date buckets as JSON blobs** -- Ingest the raw nested structure and defer flattening to dbt.
4. **Switch to Python CDK connector** -- Implement extraction logic in Python for full control over nested response handling.

---

## Decision Outcome

**Chosen option: Option 1 -- DpathExtractor with P1D step and AddFields mapping**, because it preserves the no-code declarative approach, works within the constraints of `DpathExtractor`, and produces a clean flat Bronze schema aligned with the PRD naming conventions.

**Extraction pattern.**
Use `DpathExtractor` with `field_path: ["data", "0", "results"]` and `DatetimeBasedCursor` with `step: P1D` (one day per request). This ensures `data[0]` contains exactly one date bucket. The `date` field is injected from `stream_interval['start_time'][:10]`.

**Field mapping (messages_usage).**
Use `AddFields` transformations to map API field names to schema field names:

- `record.cache_read_input_tokens` -> `cache_read_tokens`
- `record.cache_creation.ephemeral_5m_input_tokens` -> `cache_creation_5m_tokens`
- `record.cache_creation.ephemeral_1h_input_tokens` -> `cache_creation_1h_tokens`
- `record.server_tool_use.web_search_requests` -> `web_search_requests`

**Cost report schema expansion.**
The `cost_report` Bronze schema is expanded to include all fields returned by the API. The `amount` field (string, USD) replaces `amount_cents` (number). Additional dimension fields (`cost_type`, `model`, `service_tier`, `context_window`, `token_type`, `inference_geo`) are added as nullable strings. The composite unique key remains `(date, workspace_id, description)` -- matching both the PRD and the reference implementation.

### Consequences

**Positive:**

- Preserves the no-code declarative connector approach, keeping the connector as a single YAML manifest.
- The P1D step guarantees exactly one date bucket per response, making `data[0].results[]` extraction deterministic and safe.
- `AddFields` transformations provide a clean mapping layer that aligns API field names with PRD naming conventions without custom code.
- Expanding the cost report schema captures all available API dimensions, enabling richer analytics in Silver/Gold layers.
- The stable composite unique key supports idempotent upserts across overlapping sync windows.

**Negative:**

- P1D step increases the number of API calls compared to P31D (one call per day instead of one per 31-day window), which may increase collection time for large backfill periods.
- Field mappings via `AddFields` add maintainability overhead if Anthropic changes nested field paths in future API versions.

**Neutral:**

- The `amount` field type changes from integer cents to string USD, requiring downstream dbt to cast and convert. This is consistent with the reference implementation approach.

### Confirmation

Verified via Airbyte Connector Builder testing against live Anthropic Admin API. All streams using nested extraction (messages_usage and cost_report) return records with correct field mapping.

---

## Pros and Cons of the Options

### Option 1: DpathExtractor with P1D step and AddFields mapping

- **Pro**: Stays within the no-code declarative manifest; no Python required.
- **Pro**: P1D step guarantees exactly one date bucket, making `data[0]` extraction safe.
- **Pro**: `AddFields` provides a clean, auditable mapping layer from API field names to PRD field names.
- **Pro**: Flat Bronze schema is directly consumable by dbt without JSON flattening.
- **Con**: One API call per day increases total API calls for large backfills.
- **Con**: Tight coupling to the `data[0].results[]` response shape.

### Option 2: P31D step with wildcard flattening

- **Pro**: Fewer API calls (one per 31-day window).
- **Con**: Rejected because Airbyte's `DpathExtractor` uses `dpath.util.get`, not `dpath.util.values`, and does not support wildcard `*` on array indices. This makes `data[*].results[*]` extraction impossible in the declarative framework.

### Option 3: Store date buckets as JSON blobs

- **Pro**: Simplest connector implementation -- no extraction or field mapping needed.
- **Con**: Rejected because it would require complex dbt JSON flattening and fundamentally change the Bronze data model away from the flat-record convention used by all other connectors.

### Option 4: Switch to Python CDK connector

- **Pro**: Full programmatic control over nested response traversal and field mapping.
- **Con**: Rejected because it violates the no-code approach per project conventions, increases maintenance burden, and is unnecessary given that Option 1 works within declarative constraints.

---

## More Information

- Reference implementation: `additional-claude-platform/apps/claude-platform/src/messages-usage-sync.ts`, `cost-report-sync.ts`
- Anthropic Admin API actual response structure (verified 2026-03-27)
- Airbyte CDK `DpathExtractor` implementation: uses `dpath.util.get` internally, which does not support wildcard array indices

---

## Traceability

| Artifact | ID | Relationship |
|---|---|---|
| PRD | [`cpt-insightspec-fr-claude-api-messages-usage`](../PRD.md#collect-messages-usage-reports) | This ADR resolves the extraction and field mapping approach for the messages_usage stream specified in this requirement |
| PRD | [`cpt-insightspec-fr-claude-api-cost-report`](../PRD.md#collect-cost-reports) | This ADR resolves the schema expansion and extraction approach for the cost_report stream specified in this requirement |
| PRD | [`cpt-insightspec-fr-claude-api-usage-unique-key`](../PRD.md#generate-composite-unique-keys-for-usage-records) | Composite unique key definition is preserved as specified |
| PRD | [`cpt-insightspec-fr-claude-api-cost-unique-key`](../PRD.md#generate-composite-unique-keys-for-cost-records) | Composite unique key definition is preserved as specified |
| DESIGN | [`cpt-insightspec-design-claude-api-connector`](../DESIGN.md) | This ADR documents a deviation from the initially assumed API response structure that drove changes in the connector.yaml implementation |
