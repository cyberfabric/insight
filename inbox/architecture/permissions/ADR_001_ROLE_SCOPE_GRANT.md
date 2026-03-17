---
status: accepted
date: 2026-03-11
decision-makers: Insight Product Team
---

# ADR-001: Use Role + Explicit Scope Grant Instead of ABAC for Cross-Hierarchy Access


<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Role + Explicit Scope Grant](#role-explicit-scope-grant)
  - [Attribute-Based Access Control (ABAC)](#attribute-based-access-control-abac)
  - [RBAC-only with Global Roles](#rbac-only-with-global-roles)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

**ID**: `cpt-insightspec-adr-role-scope-grant-vs-abac`

## Context and Problem Statement

Insight collects and surfaces engineering productivity metrics scoped to organizational units. Most users access data within their natural org-hierarchy subtree (a manager sees their team and all sub-teams). However, certain functional roles — such as HR specialists — operate across org branches: an HR person sits in the HR department but legitimately needs to see metrics for the engineering departments they hire for.

How should Insight grant data visibility to users whose access requirements extend beyond their natural org-hierarchy position, without exposing the full dataset and without coupling access control to volatile business objects?

## Decision Drivers

- HR and similar functional specialists change roles, departments, and hiring responsibilities frequently — access must not outlive the assignment
- Access grants must be auditable: who granted what, when, and why
- The system must support broad functional roles (e.g., HR sees all people-metrics) as well as precise org-unit overrides (e.g., HR sees only the engineering division)
- Implementation complexity must remain manageable for the initial release
- Access control must be decoupled from analytical cohorts (functional teams used for benchmarking)

## Considered Options

1. **Role + Explicit Scope Grant** — named roles cover broad access needs; admins issue time-bounded ScopeGrants for precise cross-hierarchy overrides
2. **Attribute-Based Access Control (ABAC)** — access derived dynamically from business object attributes (e.g., `hiring_manager_id`, `recruiter_id` on open requisitions)
3. **RBAC-only with global roles** — broad roles (`global_hr`, `global_finance`) without any per-org-unit override mechanism

## Decision Outcome

Chosen option: **Role + Explicit Scope Grant**, because it satisfies the auditability requirement, handles role changes cleanly through `valid_to` expiry, supports both broad and precise access needs, and avoids coupling access control to external business objects that change independently of the permission system.

### Consequences

- Good, because every cross-hierarchy access grant is explicit, visible to admins, and carries a business justification
- Good, because access expires automatically when `valid_to` is reached — no cleanup required when an HR person changes role or leaves
- Good, because global roles (`global_hr`, `global_finance`) cover the common case without requiring per-org-unit ScopeGrants
- Good, because permission evaluation remains simple: union of (natural hierarchy scope) + (active ScopeGrants)
- Bad, because admins must proactively create and maintain ScopeGrants for cross-hierarchy access — there is no automatic derivation from business data
- Bad, because very fine-grained access patterns (e.g., "recruiter sees only candidates they personally manage") cannot be expressed without creating many individual ScopeGrants

### Confirmation

This decision is confirmed when:

- The `permissions.scope_grant` table exists and enforces `valid_to IS NOT NULL`
- PermissionManager unions natural org-scope with active ScopeGrants at evaluation time
- Admin UI exposes grant creation with mandatory `reason` and `valid_to` fields
- An integration test verifies that an HR specialist loses cross-branch access after `valid_to` passes without any manual revocation

## Pros and Cons of the Options

### Role + Explicit Scope Grant

An admin assigns a named role (e.g., `global_hr`) to the user and optionally creates one or more time-bounded `ScopeGrant` records pointing to specific `org_unit` subtrees. PermissionManager unions the user's natural org subtree with all active ScopeGrants at query time.

- Good, because grants are explicit, auditable, and time-bounded by design
- Good, because role changes are handled by revoking the role; org-unit overrides are handled by ScopeGrant expiry
- Good, because evaluation logic is straightforward: set union of permitted org unit IDs
- Neutral, because requires an admin to create grants — no automation, but also no hidden access
- Bad, because does not naturally express access derived from dynamic business relationships (e.g., "recruiter sees their own pipeline")

### Attribute-Based Access Control (ABAC)

Access is derived at runtime from attributes on business objects. For example, an HR specialist automatically sees metrics for any employee where `hiring_manager_id` matches their `person_id`, or for any `org_unit` that has an open requisition they own.

- Good, because access automatically follows business relationships without admin involvement
- Good, because supports very fine-grained, context-sensitive access patterns
- Bad, because business objects (requisitions, hiring relationships) change frequently and independently of the permission system — access derivation becomes unpredictable
- Bad, because HR roles change faster than permission systems can track: a person may retain derived access to data long after their responsibilities change, or lose access unexpectedly when a requisition closes
- Bad, because ABAC evaluation requires joining permission logic with operational business data at query time, increasing complexity and latency
- Bad, because access decisions are harder to audit — "why can this person see this data?" requires inspecting the current state of external business objects

### RBAC-only with Global Roles

Broad roles such as `global_hr` or `global_finance` grant access to all data of a given type across the entire workspace. No per-org-unit override mechanism is provided.

- Good, because extremely simple to implement and reason about
- Good, because role assignment and revocation is sufficient to manage access lifecycle
- Bad, because too coarse-grained: `global_hr` grants full people-metrics visibility even when the HR person only needs access to one division
- Bad, because violates the Least Privilege principle for most real-world HR configurations
- Bad, because offers no path to precise access scoping without introducing a new mechanism later

## More Information

The ScopeGrant mechanism is documented in [PERMISSION_DESIGN.md §3.1 Domain Model](./PERMISSION_DESIGN.md) and [§3.7 Database Schemas](./PERMISSION_DESIGN.md).

The maximum ScopeGrant duration is governed by workspace policy (default: 1 year) to prevent indefinite grants from accumulating. Workspace administrators are responsible for reviewing and renewing grants that remain legitimate beyond their expiry.

This decision does not cover authentication (AuthN) or the mechanism for token validation at the API gateway — those are addressed separately.

## Traceability

- **DESIGN**: [PERMISSION_DESIGN.md](./PERMISSION_DESIGN.md)

This decision directly addresses the following design elements:

- `cpt-insightspec-principle-least-privilege` — Role + ScopeGrant enforces least-privilege by requiring explicit grants for any access beyond the natural hierarchy
- `cpt-insightspec-principle-explicit-grants` — ScopeGrant is the concrete mechanism implementing this principle
- `cpt-insightspec-constraint-grant-time-bound` — `valid_to` requirement is a direct consequence of rejecting ABAC's dynamic derivation
- `cpt-insightspec-component-permission-manager` — implements the union evaluation logic described in this ADR
- `cpt-insightspec-component-role-registry` — manages role assignments and ScopeGrant lifecycle
