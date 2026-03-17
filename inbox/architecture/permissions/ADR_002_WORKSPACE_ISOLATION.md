---
status: accepted
date: 2026-03-11
decision-makers: Insight Product Team
---

# ADR-002: Logical Tenant Isolation via workspace_id Predicate Injection


<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Logical Isolation via `workspace_id` Predicate Injection](#logical-isolation-via-workspaceid-predicate-injection)
  - [Schema-per-tenant](#schema-per-tenant)
  - [Database-per-tenant](#database-per-tenant)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

**ID**: `cpt-insightspec-adr-workspace-isolation`

## Context and Problem Statement

Insight is a multi-tenant SaaS platform. Multiple customer organisations (workspaces) share the same data infrastructure: ClickHouse for Bronze, Silver, and Gold analytics tables; PostgreSQL/MariaDB for the identity schema and permission records. Data ingested from one workspace must never be visible to users of another workspace.

How should Insight enforce workspace-level data isolation given a shared-infrastructure architecture, without sacrificing operational simplicity or query performance?

## Decision Drivers

- ClickHouse is optimised for large shared tables with partition pruning; schema proliferation degrades operational manageability
- The number of workspaces may grow to hundreds; per-workspace infrastructure would multiply operational cost and migration complexity
- A single, enforceable enforcement point reduces the attack surface compared to distributed per-schema access controls
- Isolation failures must be detectable through automated testing, not just policy
- The identity schema and Bronze/Silver/Gold layers must use a consistent isolation strategy

## Considered Options

1. **Logical isolation via `workspace_id` predicate injection** — all data lives in shared tables; every query has a mandatory `workspace_id = ?` WHERE clause injected by DataScopeFilter before execution
2. **Schema-per-tenant** — each workspace gets its own PostgreSQL/ClickHouse schema (e.g., `ws_acme.git_commits`, `ws_globex.git_commits`); access controlled by database-level schema permissions
3. **Database-per-tenant** — each workspace gets a dedicated database instance; full physical isolation at the infrastructure level

## Decision Outcome

Chosen option: **Logical isolation via `workspace_id` predicate injection**, because it aligns with ClickHouse's partitioned table model, keeps the operational footprint constant regardless of tenant count, and concentrates isolation enforcement in a single auditable component (DataScopeFilter) that is straightforward to test.

### Consequences

- Good, because schema migrations, index management, and capacity planning apply once across all tenants rather than N times
- Good, because ClickHouse partition pruning on `workspace_id` achieves near-physical isolation performance without the operational overhead
- Good, because enforcement is centralised in DataScopeFilter — a single component to audit, test, and reason about
- Good, because adding a new workspace requires only inserting a `workspace_id` value, not provisioning infrastructure
- Bad, because a bug in DataScopeFilter that omits the `workspace_id` predicate would expose cross-tenant data — the enforcement point is a single point of failure
- Bad, because shared tables grow with tenant count; ClickHouse partition management requires deliberate sizing and retention policy per workspace
- Follow-up: DataScopeFilter must be covered by cross-tenant isolation integration tests that assert zero cross-workspace data leakage under adversarial query patterns

### Confirmation

This decision is confirmed when:

- DataScopeFilter is verified by integration tests that issue queries with workspace A credentials and assert that no records with `workspace_id = B` are returned under any tested query pattern
- A ClickHouse table design review confirms that all Bronze, Silver, and Gold tables include `workspace_id` as a partition key or primary key component
- The permission schema tables (`permissions.role_assignment`, `permissions.scope_grant`, `permissions.source_access`) all carry `workspace_id` and enforce it at the application layer

## Pros and Cons of the Options

### Logical Isolation via `workspace_id` Predicate Injection

All tenant data coexists in shared tables. DataScopeFilter (part of the permission evaluation pipeline) appends `workspace_id = ?` to every query before it reaches the data layer. The `workspace_id` value comes from the authenticated user's session context established at the API gateway.

- Good, because one schema definition, one migration path, one set of indices regardless of tenant count
- Good, because ClickHouse partition pruning on `workspace_id` provides query performance comparable to physical separation
- Good, because enforcement is a single auditable code path — easy to test exhaustively
- Good, because zero infrastructure change required to onboard a new workspace
- Neutral, because requires discipline: every new query path must go through DataScopeFilter; enforcement must be validated by automated testing
- Bad, because a missed predicate injection leaks cross-tenant data silently; requires high test coverage of DataScopeFilter

### Schema-per-tenant

Each workspace gets a dedicated database schema (e.g., `ws_acme`, `ws_globex`). Database-level permissions prevent cross-schema reads. The application connects with a per-workspace role or connection string.

- Good, because database-level access controls provide a hard enforcement boundary independent of application logic
- Good, because schema isolation is visible and auditable at the infrastructure level
- Bad, because ClickHouse has limited support for schema-level access controls; this option is primarily viable for PostgreSQL/MariaDB but not for the analytics layer
- Bad, because schema migrations must be applied N times (once per tenant); migration tooling must manage N schemas in lockstep
- Bad, because index and table statistics are per-schema; query optimiser has less data to work with for small tenants
- Bad, because adding a new tenant requires schema provisioning — a non-trivial infrastructure operation

### Database-per-tenant

Each workspace runs against a dedicated database instance. Physical isolation is complete: no shared tables, no shared connection pool, no cross-tenant risk at the data layer.

- Good, because provides the strongest possible isolation guarantee — no application-level bugs can leak cross-tenant data
- Good, because per-tenant resource quotas and SLAs are enforceable at the infrastructure level
- Bad, because ClickHouse cluster management at scale (hundreds of instances) is operationally prohibitive
- Bad, because data joining across tenants (e.g., for platform-level analytics or support tooling) requires cross-database federation
- Bad, because provisioning a new tenant requires standing up a new database instance — minutes to hours of lead time
- Bad, because multiplies infrastructure cost linearly with tenant count

## More Information

The `workspace_id` predicate injection is implemented by DataScopeFilter (see [PERMISSION_DESIGN.md §3.2](./PERMISSION_DESIGN.md)). DataScopeFilter receives a resolved `PermissionScope` from PermissionManager and emits SQL predicates; `workspace_id = ?` is always the first and unconditional predicate in that set.

The Bronze layer (ClickHouse) and the identity schema (PostgreSQL/MariaDB) both carry `workspace_id`. The identity schema uses `workspace_id` as a scoping key on all permission tables; Bronze and Silver tables use it as a partition key component to enable efficient pruning.

Cross-tenant isolation tests must be part of the continuous integration suite and must gate every release.

## Traceability

- **PRD**: [PRD.md](./PRD.md)
- **DESIGN**: [PERMISSION_DESIGN.md](./PERMISSION_DESIGN.md)

This decision directly addresses the following requirements and design elements:

- `cpt-insightspec-nfr-tenant-isolation` — defines the zero-leaks requirement this ADR satisfies
- `cpt-insightspec-fr-predicate-injection` — the functional requirement for mandatory predicate injection at the data layer
- `cpt-insightspec-constraint-tenant-isolation` — the design constraint that workspace_id injection is non-negotiable
- `cpt-insightspec-component-data-scope-filter` — the component that implements the predicate injection mechanism chosen in this ADR
