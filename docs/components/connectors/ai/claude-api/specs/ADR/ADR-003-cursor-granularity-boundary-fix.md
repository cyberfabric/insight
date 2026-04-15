---
status: accepted
date: 2026-04-08
---

# ADR-003: Cursor granularity `PT1S` to avoid empty date-boundary windows

**ID**: `cpt-insightspec-adr-claude-api-003`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Option 1: cursor_granularity: PT1S](#option-1-cursorgranularity-pt1s)
  - [Option 2: Remove end_time_option and let API default ending_at](#option-2-remove-endtimeoption-and-let-api-default-endingat)
  - [Option 3: Set end_datetime to day_delta(1) to push past today](#option-3-set-enddatetime-to-daydelta1-to-push-past-today)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

Airbyte's `DatetimeBasedCursor` computes the `ending_at` timestamp for each time window partition as:

```text
ending_at = partition_start + step - cursor_granularity
```

With the original configuration (`step: P1D`, `cursor_granularity: P1D`), the last partition for the current day produces:

```text
ending_at = today_00:00 + P1D - P1D = today_00:00 = starting_at
```

The Anthropic Admin API rejects requests where `ending_at == starting_at` with HTTP 400: `"ending_at must be after starting_at"`. This caused incremental sync to fail every time the cursor reached the current day.

Both `claude_api_messages_usage` and `claude_api_cost_report` streams include `end_time_option` in their configuration, meaning they send `ending_at` as a query parameter to the API. This made both streams vulnerable to the boundary condition.

## Decision Drivers

- Anthropic API rejects `ending_at == starting_at` with HTTP 400.
- Airbyte `DatetimeBasedCursor` computes `ending_at = partition_start + step - cursor_granularity`.
- With `step: P1D` and `cursor_granularity: P1D`, the current-day partition always produces `ending_at == starting_at`.
- The bug manifests only on the current-day partition (all historical partitions have `ending_at > starting_at`).
- Both `claude_api_messages_usage` and `claude_api_cost_report` inject `end_time_option` into API requests.

## Considered Options

1. **`cursor_granularity: PT1S`** -- Change granularity from one day to one second.
2. **Remove `end_time_option`** and let the API default `ending_at`.
3. **Set `end_datetime` to `day_delta(1)`** to push the cursor boundary past today.

## Decision Outcome

**Chosen option: Option 1 -- `cursor_granularity: PT1S`.** Minimal change that maintains explicit date windowing while ensuring `ending_at` is always strictly greater than `starting_at`.

With `step: P1D` and `cursor_granularity: PT1S`, the current-day partition computes:

```text
ending_at = today_00:00 + P1D - PT1S = today_23:59:59Z
```

This is always greater than `starting_at` (`today_00:00:00Z`), satisfying the API constraint.

### Consequences

- `ending_at` for the current-day partition becomes `today_23:59:59Z` (always > `starting_at`).
- Historical windows are unaffected: for any past day `D`, `ending_at = D_00:00 + P1D - PT1S = D_23:59:59Z`.
- The one-second gap at midnight (`23:59:59Z` to `00:00:00Z`) is negligible -- the Anthropic usage API aggregates at daily granularity, so no data is lost.
- The fix was applied to both `claude_api_messages_usage` and `claude_api_cost_report` streams in `connector.yaml`.

### Confirmation

- Tested: claude-api sync completed successfully with `PT1S` on 2026-04-07.
- The current-day partition no longer triggers HTTP 400.

## Pros and Cons of the Options

### Option 1: cursor_granularity: PT1S

- Good, because it is a minimal, targeted fix -- only the `cursor_granularity` value changes.
- Good, because it preserves explicit `ending_at` in API requests, giving full control over date windowing.
- Good, because historical partitions remain correct (daily boundaries are preserved).
- Bad, because `ending_at` is now `23:59:59Z` instead of the next day's `00:00:00Z`, leaving a 1-second theoretical gap. In practice, the API aggregates daily, so no data is lost.

### Option 2: Remove end_time_option and let API default ending_at

- Good, because it sidesteps the boundary calculation entirely.
- Bad, because it removes explicit control over the request window, making behavior dependent on undocumented API defaults.
- Bad, because if the API default changes, sync behavior could break silently.

### Option 3: Set end_datetime to day_delta(1) to push past today

- Good, because it avoids the boundary edge case by extending the cursor range.
- Bad, because it changes the sync window semantics -- the connector would request data for a future day, which may return errors or empty results depending on API behavior.
- Bad, because it is a less intuitive fix that introduces coupling between `end_datetime` and the boundary condition.

## More Information

- Airbyte CDK `DatetimeBasedCursor`: `step=P1D` sends one request per day; `cursor_granularity` controls the subtraction from `ending_at`.
- Affected streams: `claude_api_messages_usage`, `claude_api_cost_report` (both have `end_time_option`).
- The fix was applied to both streams in `connector.yaml`.

## Traceability

| Artifact | Requirement ID | Relationship |
|----------|---------------|--------------|
| [DESIGN.md](../DESIGN.md) | `cpt-insightspec-design-claude-api-connector` | Implements -- `cursor_granularity: PT1S` on incremental streams |
| [DESIGN.md](../DESIGN.md) | `cpt-insightspec-constraint-claude-api-date-range` | Satisfies -- prevents `starting_at == ending_at` API rejection |
