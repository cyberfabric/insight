# Specification Registry — Readiness, Priority, and Status

> Version 1.1 — March 2026
>
> Single source of truth for everything authored in this repository: architecture documents, connector specifications, domain schemas, ADRs, and backlog. Use this file to understand what exists, what is in progress, and what is missing.

---

## Table of Contents

- [Legend](#legend)
- [Summary](#summary)
- [Architecture Documents](#architecture-documents)
  - [Product & Strategy](#product--strategy)
  - [Data Architecture](#data-architecture)
  - [Connector Architecture](#connector-architecture)
  - [Identity Resolution](#identity-resolution)
  - [Permissions & Security](#permissions--security)
- [Connectors with Existing Specs](#connectors-with-existing-specs)
  - [Git / Version Control](#git--version-control)
  - [Task Tracking](#task-tracking)
  - [Collaboration](#collaboration)
  - [Wiki / Knowledge Base](#wiki--knowledge-base)
  - [Support / Helpdesk](#support--helpdesk)
  - [HR / Directory](#hr--directory)
  - [CRM](#crm)
  - [AI Dev Tools](#ai-dev-tools)
  - [AI Tools (General)](#ai-tools-general)
  - [Design Tools](#design-tools)
  - [Quality / Testing](#quality--testing)
- [Backlog — Not Yet Started](#backlog--not-yet-started)
  - [P2 — High Priority](#p2--high-priority)
  - [P3 — Medium Priority](#p3--medium-priority)
  - [P4 — Situational](#p4--situational)
- [Open Questions Summary](#open-questions-summary)
- [In-Flight PRs](#in-flight-prs)

---

## Legend

### Spec Status

| Status | Meaning |
|--------|---------|
| `Proposed` | Spec is complete and stable. All Bronze tables defined, Silver mapping declared, OQs documented. Ready for implementation. |
| `Draft` | Spec exists but is incomplete — missing sections, unresolved structural questions, or schema not finalised. |
| `In PR` | Spec written, pull request open for review. Not yet merged to `main`. |
| `None` | No spec written. Connector is in the backlog only. |

### Domain Schema Status

The domain schema (domain `README.md`) defines the unified Silver `class_*` tables that all connectors in the domain feed into. A connector spec without a domain schema has no Silver target defined.

| Status | Meaning |
|--------|---------|
| `Ready` | Domain README merged with full `class_*` table definitions |
| `In PR` | Domain README written, PR open |
| `None` | No domain schema yet |

### Priority

| Priority | Meaning |
|----------|---------|
| **P1 — Core** | Required for basic analytics. Identity resolution depends on this, or key Silver streams cannot be populated without it. |
| **P2 — High** | High analytics value. Closes important gaps in an existing Silver stream or enables a new high-demand domain. |
| **P3 — Medium** | Solid value for specific use cases or teams. Build after P1/P2 coverage is stable. |
| **P4 — Situational** | Narrow audience or customer-specific. Build on request. |

---

## Summary

| Category | Count |
|----------|-------|
| Architecture documents (merged) | 7 |
| Architecture documents in open PR | 5 |
| Connectors with spec (Proposed or Draft) | 24 |
| Connectors with spec in open PR | 4 |
| Connectors in backlog (no spec) | 12 |
| Domain schemas ready | 4 (git, task-tracking, hr-directory, support) |
| Domain schemas in PR | 4 (collaboration, crm, wiki, design) |
| Open questions total | 62 |

---

## Architecture Documents

Documents that define platform-level design decisions, data models, and architectural constraints. These are the "why" behind the connector specs.

### Document Status

| Status | Meaning |
|--------|---------|
| `Current` | Authoritative. This is the version to read and implement against. |
| `Draft` | Incomplete or under active revision. Do not implement against. |
| `Superseded` | An older version. Kept for history; replaced by a newer document. |
| `In PR` | Written and submitted; not yet merged to `main`. |

---

### Product & Strategy

| Document | Status | Description |
|----------|--------|-------------|
| [`PRODUCT_SPECIFICATION.md`](architecture/PRODUCT_SPECIFICATION.md) | Draft | Platform vision, target users, use cases, NFRs, dashboard taxonomy. Non-engineering users (Sales/Marketing/Ops) added March 2026. |

**Gaps**: No roadmap document. No OKRs or success metrics defined. Product spec is a single file — consider splitting into PRD (what) + Architecture (how) as it grows.

---

### Data Architecture

| Document | Status | Description |
|----------|--------|-------------|
| [`STORAGE_TECHNOLOGY_EVALUATION.md`](architecture/STORAGE_TECHNOLOGY_EVALUATION.md) | Current | Evaluation of ClickHouse vs MariaDB ColumnStore vs PostgreSQL+TimescaleDB. **Decision: ClickHouse.** |
| [`CONNECTORS_REFERENCE.md`](CONNECTORS_REFERENCE.md) | Current | Canonical Bronze table schemas for all sources, Bronze→Silver→Gold pipeline overview. v2.13. |
| [`CONNECTORS_ARCHITECTURE.md`](architecture/CONNECTORS_ARCHITECTURE.md) | Current | Medallion architecture design, custom fields pattern (`_ext` + `Map(String,*)`), cross-domain join patterns, SDK design principles. |
| [`CONNECTOR_AUTOMATION.md`](architecture/CONNECTOR_AUTOMATION.md) | In PR (#17) | What can and cannot be automated in connector development. Bronze/Silver as automation boundary. AI-assisted Silver mapping and Onboarding UI concept. |

**Gaps**: No Silver layer design document for the platform as a whole (only per-domain READMEs). No Gold layer spec — metric definitions, aggregation logic, and dashboard feed contracts are unwritten. No SLA/data freshness spec.

---

### Connector Architecture

Domain schemas define the unified Silver `class_*` tables. Each domain README is both a specification and a contract for the connectors feeding it.

| Document | Domain | Status | Silver Streams |
|----------|--------|--------|----------------|
| [`connectors/git/README.md`](connectors/git/README.md) | Git | Draft | `class_git_commits`, `class_git_pull_requests`, `class_git_reviews` |
| [`connectors/task-tracking/README.md`](connectors/task-tracking/README.md) | Task Tracking | In PR (#10) | `class_issues`, `class_issue_activities`, `class_sprints` |
| [`connectors/collaboration/README.md`](connectors/collaboration/README.md) | Collaboration | In PR (#11) | `class_communication_metrics`, `class_meetings` |
| [`connectors/wiki/README.md`](connectors/wiki/README.md) | Wiki | In PR (#16) | `class_wiki_pages`, `class_wiki_activity` |
| [`connectors/support/README.md`](connectors/support/README.md) | Support | In PR (#17) | `class_support_activity` |
| [`connectors/hr-directory/README.md`](connectors/hr-directory/README.md) | HR / Directory | In PR (#13) | `class_people` (SCD Type 2), `class_org_units` (SCD Type 2) |
| [`connectors/crm/README.md`](connectors/crm/README.md) | CRM | In PR (#9) | `class_crm_activities`, `class_deals`, `class_contacts` |
| [`connectors/design/README.md`](connectors/design/README.md) | Design | In PR (#17) | `class_design_activity` |

**Missing domain schemas** (no README written yet):

| Domain | Silver Stream | Priority |
|--------|---------------|----------|
| AI Dev Tools (`ai-dev/`) | `class_ai_dev_usage` | P2 — all 4 connectors exist but no unified schema |
| AI Tools (`ai/`) | `class_ai_tool_usage`, `class_ai_api_usage` | P2 — 4 connectors, no unified schema |
| Quality / Testing (`quality/`) | `class_test_execution` | P2 — Allure spec exists; needed for TestRail addition |
| CI/CD | `class_cicd_runs` | P2 — Jenkins backlog item; new domain |
| Code Quality | `class_code_quality` | P2 — SonarQube + Snyk backlog; new domain |
| Employee Engagement | `class_engagement` | P3 — Peakon backlog; new domain |
| Learning & Development | `class_learning` | P3 — Udemy/Pluralsight backlog; new domain |
| Finance / ERP | `class_financials` | P3 — Acumatica/1C backlog; new domain |

---

### Identity Resolution

Identity Resolution has three versions in the repository simultaneously — understanding which is authoritative matters.

| Document | Version | Status | Notes |
|----------|---------|--------|-------|
| [`IDENTITY_RESOLUTION_V2.md`](architecture/IDENTITY_RESOLUTION_V2.md) | v2 | Superseded | Original conceptual architecture. 1421 lines. Replaced by v3. Keep for historical context. |
| [`IDENTITY_RESOLUTION_V3.md`](architecture/IDENTITY_RESOLUTION_V3.md) | v3 | Current | Canonical architecture. 4899 lines. Covers SCD Type 2, Bronze contract, resolver pipeline, `person_golden` table, fallback chain. Implement against this version. |
| [`EXAMPLE_IDENTITY_PIPELINE.md`](architecture/EXAMPLE_IDENTITY_PIPELINE.md) | — | Current | Step-by-step walkthrough of the v3 pipeline with concrete examples. Companion to v3. |
| `IDENTITY_RESOLUTION_V4.md` | v4 | In PR (#14) | Architectural integrity overhaul by external contributor. Not yet reviewed or merged. |

**Versioning situation**: v3 is current and authoritative. v4 is a proposed overhaul in PR #14 from an external contributor — requires review to determine whether it supersedes v3 or introduces breaking changes. Do not implement against v4 until PR #14 is resolved.

**Gaps**: Identity Resolution v3 defines the resolver pipeline in detail but does not enumerate per-source identity rules (which field, which fallback strategy). These are scattered across individual connector specs as OQs (OQ-JIRA-1, OQ-HS-1, OQ-YT-2). A consolidated identity rules registry would reduce duplication.

---

### Permissions & Security

| Document | Status | Description |
|----------|--------|-------------|
| `permissions/PERMISSION_PRD.md` | In PR (#12) | Permission system requirements — role-based access, multi-tenant scope, data sensitivity levels. |
| `permissions/PERMISSION_DESIGN.md` | In PR (#12) | Technical design — Role + Explicit Scope Grant model (chosen over ABAC). `workspace_id` predicate injection via `DataScopeFilter`. |
| `permissions/ADR_001_ROLE_SCOPE_GRANT.md` | In PR (#12) | ADR: why Role + Explicit Scope Grant over pure ABAC. |
| `permissions/ADR_002_WORKSPACE_ISOLATION.md` | In PR (#12) | ADR: why `workspace_id` predicate injection over schema-per-tenant or DB-per-tenant. |

**Decision summary** (from PR #12, pending merge):
- Permission model: Role + Explicit Scope Grant
- Tenant isolation: `workspace_id` predicate injection, not schema/DB-per-tenant
- Both decisions are ADR-backed

**Gaps**: No API security spec. No data classification policy (what is PII, what requires masking). Privacy decisions for individual connectors (e.g., Zulip message text) are documented per-spec but there is no platform-wide data sensitivity policy document.

---

## Connectors with Existing Specs

### Git / Version Control

**Domain schema**: `git/README.md` — `Draft` (merged)
**Silver streams**: `class_git_commits`, `class_git_pull_requests`, `class_git_reviews`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| GitHub | [`git/github.md`](connectors/git/github.md) | Proposed | P1 | OQ-GH-1, OQ-GH-2, OQ-GH-3 | Primary git source. |
| Bitbucket | [`git/bitbucket.md`](connectors/git/bitbucket.md) | Proposed | P1 | OQ-BB-1, OQ-BB-2, OQ-BB-3 | Self-hosted at Virtuozzo. |
| GitLab | [`git/gitlab.md`](connectors/git/gitlab.md) | Draft | P2 | OQ-GL-1, OQ-GL-2 | Not used at Virtuozzo; common elsewhere. |

**Gaps**: Domain README is Draft — needs Silver stream finalisation. OQ-GIT-1, OQ-GIT-2, OQ-GIT-3 are cross-source questions on the unified schema.

---

### Task Tracking

**Domain schema**: `task-tracking/README.md` — `In PR` (#10)
**Silver streams**: `class_issues`, `class_issue_activities`, `class_sprints`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| YouTrack | [`task-tracking/youtrack.md`](connectors/task-tracking/youtrack.md) | Proposed | P1 | OQ-YT-1, OQ-YT-2, OQ-YT-3 | Primary at Virtuozzo. OQ-YT-2: author_id is `"1-234"` string, not UInt64. OQ-YT-3: story points field name is instance-specific. |
| Jira | [`task-tracking/jira.md`](connectors/task-tracking/jira.md) | Proposed | P1 | OQ-JIRA-1, OQ-JIRA-2 | Two instances at Virtuozzo (`virtuozzo.atlassian.net`, `osystems.atlassian.net`). OQ-JIRA-1: email suppression in Atlassian privacy mode. |

**Gaps**: Domain schema in PR #10 — not merged. Story points field is instance-specific and must be configured per deployment (both YouTrack and Jira).

---

### Collaboration

**Domain schema**: `collaboration/README.md` — `In PR` (#11)
**Silver streams**: `class_communication_metrics`, `class_meetings`, `class_document_metrics`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| Microsoft 365 | [`m365.md`](connectors/m365.md) ¹ | Proposed | P1 | — | Primary at Virtuozzo. Covers email, calendar, Teams, OneDrive activity. Data retention: 7–30 days depending on report type. |
| Zulip | [`zulip.md`](connectors/zulip.md) ¹ | Proposed | P2 | OQ-ZUL-1, OQ-ZUL-2 | Used at Virtuozzo. Message text excluded (privacy). |
| Slack | `collaboration/slack.md` | In PR (#16) | P1 | — | Most common enterprise messaging platform. |
| Zoom | — | Draft (README ref) | P2 | — | Meeting activity; joins to `class_meetings` alongside M365 calendar. |

¹ Currently at root `docs/connectors/` — will move to `collaboration/` subfolder when PR #11 merges.

**Gaps**: Domain schema in PR #11. Zoom spec is referenced in README but file not present on `main`. `class_document_metrics` stream is planned but not fully defined.

---

### Wiki / Knowledge Base

**Domain schema**: `wiki/README.md` — `In PR` (#16)
**Silver streams**: `class_wiki_pages`, `class_wiki_activity`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| Confluence | `wiki/confluence.md` | In PR (#16) | P1 | — | Virtuozzo primary wiki. Atlassian Cloud. |
| Outline | `wiki/outline.md` | In PR (#16) | P2 | — | Open-source alternative; common in self-hosted setups. |

**Gaps**: Both spec and domain schema in PR #16 — not merged. No connectors for this domain are on `main` yet.

---

### Support / Helpdesk

**Domain schema**: `support/README.md` — `In PR` (#17)
**Silver streams**: `class_support_activity`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| Zendesk | [`support/zendesk.md`](connectors/support/zendesk.md) | Draft | P2 | OQ-ZD-1, OQ-ZD-2, OQ-ZD-3 | Primary support tool at Virtuozzo. OQ-ZD-1: CSAT score availability. OQ-ZD-2: SLA breach events. |
| Jira Service Management (JSM) | [`support/jsm.md`](connectors/support/jsm.md) | Draft | P2 | OQ-JSM-1, OQ-JSM-2, OQ-JSM-3, OQ-JSM-4 | Atlassian-native alternative to Zendesk. 4 open questions around SLA and ITSM-specific fields. |

**Gaps**: Domain schema in PR #17. Both connector specs are `Draft` — need Silver stream mapping review once domain README merges. `class_support_activity` covers MTTR, SLA compliance, CSAT, and first-response time.

**Note on OQ-SUP-1..3**: Cross-source open questions on unified SLA representation and ticket escalation modelling.

---

### HR / Directory

**Domain schema**: `hr-directory/README.md` — `In PR` (#13)
**Silver streams**: `class_people` (SCD Type 2), `class_org_units` (SCD Type 2)

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| BambooHR | [`hr-directory/bamboohr.md`](connectors/hr-directory/bamboohr.md) | Proposed | P1 | OQ-BHR-1, OQ-BHR-2 | Primary HRIS at Virtuozzo. Feeds `class_people` and `class_org_units`. Custom fields → `bamboohr_employee_ext`. |
| Workday | [`hr-directory/workday.md`](connectors/hr-directory/workday.md) | Proposed | P2 | OQ-WD-1, OQ-WD-2 | Enterprise HRIS. Complex API (SOAP/REST hybrid). Custom fields → `workday_worker_ext`. |
| LDAP / Active Directory | [`hr-directory/ldap.md`](connectors/hr-directory/ldap.md) | Proposed | P2 | OQ-LDAP-1, OQ-LDAP-2 | Fallback identity source when no cloud HRIS. Read-only directory sync. |
| OKTA | — | None | P2 | — | SSO gateway; authoritative user list. Identity Resolution fallback when BambooHR data is incomplete. Also provides MFA compliance and app access signals. **Tier 1 backlog item.** |

**Gaps**: Domain schema (class_people + class_org_units SCD Type 2 design) in PR #13. OKTA has no spec — high priority given its role in Identity Resolution.

---

### CRM

**Domain schema**: `crm/README.md` — `In PR` (#9)
**Silver streams**: `class_crm_activities`, `class_deals`, `class_contacts`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| HubSpot | [`crm/hubspot.md`](connectors/crm/hubspot.md) | Proposed | P2 | OQ-HS-1, OQ-HS-2 | OQ-HS-1: contacts are external customers — must NOT resolve to `person_id`. OQ-HS-2: `hs_call_disposition` is a GUID, requires separate lookup call. |
| Salesforce | [`crm/salesforce.md`](connectors/crm/salesforce.md) | Proposed | P2 | OQ-SF-1, OQ-SF-2 | Full CRM including CPQ. OQ-SF-1: opportunity stage normalisation. OQ-SF-2: activity owner attribution. |

**Gaps**: Domain schema in PR #9. OQ-CRM-1 (is_won derivation from pipeline stages), OQ-CRM-3 (stage normalisation) are unresolved cross-source questions. Both connectors have `_ext` Bronze tables for custom fields.

---

### AI Dev Tools

**Domain schema**: none (no unified `ai-dev/README.md`)
**Silver streams**: `class_ai_dev_usage` (per-developer AI coding assistant metrics)

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| GitHub Copilot | [`ai-dev/github-copilot.md`](connectors/ai-dev/github-copilot.md) | Proposed | P2 | OQ-COP-1, OQ-COP-2 | Seat-based; acceptance rate, active users. No per-suggestion data via API. |
| Cursor | [`ai-dev/cursor.md`](connectors/ai-dev/cursor.md) | Proposed | P2 | OQ-CUR-1, OQ-CUR-2 | Used at Virtuozzo. Usage telemetry API availability TBC. |
| JetBrains AI | [`ai-dev/jetbrains.md`](connectors/ai-dev/jetbrains.md) | Draft | P2 | OQ-JB-1, OQ-JB-2, OQ-JB-3 | JetBrains AI Enterprise (on-prem licence server). OQ-JB-1: API endpoint for usage data not publicly documented. |
| Windsurf | [`ai-dev/windsurf.md`](connectors/ai-dev/windsurf.md) | Proposed | P3 | OQ-WS-1, OQ-WS-2 | Smaller market share; API availability uncertain. Same Silver stream as Cursor/Copilot. |
| Zencoder | — | None | P3 | — | AI coding assistant, same category. Feed into `class_ai_dev_usage`. API availability needs verification. |

**Gaps**: No unified domain schema for `ai-dev/` — all connectors map to `class_ai_dev_usage` by convention. Claude Code is NOT a separate connector — usage is absorbed into `claude-api.md` or `claude-team.md` depending on billing mode.

---

### AI Tools (General)

**Domain schema**: none
**Silver streams**: `class_ai_tool_usage` (chat-based AI tools), `class_ai_api_usage` (API-based AI consumption)

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| Claude Team | [`ai/claude-team.md`](connectors/ai/claude-team.md) | Proposed | P2 | OQ-CT-1, OQ-CT-2 | claude.ai Team plan. Per-user usage metrics. |
| Claude API | [`ai/claude-api.md`](connectors/ai/claude-api.md) | Proposed | P2 | OQ-CAPI-1, OQ-CAPI-2 | Anthropic API usage. Includes Claude Code in API-key mode. |
| ChatGPT Team | [`ai/chatgpt-team.md`](connectors/ai/chatgpt-team.md) | Proposed | P2 | OQ-CGT-1, OQ-CGT-2 | OpenAI Team plan. Per-user active days and message counts. |
| OpenAI API | [`ai/openai-api.md`](connectors/ai/openai-api.md) | Proposed | P3 | OQ-OAPI-1, OQ-OAPI-2 | OpenAI API usage. Maps to `class_ai_api_usage`. |

**Gaps**: No domain schema. AI Tool adoption is a growing analytics domain — a unified `ai/README.md` with `class_ai_tool_usage` and `class_ai_api_usage` definitions is missing.

---

### Design Tools

**Domain schema**: `design/README.md` — `In PR` (#17)
**Silver streams**: `class_design_activity`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| Figma | [`design/figma.md`](connectors/design/figma.md) | Draft | P2 | OQ-FIGMA-1, OQ-FIGMA-2, OQ-FIGMA-3 | Primary design tool at Virtuozzo. OQ-FIGMA-1: activity API granularity. OQ-DESIGN-1..4 are cross-source domain questions. |

**Gaps**: Domain schema in PR #17. Only one connector in this domain currently — schema will expand when other design tools (Adobe XD, Sketch) are added.

---

### Quality / Testing

**Domain schema**: none (Allure is a standalone spec without a domain README)
**Silver streams**: `class_test_execution` (automated), `class_test_runs`

| Connector | Spec | Spec Status | Priority | Open Questions | Notes |
|-----------|------|-------------|----------|----------------|-------|
| Allure TestOps | [`allure.md`](connectors/allure.md) | Proposed | P2 | OQ-AL-1, OQ-AL-2 | Automated test execution. Joins to `task-tracking` via `external_issue_id`. |
| TestRail | — | None | P2 | — | Manual QA. Same Silver stream as Allure (`class_test_execution`). **Tier 1 backlog item** for Virtuozzo — covers manual testing workflow. |

**Gaps**: No domain schema for `quality/` — needed to align Allure and TestRail into a unified stream. `class_test_execution` covers both automated (Allure) and manual (TestRail) test results.

---

## Backlog — Not Yet Started

Connectors with no spec written. Ordered by priority within each tier.

### P2 — High Priority

These connectors close significant gaps in existing analytics domains or are required for Virtuozzo customer deployment.

| Connector | Domain | Silver Stream | Rationale | Blocker / Dependency |
|-----------|--------|---------------|-----------|---------------------|
| **Jenkins** (×5 instances) | CI/CD | `class_cicd_runs` (new) | DORA metrics: deployment frequency, lead time, change failure rate, MTTR. Closes the gap between git commits and actual deployments. Five self-hosted instances — each is a separate `source_instance_id`. | Requires new `class_cicd_runs` Silver schema. |
| **SonarQube** | Code Quality | `class_code_quality` (new) | Technical debt, test coverage, security hotspot density — per repo and per team. Joins to `git_repositories` by repo name. Self-hosted at `sonarqube.vzint.dev`. | Requires new `class_code_quality` Silver schema. |
| **TestRail** | Quality / Testing | `class_test_execution` | Manual QA coverage. Complements Allure (automated). Same Silver stream — just another `data_source` value. | Needs `quality/README.md` domain schema aligned with Allure. |
| **OKTA** | HR / Identity | `class_people` (enrichment) | Authoritative user directory independent of BambooHR. SSO gateway = every active employee has an OKTA account. Identity Resolution fallback + MFA compliance signal + app access map. | Fits into `hr-directory/` domain; supplements `class_people`. |
| **Peakon** | HR / Engagement | `class_engagement` (new) | Employee engagement scores (eNPS, driver scores, response rates) per team per survey round. Leading indicator of attrition risk. Joins to `class_people` via email. | Requires new `class_engagement` Silver schema. BambooHR connector should be merged first. |

### P3 — Medium Priority

Solid analytics value for specific domains. Build after P1/P2 coverage is stable.

| Connector | Domain | Silver Stream | Rationale |
|-----------|--------|---------------|-----------|
| **Google G-Suite** | Collaboration | `class_communication_metrics` | Not all employees use M365 — IT and Finance at some customers use Google. Same Silver stream as M365 via Google Workspace Reports API. |
| **Snyk** | Code Quality | `class_code_quality` | Security vulnerability scanning per repo. Adds security debt dimension to SonarQube's quality view. Best after SonarQube schema is defined. |
| **Udemy Business** | L&D | `class_learning` (new) | Course completion rate and learning hours per employee. L&D gap in current HR analytics. |
| **Pluralsight / Cloud Guru** | L&D | `class_learning` | Same Silver stream as Udemy — both feed learning metrics. Build together for a unified L&D view. |
| **ADP US** | HR / Payroll | `class_people` (enrichment) | Employment type, pay group, cost centre for US employees. Enriches `class_people` where BambooHR coverage is incomplete. Sensitive PII — requires careful access controls. |
| **ADP Streamline** | HR / Payroll | `class_people` (enrichment) | Same as ADP US but for EMEA payroll. |
| **Acumatica** | Finance / ERP | `class_financials` (new) | Cost centre hierarchy, budget per department, project cost allocations. Enables revenue-per-headcount and labour-cost-per-team metrics. Joins to `class_people` via department. |
| **1C** | Finance / ERP | `class_financials` | Same analytical purpose as Acumatica for EMEA/CIS entities. No standard REST API — custom integration required. |
| **Amplemarket** | CRM / Sales | `class_crm_activities` | Outbound sales engagement (sequences, email sends, call attempts). High-frequency signal complementing Salesforce logged activity. |
| **Zencoder** | AI Dev Tools | `class_ai_dev_usage` | AI coding assistant, same category as Cursor/JetBrains. No new Silver schema needed. |

### P4 — Situational

Narrow audience or limited cross-team analytics value. Build on explicit customer request.

| Connector | Domain | Rationale |
|-----------|--------|-----------|
| **KnowBe4** | Compliance | Security training completion rate. Compliance metric, not productivity signal. |
| **Pardot** | Marketing | Marketing campaign performance per rep. Siloed — does not join to HR or engineering data. |
| **BetterStack** | Ops / SRE | On-call incident log, uptime monitoring. Relevant for SRE workload tracking but niche. |
| **LinkedIn** | Marketing / Sales | Organic post engagement metrics. No per-person productivity model; Sales Navigator API is restrictive. |
| **Semrush** | Marketing | SEO metrics. No per-person attribution. |
| **Consensus** | Sales Enablement | Demo content engagement per prospect. Sales enablement metric, not rep productivity. |

---

## What's Missing

Key gaps across the entire specification — documents and decisions that don't exist yet and are needed for the platform to be implementable.

| Gap | Area | Impact |
|-----|------|--------|
| Gold layer spec | Architecture | Metric definitions, aggregation logic, and dashboard feed contracts are unwritten. Gold is where analytics value is delivered — nothing for analytics engineers to implement against. |
| `ai-dev/README.md` domain schema | Connector | 4 AI dev connectors exist but the unified Silver stream is not formally defined. |
| `ai/README.md` domain schema | Connector | 4 AI tool connectors exist but no unified schema. |
| `quality/README.md` domain schema | Connector | Allure spec exists; no domain schema to align Allure + TestRail. |
| Identity rules registry | Identity | Per-source identity rules (field, fallback, exclusions) are scattered across 62 connector OQs. No consolidated view of how each source resolves to `person_id`. |
| Data classification policy | Privacy | Privacy decisions per connector exist ad-hoc (Zulip message text excluded, etc.). No platform-wide policy defining PII categories, masking rules, and data sensitivity levels. |
| API specification | Platform | No API spec for the Insight platform itself — how Gold data is queried, authenticated, and paginated by dashboard consumers. |
| Silver layer overview | Architecture | Individual domain READMEs define their `class_*` tables. No document gives a complete picture of all Silver streams, their relationships, and the join keys between them. |
| Connector SDK spec | Platform | `CONNECTOR_AUTOMATION.md` describes what the SDK should do; there is no specification of what it actually does — its APIs, the `connector.yaml` schema, and the `BaseConnector` interface. |
| Onboarding UI spec | Platform | `CONNECTOR_AUTOMATION.md` §7 describes the AI-assisted onboarding concept. No UX spec, wireframes, or functional requirements document. |
| PR #3 resolution | Architecture | The "Streams Proposal" PR (#3, `constructor-streams` branch) defines an alternative Bronze schema for git, M365, YouTrack, Zulip, and Cursor using a `streams/` folder structure. It has been open since February 2026 and conflicts with the current `connectors/` approach. Needs a decision: merge, close, or extract useful parts. |
| PR #14 resolution | Identity | Identity Resolution V4 is an architectural overhaul from an external contributor. Needs review to determine if it supersedes v3 or introduces breaking changes before any Identity Resolution work begins. |

---

## Open Questions Summary

Open questions that block or constrain spec finalisation. Full OQ text is in the individual connector spec files.

### Blocking — must resolve before implementation

| OQ | Connector | Issue |
|----|-----------|-------|
| OQ-YT-2 | YouTrack | `author_id` format is `"1-234"` (string), not numeric. Silver table type TBC. |
| OQ-YT-3 | YouTrack | Story points custom field name is instance-specific. Must be configured per deployment. |
| OQ-JIRA-1 | Jira | Email may be suppressed by Atlassian privacy settings. Fallback identity strategy not defined. |
| OQ-HS-1 | HubSpot | `hubspot_contacts` = external customers. Must not resolve to `person_id`. Resolution exclusion rule not yet encoded. |
| OQ-CRM-1 | HubSpot | `is_won` / `is_closed` require separate pipeline stage API call — not in deal object. |
| OQ-JSM-1..4 | JSM | Four unresolved questions around SLA breach events, ITSM-specific fields, and multi-tier SLA representation. |

### Non-blocking — document and revisit

| OQ | Connector | Issue |
|----|-----------|-------|
| OQ-GH-1..3 | GitHub | API rate limits for large orgs; GHES version compatibility; secret scanning events scope. |
| OQ-BB-1..3 | Bitbucket | Self-hosted vs Cloud API differences; workspace vs project permission model. |
| OQ-ZD-1..3 | Zendesk | CSAT response rate API availability; SLA breach event structure; multi-brand setup. |
| OQ-HS-2 | HubSpot | `hs_call_disposition` is a GUID — needs separate lookup to `call-dispositions` endpoint. |
| OQ-CRM-3 | CRM (cross) | Deal stage normalisation across HubSpot and Salesforce — no universal vocabulary. |
| OQ-JB-1..3 | JetBrains | AI usage API not publicly documented; licence server required for self-hosted. |
| OQ-FIGMA-1..3 | Figma | Activity API granularity; file version event completeness; org-level vs team-level scoping. |
| OQ-LDAP-1..2 | LDAP | Schema varies between AD and OpenLDAP; attribute mapping must be configured per deployment. |
| OQ-WD-1..2 | Workday | API authentication is complex (OAuth + tenant-specific WSDL); field availability depends on Workday modules licensed. |

---

## In-Flight PRs

### Connector and domain schema PRs

| PR | Branch | Contents | Status |
|----|--------|----------|--------|
| [#9](https://github.com/cyberfabric/insight-spec/pull/9) | `feat/crm-unified-schema` | CRM domain schema (`crm/README.md`), HubSpot + Salesforce spec updates | Open |
| [#10](https://github.com/cyberfabric/insight-spec/pull/10) | `feat/task-tracking-unified-schema` | Task tracking domain schema (`task-tracking/README.md`), YouTrack + Jira spec updates | Open |
| [#11](https://github.com/cyberfabric/insight-spec/pull/11) | `feat/collaboration-unified-schema` | Collaboration domain schema, M365 + Zulip moved to `collaboration/` subfolder | Open |
| [#13](https://github.com/cyberfabric/insight-spec/pull/13) | `feat/hr-silver-design` | HR Silver Layer design (`class_people` + `class_org_units`, SCD Type 2) | Open |
| [#16](https://github.com/cyberfabric/insight-spec/pull/16) | `feat/slack-and-wiki` | Slack connector spec, Wiki domain schema, Confluence + Outline specs | Open |
| [#17](https://github.com/cyberfabric/insight-spec/pull/17) | `feat/connector-spec-improvements` | Support + Design domain schemas, JetBrains spec, `CONNECTOR_AUTOMATION.md` | Open |

### Architecture PRs

| PR | Branch | Contents | Status |
|----|--------|----------|--------|
| [#12](https://github.com/cyberfabric/insight-spec/pull/12) | `feat/permission-architecture` | Permission PRD, DESIGN, ADR-001 (Role+Scope Grant), ADR-002 (workspace isolation) | Open |
| [#14](https://github.com/cyberfabric/insight-spec/pull/14) | `Mitriyweb:main` | Identity Resolution V4 — architectural overhaul | Open — external; **needs review before merge** |

### Older / stalled PRs

| PR | Branch | Contents | Status |
|----|--------|----------|--------|
| [#15](https://github.com/cyberfabric/insight-spec/pull/15) | `maxcherey:main` | Git connector tables reclassification Bronze → Silver | Open — external |
| [#3](https://github.com/cyberfabric/insight-spec/pull/3) | `constructor-streams` | Alternative Bronze schema using `streams/` folder structure (git, M365, YouTrack, Zulip, Cursor) | Open since Feb 2026 — **needs decision: merge, close, or extract** |

### Recommended merge order

| Step | PR | Reason |
|------|----|--------|
| 1 | **#13** HR Silver | Foundational — `class_people` is the identity anchor for all other Silver streams |
| 2 | **#10** Task Tracking schema | No dependency; closes a gap in the most-used domain |
| 3 | **#9** CRM schema | No dependency |
| 4 | **#11** Collaboration schema | No dependency; relocates M365 + Zulip files |
| 5 | **#16** Slack + Wiki | Depends on #11 (adds to collaboration domain, extends wiki) |
| 6 | **#17** Support + Design + Architecture | Independent; `CONNECTOR_AUTOMATION.md` has no blockers |
| 7 | **#12** Permission architecture | Independent; foundational for API layer work |
| 8 | **#14** Identity Resolution V4 | Review against v3 first — may supersede or conflict |
| 9 | **#15** Git reclassification | External; touches merged specs — review separately |
| — | **#3** Streams Proposal | Needs explicit decision — do not merge without discussion |
