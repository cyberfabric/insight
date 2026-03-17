# PRD — Permission Architecture

<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background-problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
    - [Workspace Administrator](#workspace-administrator)
    - [Manager](#manager)
    - [Functional Specialist](#functional-specialist)
    - [End User](#end-user)
  - [2.2 System Actors](#22-system-actors)
    - [Permission Service](#permission-service)
    - [Identity Manager](#identity-manager)
- [3. Operational Concept & Environment](#3-operational-concept-environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Role Management](#51-role-management)
    - [Role Assignment](#role-assignment)
    - [Role Revocation](#role-revocation)
  - [5.2 Org-Hierarchy Data Scoping](#52-org-hierarchy-data-scoping)
    - [Natural Subtree Visibility](#natural-subtree-visibility)
    - [Predicate Injection](#predicate-injection)
  - [5.3 Cross-Hierarchy Access (ScopeGrants)](#53-cross-hierarchy-access-scopegrants)
    - [ScopeGrant Creation](#scopegrant-creation)
    - [ScopeGrant Evaluation](#scopegrant-evaluation)
    - [ScopeGrant Revocation](#scopegrant-revocation)
    - [ScopeGrant Automatic Expiry](#scopegrant-automatic-expiry)
  - [5.4 Source-Domain Access Control](#54-source-domain-access-control)
    - [SourceAccess Grant](#sourceaccess-grant)
    - [Source-Domain Predicate Enforcement](#source-domain-predicate-enforcement)
  - [5.5 Audit](#55-audit)
    - [Permission Change Audit Log](#permission-change-audit-log)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
    - [Tenant Isolation](#tenant-isolation)
    - [Permission Evaluation Latency](#permission-evaluation-latency)
    - [Auditability](#auditability)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
    - [AuthZ Evaluation API](#authz-evaluation-api)
    - [Permission Admin API](#permission-admin-api)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
    - [Identity Manager Contract](#identity-manager-contract)
- [8. Use Cases](#8-use-cases)
    - [Grant Cross-Department Access to HR Specialist](#grant-cross-department-access-to-hr-specialist)
    - [Access Expires Automatically](#access-expires-automatically)
    - [Manager Views Team Metrics](#manager-views-team-metrics)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Permission Architecture module defines and enforces how data access is controlled across the Insight platform. It determines what each authenticated user is allowed to see — which metrics, which org units, and which data source domains — and enforces those boundaries at query time across all Silver and Gold data layers.

The module delivers three core capabilities: role-based access control (RBAC) for broad permission categories, org-hierarchy-based data scoping so that each user sees their own subtree by default, and explicit time-bounded ScopeGrants for users whose legitimate access extends beyond their natural org position.

### 1.2 Background / Problem Statement

Insight aggregates sensitive productivity metrics from many sources — git activity, HR data, communication patterns, CRM records — across the entire organizational hierarchy of a customer. Without a coherent permission model, all authenticated users would see the same data, which violates both customer data governance expectations and basic security principles.

The primary pain points driving this module are:

- Managers must see their team's metrics but not those of peer teams or unrelated departments
- Functional specialists such as HR need to view metrics outside their org branch (e.g., the engineering department they hire for) without being granted access to the entire company
- Certain data source domains (e.g., Allure test results, HubSpot CRM data) are sensitive and should only be visible to users whose role explicitly covers them
- Access granted to a person for a particular purpose must expire automatically when that purpose ends — relying on manual revocation leads to permission debt

### 1.3 Goals (Business Outcomes)

- Workspace administrators can configure and audit all access grants without engineering involvement
- No user can access data outside their permitted scope regardless of how they query the system
- Cross-hierarchy access for functional roles (HR, Finance) is operational within minutes of admin grant creation and expires automatically at the configured date
- Every access grant is traceable: who granted it, when, and why

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Workspace | Top-level tenant boundary; all data and permissions are scoped within a workspace |
| OrgNode | A unit in the org hierarchy: Company, Division, Department, Team, or Person |
| Role | A named permission set assigned to a user within a workspace (e.g., `manager`, `global_hr`) |
| ScopeGrant | An explicit, time-bounded grant that extends a user's data visibility to an org subtree outside their natural position |
| SourceAccess | An explicit grant allowing a user to access data from a specific source domain (e.g., Allure, HubSpot) |
| Natural org scope | The set of OrgNodes a user sees by default: their own node and all descendant nodes |
| Permission debt | Accumulated access grants that outlive their business justification due to lack of expiry enforcement |

## 2. Actors

### 2.1 Human Actors

#### Workspace Administrator

**ID**: `cpt-insightspec-actor-workspace-admin`

**Role**: Manages all roles, ScopeGrants, and SourceAccess records within a workspace. The sole actor authorized to create or revoke cross-hierarchy grants.

**Needs**: A clear, auditable interface to assign roles, create time-bounded ScopeGrants, and review the current access state for any user.

---

#### Manager

**ID**: `cpt-insightspec-actor-manager`

**Role**: An authenticated user who needs to view metrics for their direct and indirect reports. Occupies a node in the org hierarchy and by default sees all data at or below that node.

**Needs**: Access to metrics for their entire org subtree without requiring manual grants; no visibility into peer teams or parent data beyond their own node.

---

#### Functional Specialist

**ID**: `cpt-insightspec-actor-functional-specialist`

**Role**: An authenticated user (e.g., HR, Finance) who occupies a node in a support or functional department but legitimately needs access to metrics in other org branches as part of their job function.

**Needs**: Access to specific org-unit subtrees outside their natural position, granted explicitly by a workspace admin with a defined expiry date.

---

#### End User

**ID**: `cpt-insightspec-actor-end-user`

**Role**: An authenticated user with a standard member or viewer role. Sees only data within their own org subtree and any explicitly granted source domains.

**Needs**: Self-service access to their own metrics; no ability to escalate their own permissions.

### 2.2 System Actors

#### Permission Service

**ID**: `cpt-insightspec-actor-permission-service`

**Role**: Internal service that evaluates the resolved PermissionScope for each request. Called by the API gateway before every data query; injects SQL predicates via DataScopeFilter.

---

#### Identity Manager

**ID**: `cpt-insightspec-actor-identity-manager`

**Role**: External system (defined in IDENTITY_RESOLUTION_V3) that provides the canonical org hierarchy (`identity.org_unit`) and person assignments (`identity.person_assignment`). Read-only dependency for the permission module.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- The permission module reads `identity.org_unit` and `identity.person_assignment` from the Identity Manager; it must tolerate eventual consistency in org-structure updates (org changes propagate within minutes, not milliseconds)
- ScopeGrant expiry evaluation is time-based; the system clock must be consistent across all permission evaluation nodes

## 4. Scope

### 4.1 In Scope

- Role assignment and management for workspace users
- Org-hierarchy-based data scoping (natural subtree visibility)
- Explicit ScopeGrant creation, expiry, and revocation
- Source-domain access control (SourceAccess grants)
- Permission evaluation at query time via SQL predicate injection
- Audit log for all permission changes (grant created, revoked, expired)
- Automatic access expiry when ScopeGrant `valid_to` is reached

### 4.2 Out of Scope

- Authentication (AuthN) — token validation and session management are handled at the API gateway level
- User interface for permission management (admin UI is a separate deliverable)
- Analytical cohort management (functional teams used for benchmarking) — governed by FunctionalTeamManager, independent of access control
- Row-level access control within a single OrgNode's data (all members of a permitted OrgNode see the same data)
- Attribute-based access control (ABAC) derived from external business objects (see ADR-001)

## 5. Functional Requirements

### 5.1 Role Management

#### Role Assignment

- [ ] `p1` - **ID**: `cpt-insightspec-fr-role-assignment`

The system **MUST** allow workspace administrators to assign a role to any user within the workspace. Supported roles are: `workspace_admin`, `manager`, `member`, `viewer`, `global_hr`, `global_finance`.

**Rationale**: Role is the primary dimension of access control; without it, no per-user differentiation is possible.

**Actors**: `cpt-insightspec-actor-workspace-admin`

---

#### Role Revocation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-role-revocation`

The system **MUST** allow workspace administrators to revoke a role from any user. Revocation MUST take effect on the next permission evaluation request with no caching delay exceeding 60 seconds.

**Rationale**: Timely revocation is critical when a user changes job function or leaves the organisation.

**Actors**: `cpt-insightspec-actor-workspace-admin`

### 5.2 Org-Hierarchy Data Scoping

#### Natural Subtree Visibility

- [ ] `p1` - **ID**: `cpt-insightspec-fr-subtree-visibility`

The system **MUST** automatically scope each user's data access to their natural org position: the user's own OrgNode and all descendant OrgNodes in the hierarchy. No additional configuration is required for this default behaviour.

**Rationale**: The fundamental access model for Insight; managers see their team, executives see their division.

**Actors**: `cpt-insightspec-actor-manager`, `cpt-insightspec-actor-end-user`

---

#### Predicate Injection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-predicate-injection`

The system **MUST** enforce visibility by injecting SQL predicates (`workspace_id`, `org_unit_id IN (...)`) into every Silver and Gold data query. Filtering MUST occur at the data layer, not in application code after retrieval.

**Rationale**: Post-retrieval filtering is error-prone and risks over-fetching sensitive data.

**Actors**: `cpt-insightspec-actor-permission-service`

### 5.3 Cross-Hierarchy Access (ScopeGrants)

#### ScopeGrant Creation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-scope-grant-creation`

The system **MUST** allow workspace administrators to create a ScopeGrant that extends a named user's data visibility to a specific OrgNode subtree. Every ScopeGrant **MUST** include: `grantee_person_id`, `org_unit_id`, `valid_from`, `valid_to`, `granted_by`, and `reason`. Grants without `valid_to` **MUST** be rejected.

**Rationale**: Explicit, time-bounded grants prevent permission debt and ensure all cross-hierarchy access is intentional and auditable.

**Actors**: `cpt-insightspec-actor-workspace-admin`

---

#### ScopeGrant Evaluation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-scope-grant-evaluation`

The system **MUST** include all active ScopeGrants (where `valid_from <= now() <= valid_to`) in the resolved PermissionScope for a user. The granted org subtrees **MUST** be unioned with the user's natural org scope when generating SQL predicates.

**Rationale**: Cross-hierarchy access must be seamlessly integrated into the same query-time enforcement path.

**Actors**: `cpt-insightspec-actor-permission-service`, `cpt-insightspec-actor-functional-specialist`

---

#### ScopeGrant Revocation

- [ ] `p1` - **ID**: `cpt-insightspec-fr-scope-grant-revocation`

The system **MUST** allow workspace administrators to revoke a ScopeGrant before its `valid_to` date. Revocation **MUST** take effect within 60 seconds.

**Rationale**: Business relationships that justified a grant may end before the original expiry date.

**Actors**: `cpt-insightspec-actor-workspace-admin`

---

#### ScopeGrant Automatic Expiry

- [ ] `p1` - **ID**: `cpt-insightspec-fr-scope-grant-expiry`

The system **MUST** automatically stop including a ScopeGrant in PermissionScope evaluation once `valid_to` has passed. No manual action is required to enforce expiry.

**Rationale**: Eliminates permission debt caused by personnel changes; access lapses automatically when the grant period ends.

**Actors**: `cpt-insightspec-actor-permission-service`

### 5.4 Source-Domain Access Control

#### SourceAccess Grant

- [ ] `p1` - **ID**: `cpt-insightspec-fr-source-access-grant`

The system **MUST** allow workspace administrators to grant a user access to a specific source domain (e.g., `allure`, `hubspot`, `salesforce`). By default, users have no source-domain access beyond what their role provides.

**Rationale**: Certain data sources contain information restricted to specific job functions (e.g., test results to QA, CRM data to Sales).

**Actors**: `cpt-insightspec-actor-workspace-admin`

---

#### Source-Domain Predicate Enforcement

- [ ] `p1` - **ID**: `cpt-insightspec-fr-source-domain-enforcement`

The system **MUST** filter queries against source-domain-restricted data by the requesting user's active SourceAccess records. Users without an active SourceAccess grant for a given domain **MUST NOT** receive any data from that domain.

**Actors**: `cpt-insightspec-actor-permission-service`

### 5.5 Audit

#### Permission Change Audit Log

- [ ] `p1` - **ID**: `cpt-insightspec-fr-audit-log`

The system **MUST** record an immutable audit log entry for every permission change: role assignment, role revocation, ScopeGrant creation, ScopeGrant revocation, ScopeGrant expiry, SourceAccess grant, and SourceAccess revocation. Each entry **MUST** include: `actor_person_id`, `action_type`, `target_person_id`, `change_details`, `timestamp`.

**Rationale**: Regulatory and governance requirements demand that all access changes are traceable. Administrators must be able to answer "who had access to what and when?"

**Actors**: `cpt-insightspec-actor-workspace-admin`, `cpt-insightspec-actor-permission-service`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Tenant Isolation

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-tenant-isolation`

The system **MUST** enforce workspace-level isolation such that no query against Silver or Gold data can return records belonging to a different workspace. `workspace_id` predicate injection is mandatory on every data request.

**Threshold**: Zero cross-tenant data leaks under any query pattern.

**Rationale**: Multi-tenant data isolation is a foundational security requirement; any leak constitutes a critical vulnerability.

---

#### Permission Evaluation Latency

- [ ] `p2` - **ID**: `cpt-insightspec-nfr-query-performance`

The permission evaluation path (PermissionManager + DataScopeFilter) **MUST** add no more than 50ms to p95 query latency under normal load.

**Threshold**: ≤ 50ms added latency at p95, measured from permission evaluation start to predicate injection complete.

**Rationale**: Insight dashboards are expected to respond within 500ms; permission overhead must not become the bottleneck.

**Verification Method**: Load test with realistic concurrent user count and org hierarchy depth.

---

#### Auditability

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-auditability`

Every permission grant and revocation event **MUST** be queryable from the audit log within 5 seconds of occurrence. Audit records **MUST** be immutable after creation.

**Threshold**: 100% of permission changes appear in audit log; zero deletions or modifications to existing records.

**Rationale**: Compliance and incident investigation depend on a complete and tamper-proof audit trail.

### 6.2 NFR Exclusions

- **Accessibility** (UX): Not applicable — permission management is an admin-only backend capability with no end-user UI in this scope
- **Internationalisation**: Not applicable — permission system has no user-facing text in this scope

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### AuthZ Evaluation API

- [ ] `p1` - **ID**: `cpt-insightspec-interface-authz-evaluation`

**Type**: Internal REST API

**Stability**: stable

**Description**: Accepts `(person_id, workspace_id)` and returns a resolved PermissionScope. Called by the API gateway before every data query.

**Breaking Change Policy**: Any change to the PermissionScope response schema requires a versioned endpoint.

---

#### Permission Admin API

- [ ] `p2` - **ID**: `cpt-insightspec-interface-permission-admin`

**Type**: Internal REST API

**Stability**: stable

**Description**: CRUD operations for role assignments, ScopeGrants, and SourceAccess records. Used by the workspace admin UI and automation tooling.

**Breaking Change Policy**: Major version bump required for breaking changes.

### 7.2 External Integration Contracts

#### Identity Manager Contract

- [ ] `p1` - **ID**: `cpt-insightspec-contract-identity-manager`

**Direction**: Required from Identity Manager

**Protocol/Format**: Read-only SQL access to `identity.org_unit` and `identity.person_assignment`

**Compatibility**: Permission module assumes SCD Type 2 semantics on `person_assignment` (as defined in IDENTITY_RESOLUTION_V3 §6.4)

## 8. Use Cases

#### Grant Cross-Department Access to HR Specialist

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-grant-hr-scope`

**Actor**: `cpt-insightspec-actor-workspace-admin`

**Preconditions**:
- HR specialist exists as a canonical person in the workspace
- Target org unit (e.g., Engineering division) exists in `identity.org_unit`
- Admin is authenticated with `workspace_admin` role

**Main Flow**:
1. Admin selects the HR specialist from the user list
2. Admin creates a ScopeGrant: target org unit = Engineering, `valid_from` = today, `valid_to` = 12 months from today, reason = "Recruiting for backend and platform roles"
3. System validates that `valid_to` is set and is in the future
4. System persists the ScopeGrant and records an audit log entry
5. HR specialist's next data query includes Engineering subtree data

**Postconditions**: HR specialist can view metrics for the Engineering org subtree until `valid_to`; audit log entry exists.

**Alternative Flows**:
- **Missing `valid_to`**: System rejects the grant with a validation error
- **Admin lacks `workspace_admin` role**: System returns 403

---

#### Access Expires Automatically

- [ ] `p2` - **ID**: `cpt-insightspec-usecase-grant-expiry`

**Actor**: `cpt-insightspec-actor-permission-service`

**Preconditions**:
- An active ScopeGrant exists with `valid_to` in the past

**Main Flow**:
1. HR specialist submits a data query
2. PermissionManager retrieves active grants (where `valid_from <= now() <= valid_to`)
3. Expired ScopeGrant is not included in the active set
4. DataScopeFilter generates predicates based on natural org scope only
5. Query returns data scoped to HR specialist's natural org subtree only

**Postconditions**: HR specialist can no longer see Engineering data; no admin action was required.

---

#### Manager Views Team Metrics

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-manager-views-team`

**Actor**: `cpt-insightspec-actor-manager`

**Preconditions**:
- Manager is authenticated
- Manager is assigned to an OrgNode in `identity.org_unit`

**Main Flow**:
1. Manager opens a team metrics dashboard
2. API gateway calls PermissionManager with `(manager_person_id, workspace_id)`
3. OrgTreeService returns the manager's OrgNode and all descendant OrgNode IDs
4. DataScopeFilter injects `workspace_id = ? AND org_unit_id IN (...)` into the query
5. Dashboard displays metrics for manager's team and all sub-teams

**Postconditions**: Manager sees metrics for their full reporting subtree; no data from peer teams is returned.

## 9. Acceptance Criteria

- [ ] A user with no explicit grants cannot access data outside their natural org subtree
- [ ] A ScopeGrant with `valid_to` in the past grants no access — automatically, without manual revocation
- [ ] A query from workspace A returns zero records belonging to workspace B under any conditions
- [ ] Every role change and grant event produces an immutable audit log entry within 5 seconds
- [ ] Permission evaluation adds ≤ 50ms to p95 query latency under load test conditions
- [ ] A user with no SourceAccess for `hubspot` receives no HubSpot data, even if they have broad org scope

## 10. Dependencies

| Dependency | Description | Criticality |
|---|---|---|
| Identity Manager (IDENTITY_RESOLUTION_V3) | Provides `identity.org_unit` hierarchy and `identity.person_assignment` records | p1 |
| Gold / Silver Query Layer | Must support SQL predicate injection from DataScopeFilter | p1 |
| Workspace / Tenant Registry | Provides canonical `workspace_id` per authenticated session | p1 |

## 11. Assumptions

- The org hierarchy in `identity.org_unit` is kept up to date by HR connectors; the permission module does not need to handle real-time org changes within a single request
- Workspace administrators are trusted actors; the system does not validate the business justification in ScopeGrant `reason` fields beyond requiring non-empty text
- A user belongs to exactly one primary OrgNode at any given time (multiple assignments are possible but one is designated primary for scope resolution)

## 12. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Admin grant accumulation | Permissions accumulate over time as ScopeGrants are created but not reviewed | Dashboard showing all active grants with expiry dates; default max grant duration of 1 year |
| Overly broad global roles | `global_hr` grants full people-metrics visibility — may be too wide for some orgs | Support role + ScopeGrant combination; allow `global_hr` to be scoped to specific divisions in a future iteration |
| Org hierarchy lag | Permission scoping reflects org structure as of last HR sync; recent reorgs may cause brief misalignment | Document eventual consistency contract; HR sync runs at least every 4 hours |
| Identity resolution gaps | Users not yet resolved to a canonical `person_id` have no effective org scope | Unresolved users receive zero data access until identity resolution completes |
