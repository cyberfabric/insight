---
status: accepted
date: 2026-03-27
---

# ADR-001: Drop `inference_geo` from `group_by` dimensions

**ID**: `cpt-insightspec-adr-claude-api-001`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Option 1: Drop `inference_geo` (and `speed`)](#option-1-drop-inferencegeo-and-speed)
  - [Option 2: Drop `context_window` instead](#option-2-drop-contextwindow-instead)
  - [Option 3: Make two API calls with different `group_by` sets and merge](#option-3-make-two-api-calls-with-different-groupby-sets-and-merge)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The Anthropic Admin API enforces a **maximum of 5 `group_by[]` dimensions** per request on the `/v1/organizations/usage_report/messages` endpoint. The PRD (`cpt-insightspec-fr-claude-api-messages-usage`, `cpt-insightspec-fr-claude-api-usage-unique-key`) specified 7 grouping dimensions plus `date`:

`(date, model, api_key_id, workspace_id, service_tier, context_window, inference_geo, speed)`

During implementation (2026-03-27), the API rejected the request:

1. `speed` is not a valid `group_by` option (6 remaining).
2. 6 dimensions still exceeds the max-5 limit (need to drop one more).

The reference implementation (`additional-claude-platform/apps/claude-platform/src/messages-usage-sync.ts:269`) already solved this by using exactly 5 dimensions: `model`, `api_key_id`, `workspace_id`, `service_tier`, `context_window`, with an inline comment: `// Anthropic API allows max 5 group_by dimensions`.

## Decision Drivers

- The Anthropic Admin API hard limit of 5 `group_by[]` dimensions cannot be circumvented.
- `speed` is not a valid `group_by` option in the API, eliminating it automatically.
- The connector's core use case is **API cost attribution** -- each retained dimension must directly affect pricing or cost center allocation.
- `inference_geo` is a deployment routing detail, not a billing dimension; Anthropic does not charge differently by geography.
- Workspace-level `data_residency` (collected via `claude_api_workspaces` stream) already captures the configured geo policy, making per-row geo redundant for most analytics.
- Most organizations operate within a single inference region.
- The production reference implementation has been running successfully with the same 5-dimension approach.

## Considered Options

1. **Drop `inference_geo` (and `speed`)** -- Use 5 dimensions: `model`, `api_key_id`, `workspace_id`, `service_tier`, `context_window`.
2. **Drop `context_window` instead** -- Keep `inference_geo`, drop `context_window` to stay within the 5-dimension limit.
3. **Make two API calls with different `group_by` sets and merge** -- Split dimensions across two requests and combine results.

## Decision Outcome

**Chosen option: Option 1 -- Drop `inference_geo` (and `speed`) from `group_by` parameters.** Use 5 dimensions: `model`, `api_key_id`, `workspace_id`, `service_tier`, `context_window`.

Both `inference_geo` and `speed` are retained in the Bronze schema as nullable fields for forward compatibility but excluded from `group_by` and the composite `unique` key.

Each of the 5 retained dimensions is critical for the connector's core use case (API cost attribution):

| Dimension | Role in cost attribution | Can drop? |
|-----------|-------------------------|-----------|
| `model` | Different pricing per model (opus vs sonnet vs haiku) | No -- primary cost driver |
| `api_key_id` | Per-key usage attribution -- the connector's primary use case | No -- core requirement |
| `workspace_id` | Cost center / organizational structure | No -- required for workspace-level cost reports |
| `service_tier` | `scale` vs `standard` -- different rate cards | No -- directly affects pricing |
| `context_window` | Affects per-token pricing (e.g., 200k vs 100k) | No -- pricing dimension |
| **`inference_geo`** | **Routing/deployment detail** | **Yes** -- not a billing dimension |

`inference_geo` is the weakest candidate for cost attribution:

- It is a **deployment routing detail**, not a billing dimension -- Anthropic does not charge differently by geography.
- Workspace-level `data_residency` (collected via `claude_api_workspaces` stream) already captures the configured geo policy, making per-row geo redundant for most analytics.
- Most organizations operate within a single inference region.
- The reference implementation made the same tradeoff and has been running in production without issue.

### Consequences

#### On Bronze layer

- Without `group_by[]=inference_geo`, the API **aggregates usage across geographies** into a single row per `(date, model, api_key_id, workspace_id, service_tier, context_window)`.
- `inference_geo` field will be `null` in all records (same behavior as the reference implementation).
- `speed` field will be `null` in all records.

#### On composite unique key

- Before: `date|model|api_key_id|workspace_id|service_tier|context_window|inference_geo|speed` (8 components)
- After: `date|model|api_key_id|workspace_id|service_tier|context_window` (6 components)

#### On Silver layer (`class_ai_api_usage`)

- `inference_geo` and `speed` are **removed from the Silver model** (`to_ai_api_usage.sql`) -- they would always be null, adding no analytical value.
- All cost attribution dimensions (model, key, workspace, tier, context window) remain intact.
- Cross-provider joins with OpenAI API usage are unaffected -- OpenAI does not expose an equivalent geo dimension.

#### On PRD compliance

- PRD requirement `cpt-insightspec-fr-claude-api-messages-usage` lists `inference_geo` and `speed` in the MUST-collect fields. This ADR documents a deviation: the fields are collected (present in Bronze schema) but always null due to API constraints.
- PRD requirement `cpt-insightspec-fr-claude-api-usage-unique-key` specified an 8-component key. The key is reduced to 6 components. This is a **non-breaking change** -- the reduced key is still unique because the dropped dimensions were never populated.

### Confirmation

Verified via Airbyte Connector Builder testing against live Anthropic Admin API (2026-03-27).

## Pros and Cons of the Options

### Option 1: Drop `inference_geo` (and `speed`)

- Good, because it matches the production reference implementation's proven approach.
- Good, because all 5 retained dimensions are direct cost/pricing drivers.
- Good, because `inference_geo` information is still available via workspace-level `data_residency`.
- Good, because Bronze schema retains nullable fields for forward compatibility.
- Bad, because per-request geographic routing detail is lost at the usage row level.

### Option 2: Drop `context_window` instead

- Good, because `inference_geo` would be populated per row.
- Bad, because context window affects per-token pricing and is a meaningful dimension for cost optimization analysis.
- Bad, because it removes a direct pricing dimension in favor of a non-billing dimension.

### Option 3: Make two API calls with different `group_by` sets and merge

- Good, because all dimensions would be populated.
- Bad, because it increases API calls and complexity.
- Bad, because it introduces risk of double-counting aggregated metrics.
- Bad, because the declarative manifest framework does not support this pattern.

## More Information

- Anthropic Admin API error: `Cannot specify more than 5 group_by[] dimensions`
- Reference implementation: `additional-claude-platform/apps/claude-platform/src/messages-usage-sync.ts:269-274`

## Traceability

| Artifact | Requirement ID | Relationship |
|----------|---------------|--------------|
| [PRD.md](../PRD.md) | `cpt-insightspec-fr-claude-api-messages-usage` | Deviates -- `inference_geo` and `speed` collected but always null due to API `group_by` limit |
| [PRD.md](../PRD.md) | `cpt-insightspec-fr-claude-api-usage-unique-key` | Deviates -- composite key reduced from 8 to 6 components (dropped dimensions never populated) |
| [DESIGN.md](../DESIGN.md) | `cpt-insightspec-fr-claude-api-messages-usage` | Implements -- `claude_api_messages_usage` stream uses 5 `group_by` dimensions |
| [DESIGN.md](../DESIGN.md) | `cpt-insightspec-fr-claude-api-usage-unique-key` | Implements -- `AddFields` generates 6-component composite `unique` key |
