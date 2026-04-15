---
status: accepted
date: 2026-04-08
---

# ADR-001: Cursor granularity `PT1S` for consistency with claude-api date-boundary fix

**ID**: `cpt-insightspec-adr-claude-team-001`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Option 1: cursor_granularity: PT1S (chosen)](#option-1-cursorgranularity-pt1s-chosen)
  - [Option 2: Keep cursor_granularity: P1D](#option-2-keep-cursorgranularity-p1d)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

Airbyte's `DatetimeBasedCursor` computes the `ending_at` timestamp for each time window partition as:

```text
ending_at = partition_start + step - cursor_granularity
```

In the `claude-api` connector, this formula with `step: P1D` and `cursor_granularity: P1D` caused the current-day partition to produce `ending_at == starting_at`, which the Anthropic API rejects with HTTP 400 (`"ending_at must be after starting_at"`). That bug was fixed by changing `cursor_granularity` to `PT1S` (see `cpt-insightspec-adr-claude-api-003`).

The `claude-team` connector's `claude_team_code_usage` stream uses the same `DatetimeBasedCursor` with `step: P1D`. However, this stream does **not** include `end_time_option` -- it only sends `start_time_option` (`starting_at`). Because `ending_at` is never sent to the API, the boundary bug does not manifest directly.

Nevertheless, the `cursor_granularity` was changed from `P1D` to `PT1S` in `claude-team` as well, for consistency and as a defensive measure.

## Decision Drivers

- The `claude-api` connector required `PT1S` to fix an HTTP 400 error on the current-day partition.
- Both connectors share the same `DatetimeBasedCursor` pattern with `step: P1D`.
- Consistency across connectors reduces cognitive load and maintenance risk.
- If `end_time_option` is ever added to `claude_team_code_usage`, the bug would surface immediately without this fix.

## Considered Options

1. **`cursor_granularity: PT1S`** -- Align with `claude-api` for consistency and future-proofing.
2. **Keep `cursor_granularity: P1D`** -- No change, since the bug does not manifest in `claude-team` today.

## Decision Outcome

**Chosen option: Option 1 -- `cursor_granularity: PT1S`.** Defensive alignment with the `claude-api` fix prevents a latent bug and maintains consistency across the two connectors.

### Consequences

- `claude_team_code_usage` cursor windowing is unchanged in practice: the stream only sends `starting_at`, so `ending_at` computation has no effect on API requests.
- If `end_time_option` is added in the future, the stream will automatically produce valid windows (`ending_at = today_23:59:59Z`).
- Both `claude-api` and `claude-team` connectors now use the same `cursor_granularity: PT1S` value, reducing cross-connector divergence.

### Confirmation

- Tested: `claude-team` sync completed successfully with `PT1S` on 2026-04-07.
- No behavioral change observed (as expected, since `ending_at` is not sent to the API).

## Pros and Cons of the Options

### Option 1: cursor_granularity: PT1S (chosen)

- Good, because it aligns with the `claude-api` connector fix, maintaining consistency.
- Good, because it prevents a latent bug if `end_time_option` is ever added.
- Good, because it reduces cognitive load -- both connectors use the same granularity.
- Neutral, because it has no observable effect on current behavior.

### Option 2: Keep cursor_granularity: P1D

- Good, because no change is needed -- the bug does not manifest today.
- Bad, because it creates a divergence between `claude-api` and `claude-team` cursor configurations.
- Bad, because it leaves a latent bug that would surface if `end_time_option` is added later.

## More Information

- Airbyte CDK `DatetimeBasedCursor`: `step=P1D` sends one request per day; `cursor_granularity` controls the subtraction from `ending_at`.
- The `claude_team_code_usage` stream only sends `start_time_option` (`starting_at`) -- it does not send `end_time_option`.
- Related fix: `cpt-insightspec-adr-claude-api-003` (claude-api connector).

## Traceability

| Artifact | Requirement ID | Relationship |
|----------|---------------|--------------|
| [DESIGN.md](../DESIGN.md) | `cpt-insightspec-design-claude-team-connector` | Implements -- `cursor_granularity: PT1S` on `claude_team_code_usage` stream |
| ADR-003 (claude-api) | `cpt-insightspec-adr-claude-api-003` | Related -- original fix for the date-boundary bug |
