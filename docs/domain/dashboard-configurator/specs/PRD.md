# PRD — Dashboard Configurator

<!-- toc -->

- [Changelog](#changelog)
- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Metric Catalog Dependency](#51-metric-catalog-dependency)
  - [5.2 Dashboard Composition](#52-dashboard-composition)
  - [5.3 Rendering](#53-rendering)
  - [5.4 Seed and Migration](#54-seed-and-migration)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Admin Swaps a Bullet Section Widget](#uc-001-admin-swaps-a-bullet-section-widget)
  - [UC-002 Admin Adds a Role and a Role-Specific Dashboard](#uc-002-admin-adds-a-role-and-a-role-specific-dashboard)
  - [UC-003 Viewer Loads an IC Dashboard for a Person of Specific Role](#uc-003-viewer-loads-an-ic-dashboard-for-a-person-of-specific-role)
  - [UC-004 Team Lead Customizes Their Team Dashboard (Post-MVP)](#uc-004-team-lead-customizes-their-team-dashboard-post-mvp)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)
- [14. Current-State Gap Analysis (Backend)](#14-current-state-gap-analysis-backend)
  - [Present](#present)
  - [Missing — MVP](#missing--mvp)
  - [Missing — Post-MVP (`p2` features)](#missing--post-mvp-p2-features)
  - [Relevant Open Pull Requests](#relevant-open-pull-requests)
  - [Implementation Sequencing (informative)](#implementation-sequencing-informative)

<!-- /toc -->

## Changelog

- **v1.6** (current): Added a team-scoped threshold override FR (`cpt-dash-cfg-fr-team-threshold-scope`, `p2`) that lets team leads tweak their team's thresholds without touching other teams with the same role. Wired into the Metric Catalog PRD's extended scope model (`team + dashboard → team → dashboard → tenant → product-default`). Clarified that dashboard-scoped thresholds implicitly cover role because dashboards are keyed by `(view_type, role)`; no separate `role` scope was introduced on either side.
- **v1.5**: Extracted the Metric Catalog concern into a separate PRD (`docs/domain/metric-catalog/specs/PRD.md`). This PRD now consumes the catalog through the contract documented there and no longer owns catalog storage, threshold persistence, or the `GET /catalog/metrics` endpoint. Made the document tenant-neutral by removing tenant-specific identifiers from the body. Cleaned residual inconsistencies (role-taxonomy table name reconciled to `role_alias`; outdated "normalization TBD" in Out-of-Scope reconciled with the actual `cpt-dash-cfg-fr-role-source` + `cpt-dash-cfg-fr-role-alias` design).
- **v1.4**: Sharpened connector expectations — for tenants whose HR already exposes a job-role-equivalent field, the gap is a connector configuration step (adding the field alias to the HR connector's field list), not an HR-admin ask. Captured the current-state gap analysis against the backend: analytics-api lacks `dashboard` / `dashboard_widget` / `role_catalog` / `metric_catalog` tables; `Person` struct in both identity and analytics-api IR client carries only `job_title` and must add `job_role`; sequencing now references open PR #214 (MariaDB persons store) as the preferred landing point for the `job_role` column.
- **v1.3**: Replaced `job_title` parsing with a dedicated HR `job_role` attribute as the role source. Identity Resolution now surfaces `job_role` as a first-class structured field — no more pattern-matching over free-form job titles. Tenant onboarding includes wiring the HR-system `job_role` field into Identity Resolution.
- **v1.2**: Clarified per-user customization boundary — the role-default IC dashboard is immutable from the end user's perspective, preserving comparability across people with the same role. Any future per-user customization (pinning, personal "My View") lives on a separate surface that never replaces the role-default view that team leads and VPs see.
- **v1.1**: Split the "view type" concept (fixed: executive / team / IC) from the "professional role" concept (per-tenant taxonomy sourced from HR via Identity Resolution). Added per-tenant role taxonomy, role-aware resolution for team and IC views, executive-view role invariance, and post-MVP team-lead self-customization.
- **v1.0**: Initial PRD with a single conflated "role" concept.

## 1. Overview

### 1.1 Purpose

Dashboard Configurator enables Insight tenant admins to compose dashboards tailored to two orthogonal dimensions — a fixed set of **view types** (executive, team, individual-contributor) and an open, per-tenant taxonomy of **professional roles** (e.g., `backend-dev`, `frontend-dev`, `qa`) sourced from the tenant's HR system via Identity Resolution. It replaces the current hardcoded three-screen frontend with a database-driven composition where widget placement, metric metadata, and per-tenant thresholds live in MariaDB and are editable without a frontend deploy. Team leads can additionally customize their own team's dashboard (post-MVP) without involving the tenant admin for every change.

### 1.2 Background / Problem Statement

Insight today has three hardcoded dashboard screens — `ExecutiveViewScreen`, `TeamViewScreen`, `IcDashboardScreen`. Each is a React component with a fixed sequence of KPI strips, bullet sections, tables, and charts. Metric metadata (label, sublabel, unit, thresholds, `higher_is_better`) is duplicated between `src/screensets/insight/api/thresholdConfig.ts` on the frontend and `analytics.metrics.query_ref` on the backend. Adding a new role-specific view requires a frontend code change, and per-tenant threshold tuning requires a full FE deploy.

**Target Users**:

- Tenant admins tuning dashboards and maintaining the role taxonomy for their organization
- Team leads customizing their own team's dashboard (post-MVP)
- Insight product team seeding default dashboards per (view type, role) pair
- End users (executives, team leads, individual contributors) consuming dashboards that match both the view they selected and their professional role

**Key Problems Solved**:

- No path to ship a dashboard for a new role or tenant without frontend code
- Threshold and label changes require a redeploy instead of a configuration update
- Metric label and unit definitions drift between frontend and backend
- Computed KPIs (`at_risk_count`, `focus_gte_60`, `not_using_ai`, `team_dev_time`) live in frontend helpers and are invisible to admins tuning dashboards
- Professional role (backend vs frontend vs QA) has no expression in the current UI; every IC and every team sees the same widget set regardless of the function they actually perform

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Time-to-ship a new role-based dashboard falls from a frontend sprint to an admin CRUD session (Baseline: 1-2 week cycle; Target: same-day by end of rollout quarter)
- Zero frontend deploys required for threshold or label changes on existing metrics (Baseline: required for every change; Target: 0)
- Metric labels, units, formats, and thresholds resolved from a single MariaDB source (Baseline: duplicated between FE and BE; Target: BE only)
- Dashboard first-paint latency stays within 10% of the current hardcoded screens (Baseline: current p95 load time per view, captured at rollout; Target: ≤ 1.1× baseline)

**Capabilities**:

- Curate a catalog of metrics with label, unit, format, and source tag
- Define per-tenant metric thresholds for bullet color and alert triggers
- Compose dashboards from typed widgets bound to metric queries
- Assign dashboards as default for a role, or share across multiple roles
- Render any configured dashboard through a single frontend entry point

### 1.4 Glossary

| Term | Definition |
|------|------------|
| View type | One of three fixed data perspectives — `executive` (organization-wide rollup), `team` (team or org-unit aggregate), `ic` (individual contributor). Not user-configurable; the set is closed in code. |
| Role | A professional-function label (e.g., `backend-dev`, `frontend-dev`, `qa`, `devops`, `engineering-manager`) resolved for a person from the HR-system `job_role` attribute surfaced through Identity Resolution. Each tenant maintains its own role taxonomy. Explicitly **not** parsed from free-form `job_title` strings. |
| Job role (HR attribute) | A structured, function-level field on an HR record — distinct from the free-form `job_title`. Examples: BambooHR custom field, Workday "Job Profile", Okta attribute mirrored from the primary HR source. The tenant configures this field in their HR system during onboarding; Identity Resolution exposes its value verbatim as `person.job_role`. |
| Role taxonomy | The per-tenant catalog of valid role slugs, display names, and optional alias rows that reconcile raw HR `job_role` values to canonical slugs (e.g., "Backend Developer" and "Backend Engineer" both map to `backend-dev`). Bootstrapped by the product team with sensible defaults and editable by tenant admins. |
| Dashboard | A named composition of widgets scoped to a tenant and keyed by `(view_type, role)`. Executive dashboards have `role = null` (role-invariant). |
| Subject | The person or team whose data the dashboard is rendering. For IC view the subject is the viewed person; for team view the subject is the team. The subject's role — not the viewer's — drives dashboard selection for IC view. |
| Metric catalog | MariaDB table of `metric_key` → (`label_i18n_key`, `unit`, `format`, `source_tag`, `higher_is_better`, `is_member_scale`). One row per semantic metric, per tenant. |
| Metric query | MariaDB row in `analytics.metrics` carrying a UUID and a `query_ref` ClickHouse SQL string that returns rows annotated with one or more `metric_key` values. |
| Widget | A typed display unit (bullet section, KPI strip, trend chart, table, drill panel, hero strip) bound to a metric query and carrying type-specific JSON config. |
| Widget type | A React component plus a JSON schema for its config. Enumerated in code; DB stores only the type discriminator and the config blob. |
| Threshold scope | Either `tenant` (default per tenant) or `dashboard` (override for a specific dashboard); precedence is dashboard → tenant. |

## 2. Actors

### 2.1 Human Actors

#### Tenant Admin

**ID**: `cpt-dash-cfg-actor-tenant-admin`

**Role**: Curates dashboards for their tenant, defines the tenant's role taxonomy, assigns dashboards per `(view_type, role)` pair, tunes metric thresholds, previews changes before publishing.

**Needs**: CRUD on dashboards, widgets, thresholds, and role taxonomy without requiring a deploy; preview with real tenant data before publish; clear feedback when a widget config is invalid; the ability to bootstrap from a product-supplied default taxonomy and adapt it.

#### Team Lead

**ID**: `cpt-dash-cfg-actor-team-lead`

**Role**: Manages a specific team within the tenant. In MVP, consumes the team-view dashboard resolved for their team's role exactly like any other viewer. Post-MVP (`p2`), customizes the team's own dashboard — overriding widgets, reordering, adding team-scoped widgets — without involving the tenant admin for every change.

**Needs**: Ability to tweak a team dashboard without breaking the tenant default for other teams sharing the same role; visibility into which widgets are inherited vs overridden; revert-to-default option.

#### Insight Product Team

**ID**: `cpt-dash-cfg-actor-product-team`

**Role**: Ships default dashboards and seeds the metric catalog and the default role taxonomy that every new tenant starts with. Introduces new widget types by landing a backend enum entry plus a React component. Maintains the contract with Identity Resolution for consuming HR-provided role data.

**Needs**: Migration-based seed mechanism for catalog, dashboards, and default role taxonomy; explicit deprecation path for widget types that are being replaced; way to version metric query formulas without breaking live dashboards.

#### Dashboard Viewer

**ID**: `cpt-dash-cfg-actor-viewer`

**Role**: End user (executive, team lead, or individual contributor) consuming the dashboard resolved for the view they selected and the subject's role. Does not edit dashboards.

**Needs**: Fast first paint, graceful degradation when a metric source is unavailable (ComingSoon or em-dash, not fake zeros), stable deep links that survive dashboard composition changes, sensible fallback when the subject's role has no tailored dashboard.

### 2.2 System Actors

#### Analytics API

**ID**: `cpt-dash-cfg-actor-analytics-api`

**Role**: Serves dashboard composition (`GET /catalog/dashboards?view_type=...&role=...`), metric catalog (`GET /catalog/metrics`), role taxonomy (`GET /catalog/roles`), and metric query results (`POST /metrics/:uuid/query`). Validates widget config against registered widget-type schemas on save.

#### Identity Resolution Service

**ID**: `cpt-dash-cfg-actor-identity`

**Role**: The existing `insight-identity-resolution` service, upstream of the configurator. Returns per-person identity records including HR attributes — `job_title` (free-form), `job_role` (structured function field), `department`, `supervisor_email`, subordinates tree. The configurator reads **only `job_role`** for dashboard selection and treats `job_title` as display-only metadata. The upstream source varies by tenant (supported HR integrations include BambooHR, Okta, Workday, and Jira People); the configurator treats Identity Resolution as the single point of contact and does not integrate with raw HR systems directly. Onboarding wiring varies by tenant: when the HR source already has the field, the task is extending the connector configuration to fetch it; when it does not, the tenant's HR admin creates the field as part of Insight onboarding.

#### MariaDB Catalog

**ID**: `cpt-dash-cfg-actor-mariadb`

**Role**: Persists catalog tables (`metric_catalog`, `metric_threshold`), composition tables (`dashboard`, `dashboard_widget`), and role-taxonomy tables (`role_catalog`, `role_alias`). Provides referential integrity between widgets and metric queries, between dashboards and roles, and between aliases and role slugs.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

None beyond project defaults (React 18, Vite, TypeScript, `@hai3/react`, MariaDB, ClickHouse). Dashboard Configurator inherits the project runtime.

## 4. Scope

### 4.1 In Scope

- Three fixed view types (`executive`, `team`, `ic`) as a code-level enum — not tenant-configurable
- Per-tenant role taxonomy (`role_catalog` + `role_alias`) editable by tenant admins
- Dashboard composition tables keyed by `(view_type, role)` with `role = null` for executive
- Dashboard resolution API: given `(view_type, subject, viewer)` return the correct dashboard with fallback to the view-type default
- Backend `GET /catalog/roles` and `GET /catalog/dashboards` endpoints
- Widget-type enum with 7 initial types: `hero_strip`, `bullet_section`, `kpi_strip`, `trend_chart`, `members_table`, `drill_panel`, `coming_soon_banner`
- JSON schema validation of widget config on save
- Frontend `<DashboardRenderer>` component resolving composition to rendered widgets via `(view_type, subject)` instead of a slug
- Seed migration for default dashboards — one executive (role-invariant) plus a default team and default IC dashboard per seeded role in the default taxonomy
- Migration path replacing `ExecutiveViewScreen`, `TeamViewScreen`, `IcDashboardScreen` with thin `<DashboardRenderer view_type="...">` wrappers
- Dashboard-scoped threshold overrides (contributes the `scope = 'dashboard'` value into the catalog's `metric_threshold` store; does not own the store itself)
- Moving computed KPI chips (`at_risk_count`, `focus_gte_60`, `not_using_ai`, `team_dev_time`) from frontend `deriveTeamKpis` into backend `metric_query` rows

### 4.2 Out of Scope

- **Metric Catalog storage, tenant-scoped threshold persistence, and the `GET /catalog/metrics` endpoint** — owned by `docs/domain/metric-catalog/specs/PRD.md`. This PRD consumes the catalog; it does not define its schema or write semantics.
- Deletion of frontend metadata duplication (`BULLET_DEFS`, `IC_KPI_DEFS`, most of `METRIC_KEYS`) — owned by the Metric Catalog PRD's rollout; this PRD inherits the cleaned state but does not drive the deletion.
- Admin UI for CRUD operations — deferred to a follow-up PRD; this PRD covers the data model and rendering path for dashboards and roles, not the admin UI surface.
- Team-lead self-customization flows — tracked as `p2` in functional requirements; initial rollout has tenant admin as the only editor
- SQL authoring inside any future Admin UI — `metric_query.query_ref` stays managed by backend code migrations
- Parsing of free-form `job_title` strings to infer a role — the configurator reads the structured `job_role` HR attribute directly (see `cpt-dash-cfg-fr-role-source`) and never infers role from `job_title`. Alias reconciliation across `job_role` values happens per-tenant in `role_alias` (see `cpt-dash-cfg-fr-role-alias`).
- Per-user dashboard cloning or customization beyond team-lead scope
- Cross-tenant dashboard or role-taxonomy sharing
- Versioned snapshots of published dashboards (basic `is_published` flag only)
- Scheduled exports, PDF rendering, or email digests
- Mobile-specific layouts for configured dashboards
- Dynamic addition of new view types at runtime — the three view types are fixed by code; broadening requires a new PRD and frontend release
- **Per-user editing of the role-default IC dashboard — principled rejection, not a deferral.** End users **MUST NOT** be able to add, remove, or rearrange widgets on their own role-default IC dashboard. The view that a team lead or VP sees for an individual contributor **MUST** be identical to what the contributor sees. Side-by-side comparison across people in the same role stays meaningful only under this constraint. Relaxing it is out of scope in v1 and remains out of scope in any follow-up that does not separately rethink Insight's role as a management instrument.
- Per-user widget pinning, personal reorder, or "My View" personal workspace — out of scope for MVP; tracked as a potential follow-up in Open Questions. Any such feature would live on a **separate surface** alongside the role-default view, not replace it.

## 5. Functional Requirements

### 5.1 Metric Catalog Dependency

This PRD consumes metric metadata (labels, units, formats, thresholds, `higher_is_better`, `is_member_scale`, `source_tag`) from the Metric Catalog module defined in `docs/domain/metric-catalog/specs/PRD.md`. Catalog storage, tenant-scoped threshold persistence, and the `GET /catalog/metrics` endpoint are **not** owned by this PRD.

#### Consumes the Metric Catalog

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-consumes-catalog`

The system **MUST** hydrate widget-level metric metadata by calling `GET /catalog/metrics` (documented in `cpt-metric-cat-interface-read`) once per session or cache-TTL window, and **MUST NOT** carry local copies of metric labels, units, formats, or thresholds on the frontend. The system **MUST** degrade gracefully when a `metric_key` is absent from the catalog response — render as ComingSoon rather than erroring.

**Rationale**: Single source of truth. This PRD is the first consumer of the catalog; future consumers (alerting, reports) follow the same contract.

**Actors**: `cpt-dash-cfg-actor-viewer`, `cpt-dash-cfg-actor-analytics-api`

#### Dashboard-Scoped Threshold Overrides

- [ ] `p2` - **ID**: `cpt-dash-cfg-fr-dashboard-threshold-scope`

The system **SHOULD** support dashboard-scoped threshold overrides by writing rows into the catalog's `metric_threshold` store with `scope = 'dashboard'` and a `dashboard_id` reference. Because dashboards in this PRD are keyed by `(view_type, role)`, dashboard-scoped thresholds implicitly cover role-specific overrides — no separate `role` scope is needed. Resolution precedence is owned by the Metric Catalog PRD (`cpt-metric-cat-fr-scoped-thresholds`) and is `team + dashboard → team → dashboard → tenant → product-default`. This PRD contributes the `dashboard` scope value; it does not reimplement the resolution logic.

**Rationale**: Different dashboards aimed at different audiences within the same tenant may legitimately disagree on what "good" means; the catalog's scope model makes this expressible without forking metadata. Folding role into dashboard scope keeps the chain short.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`

#### Team-Scoped Threshold Overrides (Team Lead)

- [ ] `p2` - **ID**: `cpt-dash-cfg-fr-team-threshold-scope`

Together with `cpt-dash-cfg-fr-team-lead-customization`, the system **SHOULD** allow a team lead to write team-scoped threshold overrides for their own team by calling the catalog's threshold admin endpoints with `scope = 'team'` and `team_id` set. Authorization restricts these writes to the team lead of the target team. Resolution precedence is owned by the Metric Catalog PRD and is `team + dashboard → team → dashboard → tenant → product-default`.

**Rationale**: A team lead should be able to nudge their team's bar without touching other teams with the same role. Without this, team-lead customization is purely cosmetic (widget composition only) and the one number that actually controls the red/yellow/green of each widget stays locked.

**Actors**: `cpt-dash-cfg-actor-team-lead`

### 5.2 Dashboard Composition

#### Dashboards Persist as a Widget Table

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-dashboard-storage`

The system **MUST** persist dashboards with fields `id`, `tenant_id`, `slug`, `name_i18n_key`, `default_for_role_id`, and `is_published`. The system **MUST** persist widgets with fields `id`, `dashboard_id`, `widget_type`, `title_i18n_key`, `position`, and a `config` JSON column whose shape depends on `widget_type`.

**Rationale**: DB-driven composition is the prerequisite for removing hardcoded screens; every downstream capability (role mapping, admin CRUD, preview) depends on this storage layer.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`, `cpt-dash-cfg-actor-mariadb`

#### Widget Types Enumerated in Code with JSON Schemas

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-widget-type-enum`

The system **MUST** define `widget_type` as an enum covering `hero_strip`, `bullet_section`, `kpi_strip`, `trend_chart`, `members_table`, `drill_panel`, and `coming_soon_banner`. Each `widget_type` **MUST** have a JSON schema validating its `config` on save, rejecting invalid configs before commit. The frontend **MUST** render a `coming_soon_banner` placeholder when it encounters an unknown `widget_type` (e.g., a newer backend than the frontend build) instead of crashing the dashboard.

**Rationale**: DB stores pure configuration; visual contracts and schemas live in code where they can be type-checked. This matches the Grafana and Superset pattern and keeps schema migrations off the critical path for UI experiments.

**Actors**: `cpt-dash-cfg-actor-product-team`, `cpt-dash-cfg-actor-analytics-api`

#### View Types Are Fixed Code-Level Enum

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-view-types`

The system **MUST** define exactly three view types in code: `executive`, `team`, `ic`. Tenants and admins **MUST NOT** be able to add, rename, or remove view types at runtime. Dashboards **MUST** reference a `view_type` value from this enum.

**Rationale**: View type reflects a product-level decision about what data perspectives exist. Allowing tenant-defined view types would explode the configuration surface and make core routing logic unpredictable.

**Actors**: `cpt-dash-cfg-actor-product-team`

#### Per-Tenant Role Taxonomy

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-role-taxonomy`

The system **MUST** persist `role_catalog` rows per tenant, each with `role_slug`, `label_i18n_key`, and `is_enabled`. The system **MUST** allow tenant admins to add, rename, disable, and re-enable role entries. The system **MUST** ship a default taxonomy on tenant bootstrap covering at least `backend-dev`, `frontend-dev`, `fullstack-dev`, `qa`, `devops`, `engineering-manager`, `product-manager`, `designer`, and `other`; admins can extend or prune it.

**Rationale**: Different tenants care about different functional axes. One tenant cares about backend / frontend / QA distinctions; another might split by seniority (IC1 / IC2 / Staff) or by product line. The taxonomy must be editable per tenant without touching code.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`, `cpt-dash-cfg-actor-product-team`

#### Dashboards Keyed by (view_type, role)

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-dashboard-key`

The system **MUST** key dashboards on the pair `(view_type, role)` where `role` is a nullable FK to `role_catalog`. Executive-view dashboards **MUST** always have `role = null`. Team-view and IC-view dashboards **MAY** have `role = null` (default for that view type) or a specific `role` slug. A `(tenant_id, view_type, role)` combination **MUST** be unique.

**Rationale**: Two orthogonal dimensions compose the space of possible dashboards. Keying on their pair is the minimal structural expression of the requirement and enables `role = null` fallbacks per view type.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`

#### Executive View Is Role-Invariant

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-exec-role-invariant`

The system **MUST** serve a single executive dashboard per tenant regardless of the viewer's or subject's role. The `role` column on the executive dashboard row **MUST** be `null`. Attempts to create an executive dashboard with a non-null role **MUST** be rejected at the API layer.

**Rationale**: Executive view is the organization-wide rollup; the executive viewer is already abstracted above function boundaries, and personalizing it by function would harm the comparability that is its reason to exist.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`

#### Role-Aware Dashboard Resolution

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-dashboard-resolution`

The system **MUST** resolve a dashboard for a request as follows:

- **Executive view**: return the tenant's single executive dashboard (`role = null`).
- **IC view**: resolve the subject's role via Identity Resolution; return the dashboard matching `(view_type='ic', role=subject.role)`; if absent, fall back to `(view_type='ic', role=null)`.
- **Team view**: if the team has a team-lead override, return it; otherwise resolve the team's role (via either a `team.dominant_role` field or, if not set, by consulting members' roles through Identity Resolution per rule defined in DESIGN) and return the dashboard matching `(view_type='team', role=team.role)`; if absent, fall back to `(view_type='team', role=null)`.

**Rationale**: Viewers see the most specific dashboard available without the admin having to define every combination; fallback guarantees that any valid subject has a rendered dashboard.

**Actors**: `cpt-dash-cfg-actor-viewer`, `cpt-dash-cfg-actor-analytics-api`, `cpt-dash-cfg-actor-identity`

#### Role Source Is the HR `job_role` Field via Identity Resolution

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-role-source`

The system **MUST** obtain a person's role exclusively from the HR-system `job_role` attribute surfaced through Identity Resolution. The system **MUST NOT** parse, pattern-match, or infer the role from `job_title` or any other free-form field. The system **MUST NOT** query HR systems (BambooHR, Okta, Workday, Jira People) directly.

When a tenant's `job_role` field is not resolvable (either the HR source does not have it, or the connector is not configured to fetch it), the configurator **MUST** resolve that person's role as absent and fall back to the default `(view_type, role=null)` dashboard per `cpt-dash-cfg-fr-dashboard-resolution`. The system **MUST** surface the unresolved state to tenant admins via a diagnostics endpoint so onboarding gaps are visible and fixable.

**Rationale**: A structured HR field is authoritative. Pattern-matching across "Senior Backend Developer II, Cloud Platform" variants is fragile and ships a maintenance tail; delegating that responsibility to the HR administrator who already curates employee records is cleaner. Falling back silently but surfacing the gap to admins keeps the product usable during onboarding while pushing tenants to fix the source of truth.

**Actors**: `cpt-dash-cfg-actor-identity`, `cpt-dash-cfg-actor-product-team`, `cpt-dash-cfg-actor-tenant-admin`

#### Connector Wiring for `job_role`

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-connector-job-role-wiring`

For every HR connector that supports a `job_role`-equivalent attribute, the system **MUST** fetch that attribute and expose it downstream as `person.job_role`. Specifically:

- For BambooHR, when a tenant has already populated the relevant custom field in HR, the connector configuration **MUST** include the field alias in its field list so the value appears in the bronze layer and propagates through Identity Resolution. The exact alias per tenant is tracked in Open Questions.
- For other HR sources (Okta, Workday, Jira People), the equivalent connector-side wiring is part of that tenant's onboarding.

The Identity Resolution contract — both the `services/identity` service and the analytics-api client consuming it — **MUST** expose `job_role` as a first-class, optional field on the `Person` struct. Adding this field to the upstream MariaDB persons schema (open PR #214 on cyberfabric/insight) is the preferred landing point.

**Rationale**: Separating "HR has the field" from "ingestion fetches the field" keeps the onboarding checklist honest. The BambooHR connector already supports custom fields via `bamboohr_employees_custom_fields`; the outstanding work is configuration plus a `Person` struct extension, not new HR data.

**Actors**: `cpt-dash-cfg-actor-identity`, `cpt-dash-cfg-actor-product-team`

#### Role Alias Reconciliation (Per-Tenant)

- [ ] `p2` - **ID**: `cpt-dash-cfg-fr-role-alias`

The system **SHOULD** support a per-tenant alias table that maps raw HR `job_role` values to canonical `role_catalog.role_slug` values (e.g., "Backend Developer", "Backend Engineer", "BE Dev" all alias to `backend-dev`). Aliases **MUST** be editable by tenant admins and **MUST** be applied after Identity Resolution returns `person.job_role` but before dashboard lookup. Unmatched `job_role` values **MUST NOT** silently fail — they route to the default dashboard and also appear in the admin diagnostics view for manual aliasing.

**Rationale**: Even with a structured `job_role` field, tenants still have inconsistent values (different teams, historical drift, typos). A one-to-many alias table is a vastly simpler normalization layer than free-form `job_title` parsing and keeps tenant admins in control without code changes.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`

#### Team Lead Customization (Post-MVP)

- [ ] `p2` - **ID**: `cpt-dash-cfg-fr-team-lead-customization`

The system **SHOULD** allow a team lead to customize their own team's dashboard by creating a team-scoped override on top of the tenant default for `(view_type='team', role=team.role)`. Overrides **MUST** be visually distinguishable from inherited widgets in the Admin UI, **MUST** support per-widget revert to default, and **MUST NOT** propagate to other teams.

**Rationale**: Team leads know their team's specific focus better than the tenant admin; forcing every team adjustment through a central admin bottleneck will cause the configurator to be bypassed.

**Actors**: `cpt-dash-cfg-actor-team-lead`

### 5.3 Rendering

#### Single Renderer Component Handles Any Configured Dashboard

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-single-renderer`

The system **MUST** expose a `<DashboardRenderer dashboardId=... | slug=...>` React component that fetches the composition from `GET /catalog/dashboards/:slug` and renders each widget through a widget-type to React-component registry. The three existing screens (`ExecutiveViewScreen`, `TeamViewScreen`, `IcDashboardScreen`) **MUST** become thin wrappers around `<DashboardRenderer slug="...">` after migration.

**Rationale**: Every new role-based dashboard must require zero frontend code; a single renderer is the structural prerequisite.

**Actors**: `cpt-dash-cfg-actor-viewer`

#### Widgets Resolve Metadata from the Catalog

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-fe-no-metadata`

Widgets rendered by `<DashboardRenderer>` **MUST** resolve labels, units, formats, and thresholds from the Metric Catalog response (`cpt-metric-cat-interface-read`) rather than from any local frontend constant. The deletion of the duplicated frontend metadata (`BULLET_DEFS`, `IC_KPI_DEFS`, most of `METRIC_KEYS`) is a Metric Catalog rollout deliverable (`cpt-metric-cat-fr-seed-from-frontend`); this PRD's acceptance criteria assume that deletion is in place.

**Rationale**: Eliminates drift between frontend and backend. Responsibility for the deletion lives with the Metric Catalog PRD; this PRD depends on it.

**Actors**: `cpt-dash-cfg-actor-viewer`

#### Computed KPIs Become Metric Queries

- [ ] `p2` - **ID**: `cpt-dash-cfg-fr-computed-kpis`

The system **MUST** define `at_risk_count`, `focus_gte_60`, `not_using_ai`, and `team_dev_time` as `metric_query` rows that return single-row responses computed server-side. The frontend helper `deriveTeamKpis` **MUST** be deleted once the queries are live.

**Rationale**: Computed chips must be addable through the configurator without a frontend change; otherwise the configurator has a hole where every aggregation needs code.

**Actors**: `cpt-dash-cfg-actor-tenant-admin`, `cpt-dash-cfg-actor-product-team`

#### Widget Failure Isolation

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-widget-failure-isolation`

The system **MUST** render each widget independently so that a failed metric query or a rejected widget config affects only the failing widget. A failing widget **MUST** render a ComingSoon or error placeholder while other widgets continue to render normally.

**Rationale**: Viewers must not lose the entire dashboard because a single backend query is slow or a single widget has an invalid config.

**Actors**: `cpt-dash-cfg-actor-viewer`

### 5.4 Seed and Migration

#### Default Dashboards and Role Taxonomy Shipped as Seed Migration

- [ ] `p1` - **ID**: `cpt-dash-cfg-fr-seed-defaults`

The system **MUST** seed on first deploy: (a) the default role taxonomy described in `cpt-dash-cfg-fr-role-taxonomy`, (b) one executive dashboard per tenant (`role = null`), (c) one default team dashboard per tenant (`view_type='team', role=null`), and (d) one default IC dashboard per tenant (`view_type='ic', role=null`). Each default dashboard **MUST** replicate the current hardcoded equivalent view so day-one users see no visual regression. Role-specific dashboards beyond the defaults are not seeded; tenant admins create them post-rollout. Seed migrations **MUST** be idempotent so re-runs on non-empty databases do not duplicate rows.

**Rationale**: Tenants need a working dashboard out of the box for every view type even if no role-specific composition has been authored yet; idempotency prevents deployment accidents.

**Actors**: `cpt-dash-cfg-actor-product-team`

#### Existing Users Routed to Defaults on Rollout

- [ ] `p2` - **ID**: `cpt-dash-cfg-fr-rollout-routing`

The system **MUST** route every existing user on first deploy to the matching default dashboard for their requested view. No user **MUST** see a blank dashboard or an error during the migration window. Role-aware routing activates only after tenant admins begin authoring role-specific dashboards; until then, fallback to `role = null` applies to everyone.

**Rationale**: Zero-downtime rollout; day-one users see the same dashboards they saw before migration even though the backend is now DB-driven.

**Actors**: `cpt-dash-cfg-actor-product-team`, `cpt-dash-cfg-actor-viewer`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Performance — Render Latency

- [ ] `p1` - **ID**: `cpt-dash-cfg-nfr-render-latency`

Dashboard first-paint for any seeded default dashboard **MUST** remain within 10% of the current hardcoded equivalent screen's p95 load time.

**Threshold**: p95 first-paint ≤ 1.1 × baseline p95, measured at rollout against the same tenant and same period selection.

**Rationale**: DB-driven dashboards must not be a regression on the day they replace hardcoded screens.

#### Reliability — Honest Null Rendering

- [ ] `p1` - **ID**: `cpt-dash-cfg-nfr-honest-nulls`

Every widget **MUST** follow the honest-null contract when a metric value is NULL: bullets render ComingSoon in the bar slot, KPI cells render em-dash, tables render em-dash, trend charts either hide the series or render a ComingSoon placeholder. No widget renders `0`, `null%`, or `nullh` as a display value.

**Threshold**: Zero occurrences of the strings `null%`, `nullh`, `null ` (with trailing space followed by a unit) in rendered DOM for any seeded default dashboard under post-migration backend behavior (cyberfabric/insight PR #223 merged).

**Rationale**: Consistent with the honest-null program (cyberfabric/insight PRs #218, #222, #223 and cyberfabric/insight-front PR #33). Removing the three hardcoded screens must not regress this contract.

#### Backward Compatibility — Existing Routes

- [ ] `p2` - **ID**: `cpt-dash-cfg-nfr-backward-compat`

Existing routes `/executive-view`, `/team-view`, and `/ic-dashboard` **MUST** continue to resolve to the corresponding seeded default dashboards for at least one release cycle after migration, to preserve external deep links.

**Threshold**: All three routes return a rendered dashboard with HTTP 200 during the compatibility window; deprecation warning is permissible but not a redirect that breaks bookmarks.

**Rationale**: Users bookmark the three views; breaking links on migration day creates avoidable support load.

### 6.2 NFR Exclusions

- **Accessibility** (UX-PRD-002): Inherits the screenset-level accessibility posture. This PRD does not redefine a11y requirements.
- **Internationalization** (UX-PRD-003): The i18n key structure in the catalog enables localization, but delivering localized copy is scoped to the i18n program, not this PRD.
- **Multi-region** (OPS-PRD-005): Not applicable — the catalog is per-tenant and tenants are single-region today.
- **Offline support** (UX-PRD-006): Not applicable — Insight is a connected analytics tool; cached offline rendering would be meaningless for live metrics.
- **Mobile-first layout** (UX-PRD-004): Not applicable — Insight targets desktop analytics workflows; mobile is a separate product investment.

## 7. Public Library Interfaces

### 7.1 Public API Surface

This PRD owns `GET /catalog/roles` and `GET /catalog/dashboards`. `GET /catalog/metrics` is owned by the Metric Catalog PRD (`cpt-metric-cat-interface-read`) and is referenced here, not redefined.

#### GET /catalog/dashboards

- [ ] `p1` - **ID**: `cpt-dash-cfg-interface-catalog-dashboard`

**Type**: REST API

**Stability**: stable

**Description**: Returns the dashboard composition matching a request. Query parameters: `view_type` (required, one of `executive` / `team` / `ic`), `subject_id` (required for team and IC views; identifies the team or person to analyze), `team_id` (optional override for team view to distinguish team-lead customizations). Response shape: `{ dashboard: { id, view_type, role, name_i18n_key, is_published, is_override }, widgets: [{ id, widget_type, title_i18n_key, position, config }] }`. The `config` value conforms to the JSON schema registered for its `widget_type`. The server internally resolves the subject's role via Identity Resolution and applies the fallback chain per `cpt-dash-cfg-fr-dashboard-resolution`.

**Breaking Change Policy**: New `widget_type` values are additive. The frontend handles unknown `widget_type` values via `coming_soon_banner`, so backend additions are safe across frontend versions. Query parameter additions are additive; removal is a major bump.

#### GET /catalog/roles

- [ ] `p1` - **ID**: `cpt-dash-cfg-interface-catalog-roles`

**Type**: REST API

**Stability**: stable

**Description**: Returns the caller tenant's role catalog: `{ roles: [{ role_slug, label_i18n_key, is_enabled }] }`. Used by the Admin UI to populate role pickers and by the frontend to render role-related labels. Only `is_enabled = true` rows appear in admin-facing pickers; disabled roles are preserved for historical dashboards that reference them.

**Breaking Change Policy**: Field additions are non-breaking. Role slug format changes or field removal require a major bump.

### 7.2 External Integration Contracts

#### Widget React Component Contract

- [ ] `p1` - **ID**: `cpt-dash-cfg-contract-widget-component`

**Direction**: provided by library

**Protocol/Format**: React component registered against a `widget_type` discriminator with generically typed props: `type WidgetProps<T> = { config: T; tenantId: string; metricCatalog: MetricCatalog; }`. The generic parameter `T` is the widget type's config schema; mismatches fail at compile time in the frontend registry.

**Compatibility**: Widget types are deprecated at least two minor versions before removal; during that window the widget continues to render as expected.

## 8. Use Cases

### UC-001 Admin Swaps a Bullet Section Widget

**ID**: `cpt-dash-cfg-usecase-swap-widget`

**Actor**: `cpt-dash-cfg-actor-tenant-admin`

**Preconditions**: Admin has access to the Admin UI. The target dashboard exists and is unpublished or the admin has publish permission. Target metric keys are present in the tenant's catalog.

**Main Flow**:

1. Admin opens the Admin UI for the target dashboard
2. Admin selects a bullet-section widget and edits its `metric_keys` list
3. Admin clicks save; backend validates `config` against the `bullet_section` schema
4. Admin clicks publish; `is_published` flips to true
5. Viewers see the updated widget on their next dashboard load

**Postconditions**: Dashboard composition is updated and persisted. No frontend deploy was required. Non-admin viewers see the change on next request.

**Alternative Flows**:

- **Schema validation fails**: At step 3, backend rejects the save with a specific schema violation. The Admin UI highlights the invalid field. The dashboard composition is not mutated.
- **Admin loses network during save**: Save fails atomically; the dashboard is in its pre-save state.

### UC-002 Admin Adds a Role and a Role-Specific Dashboard

**ID**: `cpt-dash-cfg-usecase-new-role`

**Actor**: `cpt-dash-cfg-actor-tenant-admin`

**Preconditions**: The tenant is already using the configurator. The relevant metrics are already in the catalog. Identity Resolution can return `role_slug` for the relevant HR `job_title` values (either natively or via the mapping layer resolved in DESIGN).

**Main Flow**:

1. Admin opens the Admin UI → "Role Taxonomy" and adds a new role (e.g., `ux-designer`) with label and `is_enabled = true`
2. Admin confirms that Identity Resolution can map relevant HR job titles to the new role slug (either by reading the mapping-rule UI or by inspecting a person's resolved role via preview)
3. Admin creates a new dashboard with `(view_type='ic', role='ux-designer')` and assembles widgets
4. Admin previews the dashboard with an actual UX designer as subject
5. Admin publishes; users whose Identity Resolution role resolves to `ux-designer` see the new dashboard when opening the IC view

**Postconditions**: A new role is live in the taxonomy. A role-specific dashboard is published. No frontend code change was required.

**Alternative Flows**:

- **Role slug not returned by Identity Resolution**: Admin cannot validate preview for the new role until the mapping layer returns `ux-designer` for some HR title. Product team updates the mapping; admin retries.
- **New role requires a new widget type**: Admin cannot complete the flow; product team ships the widget type in a backend + frontend release; admin then resumes.
- **New role requires a metric query not in the catalog**: Admin requests a new query from the product team; when seeded, admin adds the widget.

### UC-003 Viewer Loads an IC Dashboard for a Person of Specific Role

**ID**: `cpt-dash-cfg-usecase-viewer-load`

**Actor**: `cpt-dash-cfg-actor-viewer`

**Preconditions**: Viewer is authenticated. Subject (the person being viewed) has an HR record accessible through Identity Resolution.

**Main Flow**:

1. Viewer navigates to `/ic-dashboard/:personId`
2. Frontend calls `GET /catalog/dashboards?view_type=ic&subject_id=:personId`
3. Backend resolves the subject's role via Identity Resolution (`subject.role_slug = 'backend-dev'`)
4. Backend returns the dashboard matching `(view_type='ic', role='backend-dev')`; if absent, returns `(view_type='ic', role=null)` as fallback
5. `<DashboardRenderer>` receives the composition JSON and renders widgets
6. For each widget, the renderer resolves `widget_type` to a registered component and starts the widget's metric query; widgets render independently

**Postconditions**: Dashboard is rendered. Viewer sees the role-appropriate composition for the subject.

**Alternative Flows**:

- **Subject's role cannot be resolved**: Identity Resolution returns no role slug (e.g., unmapped job title). Backend returns `(view_type='ic', role=null)` default dashboard; response includes a `role_resolution: 'fallback'` hint so the frontend can optionally surface a debug banner for admins.
- **Metric query fails for one widget**: That widget renders a ComingSoon placeholder or error tile; other widgets render normally.
- **Frontend is older than the backend composition**: Unknown `widget_type` renders `coming_soon_banner`; known widgets render normally.
- **Subject does not exist**: Backend returns `404`; frontend routes to a neutral error state without rendering an empty dashboard shell.

### UC-004 Team Lead Customizes Their Team Dashboard (Post-MVP)

**ID**: `cpt-dash-cfg-usecase-team-lead-customize`

**Actor**: `cpt-dash-cfg-actor-team-lead`

**Preconditions**: Team lead is authenticated with the `team-lead` permission for their team. Tenant default for `(view_type='team', role=team.role)` exists and is published.

**Main Flow**:

1. Team lead opens the team view for their team
2. Team lead clicks "Customize" on a widget; UI loads the team-specific override view
3. Team lead edits widget config (swap metric, change title, remove widget, add a new one) within the widgets library their tenant admin has authorized
4. UI visually marks overridden widgets vs inherited ones
5. Team lead saves; backend stores the override keyed by `team_id`
6. On next load for that specific team, the override applies; other teams sharing the same role are unaffected

**Postconditions**: Team-specific override exists for that team only. Tenant default for the role remains unchanged.

**Alternative Flows**:

- **Team lead reverts a widget**: Override for that widget is deleted; the widget re-inherits from the tenant default.
- **Team lead deletes all overrides**: Team falls back to tenant default cleanly.
- **Tenant default changes after team-lead override exists**: Inherited widgets reflect the change; overridden widgets stay on the override until revert.

## 9. Acceptance Criteria

- [ ] The three existing hardcoded screens (`ExecutiveViewScreen`, `TeamViewScreen`, `IcDashboardScreen`) are replaced with `<DashboardRenderer view_type="...">` wrappers without visible regression against the prior layouts for the seeded default dashboards.
- [ ] Widgets resolve labels, units, formats, and thresholds from the Metric Catalog (per `cpt-metric-cat-interface-read`); no hardcoded metric metadata is referenced by widget rendering code.
- [ ] Adding a new `widget_type` requires exactly one backend enum entry plus one frontend React component; no schema migration for `dashboard_widget` is required.
- [ ] Dashboard first-paint p95 for any seeded default dashboard is within 10% of the pre-migration baseline for the equivalent hardcoded screen.
- [ ] All four computed chips (`at_risk_count`, `focus_gte_60`, `not_using_ai`, `team_dev_time`) are served by backend metric queries; `deriveTeamKpis` is removed from the frontend.
- [ ] Existing routes `/executive-view`, `/team-view`, and `/ic-dashboard` continue to resolve to the equivalent seeded dashboards for at least one release cycle after migration.
- [ ] A widget with an invalid config or a failing metric query degrades gracefully to ComingSoon or an error placeholder without affecting sibling widgets on the same dashboard.
- [ ] The three view types (`executive`, `team`, `ic`) are the only allowed values; attempts to create a dashboard with any other `view_type` are rejected at the API.
- [ ] Every tenant has an editable role taxonomy; adding, renaming, disabling, and re-enabling role entries works through the API without a code change.
- [ ] The executive dashboard has `role = null` in every tenant; attempts to create an executive dashboard with a non-null role are rejected.
- [ ] For the IC view, the dashboard is selected based on the subject's role resolved via Identity Resolution; fallback to the default `(view_type='ic', role=null)` dashboard works when the subject's role has no tailored dashboard.
- [ ] The role source for every dashboard resolution is Identity Resolution; no direct HR-system query happens in the configurator path.
- [ ] Dashboard-scoped threshold overrides (when written) are persisted into the Metric Catalog's `metric_threshold` store with `scope = 'dashboard'` and honored by the catalog's resolution precedence (`cpt-metric-cat-fr-scoped-thresholds`).
- [ ] End users cannot add, remove, or reorder widgets on their own role-default IC dashboard; the API exposes no endpoint for per-user mutation of the role-default composition.
- [ ] The IC view rendered for a person is byte-for-byte identical regardless of whether the viewer is the person themselves, their team lead, or a VP up the chain; divergence only happens post-MVP on a separate "My View" surface if one ships.

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Metric Catalog PRD (`docs/domain/metric-catalog/specs/PRD.md`) | Owns metric metadata, tenant-scoped thresholds, `GET /catalog/metrics`; this PRD consumes the catalog and writes only dashboard-scoped threshold overrides into the catalog's `metric_threshold` store | p1 |
| MariaDB | Hosts `role_catalog`, `role_alias`, `dashboard`, `dashboard_widget` tables, plus team-scoped override tables for `cpt-dash-cfg-fr-team-lead-customization` | p1 |
| Analytics API service | Backend service implementing `/catalog/*` endpoints, dashboard resolution, and metric query resolution | p1 |
| Identity Resolution service | Existing `insight-identity-resolution` deployment; returns per-person identity records used to resolve subject role for dashboard selection | p1 |
| ClickHouse gold views (honest-null) | Source for all metric query results; cyberfabric/insight PR #223 honest-null work is a prerequisite for consistent widget null handling | p1 |
| Frontend i18n loader | Resolves `label_i18n_key`, `sublabel_i18n_key`, and role `label_i18n_key` values to display strings | p1 |
| `@hai3/react` | Component library providing widget primitives and state hooks | p1 |
| HR integrations (BambooHR, Okta, Workday, Jira People) | Raw `job_title` and `job_role` source consumed by Identity Resolution, not by the configurator directly | p1 |

## 11. Assumptions

- Tenants are single-region; the catalog does not need multi-region replication.
- HR role assignment is already managed upstream by BambooHR / Okta / Workday / Jira People; the configurator consumes role data through Identity Resolution and does not redefine role assignment.
- Each tenant's HR source exposes a structured `job_role` attribute distinct from the free-form `job_title`. When the HR field already exists, outstanding work is connector-side — adding the field alias to the HR connector's field list (e.g., `bamboohr_employees_custom_fields` or a dedicated config key) and re-syncing — not creating the HR field itself. When it does not, the cost of introducing it sits with the tenant's HR admin during Insight onboarding.
- Identity Resolution surfaces `person.job_role` as a first-class field, maintained as part of its contract with the configurator. The configurator does not parse or infer role from `job_title`. The upcoming MariaDB persons store (open PR #214 on cyberfabric/insight) is the preferred landing point for the new `job_role` column in the identity schema; this PRD should sequence its implementation after that PR merges.
- Identity Resolution is authoritative for per-person HR attributes and is reachable from the analytics-api service in all environments.
- A single backend environment serves all widgets; per-widget sharding is out of scope.
- The product team can migrate the three existing views to DB-seeded defaults within one release cycle.
- Admin UI is deferred; the initial rollout uses direct seed migrations to create defaults; role-specific dashboards are authored by tenant admins post-rollout through direct DB writes or a minimal admin-only interface outside the MVP.
- `metric_query.query_ref` stays SQL-only; widget configs never embed SQL.
- Widget JSON schemas are authored alongside their React components and shipped together.
- The existing empty `analytics.thresholds` table will be either repurposed into `metric_threshold` or dropped in the same migration; DESIGN will make this call.

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Widget JSON schema drift between frontend and backend | Admin saves invalid config; UI breaks silently or rejects valid configs | Single source of truth for schemas shared between frontend and backend; schema validation tests in CI |
| DB-driven composition slower than hardcoded | Viewer-perceived regression on migration day | Cache `GET /catalog/dashboards` per `(tenant, view_type, role)` for 5 minutes; parallel widget data fetches; baseline measurement before rollout |
| Threshold override precedence confusion | Admin cannot predict which threshold applies to a widget | Fixed precedence dashboard → tenant → kit default; tests cover each level; admin UI shows resolved value alongside source |
| Admin submits unknown `widget_type` via API | Dashboard renders with ComingSoon blocks instead of expected widgets | Server-side enum validation rejects unknown `widget_type` at save time |
| Migration from hardcoded screens introduces pixel-level regression | Users complain about visual changes | Side-by-side snapshot comparison during rollout; per-screen feature flag to fall back to the hardcoded implementation for one release |
| Metric catalog accumulates deprecated keys | Admin UI noise; confusion about which metrics are current | `is_enabled` flag hides deprecated metrics from new dashboards while preserving existing dashboards that reference them |
| Computed KPI queries materially slower than frontend derivation | Team-view chips regress on load time | Benchmark each computed-KPI query at seed time; require p95 ≤ 200ms on representative tenant data |
| HR source has the `job_role` field but the ingestion connector is not configured to fetch it | Every person in that tenant falls back to the default dashboard; role-aware behavior never activates despite the data existing upstream | Onboarding checklist includes a "connector field map verification" step — confirm the HR custom-field alias is wired into the connector secret and that the value appears on a sample person via Identity Resolution before declaring the tenant ready |
| Tenant HR source genuinely lacks the `job_role` field | Role-aware behavior cannot activate until HR creates the field | Diagnostics page lists affected users; onboarding treats this as an HR-admin task with a visible readiness gate, not a silent fallback |
| Raw HR `job_role` value drift — new values appear in the HR source without an alias entry | New employees silently fall back to default IC dashboard with no signal to admins | Admin UI surfaces a "role resolution" diagnostics page listing unmatched `job_role` values and affected users; Identity Resolution change log fires an alert when a new value appears |
| Team-lead customization sprawl (each team diverges arbitrarily) | Inconsistent experience across teams; support load for "why does my team look different" | Visual distinction between inherited and overridden widgets; per-widget revert; admin sees a list of all team overrides |
| Role taxonomy proliferates across tenants | Inconsistent product-level comparisons across tenants | Product-seeded default taxonomy ships as a baseline; tenant extensions are additive and do not affect cross-tenant rollups |
| Tenant admin disables a role that has live dashboards | Dashboards silently orphan; viewers fall back to defaults without warning | Disabling a role surfaces a confirmation listing dashboards that reference it; existing dashboards keep working on fallback with an admin-visible status |
| Future per-user customization introduced incorrectly — replacing the role-default instead of supplementing it | Breaks the comparability that makes Insight usable as a management instrument; team leads see a different dashboard than the one the IC is actually configuring against | Any personal customization lives on a separate "My View" or pinning surface; the role-default view is immutable from the user's side; design reviews enforce this invariant explicitly before any per-user feature ships |
| Users bypass the configurator by exporting data and building external dashboards | Organizational signal fragments; management loses a consistent lens | Ship a compelling role-default plus, if needed, a personal "My View" follow-up so the friction to get a decent personal view is low without breaking the official surface |

## 13. Open Questions

| Question | Owner | Target Resolution |
|----------|-------|-------------------|
| For the pilot tenant, what is the exact HR custom-field alias used for their existing `job_role` field? Answer unblocks the connector config change in the HR connector definition plus the tenant-specific connector secret. | Insight Product Team + pilot tenant's HR admin | Before backend implementation starts |
| For subsequent tenants — do the expected HR systems (BambooHR, Okta, Workday, Jira People) already surface a job-role-equivalent field, and what is it called in each one? Inventory before each new tenant onboards. | Insight Product Team | Before each new tenant onboards |
| Does Identity Resolution already expose `job_role`, or does it need a contract extension? The current `Person` struct in both `services/identity/src/people.rs` and `services/analytics-api/src/infra/identity_resolution/mod.rs` has only `job_title`. Preferred landing point: open PR #214 (MariaDB persons store) — extend its schema or follow up immediately after it merges. | Insight Product Team + PR #214 author | Before DESIGN is accepted |
| Should the BambooHR connector continue to accept `job_role` via the generic `bamboohr_employees_custom_fields` array, or should it gain a dedicated `bamboohr_job_role_field` config key (first-class config)? First-class is more discoverable; generic is less YAML churn. | Backend tech lead | Before the connector config PR |
| For the team view, how is a team's role determined — a dedicated `team.dominant_role` column, aggregation of member roles via Identity Resolution, or manual admin selection? | Insight Product Team | Before DESIGN is accepted |
| What is the minimum list of seeded roles the default tenant ships with for MVP? Candidates: `backend-dev`, `frontend-dev`, `fullstack-dev`, `qa`, `devops`, `data-engineer`, `engineering-manager`, `product-manager`, `designer`, `other`. | Insight Product Team + pilot tenant stakeholder | Before seed migration PR |
| Does the existing empty `analytics.thresholds` table get dropped, renamed, or extended into `metric_threshold`? | Backend tech lead | DESIGN phase |
| Are team-lead overrides also allowed to reference metric queries outside what the tenant admin has exposed, or are they constrained to an admin-authorized subset? | Insight Product Team | Before team-lead customization PR |
| Do tenants need a `role_groups` concept (e.g., "all engineering" spanning backend + frontend + devops), or is a flat role list sufficient for MVP? | Insight Product Team | Before admin UI PRD |
| For the admin UI (separate PRD), is CRUD handled via a dedicated admin app, or through a tenant-admin-only screen inside the main Insight app? | Insight Product Team | Before admin UI PRD kicks off |
| Post-MVP personal customization surface — should end users get (a) widget pinning, (b) a separate "My View" tab, (c) both, or (d) neither? Hard constraint regardless of the choice: the role-default IC dashboard that team leads and VPs see stays immutable from the user's perspective. | Insight Product Team | Before any per-user customization PRD |

## 14. Current-State Gap Analysis (Backend)

This section is informative, not normative. It captures the delta between today's backend code on cyberfabric/insight and what this PRD requires, so DESIGN can scope work accurately.

### Present

- `services/analytics-api` is a running Rust / Axum service with a working `/v1/metrics`, `/v1/metrics/{id}/query`, `/v1/thresholds`, `/v1/persons/{email}`, `/v1/columns` surface. SeaORM entities cover `metrics`, `thresholds`, `table_columns`. Sea-orm migrations run at service startup.
- `services/identity` reads BambooHR via the existing ingestion pipeline and exposes `/v1/persons/{email}` with a rich `Person` struct including `department`, `division`, `job_title`, `supervisor_email`, `subordinates`. Identity Resolution is already the single HR touchpoint for analytics-api.
- `ingestion/connectors/hr-directory/bamboohr/connector.yaml` supports `bamboohr_employees_custom_fields` — an opt-in per-tenant array of custom-field aliases to add to the employee fetch.
- ClickHouse gold views follow the honest-null contract (PRs #218, #222, and #223 in flight) — widgets that this PRD ships will inherit correct NULL propagation.

### Missing — MVP

- No `role_catalog`, `role_alias`, `dashboard`, `dashboard_widget` tables or SeaORM entities (this PRD's scope).
- No `metric_catalog` / `metric_threshold` tables either; these belong to the Metric Catalog PRD but are a prerequisite for this PRD's rollout.
- No `/v1/catalog/roles`, `/v1/catalog/dashboards`, or role-diagnostics endpoints (this PRD). `/v1/catalog/metrics` is owned by the Metric Catalog PRD.
- No widget-type enum, widget config JSON-schema validator, or widget-type to React-component registry. JSON-schema validation is not currently a dependency on analytics-api.
- No dashboard resolution logic (domain module that takes `(view_type, subject_id, viewer)` and returns the right composition with fallback chain).
- No `job_role` attribute anywhere — neither in the `Person` struct in `services/identity/src/people.rs` nor in the analytics-api IR client at `services/analytics-api/src/infra/identity_resolution/mod.rs`.
- No seed migrations for the default role taxonomy, the three default dashboards, or the computed-KPI metric queries that replace `deriveTeamKpis`.
- RBAC for admin-scope endpoints (tenant-admin only) is not modelled today; `auth.rs` currently authenticates but does not carry a role claim the configurator can gate on.

### Missing — Post-MVP (`p2` features)

- No `team_dashboard_override` storage or team-lead scoped authorization for the override endpoints.
- No team-scoped role authorization (no "is this user the lead of this team" predicate).

### Relevant Open Pull Requests

| PR | Relationship to this PRD |
|----|--------------------------|
| **#214 — MariaDB persons store + migration runner** (Gregory91G) | Introduces `persons` and `account_person_map` in a dedicated MariaDB `identity` database, with service-owned migrations (ADR-0006). Preferred landing point for adding the `job_role` column to the identity schema. Dashboard Configurator implementation should sequence after this PR merges. |
| **#213 — silver class_ai_dev_usage / class_ai_api_usage** (mozhaev-dev) | Adds silver tables for Claude Code / Codex / ChatGPT, which are the sources currently emitting NULL via PR #223. Merging this partially reduces the "unsourced metric" footprint before configurator seeds ship. |
| **#182 — dbt-based identity resolution** (mitasovr) | Replaces the C# BootstrapJob with a dbt pipeline for identity. The `job_role` attribute flow should be designed consistently with this pipeline, not bolted on separately. |
| #205 (Jira silver), #217 (CH 25.3 compat), #220 (ReplacingMergeTree), #204 (Bitbucket CDK) | No direct overlap with this PRD; listed here to rule out accidental coupling. |

### Implementation Sequencing (informative)

A plausible order, each step shippable in isolation:

1. Wire the relevant HR connector (e.g., BambooHR) to fetch `job_role` for the pilot tenant (connector config + per-tenant secret).
2. Extend the identity pipeline and the `Person` struct to carry `job_role`. Prefer landing in or immediately after PR #214.
3. Analytics-api: extend the IR client's `Person` struct.
4. **Metric Catalog PRD delivery** (owned by `docs/domain/metric-catalog/specs/PRD.md`): ship `metric_catalog`, `metric_threshold`, `GET /catalog/metrics`, admin CRUD on thresholds, and delete duplicated frontend metadata. This unblocks both this PRD and future consumers.
5. Analytics-api: add `role_catalog`, `role_alias` tables + `GET /catalog/roles`. Seed the default role taxonomy.
6. Analytics-api: add `dashboard`, `dashboard_widget`, widget-type enum, resolution logic, and the `/v1/catalog/dashboards` endpoint. Seed the three default dashboards and the four computed-KPI metric queries.
7. Frontend PR: replace `ExecutiveViewScreen` / `TeamViewScreen` / `IcDashboardScreen` with `<DashboardRenderer view_type="...">` wrappers; delete `deriveTeamKpis`.
8. Admin-UI PRD (separate) — CRUD surface for tenant admins.
9. Team-lead override PRD (separate, `p2`) — team-scoped customization.
