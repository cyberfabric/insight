---
cypilot: true
type: requirement
name: Plan Decomposition Strategies
version: 1.0
purpose: Define how to split tasks into phases by type — generate, analyze, implement
---

# Plan Decomposition Strategies

<!-- toc -->

- [Plan Decomposition Strategies](#plan-decomposition-strategies)
  - [Overview](#overview)
  - [Strategy Selection](#strategy-selection)
  - [Strategy 1: Generate (by Template Sections)](#strategy-1-generate-by-template-sections)
  - [Strategy 2: Analyze (by Checklist Categories)](#strategy-2-analyze-by-checklist-categories)
  - [Strategy 3: Implement (by CDSL Blocks)](#strategy-3-implement-by-cdsl-blocks)
  - [Budget Enforcement](#budget-enforcement)
  - [Execution Context Prediction](#execution-context-prediction)
    - [Estimation Formula](#estimation-formula)
    - [Execution Context Budget](#execution-context-budget)
    - [Auto-Split on Predicted Overflow](#auto-split-on-predicted-overflow)
    - [Example: Overflow Detection](#example-overflow-detection)
    - [Integration with Decomposition](#integration-with-decomposition)
  - [Phase Dependencies](#phase-dependencies)
  - [Single-Context Bypass](#single-context-bypass)

<!-- /toc -->

---

## Overview

When the plan workflow decomposes a task into phases, it MUST select one of three strategies based on the task type. Each strategy defines how to split the work into independent, self-contained units that fit within the line budget.

**Core principle**: Each phase MUST be independently executable. An agent reading a phase file MUST be able to complete it without knowledge of other phases (except the explicit Prior Context summary).

---

## Strategy Selection

| Task Type | Trigger | Strategy |
|-----------|---------|----------|
| `generate` | User requests creation or update of an artifact (PRD, DESIGN, FEATURE, ADR, DECOMPOSITION) | Split by template sections |
| `analyze` | User requests validation, review, or audit of an artifact or codebase | Split by checklist categories |
| `implement` | User requests code implementation from a FEATURE spec | Split by CDSL blocks |

**Detection rules**:
- If the task mentions "create", "generate", "write", "update", or "draft" → `generate`
- If the task mentions "validate", "review", "check", "audit", or "analyze" → `analyze`
- If the task mentions "implement", "code", "build", or "develop" → `implement`
- If ambiguous, ask the user to clarify

---

## Strategy 1: Generate (by Template Sections)

**Applies to**: Creating or updating artifacts using kit templates.

**How to decompose**:

1. Load the template for the target artifact kind (e.g., `{prd_template}`, `{design_template}`)
2. Identify all H2 sections in the template
3. Group adjacent sections into phases of 2-4 sections each
4. Each phase creates or updates one group of sections

**Grouping rules**:

- Group sections that share data dependencies (e.g., "Actors" before "Use Cases" that reference actors)
- Keep the first group small (1-2 sections) so the agent establishes the file structure
- Keep the last group small (1-2 sections) for final synthesis sections (Acceptance Criteria, Dependencies)
- If a single section would exceed 300 lines when compiled, give it its own phase

**Phase structure**:

| Phase | Typical Content | Input |
|-------|----------------|-------|
| 1 | Frontmatter + Overview + Problem/Purpose (sections 1-2) | Template, project context |
| 2 | Core content sections (sections 3-5) | Template, Phase 1 output summary |
| 3 | Detail sections (sections 6-8) | Template, Phase 1-2 output summary |
| N | Synthesis + Acceptance Criteria (final sections) | Template, all prior phase summaries |

**Example — generating a PRD (8 sections → 4 phases)**:

```
Phase 1: Frontmatter, Overview, Problem Statement (sections 1-2)
Phase 2: Goals, Actors, Operational Concept (sections 3-5)
Phase 3: Functional Requirements, Non-Functional Requirements (sections 6-7)
Phase 4: Use Cases, Acceptance Criteria, Dependencies (sections 8-10)
```

---

## Strategy 2: Analyze (by Checklist Categories)

**Applies to**: Validating, reviewing, or auditing artifacts or code.

**How to decompose**:

1. Load the checklist for the target artifact kind (e.g., `{prd_checklist}`, `{design_checklist}`)
2. Identify checklist categories (typically grouped by H2 or H3 headings)
3. Group categories into phases following the validation pipeline order
4. Each phase performs one category group of checks and produces a partial report

**Validation pipeline order** (MUST follow this sequence):

1. **Structural** — file exists, frontmatter valid, headings match template, TOC correct
2. **Semantic** — content quality, completeness, consistency within the artifact
3. **Cross-reference** — IDs defined, IDs referenced correctly, no dangling references
4. **Traceability** — requirements traced to design, design traced to features, features traced to code
5. **Synthesis** — overall assessment, priority-ranked issues, actionable recommendations

**Phase structure**:

| Phase | Category | Input |
|-------|----------|-------|
| 1 | Structural checks | Target artifact content, template structure |
| 2 | Semantic checks | Target artifact content, checklist criteria |
| 3 | Cross-reference checks | Target artifact + all referenced artifacts |
| 4 | Traceability checks | Target artifact + codebase markers |
| 5 | Synthesis | Partial reports from phases 1-4 |

**Grouping rules**:

- Structural and semantic checks MAY be combined into one phase if the checklist is short (< 20 items)
- Cross-reference and traceability MAY be combined if the artifact has few external references
- Synthesis is always the final phase
- If the full checklist has < 15 items, combine all checks into 2 phases (checks + synthesis)

---

## Strategy 3: Implement (by CDSL Blocks)

**Applies to**: Implementing code from a FEATURE specification.

**How to decompose**:

1. Load the FEATURE spec for the target feature
2. Identify all CDSL blocks: actor flows, algorithms/processes, state machines
3. Each CDSL block + its related test scenarios = 1 phase
4. Add a final integration phase for wiring and cross-cutting concerns

**Phase structure**:

| Phase | Content | Input |
|-------|---------|-------|
| 1 | Project scaffolding: file structure, imports, base types | FEATURE overview, project structure rules |
| 2..N-1 | One CDSL block: implementation + unit tests | CDSL block from FEATURE, coding rules, Phase 1 output |
| N | Integration: wiring, entry points, integration tests | All CDSL blocks summary, Phase 1 output |

**Grouping rules**:

- Each flow, algorithm, or state machine is its own phase
- If a CDSL block has < 3 steps, combine it with a related block
- If a CDSL block would produce > 500 lines of code, split by step groups
- Tests for a CDSL block are ALWAYS in the same phase as the implementation
- The scaffolding phase (phase 1) MUST NOT implement any business logic
- The integration phase (final) MUST NOT introduce new business logic

**Example — implementing a feature with 3 flows + 2 algorithms**:

```
Phase 1: Scaffolding — file structure, base types, imports
Phase 2: Flow 1 — generate-plan flow + tests
Phase 3: Flow 2 — execute-phase flow + tests
Phase 4: Flow 3 — check-status flow + tests
Phase 5: Algorithm 1 — decompose algorithm + tests
Phase 6: Algorithm 2 — compile-phase algorithm + tests
Phase 7: Integration — wiring, entry points, integration tests
```

---

## Budget Enforcement

Every phase MUST fit within the line budget after compilation (rules + input + task inlined).

| Metric | Target | Maximum | Action |
|--------|--------|---------|--------|
| Compiled phase file | ≤ 500 lines | ≤ 1000 lines | Split into sub-phases |
| Rules section | ≤ 200 lines | ≤ 300 lines | Narrow rule scope to phase |
| Input section | ≤ 300 lines | ≤ 500 lines | Split input across phases |
| Task steps | 3-7 steps (≤10 max) | 10 steps | Split task |

**Budget enforcement algorithm**:

1. Compile the phase file (inline all rules, input, task)
2. Count total lines
3. If ≤ 500: accept
4. If 501-1000: accept with warning, suggest splitting
5. If > 1000: MUST split — identify the largest section (rules or input) and create sub-phases

**Splitting strategy when over budget**:

- If Rules section is largest: **NEVER trim or summarize rules** — instead, narrow the phase scope (fewer template sections / checklist categories) so the phase handles less work but still carries the full applicable rules. Split into more phases if necessary. Kit rules completeness is the highest priority.
- If Input section is largest: split the input content across two phases (e.g., template sections 1-3 in phase A, 4-6 in phase B)
- If Task section is largest: split the task steps into two sequential phases with explicit handoff

> **Invariant**: The union of all phases' Rules sections MUST cover 100% of the kit's `rules.md` for the target artifact kind. No rule may be dropped from the plan.

---

## Execution Context Prediction

The compiled phase file size is only ONE part of the context budget. During **execution**, the agent's context window also accumulates:

1. **Phase file** — the compiled instructions (already budgeted above)
2. **Input file reads** — project files the agent must read during the task (`input_files`)
3. **Intermediate result reads** — prior phase outputs the agent loads (`inputs` from `out/`)
4. **Generated output** — content the agent writes stays in context until the phase ends
5. **Tool output** — JSON results from `EXECUTE` commands (validation reports, ID lists, etc.)
6. **Agent reasoning** — internal chain-of-thought overhead (~20-30% of total)

### Estimation Formula

For each phase, estimate the **total execution context**:

```
execution_context = phase_file_lines
                  + sum(input_file_lines)       # files listed in input_files
                  + sum(intermediate_input_lines) # files listed in inputs (out/)
                  + estimated_output_lines       # what the agent will write
                  + estimated_tool_output_lines   # JSON from EXECUTE commands
                  + reasoning_overhead            # ~30% of above
```

**Estimation heuristics**:

| Component | How to estimate |
|-----------|----------------|
| `input_file_lines` | Count lines of each file in `input_files` (or estimate from file size) |
| `intermediate_input_lines` | Estimate from prior phase's `outputs` — typically 20-100 lines per intermediate file |
| `estimated_output_lines` | For generate: ~lines of template sections assigned. For analyze: ~50-150 lines per checklist category. For implement: ~lines of code per CDSL block |
| `estimated_tool_output_lines` | ~20-50 lines per EXECUTE command (JSON output) |
| `reasoning_overhead` | 30% of the sum of all above |

### Execution Context Budget

| Level | Threshold | Action |
|-------|-----------|--------|
| **Safe** | ≤ 1500 lines | Accept phase as-is — optimal zone, >95% rule adherence |
| **Warning** | 1501-2500 lines | Accept with warning; consider splitting if active constraints are dense |
| **Overflow** | > 2500 lines | **MUST split** — phase will exceed effective working memory |

> **Why these thresholds**: Rule-following quality degrades above ~8K tokens (~2000 lines). Active constraints (MUST rules from rules.md/checklist.md) are the heaviest context type — 50-80 simultaneous rules is the practical ceiling for modern models. SDLC kit artifacts are 1300-1850 lines of kit files alone. A compiled phase file with full rules + input + task must stay well under these limits.

### Auto-Split on Predicted Overflow

If a phase's predicted execution context exceeds **2500 lines**, decompose further:

1. **Identify the largest contributor** — which component (input files, output size, tool calls) dominates?
2. **Split strategy by contributor**:

| Largest contributor | Split strategy |
|-------------------|----------------|
| **Input files** (reading large project files) | Split into phases that each read a subset of files |
| **Intermediate inputs** (too many prior outputs) | Add a consolidation sub-phase that summarizes prior outputs into one condensed file, then feed that to the main phase |
| **Generated output** (phase writes too much) | Split the generation scope — fewer template sections or checklist categories per phase |
| **Tool output** (many EXECUTE commands) | Group related commands into sub-phases; each sub-phase runs a few commands and saves results to `out/` |
| **Combination** | Apply multiple strategies; prefer splitting by output scope first |

3. **Re-estimate** each sub-phase after splitting — repeat until all are within budget

### Example: Overflow Detection

```
Phase 4: "Consolidated Report" (analyze plan)
  phase_file_lines:        300
  input_files:             architecture/PRD.md (400 lines)
                           architecture/DESIGN.md (800 lines)
  intermediate_inputs:     out/phase-01-findings.md (80 lines)
                           out/phase-02-findings.md (120 lines)
                           out/phase-03-findings.md (90 lines)
  estimated_output_lines:  ~500 (consolidated report)
  tool_output_lines:       ~60 (2 validate commands)
  reasoning_overhead:      ~30% of 2350 = ~705

  TOTAL: ~3055 lines → OVERFLOW
  Action: MUST split — e.g., split into two sub-phases: one reads PRD + prior
          findings, another reads DESIGN + prior findings, then a merge phase
```

```
Phase 3: "Analyze DECOMPOSITION" (single artifact)
  phase_file_lines:        350
  input_files:             architecture/DECOMPOSITION.md (230 lines)
  intermediate_inputs:     none
  estimated_output_lines:  ~150 (analysis report)
  tool_output_lines:       ~30 (1 validate command)
  reasoning_overhead:      ~30% of 760 = ~228

  TOTAL: ~988 lines → SAFE
  Action: accept
```

### Integration with Decomposition

During Phase 2 (Decompose), after creating the initial phase list:

1. **Estimate** execution context for each phase using the formula above
2. **Flag** any phase in WARNING or OVERFLOW zone
3. **Auto-split** OVERFLOW phases before proceeding to compilation
4. **Report** estimates to user in the decomposition summary:

```
Decomposition ({strategy} strategy):
  Phase 1: {title} — ~{N} lines execution context ✓
  Phase 2: {title} — ~{N} lines execution context ✓
  Phase 3: {title} — ~{N} lines execution context ⚠ (warning)
  Phase 4: {title} — ~{N} lines execution context ✓
  
  Total phases: {N}
  Overflow phases: {count} (auto-split if any)
```

---

## Phase Dependencies

Phases within a plan MUST declare dependencies explicitly in the TOML frontmatter.

**Dependency rules**:

- Phase 1 has no dependencies (`depends_on = []`)
- Later phases depend on the phase that creates their input files
- Phases that operate on independent sections MAY run in parallel (no mutual dependencies)
- The synthesis/integration phase (final) depends on all prior phases

**Dependency graph example** (generate strategy, 4 phases):

```
Phase 1: [] — creates file with sections 1-2
Phase 2: [1] — adds sections 3-5 (needs file from phase 1)
Phase 3: [1] — adds sections 6-7 (needs file from phase 1, independent of phase 2)
Phase 4: [2, 3] — adds sections 8-10 (needs all prior sections for synthesis)
```

**Parallel execution**: Phases 2 and 3 in this example have no mutual dependency and could theoretically execute in parallel. However, the plan workflow MUST present phases sequentially by default. Parallel execution is an optimization the user may choose.

---

## Single-Context Bypass

If the total compiled content (all rules + all input + task) fits within 500 lines, the plan workflow MUST **stop and redirect** the user to the appropriate direct workflow. The plan workflow never executes tasks itself.

**Bypass check**:

1. Estimate total compiled size: template lines + rules lines + checklist lines + existing content lines
2. If estimate ≤ 500: **stop plan generation** and tell the user to run `/cypilot-generate` or `/cypilot-analyze` directly
3. If estimate > 500: proceed with plan generation

This prevents unnecessary overhead for small tasks and enforces the constraint that `/cypilot-plan` only produces plans.
