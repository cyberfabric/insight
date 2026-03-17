---
cypilot: true
type: workflow
name: cypilot-plan
description: Decompose large tasks into self-contained phase files
version: 1.0
purpose: Universal workflow for generating execution plans with phased delivery
---

# Plan

> **⛔ CRITICAL CONSTRAINT**: This workflow ONLY generates execution plans. It NEVER executes the underlying task (generate, analyze, implement) directly. Even if the task seems small, this workflow's job is to produce phase files — not to do the work itself. If the task is small enough for direct execution, tell the user to use `/cypilot-generate` or `/cypilot-analyze` instead.

> **⛔ CRITICAL CONSTRAINT — FULL CONTEXT LOADING**: Before generating ANY plan, you MUST load and process ALL navigation rules (`ALWAYS open`, `OPEN and follow`, `ALWAYS open and follow`) from the **target workflow** (generate.md, analyze.md, or the relevant workflow). Every file referenced by those directives MUST be opened and its content used during decomposition and compilation. Skipping ANY navigation rule means phase files will be compiled with incomplete context, producing broken or shallow results. This is the #1 source of plan quality failures.

> **⛔ CRITICAL CONSTRAINT — KIT RULES ARE LAW** *(highest priority)*: Every rule in the kit's `rules.md` for the target artifact kind MUST be enforced in the generated plan — **completely, without omission or summarization**. Rules are inlined verbatim into phase files. If the full rules don't fit in a single phase, split the phase so each sub-phase gets ALL rules relevant to its scope — but NEVER trim, summarize, or selectively skip rules to fit a budget. The `checklist.md` items are equally mandatory for analyze tasks. A plan that drops kit rules produces artifacts that fail validation.

> **⛔ CRITICAL CONSTRAINT — DETERMINISTIC FIRST**: Every phase step that CAN be done by a deterministic tool (cpt command, script, shell command) MUST use that tool instead of LLM reasoning. Discover available tools dynamically in Phase 0 — do NOT assume a fixed set of commands. Tool capabilities change between versions. The CLISPEC file is the source of truth for what commands exist and what they can do.

ALWAYS open and follow `{cypilot_path}/.core/skills/cypilot/SKILL.md` FIRST WHEN {cypilot_mode} is `off`

**Type**: Operation

ALWAYS open and follow `{cypilot_path}/.core/requirements/execution-protocol.md` FIRST

ALWAYS open and follow `{cypilot_path}/.core/requirements/plan-template.md` WHEN compiling phase files

ALWAYS open and follow `{cypilot_path}/.core/requirements/plan-decomposition.md` WHEN decomposing tasks into phases

OPEN and follow `{cypilot_path}/.core/requirements/prompt-engineering.md` WHEN compiling phase files (phase files ARE agent instructions)

For context compaction recovery during multi-phase workflows, follow `{cypilot_path}/.core/requirements/execution-protocol.md` Section "Compaction Recovery".

---

## Table of Contents

- [Plan](#plan)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Context Budget \& Overflow Prevention (CRITICAL)](#context-budget--overflow-prevention-critical)
  - [Phase 0: Resolve Variables \& Discover Tools](#phase-0-resolve-variables--discover-tools)
    - [0.1 Discover Available Tools](#01-discover-available-tools)
  - [Phase 1: Assess Scope](#phase-1-assess-scope)
    - [1.1 Identify Task Type](#11-identify-task-type)
    - [1.1b Extract Target Workflow Navigation Rules (CRITICAL)](#11b-extract-target-workflow-navigation-rules-critical)
    - [1.2 Estimate Compiled Size](#12-estimate-compiled-size)
    - [1.3 Scan for User Interaction Points](#13-scan-for-user-interaction-points)
    - [1.4 Identify Target](#14-identify-target)
  - [Phase 2: Decompose](#phase-2-decompose)
    - [For `generate` tasks:](#for-generate-tasks)
    - [For `analyze` tasks:](#for-analyze-tasks)
    - [For `implement` tasks:](#for-implement-tasks)
    - [Intermediate Results Analysis](#intermediate-results-analysis)
    - [Review Phases](#review-phases)
    - [Execution Context Prediction](#execution-context-prediction)
  - [Phase 3: Compile Phase Files](#phase-3-compile-phase-files)
    - [3.1 Load Phase Dependencies](#31-load-phase-dependencies)
    - [3.2 Compile Phase File](#32-compile-phase-file)
    - [3.3 Validate Phase File](#33-validate-phase-file)
    - [3.4 Write Phase File](#34-write-phase-file)
  - [Phase 4: Write Plan](#phase-4-write-plan)
    - [Plan Lifecycle Strategy](#plan-lifecycle-strategy)
    - [New-Chat Startup Prompt](#new-chat-startup-prompt)
  - [Phase 5: Execute Phases](#phase-5-execute-phases)
    - [5.1 Load Phase](#51-load-phase)
    - [5.2 Execute](#52-execute)
    - [5.3 Save Intermediate Results](#53-save-intermediate-results)
    - [5.4 Report](#54-report)
    - [5.5 Update Status](#55-update-status)
    - [5.6 Phase Handoff](#56-phase-handoff)
  - [Phase 6: Check Status](#phase-6-check-status)
  - [Plan Storage Format](#plan-storage-format)
  - [Execution Log](#execution-log)

<!-- /toc -->

---

## Overview

The plan workflow **generates** execution plans — it decomposes large agent tasks into self-contained phase files. Each phase file is a compiled prompt — all rules, constraints, context, and paths pre-resolved and inlined — executable by any AI agent without Cypilot knowledge.

**This workflow produces FILES, not results.** The output is a set of phase files in `.plans/`, not the artifact or analysis itself.

**When to use this workflow**:
- User explicitly invokes `/cypilot-plan` with a task description
- Task involves creating or updating a large artifact (estimated > 500 lines of compiled context)
- Task involves validating an artifact with a long checklist (> 15 items)
- Task involves implementing a feature with multiple CDSL blocks

**When NOT to use**:
- Task fits in a single context window (< 500 lines compiled) — redirect user to `/cypilot-generate` or `/cypilot-analyze`
- Task is a simple edit or fix
- User explicitly requests direct execution without a plan

**Workflow output**: plan.toml + N phase files in `{cypilot_path}/.plans/{task-slug}/`

**Workflow summary**:
1. Assess scope and estimate compiled size
2. Select decomposition strategy (generate / analyze / implement)
3. Decompose task into phases
4. Compile each phase into a self-contained phase file
5. Write plan manifest and phase files to disk
6. Generate startup prompt for execution in a new chat
7. (Optionally) Execute phases one at a time if user requests

---

## Context Budget & Overflow Prevention (CRITICAL)

This workflow is itself designed to PREVENT context overflow. Follow these rules strictly:

- Do NOT load all kit dependencies at once — load them incrementally per phase during compilation
- Do NOT hold all phase files in context simultaneously — compile and write one at a time
- If compiling a phase file would exceed YOUR current context budget, write what you have so far and use the Compaction Recovery protocol
- The plan manifest (`plan.toml`) serves as your recovery checkpoint — always write it before starting compilation

**Context load budget for this workflow**:
- Phase 0-1: ~200 lines (execution protocol + info output)
- Phase 2: ~300 lines (decomposition strategies + target artifact overview)
- Phase 3: ~500 lines per phase file (template + rules + input for ONE phase at a time)
- Phase 4: ~50 lines (plan manifest)
- Phase 5-6: ~500 lines (one phase file at a time)

---

## Phase 0: Resolve Variables & Discover Tools

Run the execution protocol to discover Cypilot configuration:

```
EXECUTE: {cypilot_command} info
```

Store these resolved variables:

| Variable | Source | Used For |
|----------|--------|----------|
| `{cypilot_path}` | info output | Plan storage location |
| `{project_root}` | info output | Resolving file paths |
| Kit paths | info output, per kit | Loading templates, rules, checklists |

### 0.1 Discover Available Tools

Read the CLISPEC file to discover all available commands and their capabilities:

```
READ: {cypilot_path}/.core/skills/cypilot/cypilot.clispec
```

For each command, extract:
- **Name** and synopsis
- **What it does** (deterministic capability)
- **Input/output format** (JSON output for machine parsing)
- **Relevant use cases** for plan phases

Build a **tool capability map** for use during decomposition and compilation. For each COMMAND block in the CLISPEC, record:

```
{command_name} — {DESCRIPTION line} [outputs: {OUTPUT format}]
```

This map MUST be built dynamically from the CLISPEC at plan generation time — **never hardcoded**. If new commands appear in future CLISPEC versions, they will be discovered and used automatically.

**Also check for kit-provided scripts**:

```
SCAN: {kit_scripts_path}/ for *.py, *.sh files
```

Add any kit scripts to the tool map with their purpose (inferred from filename and docstring/header).

---

## Phase 1: Assess Scope

Determine whether a plan is needed or the task can be executed directly.

### 1.1 Identify Task Type

Ask the user or infer from the request:

| Signal | Task Type | Target Workflow |
|--------|-----------|----------------|
| "create", "generate", "write", "update", "draft" + artifact kind | `generate` | `generate.md` |
| "validate", "review", "check", "audit", "analyze" + artifact kind | `analyze` | `analyze.md` |
| "implement", "code", "build", "develop" + feature name | `implement` | `generate.md` (code mode) |

### 1.1b Extract Target Workflow Navigation Rules (CRITICAL)

Open the target workflow file (`{cypilot_path}/.core/workflows/{target_workflow}`) and extract **every** navigation directive:

1. **Scan** for all lines matching `ALWAYS open`, `OPEN and follow`, `ALWAYS open and follow`
2. **List** every referenced file path with its condition (WHEN clause)
3. **Evaluate** each condition against the current task context
4. **Open and read** every file whose condition is met
5. **Record** a manifest of loaded files for later verification

Example extraction:

```
Target workflow: analyze.md
Navigation rules found:
  [1] ALWAYS: execution-protocol.md → loaded ✓
  [2] ALWAYS WHEN code mode: code-checklist.md → N/A (artifact mode)
  [3] ALWAYS WHEN consistency mode: consistency-checklist.md → loaded ✓
  [4] OPEN WHEN prompt review: prompt-engineering.md → N/A

Kit dependencies (from execution-protocol.md resolution):
  [5] rules.md for target kind → loaded ✓
  [6] checklist.md for target kind → loaded ✓
  [7] template.md for target kind → loaded ✓ (if generate)
  [8] example.md for target kind → loaded ✓ (if generate)
  [9] constraints.toml → loaded ✓
```

**Gate**: Do NOT proceed to Phase 1.2 until ALL applicable navigation rules have been processed and their referenced files loaded. Report the manifest to the user:

```
Context loaded for plan generation:
  Workflow: {target_workflow} ({N} navigation rules processed)
  Kit files: {M} files loaded ({rules}, {checklist}, {template}, ...)
  Total context: ~{L} lines
  
  All navigation rules processed? [YES/NO]
```

If any required file could not be loaded, STOP and report the error.

### 1.2 Estimate Compiled Size

Estimate the total compiled context needed:

```
estimated_size = template_lines + rules_lines + checklist_lines + existing_content_lines
```

**Decision**:
- If `estimated_size ≤ 500`: Report to user and **stop** (do NOT execute the task):
  ```
  This task fits in a single context window (~{N} lines).
  A plan is not needed. Run the task directly:
    /cypilot-generate {target}   — for generation tasks
    /cypilot-analyze {target}    — for analysis/review tasks
  ```
  **STOP HERE.** Do not proceed with plan generation or task execution.
- If `estimated_size > 500`: Proceed to Phase 2.

### 1.3 Scan for User Interaction Points

Scan the source workflow, rules, checklist, and template for interaction points — places where the agent is expected to ask the user something, wait for input, or request review. Look for these patterns:

| Pattern | Type | Example |
|---------|------|---------|
| Questions to user | `question` | "Ask the user which modules to include" |
| Expected user input | `input` | "User provides project name and tech stack" |
| Confirmation gates | `confirm` | "Wait for user confirmation before proceeding" |
| Review requests | `review` | "Present output for user review before writing" |
| Choice/decision points | `decision` | "User selects between option A and B" |

Collect all found interaction points into a list:

```
Interaction points found:
  [Q1] question: "What is the target system slug?" (from: rules.md)
  [Q2] input: "User provides existing content to preserve" (from: template.md)
  [R1] review: "Review generated sections before writing" (from: generate.md)
  [D1] decision: "Choose ID naming convention" (from: rules.md)
```

**Classify each interaction point**:
- **Pre-resolvable** — can be answered NOW, before plan generation (e.g., project name, tech stack, naming conventions). Ask the user immediately and record answers.
- **Phase-bound** — must be answered during a specific phase (e.g., "review this section's output"). Embed into the appropriate phase file.
- **Cross-phase** — affects multiple phases (e.g., "choose architecture style"). Ask NOW and inline the answer into all affected phase files.

Ask all pre-resolvable and cross-phase questions to the user NOW:

```
Before generating the plan, I need a few decisions:

  [Q1] What is the target system slug? (used in all ID patterns)
  [D1] Which ID naming convention? Option A: ... / Option B: ...
  
Phase-bound interactions (will be handled during execution):
  [R1] Review of generated sections (Phase 2, Phase 4)
```

Record all answers in a `decisions` block to include in phase files.

### 1.4 Identify Target

Resolve the target artifact or feature:

- **For generate/analyze**: identify artifact kind, file path, and kit
- **For implement**: identify FEATURE spec path and its CDSL blocks

Report to user:

```
Plan scope:
  Type: {generate|analyze|implement}
  Target: {artifact kind or feature name}
  Estimated size: ~{N} lines (exceeds single-context limit of 500)
  Proceeding with plan generation...
```

---

## Phase 2: Decompose

Open and follow `{cypilot_path}/.core/requirements/plan-decomposition.md`.

Select the appropriate strategy based on task type and apply it:

### For `generate` tasks:

1. Load the template for the target artifact kind
2. List all H2 sections
3. Group into phases of 2-4 sections per the grouping rules
4. Record phase boundaries

### For `analyze` tasks:

1. Load the checklist for the target artifact kind
2. List all checklist categories
3. Group into phases following the validation pipeline order (structural → semantic → cross-ref → traceability → synthesis)
4. Record phase boundaries

### For `implement` tasks:

1. Load the FEATURE spec
2. List all CDSL blocks (flows, algorithms, state machines)
3. Assign one CDSL block + tests per phase
4. Add scaffolding (phase 1) and integration (final phase)
5. Record phase boundaries

**Output**: a list of phases with:
- Phase number and title
- Sections/categories/blocks covered
- Dependencies on other phases
- Input files and output files
- Assigned interaction points (phase-bound questions, review gates)
- Intermediate results: what this phase produces that later phases need

### Intermediate Results Analysis

During decomposition, identify **data flow between phases** — cases where one phase produces output that a later phase or the final assembly needs.

Common patterns:

| Pattern | Example | What to save |
|---------|---------|--------------|
| **Incremental artifact** | Phase 1 writes PRD §1-3, Phase 2 writes §4-6 | Each phase appends to the target file |
| **Extracted data** | Phase 1 extracts actor list, Phase 2 uses it for requirements | Save actor list to `out/actors.md` |
| **Analysis notes** | Phase 1 structural check finds issues, Phase 3 synthesis references them | Save findings to `out/phase-01-findings.md` |
| **Generated IDs** | Phase 1 creates ID scheme, all later phases reference it | Save ID registry to `out/id-registry.md` |
| **Decision log** | Phase 1 resolves ambiguities, later phases depend on decisions | Save decisions to `out/decisions.md` |

For each phase, record:
- **`outputs`** — files this phase creates or updates (in `out/` or in the project)
- **`inputs`** — files from prior phases this phase needs to read

Rules:
- If a phase produces data that ANY later phase needs → it MUST save to `{cypilot_path}/.plans/{task-slug}/out/{filename}`
- If a phase only produces the final target artifact and nothing else depends on it → save directly to the project path
- If a final/synthesis phase needs to assemble outputs from all prior phases → list ALL prior output files as inputs
- Intermediate files use descriptive names: `out/phase-{NN}-{what}.md` (e.g., `out/phase-01-actors.md`)

### Review Phases

If the source workflow requires user review at certain points (e.g., "present output for review before writing to disk"), insert **review gates** between phases:

- A review gate is NOT a separate phase — it is a handoff point where the phase's Output Format includes the generated content for user inspection
- The phase's Acceptance Criteria should include: "User has reviewed and approved the output"
- The handoff prompt (Phase 5.5) naturally provides the review opportunity

If the source workflow expects a **major review** (e.g., full artifact review before finalization), add a dedicated **Review phase** that:
- Loads all outputs from prior phases
- Presents a consolidated view
- Lists specific review questions from the source workflow
- Blocks further execution until user approves

### Execution Context Prediction

After creating the initial phase list, estimate **execution-time context usage** for each phase per the Execution Context Prediction section in `plan-decomposition.md`:

1. For each phase, calculate: phase file + input files + intermediate inputs + estimated output + tool output + 30% reasoning overhead
2. Flag phases that exceed 5000 lines (OVERFLOW) — these MUST be split further
3. Flag phases that exceed 3000 lines (WARNING) — note for user

If any phase is in OVERFLOW, apply the auto-split strategies from `plan-decomposition.md` and re-estimate until all phases are within budget.

Report decomposition to user:

```
Decomposition ({strategy} strategy):
  Phase 1: {title} — ~{N} lines execution context ✓
  Phase 2: {title} — ~{N} lines execution context ✓
  Phase 3: {title} — ~{N} lines execution context ⚠ (warning)
  ...
  Phase N: {title} — ~{N} lines execution context ✓
  
  Total phases: {N}
  Overflow phases: 0
  
  Proceed with compilation? [y/n]
```

Wait for user confirmation before proceeding.

---

## Phase 3: Compile Phase Files

Open and follow `{cypilot_path}/.core/requirements/plan-template.md`.

For each phase (one at a time, to manage context):

### 3.1 Load Phase Dependencies

Load ONLY the rules and input needed for THIS phase:

- For generate: load the template sections assigned to this phase + relevant rules
- For analyze: load the checklist categories assigned to this phase + target content
- For implement: load the CDSL block assigned to this phase + coding rules

If this phase has `inputs` from prior phases (intermediate results), include **read instructions** in the phase file's Task section:
- Specify exact file paths to read (e.g., `{cypilot_path}/.plans/{task-slug}/out/phase-01-actors.md`)
- These paths will be absolute by the time the phase file is compiled

### 3.2 Compile Phase File

Following the template structure from `plan-template.md`, create the phase file:

1. **TOML frontmatter** — fill in all metadata fields with resolved values
2. **Preamble** — include verbatim (do NOT modify)
3. **What** — describe this phase's concrete deliverable and scope boundary
4. **Prior Context** — summarize relevant outputs from earlier phases (≤ 20 lines). Include pre-resolved user decisions that affect this phase.
5. **User Decisions** (if this phase has interaction points) — list decisions already made and questions to ask during execution (see plan-template.md Section 4b)
6. **Rules** — inline ALL rules from `rules.md` (and `checklist.md` for analyze tasks) that apply to this phase's artifact kind. Rules MUST be inlined **verbatim and completely** — never summarized, trimmed, or selectively excerpted. If the full applicable rules exceed 300 lines, do NOT cut rules — instead, narrow the phase scope (fewer template sections / checklist categories) and re-split so that each sub-phase carries the full rules for its narrower scope. Target ≤ 200 lines but completeness overrides the budget.
7. **Input** — inline all input content verbatim (≤ 300 lines target)
8. **Task** — write 3-10 concrete steps with verifiable outcomes. Apply the **deterministic-first** principle: for each step, check the tool capability map (from Phase 0.1) and use a `cpt` command or script if one can do the job. Write the exact command with arguments. Only fall back to LLM reasoning for steps that no tool can handle (creative writing, synthesis, judgment). If this phase has a review gate, include a step: "Present output to user for review. Wait for approval before writing." If this phase has intermediate outputs needed by later phases, include a final step: "Save {description} to `{output_path}`."
   - **Deterministic step example**: `EXECUTE: {cypilot_command} validate --artifact architecture/PRD.md --output out/phase-03-validation.json`
   - **Deterministic step example**: `EXECUTE: {cypilot_command} list-ids --artifact architecture/PRD.md --kind requirement`
   - **LLM step example**: "Analyze the validation report and write a summary of findings"
9. **Acceptance Criteria** — write 3-10 binary pass/fail checks. Prefer machine-verifiable criteria (exit code = 0, file exists, JSON field = value) over subjective ones. If review gate: include "User has reviewed and approved the output." If intermediate outputs: include "File `{output_path}` exists and contains {expected content}."
10. **Output Format** — include verbatim (do NOT modify)

### 3.3 Validate Phase File

Before writing:

1. Scan for unresolved `{...}` variables outside code fences → MUST be zero
2. Scan for external file references ("open file", "read", "see {path}") → MUST be zero
3. Count total lines → MUST be ≤ 1000
4. If > 1000: split into sub-phases per the budget enforcement rules in `plan-decomposition.md`
5. **Context coverage check**: verify that rules inlined in this phase's Rules section originate from the files loaded in Step 1.1b. If a navigation rule's content is relevant to this phase but was not inlined → add it. Missing rules = broken phase.
6. **Kit rules completeness check** *(highest priority)*: compare the phase's Rules section against the full `rules.md` for the target artifact kind. Every MUST/MUST NOT rule that applies to this phase's scope MUST be present verbatim in the Rules section. If any rule is missing → add it. If adding it pushes the phase over budget → split the phase (narrow scope), do NOT drop the rule. After the last phase is compiled, verify that the **union of all phases' Rules sections covers 100% of `rules.md`** — no rule left behind.

### 3.4 Write Phase File

Write the compiled phase file to: `{cypilot_path}/.plans/{task-slug}/phase-{NN}-{slug}.md`

Where:
- `{task-slug}` = task type + target (e.g., `generate-prd-myapp`, `analyze-design-myapp`)
- `{NN}` = zero-padded phase number (01, 02, ...)
- `{slug}` = short phase title slug

After writing, release the phase content from context before compiling the next phase.

---

## Phase 4: Write Plan

Create the plan manifest at `{cypilot_path}/.plans/{task-slug}/plan.toml`:

```toml
[plan]
task = "{task description}"
type = "{generate|analyze|implement}"
target = "{artifact kind or feature name}"
created = "{ISO 8601 timestamp}"
total_phases = {N}

[[phases]]
number = 1
title = "{phase title}"
file = "phase-01-{slug}.md"
status = "pending"
depends_on = []
outputs = ["out/phase-01-actors.md", "architecture/PRD.md"]
inputs = []

[[phases]]
number = 2
title = "{phase title}"
file = "phase-02-{slug}.md"
status = "pending"
depends_on = [1]
outputs = ["architecture/PRD.md"]
inputs = ["out/phase-01-actors.md"]

# ... one [[phases]] block per phase
# outputs/inputs paths are relative to .plans/{task-slug}/ for out/, or to project root for target files
```

**Status values**: `pending`, `in_progress`, `done`, `failed`

### Plan Lifecycle Strategy

After writing the plan, ask the user how to handle plan files after completion:

```
Plan files are stored in {cypilot_path}/.plans/{task-slug}/.
How should completed plans be handled?

  [1] .gitignore — add .plans/ to .gitignore (some editors block gitignored files)
  [2] Cleanup phase — add a final phase that deletes plan files after all phases pass
  [3] Archive — move completed plans to {cypilot_path}/.plans/.archive/ (gitignored)
  [4] Keep as-is — leave plan files in place, user manages manually
```

Record the user's choice in `plan.toml`:

```toml
[plan]
# ... other fields ...
lifecycle = "gitignore"  # or "cleanup", "archive", "manual"
```

**If `gitignore`**: append `.plans/` to `.gitignore` (or create it). All plan files become invisible to git and some editors.
**If `cleanup`**: add a final phase (N+1) titled "Cleanup" that deletes the plan directory after verifying all phases passed.
**If `archive`**: do NOT gitignore `.plans/` — plan files must remain accessible to editors during execution. After all phases complete, move the plan directory to `{cypilot_path}/.plans/.archive/{task-slug}/` and add only `.plans/.archive/` to `.gitignore`.
**If `manual`**: do nothing — user is responsible for cleanup.

Report plan summary to user:

```
Plan created: {cypilot_path}/.plans/{task-slug}/
  Phases: {N}
  Files: plan.toml + {N} phase files
  Lifecycle: {choice}
```

### New-Chat Startup Prompt

After reporting the summary, generate a **copy-pasteable prompt** that the user can paste into a fresh chat to start execution. This is critical because plan generation may exhaust the current context window.

Output the prompt inside a **single fenced code block** so the user can copy it in one click:

````
To start execution, open a new chat and paste this prompt:
````

Then output:

````markdown
```
I have a Cypilot execution plan ready at:
  {cypilot_path}/.plans/{task-slug}/plan.toml

Please read the plan manifest, then execute Phase 1.
The phase file is self-contained — follow its instructions exactly.
After completion, report results and generate the prompt for Phase 2.
```
````

The entire prompt MUST be inside a single ` ``` ` code fence — no text mixed in. This makes it trivially copy-pasteable from any chat UI.

---

## Phase 5: Execute Phases

When the user requests phase execution:

### 5.1 Load Phase

1. Read `plan.toml` to find the next pending phase (respecting dependencies)
2. Update phase status to `in_progress` in `plan.toml`
3. Read the phase file
4. Follow the phase file instructions exactly — it is self-contained

### 5.2 Execute

The phase file contains everything needed. Follow its Task section step by step.

### 5.3 Save Intermediate Results

After completing the Task but before reporting:

1. Check `plan.toml` for this phase's `outputs` list
2. Verify each output file was created/updated during execution
3. If any output is missing, flag it in the report as a failure

Intermediate results in `out/` serve as the **data contract** between phases. If a phase fails to produce its declared outputs, dependent phases cannot execute.

### 5.4 Report

After completing the phase, produce the completion report in the format specified by the phase file's Output Format section.

### 5.5 Update Status

Update `plan.toml`:
- If all acceptance criteria pass: set status to `done`
- If any criterion fails: set status to `failed`, record the failure reason

```toml
[[phases]]
number = 1
title = "PRD Overview and Actors"
file = "phase-01-overview.md"
status = "done"
depends_on = []
completed = "2026-03-12T14:30:00Z"
```

### 5.6 Phase Handoff

> **Note**: If the phase file's Output Format section already included a handoff prompt (compiled from plan-template.md Section 9), this step is already done — do NOT generate a duplicate. This step is a fallback for phase files compiled before the handoff prompt was added to the template.

After reporting phase results, generate a **copy-pasteable prompt** for the next phase. This allows the user to continue in the same chat or start a fresh one if context is running low.

First output the status line as plain text:

````
Phase {N}/{M}: {status}

Next phase prompt (copy-paste into new chat if needed):
````

Then output the prompt inside a **single fenced code block**:

````markdown
```
I have a Cypilot execution plan at:
  {cypilot_path}/.plans/{task-slug}/plan.toml

Phase {N} is complete ({status}).
Please read the plan manifest, then execute Phase {N+1}: "{title}".
The phase file is: {cypilot_path}/.plans/{task-slug}/phase-{NN}-{slug}.md
It is self-contained — follow its instructions exactly.
After completion, report results and generate the prompt for Phase {N+2}.
```
````

The entire prompt MUST be inside a single ` ``` ` code fence — no text mixed in. Then ask:

````
Continue in this chat? [y/n]
````

**If last phase**: instead of a next-phase prompt, report plan completion and execute the lifecycle strategy (cleanup/archive/manual per `plan.toml` setting).

---

## Phase 6: Check Status

When the user asks for plan status:

1. Read `plan.toml`
2. Report:

```
Plan: {task description}
  Type: {type}
  Target: {target}
  Progress: {done}/{total} phases

  Phase 1: {title} — {status}
  Phase 2: {title} — {status}
  ...
  Phase N: {title} — {status}
```

If the plan has failed phases, suggest:
- Retry: "Retry phase {N}" — re-execute the failed phase
- Skip: "Skip phase {N}" — mark as skipped and continue (if no dependencies)
- Abort: "Abort plan" — stop execution

---

## Plan Storage Format

All plan data lives in `{cypilot_path}/.plans/{task-slug}/`:

```
.plans/
  generate-prd-myapp/
    plan.toml                    # Plan manifest with phase metadata
    phase-01-overview.md         # Self-contained phase file
    phase-02-requirements.md     # Self-contained phase file
    phase-03-usecases.md         # Self-contained phase file
    phase-04-synthesis.md        # Self-contained phase file
    out/                         # Intermediate results between phases
      phase-01-actors.md         # Actor list extracted in phase 1
      phase-01-id-scheme.md      # ID naming scheme decided in phase 1
      phase-02-req-ids.md        # Requirement IDs generated in phase 2
```

**Naming conventions**:
- Task slug: `{type}-{artifact_kind}-{project_slug}` (e.g., `generate-prd-myapp`)
- Phase file: `phase-{NN}-{slug}.md` where NN is zero-padded (01, 02, ...)
- Plan manifest: always `plan.toml`

**Cleanup**: Plan directories are ephemeral. The lifecycle strategy (set during plan creation) determines what happens after completion — see Phase 4.

---

## Execution Log

During plan generation and execution, maintain a brief log for observability:

```
[plan] Assessing scope: generate PRD for myapp
[plan] Estimated size: ~1200 lines → plan needed
[plan] Strategy: generate (by template sections)
[plan] Decomposition: 4 phases
[plan] Compiling phase 1/4: Overview and Actors
[plan] Phase 1 compiled: 380 lines (within budget)
[plan] Compiling phase 2/4: Requirements
[plan] Phase 2 compiled: 420 lines (within budget)
[plan] ...
[plan] Plan written: .plans/generate-prd-myapp/ (4 phases)
[exec] Phase 1/4: in_progress
[exec] Phase 1/4: done (all criteria passed)
[exec] Phase 2/4: in_progress
...
```

This log is output to the user during execution, not saved to disk.
